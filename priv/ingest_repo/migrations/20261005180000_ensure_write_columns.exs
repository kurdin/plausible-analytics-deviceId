defmodule Plausible.IngestRepo.Migrations.EnsureWriteColumns do
  @moduledoc """
  Adds columns the app writes to events_v2 / sessions_v2 if they are missing.

  Some self-hosted installs have the migrations that add these columns
  recorded as applied while their tables lack them, e.g. after the v1 -> v2
  NumericIDs data migration dropped and recreated events_v2. Every insert then
  fails with "No such column ...", although the app answers 202.
  `ADD COLUMN IF NOT EXISTS` only changes metadata and is a no-op for tables
  that already have the column.
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
