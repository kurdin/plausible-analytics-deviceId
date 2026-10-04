# Persistent visitor tracking (fork of Plausible CE)

This fork adds **opt-in** persistent visitor identification on top of upstream
Plausible. With it, unique visitors are deduplicated across days instead of
being reset by the daily salt rotation.

| `ENABLE_PERSISTENT_TRACKING` | How `user_id` is derived |
| --- | --- |
| `false` (default) | Upstream: `SipHash(daily_salt, UA + IP + domain + root_domain)`. Daily rotation, no changes. |
| `true`, event has `deviceId` prop | **Tier 1**: `SipHash(key, "device:" + site_id + ":" + deviceId)` |
| `true`, no `deviceId` prop | **Tier 2**: `SipHash(key, "fp:" + site_id + ":" + UA + IP)` |

`key` is derived from `PERSISTENT_SALT_SECRET`. `user_id` stays a `UInt64` in
the same ClickHouse column, so there are no schema changes. Implementation:
`lib/plausible/ingestion/persistent_id.ex`, wired into
`lib/plausible/ingestion/event.ex` (`put_user_id/2`, `register_session/2`).

## Why no query changes

Plausible doesn't add up daily unique counts. Every visitor metric is
`uniq(user_id)` over the selected range, or per bucket for charts
(`lib/plausible/stats/sql/expression.ex`). Upstream's multi-day visitor counts
are inflated only because `user_id` changes every day. With a stable
`user_id`, the same queries return:

* **headline** (e.g. last 7 days): visitors deduplicated across the whole range;
* **daily chart**: each day's own unique visitors.

Historical data degrades gracefully. Events recorded before the flag was
turned on keep their daily-salted ids, so they count as before. Imported
(Google Analytics/CSV) data has no user ids and is still summed per day, as
upstream does.

## Active users: DAU, WAU, MAU

With persistent tracking on, the dashboard shows three extra tiles: **Daily,
Weekly and Monthly active users**. They are also available in the Stats API
as the metrics `dau`, `wau` and `mau`.

* **DAU** = unique visitors on the day. **WAU** = unique visitors in the 7 days
  ending on the day. **MAU** = the same over 30 days (rolling windows).
* Without a time dimension (dashboard tiles), the value is the one on the last
  day of the selected range, or today if the range extends past today (e.g.
  "This month"). With `time:day` you get a daily series. With `time:week` /
  `time:month`, the value on each bucket's last day. The generic `time`
  dimension isn't supported. Only the windows of the reported days are
  computed, so a tile for "All time" only scans the last 30 days.
* Windows reach back before the selected range. MAU for the 1st of a month
  counts visitors from the 29 days before it.
* Approximate (ClickHouse `uniq`, typically within 1–2%), consistent with
  "Unique visitors".
* Rules: they can't be combined with other metrics in one API query (the
  dashboard sends them as a separate request), they don't use imported data,
  and they aren't available for realtime or hourly views.
* **Accuracy depends on persistent tracking.** Days tracked with daily
  rotating ids count a returning visitor once per day. The app records when
  persistent tracking was switched on (table `persistent_tracking_periods`,
  written at boot). Results whose windows reach back before that carry a
  `persistent_tracking_partial` warning (`meta.metric_warnings`), shown as
  `*` on the tiles. Only the windows of the reported days count, and days
  before the site's first native stats don't. If you enabled tracking before this feature existed, set
  `PERSISTENT_TRACKING_SINCE=YYYY-MM-DD`.

```sh
curl -sS http://localhost:8000/api/v2/query -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"site_id":"example.com","metrics":["dau","wau","mau"],"date_range":"30d"}'

curl -sS http://localhost:8000/api/v2/query -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"site_id":"example.com","metrics":["mau"],"date_range":"90d","dimensions":["time:day"]}'
```

Implementation: `lib/plausible/stats/sql/active_users.ex` (per-day
`uniqState(user_id)` over the range widened by 29 days, fanned out with
`ARRAY JOIN range(0, 30)` and merged per window), and
`lib/plausible/ingestion/persistent_id/periods.ex`.

## Configuration

```env
ENABLE_PERSISTENT_TRACKING=true
PERSISTENT_SALT_SECRET=<openssl rand -base64 48>     # >= 16 bytes, keep it stable
# PERSISTENT_TRACKING_DEVICE_ID_PROP=deviceId         # optional, prop name to read
```

The app refuses to boot when the flag is on and the secret is missing or too
short. Changing the secret later makes every visitor look new.

## Sending a device id

Send the id as a custom property on **every** event, pageviews included. An
event without it falls back to Tier 2, which produces a different id for the
same browser. The prop is also stored as a regular custom property, so it
shows up in the Properties report and is subject to the 30-prop limit.

```js
// npm @plausible-analytics/tracker or the site snippet's init() options
plausible.init({
  customProperties: { deviceId: getOrCreateDeviceId() }
})
```

Privacy: Tier 1 needs a client-side identifier (cookie/localStorage/app id),
and Tier 2 is a persistent cookieless fingerprint. Both are a departure from
upstream Plausible's privacy model, so check your GDPR/ePrivacy obligations
before enabling them.

## Running

For a full install / upgrade / rollback guide (including migrating an old
v2.0 Docker install without data loss), see
[deployment.md in kurdin/community-edition](https://github.com/kurdin/community-edition/blob/claude/determined-cerf-dqrxgj/deployment.md).

```sh
cp plausible-conf.env.example plausible-conf.env   # edit BASE_URL, secrets
docker compose up -d --build
```

The compose file uses the same service and volume names as
`plausible/community-edition`. Volume names are prefixed with the Compose
project name, which is the directory name by default. To reuse an existing
install's volumes, set `COMPOSE_PROJECT_NAME=<old project>` in `.env`, and
`POSTGRES_VERSION=14` if its Postgres volume was created with 14.

## Verifying

```sh
# 0. Register a site for example.com in the dashboard first.

# 1. Track the same deviceId from two different IPs / user agents
for ip in 1.1.1.1 2.2.2.2; do
  curl -sS -X POST http://localhost:8000/api/event \
    -H 'Content-Type: application/json' \
    -H "User-Agent: Mozilla/5.0 test-$ip" -H "X-Forwarded-For: $ip" \
    -d '{"name":"pageview","url":"http://example.com/","domain":"example.com","props":{"deviceId":"dev-123"}}'
done

# 2. Both events share one user_id (events are flushed to ClickHouse every ~5s)
sleep 6
docker compose exec plausible_events_db clickhouse-client -q \
  "SELECT user_id, count() FROM plausible_events_db.events_v2 GROUP BY user_id"

# 3. Simulate visits on earlier days by copying the last hour's events and
#    sessions with backdated timestamps (/api/event can't backdate)
for d in 1 3 5; do
  docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q "
    INSERT INTO events_v2
    SELECT * REPLACE (timestamp - INTERVAL $d DAY AS timestamp)
    FROM events_v2 WHERE timestamp > now() - INTERVAL 1 HOUR"
  docker compose exec plausible_events_db clickhouse-client -d plausible_events_db -q "
    INSERT INTO sessions_v2
    SELECT * REPLACE (start - INTERVAL $d DAY AS start, timestamp - INTERVAL $d DAY AS timestamp)
    FROM sessions_v2 WHERE timestamp > now() - INTERVAL 1 HOUR"
done

# 4. 7-day query (6 days ago .. today): visitors == 1, pageviews == 8
#    Needs a Stats API key from Account settings > API keys.
RANGE="[\"$(date -u -d '-6 days' +%F)\", \"$(date -u +%F)\"]"
curl -sS http://localhost:8000/api/v2/query -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"site_id\":\"example.com\",\"metrics\":[\"visitors\",\"pageviews\"],\"date_range\":$RANGE}"

#    Per day: 1 visitor on each of the 4 days that have data
curl -sS http://localhost:8000/api/v2/query -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"site_id\":\"example.com\",\"metrics\":[\"visitors\"],\"date_range\":$RANGE,\"dimensions\":[\"time:day\"]}"
```

The automated equivalents run the real ingestion pipeline with salt rotation
between days:

```sh
mix test test/plausible/ingestion/persistent_id_test.exs \
         test/plausible/ingestion/persistent_tracking_test.exs
```
