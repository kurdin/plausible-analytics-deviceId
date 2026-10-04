defmodule Plausible.Repo.Migrations.PersistentTrackingPeriodsSingleOpen do
  use Ecto.Migration

  # At most one open (ended_at IS NULL) persistent tracking period, so app
  # nodes booting at the same time can't record duplicates.
  def change do
    create unique_index(:persistent_tracking_periods, ["(ended_at IS NULL)"],
             where: "ended_at IS NULL",
             name: :persistent_tracking_periods_single_open_index
           )
  end
end
