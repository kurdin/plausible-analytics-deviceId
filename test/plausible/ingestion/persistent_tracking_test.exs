defmodule Plausible.Ingestion.PersistentTrackingTest do
  @moduledoc """
  End-to-end checks for ENABLE_PERSISTENT_TRACKING: events go through the real
  ingestion pipeline (including daily salt rotation) into ClickHouse and are
  then read back with the regular stats query engine.
  """
  use Plausible.DataCase, async: false

  import Phoenix.ConnTest

  alias Plausible.Ingestion.{Event, PersistentId, Request}
  alias Plausible.Stats
  alias Plausible.Stats.{ParsedQueryParams, QueryBuilder}

  @secret "test-persistent-salt-secret-0123456789"

  @days [~N[2025-03-03 10:00:00], ~N[2025-03-04 11:00:00], ~N[2025-03-06 09:30:00]]

  setup do
    original = Application.get_env(:plausible, PersistentId)
    on_exit(fn -> Application.put_env(:plausible, PersistentId, original) end)

    {:ok, site: new_site()}
  end

  defp enable_persistent_tracking(opts \\ []) do
    Application.put_env(
      :plausible,
      PersistentId,
      Keyword.merge([enabled: true, secret: @secret, device_id_prop: "deviceId"], opts)
    )
  end

  defp track(site, now, opts) do
    payload =
      %{name: "pageview", url: "http://#{site.domain}/", domain: site.domain}
      |> then(fn payload ->
        if props = opts[:props], do: Map.put(payload, :props, props), else: payload
      end)

    conn =
      build_conn(:post, "/api/event", payload)
      |> Plug.Conn.put_req_header("user-agent", Keyword.get(opts, :user_agent, "Mozilla/5.0"))
      |> Plug.Conn.put_req_header("x-plausible-ip", Keyword.get(opts, :ip, "1.2.3.4"))

    {:ok, request, _conn} = Request.build(conn, now)
    {:ok, %{buffered: [event], dropped: []}} = Event.build_and_buffer(request)

    event
  end

  # Simulates one visit per day, with the daily salt rotating in between.
  defp track_daily_visits(site, opts_per_day) do
    events =
      @days
      |> Enum.zip(opts_per_day)
      |> Enum.map(fn {now, opts} ->
        event = track(site, now, opts)
        :ok = Plausible.Session.Salts.rotate()
        event
      end)

    Plausible.Session.WriteBuffer.flush()
    Plausible.Event.WriteBuffer.flush()

    events
  end

  defp query(site, dimensions) do
    {:ok, query} =
      QueryBuilder.build(site, %ParsedQueryParams{
        metrics: [:visitors, :visits, :pageviews],
        input_date_range: {:date_range, ~D[2025-03-01], ~D[2025-03-07]},
        dimensions: dimensions
      })

    %Stats.QueryResult{results: results} = Stats.query(site, query)
    results
  end

  describe "ENABLE_PERSISTENT_TRACKING=true" do
    setup do
      enable_persistent_tracking()
    end

    test "same deviceId over several days is 1 unique visitor in a 7-day query", %{site: site} do
      events =
        track_daily_visits(site, [
          [props: %{deviceId: "device-1"}, ip: "1.1.1.1", user_agent: "Mozilla/5.0 A"],
          [props: %{deviceId: "device-1"}, ip: "2.2.2.2", user_agent: "Mozilla/5.0 B"],
          [props: %{deviceId: "device-1"}, ip: "3.3.3.3", user_agent: "Mozilla/5.0 C"]
        ])

      assert [user_id] = events |> Enum.map(& &1.clickhouse_event.user_id) |> Enum.uniq()
      assert is_integer(user_id)

      assert query(site, []) == [%{dimensions: [], metrics: [1, 3, 3]}]

      assert query(site, ["time:day"]) == [
               %{dimensions: ["2025-03-03"], metrics: [1, 1, 1]},
               %{dimensions: ["2025-03-04"], metrics: [1, 1, 1]},
               %{dimensions: ["2025-03-06"], metrics: [1, 1, 1]}
             ]
    end

    test "deviceId is kept as a regular custom property", %{site: site} do
      event = track(site, hd(@days), props: %{deviceId: "device-1"})

      assert event.clickhouse_event."meta.key" == ["deviceId"]
      assert event.clickhouse_event."meta.value" == ["device-1"]
    end

    test "honours PERSISTENT_TRACKING_DEVICE_ID_PROP", %{site: site} do
      enable_persistent_tracking(device_id_prop: "visitor_uid")

      events =
        track_daily_visits(site, [
          [props: %{visitor_uid: "u-1"}, ip: "1.1.1.1"],
          [props: %{visitor_uid: "u-1"}, ip: "2.2.2.2"],
          [props: %{visitor_uid: "u-1"}, ip: "3.3.3.3"]
        ])

      assert [_] = events |> Enum.map(& &1.clickhouse_event.user_id) |> Enum.uniq()
      assert [%{metrics: [1, 3, 3]}] = query(site, [])
    end

    test "without deviceId, the persistent salt keeps IP+UA visitors stable across days",
         %{site: site} do
      track_daily_visits(site, [[], [], []])

      assert query(site, []) == [%{dimensions: [], metrics: [1, 3, 3]}]
    end

    test "different devices stay distinct visitors", %{site: site} do
      track_daily_visits(site, [
        [props: %{deviceId: "device-1"}],
        [props: %{deviceId: "device-2"}],
        [props: %{deviceId: "device-1"}]
      ])

      assert query(site, []) == [%{dimensions: [], metrics: [2, 3, 3]}]
    end
  end

  describe "ENABLE_PERSISTENT_TRACKING=false (upstream behaviour)" do
    setup do
      enable_persistent_tracking(enabled: false)
    end

    test "daily salt rotation still yields a new visitor every day, deviceId is ignored",
         %{site: site} do
      events =
        track_daily_visits(site, [
          [props: %{deviceId: "device-1"}],
          [props: %{deviceId: "device-1"}],
          [props: %{deviceId: "device-1"}]
        ])

      assert events |> Enum.map(& &1.clickhouse_event.user_id) |> Enum.uniq() |> length() == 3
      assert query(site, []) == [%{dimensions: [], metrics: [3, 3, 3]}]
    end
  end
end
