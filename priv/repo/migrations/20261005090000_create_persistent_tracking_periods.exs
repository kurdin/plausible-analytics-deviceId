defmodule Plausible.Repo.Migrations.CreatePersistentTrackingPeriods do
  use Ecto.Migration

  # Records when ENABLE_PERSISTENT_TRACKING was on, so active user metrics
  # (dau/wau/mau) can warn about windows that include days with daily
  # rotating visitor ids. See Plausible.Ingestion.PersistentId.Periods.
  def change do
    create table(:persistent_tracking_periods) do
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime

      timestamps()
    end
  end
end
