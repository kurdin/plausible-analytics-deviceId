defmodule PlausibleWeb.Api.ExternalStatsController.QueryActiveUsersTest do
  use PlausibleWeb.ConnCase

  setup [:create_user, :create_site, :create_api_key, :use_api_key]

  setup %{site: site} do
    populate_stats(site, [
      build(:pageview, user_id: 1, timestamp: ~N[2021-01-01 10:00:00]),
      build(:pageview, user_id: 2, timestamp: ~N[2021-01-02 10:00:00]),
      build(:pageview, user_id: 1, timestamp: ~N[2021-01-05 10:00:00])
    ])

    :ok
  end

  test "returns dau, wau and mau over a 7 day range", %{conn: conn, site: site} do
    conn =
      post(conn, "/api/v2/query", %{
        "site_id" => site.domain,
        "metrics" => ["dau", "wau", "mau"],
        "date_range" => ["2021-01-01", "2021-01-07"]
      })

    # as of 2021-01-07: nobody that day, users 1 and 2 within 7 and 30 days
    assert json_response(conn, 200)["results"] == [%{"dimensions" => [], "metrics" => [0, 2, 2]}]
  end

  test "returns a daily series", %{conn: conn, site: site} do
    conn =
      post(conn, "/api/v2/query", %{
        "site_id" => site.domain,
        "metrics" => ["mau"],
        "date_range" => ["2021-01-01", "2021-01-03"],
        "dimensions" => ["time:day"]
      })

    assert json_response(conn, 200)["results"] == [
             %{"dimensions" => ["2021-01-01"], "metrics" => [1]},
             %{"dimensions" => ["2021-01-02"], "metrics" => [2]},
             %{"dimensions" => ["2021-01-03"], "metrics" => [2]}
           ]
  end

  test "rejects other metrics in the same query", %{conn: conn, site: site} do
    conn =
      post(conn, "/api/v2/query", %{
        "site_id" => site.domain,
        "metrics" => ["visitors", "mau"],
        "date_range" => "7d"
      })

    assert json_response(conn, 400)["error"] =~ "cannot be queried together with other metrics"
  end

  test "rejects non-time dimensions", %{conn: conn, site: site} do
    conn =
      post(conn, "/api/v2/query", %{
        "site_id" => site.domain,
        "metrics" => ["mau"],
        "date_range" => "7d",
        "dimensions" => ["visit:source"]
      })

    assert json_response(conn, 400)["error"] =~ "time:day"
  end
end
