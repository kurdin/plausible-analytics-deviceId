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
    open = open_period()

    cond do
      PersistentId.enabled?() and is_nil(open) ->
        Repo.insert!(%__MODULE__{started_at: now})
        Logger.info("Persistent tracking enabled, recording period start at #{now}")
        :started

      not PersistentId.enabled?() and not is_nil(open) ->
        open |> Ecto.Changeset.change(ended_at: now) |> Repo.update!()
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
        [%{started_at: DateTime.new!(since, ~T[00:00:00], "Etc/UTC"), ended_at: nil} | recorded]

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

  defp open_period() do
    from(p in __MODULE__, where: is_nil(p.ended_at), order_by: [desc: p.started_at], limit: 1)
    |> Repo.one()
  end

  defp config(), do: Application.get_env(:plausible, PersistentId, [])
end
