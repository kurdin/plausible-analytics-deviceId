defmodule Plausible.Stats.QueryActiveUsersTest do
  use Plausible.DataCase
  alias Plausible.Stats
  alias Plausible.Stats.{ParsedQueryParams, QueryBuilder, QueryInclude, QueryResult}

  setup [:create_user, :create_site]

  # Timeline (UTC site):
  #   user 3: 2020-12-20                (only inside the 30-day MAU window)
  #   user 1: 2021-01-01, 2021-01-03, 2021-01-09  (page /a)
  #   user 2: 2021-01-02                            (page /b)
  defp populate_timeline(site) do
    populate_stats(site, [
      build(:pageview, user_id: 3, pathname: "/b", timestamp: ~N[2020-12-20 10:00:00]),
      build(:pageview, user_id: 1, pathname: "/a", timestamp: ~N[2021-01-01 10:00:00]),
      build(:pageview, user_id: 2, pathname: "/b", timestamp: ~N[2021-01-02 10:00:00]),
      build(:pageview, user_id: 1, pathname: "/a", timestamp: ~N[2021-01-03 10:00:00]),
      build(:pageview, user_id: 1, pathname: "/a", timestamp: ~N[2021-01-03 11:00:00]),
      build(:pageview, user_id: 1, pathname: "/a", timestamp: ~N[2021-01-09 10:00:00])
    ])
  end

  defp query(site, params) do
    params =
      Map.merge(
        %{
          metrics: [:dau, :wau, :mau],
          input_date_range: {:date_range, ~D[2021-01-01], ~D[2021-01-10]}
        },
        Map.new(params)
      )

    QueryBuilder.build(site, struct!(ParsedQueryParams, params))
  end

  describe "rolling values" do
    test "per day, including days without events and windows before the range", %{site: site} do
      populate_timeline(site)

      {:ok, query} = query(site, dimensions: ["time:day"])
      %QueryResult{results: results} = Stats.query(site, query)

      assert results == [
               %{dimensions: ["2021-01-01"], metrics: [1, 1, 2]},
               %{dimensions: ["2021-01-02"], metrics: [1, 2, 3]},
               %{dimensions: ["2021-01-03"], metrics: [1, 2, 3]},
               %{dimensions: ["2021-01-04"], metrics: [0, 2, 3]},
               %{dimensions: ["2021-01-05"], metrics: [0, 2, 3]},
               %{dimensions: ["2021-01-06"], metrics: [0, 2, 3]},
               %{dimensions: ["2021-01-07"], metrics: [0, 2, 3]},
               %{dimensions: ["2021-01-08"], metrics: [0, 2, 3]},
               %{dimensions: ["2021-01-09"], metrics: [1, 1, 3]},
               %{dimensions: ["2021-01-10"], metrics: [0, 1, 3]}
             ]
    end

    test "without dimensions: value on the last day of the range", %{site: site} do
      populate_timeline(site)

      {:ok, query} = query(site, [])
      %QueryResult{results: results} = Stats.query(site, query)

      assert results == [%{dimensions: [], metrics: [0, 1, 3]}]
    end

    test "a single metric", %{site: site} do
      populate_timeline(site)

      {:ok, query} = query(site, metrics: [:mau])
      %QueryResult{results: results} = Stats.query(site, query)

      assert results == [%{dimensions: [], metrics: [3]}]
    end

    test "time:week: value on the last day of each week bucket", %{site: site} do
      populate_timeline(site)

      {:ok, query} = query(site, dimensions: ["time:week"])
      %QueryResult{results: results} = Stats.query(site, query)

      # 2021-01-01 is a Friday: first bucket is Jan 1-3, then Jan 4-10
      assert results == [
               %{dimensions: ["2021-01-01"], metrics: [1, 2, 3]},
               %{dimensions: ["2021-01-04"], metrics: [0, 1, 3]}
             ]
    end

    test "time:month", %{site: site} do
      populate_timeline(site)

      {:ok, query} = query(site, dimensions: ["time:month"])
      %QueryResult{results: results} = Stats.query(site, query)

      assert results == [%{dimensions: ["2021-01-01"], metrics: [0, 1, 3]}]
    end

    test "filters apply to the whole window", %{site: site} do
      populate_timeline(site)

      {:ok, query} = query(site, filters: [[:is, "event:page", ["/a"]]], dimensions: ["time:day"])
      %QueryResult{results: results} = Stats.query(site, query)

      assert Enum.at(results, 1) == %{dimensions: ["2021-01-02"], metrics: [0, 1, 1]}
      assert List.last(results) == %{dimensions: ["2021-01-10"], metrics: [0, 1, 1]}
    end

    test "no users at all", %{site: site} do
      {:ok, query} = query(site, [])
      %QueryResult{results: results} = Stats.query(site, query)

      assert results == [%{dimensions: [], metrics: [0, 0, 0]}]
    end

    test "comparison with the previous period", %{site: site} do
      populate_timeline(site)

      {:ok, query} = query(site, include: %QueryInclude{compare: :previous_period})
      %QueryResult{results: results} = Stats.query(site, query)

      # previous period 2020-12-22..2020-12-31, last day 12-31: only user 3 within 30 days
      assert results == [
               %{
                 dimensions: [],
                 metrics: [0, 1, 3],
                 comparison: %{dimensions: [], metrics: [0, 0, 1], change: [0, 100, 200]}
               }
             ]
    end
  end

  describe "validation" do
    test "can't be combined with other metrics", %{site: site} do
      assert {:error, error} = query(site, metrics: [:visitors, :mau])
      assert error.message =~ "cannot be queried together with other metrics"
    end

    test "only time:day/week/month dimensions", %{site: site} do
      assert {:error, error} = query(site, dimensions: ["visit:source"])
      assert error.message =~ "time:day"

      assert {:error, _} = query(site, dimensions: ["time:hour"])
      assert {:error, _} = query(site, dimensions: ["time"])
    end

    test "only one time dimension", %{site: site} do
      assert {:error, error} = query(site, dimensions: ["time:day", "time:week"])
      assert error.message =~ "one `time:day`"
    end

    test "not for realtime", %{site: site} do
      assert {:error, error} = query(site, input_date_range: :realtime)
      assert error.message =~ "realtime"
    end
  end

  describe "imported data" do
    setup :create_site_import

    test "imports are skipped with the unsupported query warning", %{
      site: site,
      site_import: site_import
    } do
      populate_stats(site, site_import.id, [
        build(:pageview, user_id: 1, timestamp: ~N[2021-01-10 10:00:00]),
        build(:imported_visitors, visitors: 50, date: ~D[2021-01-05])
      ])

      {:ok, query} = query(site, include: %QueryInclude{imports: true})
      %QueryResult{results: results, meta: meta} = Stats.query(site, query)

      assert results == [%{dimensions: [], metrics: [1, 1, 1]}]
      refute meta[:imports_included]
      assert meta[:imports_warning] == QueryResult.imports_warnings()[:unsupported_query]
    end
  end

  describe "persistent tracking warning" do
    defp tracking_since(datetime) do
      Repo.insert!(%Plausible.Ingestion.PersistentId.Periods{started_at: datetime})
    end

    test "warns when the reported windows reach back before persistent tracking", %{site: site} do
      populate_timeline(site)
      tracking_since(~U[2021-01-05 00:00:00Z])

      # no dimensions: only the windows ending on 2021-01-10 matter
      {:ok, query} = query(site, [])
      %QueryResult{meta: meta} = Stats.query(site, query)

      assert %{code: :persistent_tracking_partial, message: message} =
               meta[:metric_warnings][:mau]

      assert message =~ "enabled on 2021-01-05"
      # WAU window 2021-01-04..10 starts one day too early
      assert meta[:metric_warnings][:wau]
      # DAU of 2021-01-10 is fully covered
      refute meta[:metric_warnings][:dau]
    end

    test "a daily series warns from the first reported day", %{site: site} do
      populate_timeline(site)
      tracking_since(~U[2021-01-05 00:00:00Z])

      {:ok, query} = query(site, dimensions: ["time:day"])
      %QueryResult{meta: meta} = Stats.query(site, query)

      # DAU of 2021-01-01..04 was tracked with rotating ids
      assert meta[:metric_warnings][:dau]
    end

    test "no warning when all windows are covered", %{site: site} do
      populate_timeline(site)
      tracking_since(~U[2020-11-01 00:00:00Z])

      {:ok, query} = query(site, [])
      %QueryResult{meta: meta} = Stats.query(site, query)

      refute meta[:metric_warnings][:mau]
      refute meta[:metric_warnings][:dau]
    end

    test "each metric only needs its own window to be covered", %{site: site} do
      populate_timeline(site)
      # reported day 2021-01-10: WAU window starts 2021-01-04, MAU window 2020-12-12
      tracking_since(~U[2020-12-26 00:00:00Z])

      {:ok, query} = query(site, [])
      %QueryResult{meta: meta} = Stats.query(site, query)

      refute meta[:metric_warnings][:dau]
      refute meta[:metric_warnings][:wau]
      assert meta[:metric_warnings][:mau]
    end

    test "days before the site's native stats start don't count", %{site: site} do
      site =
        site
        |> Ecto.Changeset.change(native_stats_start_at: ~N[2021-01-06 00:00:00])
        |> Repo.update!()

      populate_timeline(site)
      tracking_since(~U[2021-01-05 00:00:00Z])

      {:ok, query} = query(site, [])
      %QueryResult{meta: meta} = Stats.query(site, query)

      refute meta[:metric_warnings][:mau]
      refute meta[:metric_warnings][:wau]
    end
  end
end
