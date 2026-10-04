defmodule Plausible.Ingestion.PersistentIdTest do
  use ExUnit.Case, async: false

  alias Plausible.Ingestion.{PersistentId, Request}

  @secret "test-persistent-salt-secret-0123456789"

  setup do
    original = Application.get_env(:plausible, PersistentId)

    Application.put_env(:plausible, PersistentId,
      enabled: true,
      secret: @secret,
      device_id_prop: "deviceId"
    )

    on_exit(fn -> Application.put_env(:plausible, PersistentId, original) end)
  end

  defp request(attrs) do
    struct!(
      %Request{user_agent: "Mozilla/5.0", remote_ip: "1.2.3.4", props: %{}},
      attrs
    )
  end

  defp put_config(opts) do
    config = Application.get_env(:plausible, PersistentId)
    Application.put_env(:plausible, PersistentId, Keyword.merge(config, opts))
  end

  describe "enabled?/0" do
    test "is false by default" do
      Application.delete_env(:plausible, PersistentId)
      refute PersistentId.enabled?()
    end

    test "reflects config" do
      assert PersistentId.enabled?()
      put_config(enabled: false)
      refute PersistentId.enabled?()
    end
  end

  describe "device_id/1" do
    test "reads the deviceId prop by default" do
      assert PersistentId.device_id(request(props: %{"deviceId" => "abc"})) == "abc"
    end

    test "defaults the prop name to deviceId when not configured" do
      put_config(device_id_prop: nil)
      assert PersistentId.device_id_prop() == "deviceId"
      assert PersistentId.device_id(request(props: %{"deviceId" => "abc"})) == "abc"
    end

    test "honours a custom prop name" do
      put_config(device_id_prop: "visitor_uid")

      assert PersistentId.device_id(request(props: %{"visitor_uid" => "xyz"})) == "xyz"
      assert PersistentId.device_id(request(props: %{"deviceId" => "abc"})) == nil
    end

    test "matches the prop name case-sensitively" do
      assert PersistentId.device_id(request(props: %{"deviceid" => "abc"})) == nil
    end

    test "ignores blank values and missing props" do
      assert PersistentId.device_id(request(props: %{"deviceId" => "   "})) == nil
      assert PersistentId.device_id(request(props: %{})) == nil
      assert PersistentId.device_id(request(props: nil)) == nil
    end
  end

  describe "generate/2" do
    test "is deterministic and returns a UInt64" do
      req = request(props: %{"deviceId" => "abc"})
      id = PersistentId.generate(1, req)

      assert id == PersistentId.generate(1, req)
      assert is_integer(id) and id >= 0 and id < Bitwise.bsl(1, 64)
    end

    test "tier 1: device id ignores IP and user agent" do
      a = request(props: %{"deviceId" => "abc"}, remote_ip: "1.1.1.1", user_agent: "A")
      b = request(props: %{"deviceId" => "abc"}, remote_ip: "2.2.2.2", user_agent: "B")
      c = request(props: %{"deviceId" => "other"}, remote_ip: "1.1.1.1", user_agent: "A")

      assert PersistentId.generate(1, a) == PersistentId.generate(1, b)
      assert PersistentId.generate(1, a) != PersistentId.generate(1, c)
    end

    test "tier 2: falls back to IP and user agent" do
      a = request(remote_ip: "1.1.1.1", user_agent: "A")
      b = request(remote_ip: "1.1.1.1", user_agent: "A")
      c = request(remote_ip: "2.2.2.2", user_agent: "A")
      d = request(remote_ip: "1.1.1.1", user_agent: "B")

      assert PersistentId.generate(1, a) == PersistentId.generate(1, b)
      assert PersistentId.generate(1, a) != PersistentId.generate(1, c)
      assert PersistentId.generate(1, a) != PersistentId.generate(1, d)
    end

    test "tier 2: handles missing user agent" do
      assert is_integer(PersistentId.generate(1, request(user_agent: nil)))
    end

    test "field boundaries are unambiguous" do
      # naive concatenation would make these identical
      a = request(remote_ip: "1.2.3.45", user_agent: "Mozilla/5.0")
      b = request(remote_ip: "5.1.2.3.45", user_agent: "Mozilla/5.0 ")
      c = request(remote_ip: "", user_agent: "Mozilla/5.01.2.3.45")

      ids = Enum.map([a, b, c], &PersistentId.generate(1, &1))
      assert ids == Enum.uniq(ids)

      assert PersistentId.generate(1, request(props: %{"deviceId" => "1:x"})) !=
               PersistentId.generate(11, request(props: %{"deviceId" => "x"}))
    end

    test "ids are scoped per site" do
      req = request(props: %{"deviceId" => "abc"})
      assert PersistentId.generate(1, req) != PersistentId.generate(2, req)
    end

    test "ids depend on the secret" do
      req = request(props: %{"deviceId" => "abc"})
      id = PersistentId.generate(1, req)

      put_config(secret: "another-secret-value-0123456789")
      assert PersistentId.generate(1, req) != id
    end

    test "raises when the secret is missing" do
      put_config(secret: nil)

      assert_raise ArgumentError, fn ->
        PersistentId.generate(1, request([]))
      end
    end
  end
end
