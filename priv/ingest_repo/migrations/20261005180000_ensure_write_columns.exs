defmodule Plausible.IngestRepo.Migrations.EnsureWriteColumns do
  @moduledoc """
  Adds columns the app writes to events_v2 / sessions_v2 if they are missing.

  Some self-hosted installs have the migrations that add these columns
  recorded as applied while their tables lack them, e.g. after the v1 -> v2
  NumericIDs data migration dropped and recreated events_v2. Every insert then
  fails with "No such column ...", although the app answers 202.
  `ADD COLUMN IF NOT EXISTS` only changes metadata and is a no-op for tables
  that already have the column.

  The same data migration recreated sessions_v2 without the minmax_timestamp
  index (MinmaxIndexSessionTimestamp), so it's added and built here too when
  missing. Without it, queries only read more data.
  """
  use Ecto.Migration

  import Plausible.MigrationUtils

  @events_columns [
    {"revenue_source_amount", "Nullable(Decimal64(3))"},
    {"revenue_source_currency", "FixedString(3)"},
    {"revenue_reporting_amount", "Nullable(Decimal64(3))"},
    {"revenue_reporting_currency", "FixedString(3)"},
    {"scroll_depth", "UInt8"},
    {"engagement_time", "UInt32"},
    {"click_id_param", "LowCardinality(String)"}
  ]

  @sessions_columns [
    {"click_id_param", "LowCardinality(String)"},
    {"exit_page_hostname", "String CODEC(ZSTD(3))"},
    {"transferred_from", "String"}
  ]

  def up do
    add_missing("events_v2", @events_columns)
    add_missing("sessions_v2", @sessions_columns)

    unless sessions_index_exists?() do
      execute """
      ALTER TABLE sessions_v2
      #{on_cluster_statement("sessions_v2")}
      ADD INDEX IF NOT EXISTS minmax_timestamp timestamp TYPE minmax GRANULARITY 1
      """

      execute """
      ALTER TABLE sessions_v2
      MATERIALIZE INDEX minmax_timestamp
      """
    end
  end

  defp sessions_index_exists?() do
    %{rows: [[count]]} =
      repo().query!("""
      SELECT count() FROM system.data_skipping_indices
      WHERE database = currentDatabase() AND table = 'sessions_v2' AND name = 'minmax_timestamp'
      """)

    count > 0
  end

  def down, do: :ok

  defp add_missing(table, columns) do
    additions =
      Enum.map_join(columns, ",\n  ", fn {name, type} ->
        "ADD COLUMN IF NOT EXISTS #{name} #{type}"
      end)

    execute """
    ALTER TABLE #{table}
    #{on_cluster_statement(table)}
      #{additions}
    """
  end
end
