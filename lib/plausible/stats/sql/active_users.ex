defmodule Plausible.Stats.SQL.ActiveUsers do
  @moduledoc """
  Builds the query for the rolling active user metrics:

    * `dau` - unique users on the day
    * `wau` - unique users in the 7 days ending on the day
    * `mau` - unique users in the 30 days ending on the day

  These are only meaningful across days when visitor ids are stable, i.e.
  with `ENABLE_PERSISTENT_TRACKING=true` (see `Plausible.Ingestion.PersistentId`).

  The values for a day depend on up to 29 days *before* it, so they can't be
  computed from the events in the queried range alone. Instead:

    1. A per-day `uniqState(user_id)` is computed over the range widened by
       29 days, by running the regular query builder (so all filters, joins
       and site/timezone handling are reused) with the internal
       `:user_id_state` metric and a `time:day` dimension.
    2. Each day's state is fanned out to the 30 days it contributes to
       (`ARRAY JOIN range(0, 30)`). The states of each target day are then
       merged with `uniqMergeIf`, per window size.
    3. The target days are bucketed to the query's time dimension. For a week
       or month, or with no time dimension, the value is the one on the last
       day of the bucket or range.

  Queries with these metrics may only contain these metrics (see
  `Plausible.Stats.QueryBuilder`), so the rolling query drives the result rows.
  That way a day without any events still reports its WAU and MAU.
  """

  use Plausible.Stats.SQL.Fragments

  import Ecto.Query

  alias Plausible.Stats.{DateTimeRange, Query, SQL}

  @metrics [:dau, :wau, :mau]
  @window_days 30

  def metrics(), do: @metrics

  @doc "Number of days (ending on the day itself) each metric looks at."
  def window_days(:dau), do: 1
  def window_days(:wau), do: 7
  def window_days(:mau), do: @window_days

  def active_users_query?(%Query{metrics: [_ | _] = metrics}),
    do: Enum.all?(metrics, &(&1 in @metrics))

  def active_users_query?(_query), do: false

  def build(%Query{} = query, site) do
    date_range = Query.date_range(query, trim_trailing: true)
    reported = reported_days(query.dimensions, date_range)

    query
    |> per_day_states_query(first_reported_day(reported), site)
    |> rolling_query(reported)
    |> bucket(query, date_range)
  end

  @doc """
  First and last day whose values the query reports. Each metric's windows
  span from `first - (window_days - 1)` to `last`.
  """
  @spec reported_day_bounds(Query.t()) :: {Date.t(), Date.t()}
  def reported_day_bounds(%Query{} = query) do
    date_range = Query.date_range(query, trim_trailing: true)
    reported = reported_days(query.dimensions, date_range)

    {first_reported_day(reported), date_range.last}
  end

  # The days whose rolling values are returned:
  #   time:day -> every day in the range
  #   time:week / time:month -> the last day of each bucket (or the range)
  #   no dimension -> the last day of the range
  # Only these are computed, so e.g. a dashboard tile for "All time" scans
  # just the last 30 days.
  defp reported_days(["time:day"], date_range), do: {:range, date_range.first, date_range.last}
  defp reported_days([], date_range), do: {:days, [date_range.last]}

  defp reported_days(["time:week"], date_range),
    do: {:days, bucket_ends(date_range, &(Date.day_of_week(&1) == 7))}

  defp reported_days(["time:month"], date_range),
    do: {:days, bucket_ends(date_range, &(&1 == Date.end_of_month(&1)))}

  defp bucket_ends(date_range, last_day_of_bucket?) do
    date_range
    |> Enum.filter(last_day_of_bucket?)
    |> Enum.concat([date_range.last])
    |> Enum.uniq()
  end

  defp first_reported_day({:range, first, _last}), do: first
  defp first_reported_day({:days, [first | _]}), do: first

  # Per-day uniqState(user_id) from 29 days before the first reported day.
  defp per_day_states_query(query, first_reported_day, site) do
    states_range =
      DateTimeRange.new!(
        Date.add(first_reported_day, -(@window_days - 1)),
        query.utc_time_range.last,
        query.timezone
      )
      |> DateTimeRange.to_timezone("Etc/UTC")

    states_query =
      Query.set(query,
        metrics: [:user_id_state],
        dimensions: ["time:day"],
        utc_time_range: states_range,
        include_imported: false,
        order_by: [],
        pagination: nil,
        sample_threshold: :no_sampling,
        include: struct!(query.include, total_rows: false)
      )

    SQL.QueryBuilder.build(states_query, site)
  end

  defp rolling_query(states_q, reported) do
    from(s in subquery(states_q),
      # keep in sync with @window_days
      join: offset in fragment("range(0, 30)"),
      hints: "ARRAY",
      on: true,
      where: ^reported_days_condition(reported),
      group_by: fragment("? + ?", s.time, offset),
      select: %{
        target_day: fragment("? + ?", s.time, offset),
        dau: fragment("uniqMergeIf(?, ? = 0)", s.user_id_state, offset),
        wau: fragment("uniqMergeIf(?, ? < 7)", s.user_id_state, offset),
        mau: fragment("uniqMerge(?)", s.user_id_state)
      }
    )
  end

  defp reported_days_condition({:range, first, last}) do
    dynamic(
      [s, offset],
      fragment("? + ?", s.time, offset) >= ^first and fragment("? + ?", s.time, offset) <= ^last
    )
  end

  defp reported_days_condition({:days, days}) do
    dynamic(
      [s, offset],
      fragment("has(?, ? + ?)", type(^days, {:array, :date}), s.time, offset)
    )
  end

  defp bucket(rolling_q, query, date_range) do
    case query.dimensions do
      ["time:day"] ->
        from(r in subquery(rolling_q), select: %{})
        |> select_merge_as([r], %{time: r.target_day})
        |> select_metrics(query, :per_day)

      ["time:week"] ->
        from(r in subquery(rolling_q), select: %{})
        |> select_merge_as([r], %{time: weekstart_not_before(r.target_day, ^date_range.first)})
        |> group_by([], selected_as(:time))
        |> select_metrics(query, :last_in_bucket)

      ["time:month"] ->
        from(r in subquery(rolling_q), select: %{})
        |> select_merge_as([r], %{time: fragment("toStartOfMonth(?)", r.target_day)})
        |> group_by([], selected_as(:time))
        |> select_metrics(query, :last_in_bucket)

      [] ->
        from(r in subquery(rolling_q), select: %{})
        |> select_metrics(query, :last_in_bucket)
    end
  end

  defp select_metrics(q, query, :per_day) do
    Enum.reduce(query.metrics, q, fn metric, q ->
      select_merge_as(q, [r], %{metric => field(r, ^metric)})
    end)
  end

  # argMax over an empty set returns 0, so a range without any users yields 0
  defp select_metrics(q, query, :last_in_bucket) do
    Enum.reduce(query.metrics, q, fn metric, q ->
      select_merge_as(q, [r], %{
        metric => fragment("argMax(?, ?)", field(r, ^metric), r.target_day)
      })
    end)
  end
end
