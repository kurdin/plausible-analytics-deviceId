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

```sh
cp plausible-conf.env.example plausible-conf.env   # edit BASE_URL, secrets
docker compose up -d --build
```

The compose file uses the same service and volume names as
`plausible/community-edition`, so existing data volumes can be reused. Volumes
created with Postgres 14 need `POSTGRES_VERSION=14`, or a dump/restore before
upgrading.

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

# 2. Both events share one user_id
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
