defmodule Plausible.Ingestion.PersistentId.PeriodsTest do
  use Plausible.DataCase, async: false

  alias Plausible.Ingestion.PersistentId
  alias Plausible.Ingestion.PersistentId.Periods

  setup do
    original = Application.get_env(:plausible, PersistentId)
    on_exit(fn -> Application.put_env(:plausible, PersistentId, original) end)
    :ok
  end

  defp put_config(opts) do
    Application.put_env(
      :plausible,
      PersistentId,
      Keyword.merge(Application.get_env(:plausible, PersistentId), opts)
    )
  end

  describe "record_boot/1" do
    test "starts a period when enabled, ends it when disabled" do
      put_config(enabled: true, secret: "test-persistent-salt-secret-0123456789")

      assert Periods.record_boot(~U[2026-01-01 10:00:00Z]) == :started
      assert Periods.record_boot(~U[2026-01-02 10:00:00Z]) == :unchanged

      put_config(enabled: false)
      assert Periods.record_boot(~U[2026-01-03 10:00:00Z]) == :ended
      assert Periods.record_boot(~U[2026-01-04 10:00:00Z]) == :unchanged

      assert [%{started_at: ~U[2026-01-01 10:00:00Z], ended_at: ~U[2026-01-03 10:00:00Z]}] =
               Periods.list()
    end

    test "closes every open period when disabled" do
      Repo.insert!(%Periods{started_at: ~U[2026-01-01 00:00:00Z]})
      put_config(enabled: false)

      assert Periods.record_boot(~U[2026-01-03 10:00:00Z]) == :ended
      assert Enum.all?(Periods.list(), &(&1.ended_at == ~U[2026-01-03 10:00:00Z]))
    end

    test "only one open period can exist" do
      Repo.insert!(%Periods{started_at: ~U[2026-01-01 00:00:00Z]})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Periods{started_at: ~U[2026-01-02 00:00:00Z]})
      end
    end

    test "PERSISTENT_TRACKING_SINCE is stored as an open period on an enabled first boot" do
      put_config(
        enabled: true,
        secret: "test-persistent-salt-secret-0123456789",
        since: ~D[2025-06-01]
      )

      assert Periods.record_boot(~U[2026-01-01 10:00:00Z]) == :started
      assert Periods.record_boot(~U[2026-01-02 10:00:00Z]) == :unchanged
      assert Periods.list() == [%{started_at: ~U[2025-06-01 00:00:00Z], ended_at: nil}]

      put_config(enabled: false)
      assert Periods.record_boot(~U[2026-01-03 10:00:00Z]) == :ended

      assert Periods.list() == [
               %{started_at: ~U[2025-06-01 00:00:00Z], ended_at: ~U[2026-01-03 10:00:00Z]}
             ]
    end

    test "PERSISTENT_TRACKING_SINCE is closed on a disabled first boot" do
      put_config(enabled: false, since: ~D[2025-06-01])

      assert Periods.record_boot(~U[2026-01-01 10:00:00Z]) == :ended
      assert Periods.record_boot(~U[2026-01-02 10:00:00Z]) == :unchanged

      periods = Periods.list()

      assert periods == [
               %{started_at: ~U[2025-06-01 00:00:00Z], ended_at: ~U[2026-01-01 10:00:00Z]}
             ]

      # windows after tracking was turned off aren't covered
      assert %{covered: false} =
               Periods.coverage(periods, ~U[2026-01-05 00:00:00Z], ~U[2026-01-10 00:00:00Z])

      # enabling it again later starts a new period
      put_config(enabled: true, secret: "test-persistent-salt-secret-0123456789")
      assert Periods.record_boot(~U[2026-02-01 10:00:00Z]) == :started
      assert length(Periods.list()) == 2
    end

    test "a PERSISTENT_TRACKING_SINCE in the future isn't stored" do
      put_config(enabled: false, since: ~D[2027-01-01])

      assert Periods.record_boot(~U[2026-01-01 10:00:00Z]) == :unchanged
      assert Repo.aggregate(Periods, :count) == 0
    end

    test "does nothing when never enabled" do
      put_config(enabled: false)
      assert Periods.record_boot() == :unchanged
      assert Periods.list() == []
    end
  end

  describe "list/0" do
    test "includes PERSISTENT_TRACKING_SINCE as an open period" do
      put_config(since: ~D[2025-06-01])

      assert Periods.list() == [%{started_at: ~U[2025-06-01 00:00:00Z], ended_at: nil}]
    end

    test "PERSISTENT_TRACKING_SINCE lasts until the first recorded period" do
      put_config(since: ~D[2025-06-01])

      Repo.insert!(%Periods{
        started_at: ~U[2026-01-01 00:00:00Z],
        ended_at: ~U[2026-02-01 00:00:00Z]
      })

      periods = Periods.list()

      assert hd(periods) == %{
               started_at: ~U[2025-06-01 00:00:00Z],
               ended_at: ~U[2026-01-01 00:00:00Z]
             }

      # tracking was off after 2026-02-01, so later windows aren't covered
      assert %{covered: false} =
               Periods.coverage(periods, ~U[2026-01-20 00:00:00Z], ~U[2026-02-10 00:00:00Z])
    end
  end

  describe "coverage/3" do
    @periods [
      %{started_at: ~U[2026-01-10 00:00:00Z], ended_at: ~U[2026-01-20 00:00:00Z]},
      %{started_at: ~U[2026-01-20 00:00:00Z], ended_at: ~U[2026-01-25 00:00:00Z]},
      %{started_at: ~U[2026-02-01 00:00:00Z], ended_at: nil}
    ]

    test "fully inside adjacent periods" do
      assert %{covered: true, since: ~U[2026-01-20 00:00:00Z]} =
               Periods.coverage(@periods, ~U[2026-01-12 00:00:00Z], ~U[2026-01-24 00:00:00Z])
    end

    test "inside the open-ended period" do
      assert %{covered: true, since: ~U[2026-02-01 00:00:00Z]} =
               Periods.coverage(@periods, ~U[2026-02-05 00:00:00Z], ~U[2026-03-01 00:00:00Z])
    end

    test "starting before the first period" do
      assert %{covered: false, since: ~U[2026-01-10 00:00:00Z]} =
               Periods.coverage(@periods, ~U[2026-01-05 00:00:00Z], ~U[2026-01-15 00:00:00Z])
    end

    test "spanning a gap between periods" do
      assert %{covered: false, since: ~U[2026-02-01 00:00:00Z]} =
               Periods.coverage(@periods, ~U[2026-01-22 00:00:00Z], ~U[2026-02-10 00:00:00Z])
    end

    test "no periods at all" do
      assert %{covered: false, since: nil} =
               Periods.coverage([], ~U[2026-01-01 00:00:00Z], ~U[2026-01-02 00:00:00Z])
    end
  end
end
