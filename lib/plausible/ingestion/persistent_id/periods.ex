defmodule Plausible.Ingestion.PersistentId.Periods do
  @moduledoc """
  Keeps track of the periods during which persistent tracking
  (`ENABLE_PERSISTENT_TRACKING`) was enabled.

  Visitor ids are only stable across days within these periods. Outside of
  them, ids rotate daily, so rolling active user metrics (WAU, MAU) that look
  back into such days count returning visitors more than once. The stats
  layer uses `coverage/3` to attach a warning to those results.

  `record_boot/1` runs once when the application starts:

    * enabled, and no open period: a period starts now
    * disabled, and a period is open: that period ends now

  Installs that enabled persistent tracking before periods were recorded can
  set `PERSISTENT_TRACKING_SINCE=YYYY-MM-DD`. It counts as a period starting
  at that date (UTC) that is still open.
  """

  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Plausible.Ingestion.PersistentId
  alias Plausible.Repo

  @type period() :: %{started_at: DateTime.t(), ended_at: DateTime.t() | nil}

  schema "persistent_tracking_periods" do
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    timestamps()
  end

  @doc "Records the start or end of a period depending on the current config."
  @spec record_boot(DateTime.t()) :: :started | :ended | :unchanged | :error
  def record_boot(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    open? = Repo.exists?(open_periods())

    cond do
      PersistentId.enabled?() and not open? ->
        # The unique index on open periods makes concurrent boots (several
        # nodes) insert at most one open period.
        Repo.insert!(%__MODULE__{started_at: now}, on_conflict: :nothing)
        Logger.info("Persistent tracking enabled, recording period start at #{now}")
        :started

      not PersistentId.enabled?() and open? ->
        Repo.update_all(open_periods(), set: [ended_at: now, updated_at: DateTime.to_naive(now)])
        Logger.info("Persistent tracking disabled, recording period end at #{now}")
        :ended

      true ->
        :unchanged
    end
  rescue
    e ->
      Logger.error("Could not record persistent tracking period: #{Exception.message(e)}")
      :error
  end

  @doc "All known periods, including the configured `PERSISTENT_TRACKING_SINCE`."
  @spec list() :: [period()]
  def list() do
    recorded =
      from(p in __MODULE__,
        order_by: [asc: p.started_at],
        select: %{started_at: p.started_at, ended_at: p.ended_at}
      )
      |> Repo.all()

    case Keyword.get(config(), :since) do
      %Date{} = since ->
        # Covers the time before periods were recorded: it lasts until the
        # first recorded period, so later off/on gaps still show up.
        ended_at =
          case recorded do
            [first | _] -> first.started_at
            [] -> nil
          end

        [
          %{started_at: DateTime.new!(since, ~T[00:00:00], "Etc/UTC"), ended_at: ended_at}
          | recorded
        ]

      _ ->
        recorded
    end
  end

  @doc """
  Checks whether `[from, to]` lies entirely within the given periods.

  Returns `%{covered: boolean, since: DateTime.t() | nil}`, where `since` is
  the start of the period that contains `to`, or `nil` if none does.
  """
  @spec coverage([period()], DateTime.t(), DateTime.t()) :: %{
          covered: boolean(),
          since: DateTime.t() | nil
        }
  def coverage(periods, from, to) do
    periods = Enum.sort_by(periods, & &1.started_at, DateTime)

    reached =
      Enum.reduce_while(periods, from, fn period, cursor ->
        cond do
          DateTime.after?(period.started_at, cursor) -> {:halt, cursor}
          is_nil(period.ended_at) -> {:halt, :open_ended}
          DateTime.after?(period.ended_at, cursor) -> {:cont, period.ended_at}
          true -> {:cont, cursor}
        end
      end)

    covered =
      case reached do
        :open_ended -> true
        cursor -> not DateTime.before?(cursor, to)
      end

    since =
      periods
      |> Enum.filter(fn p ->
        not DateTime.after?(p.started_at, to) and
          (is_nil(p.ended_at) or not DateTime.before?(p.ended_at, to))
      end)
      |> Enum.map(& &1.started_at)
      |> Enum.max(DateTime, fn -> nil end)

    %{covered: covered, since: since}
  end

  defp open_periods() do
    from(p in __MODULE__, where: is_nil(p.ended_at))
  end

  defp config(), do: Application.get_env(:plausible, PersistentId, [])
end
