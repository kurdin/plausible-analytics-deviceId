defmodule Plausible.Ingestion.PersistentId do
  @moduledoc """
  Opt-in persistent visitor identification.

  Upstream Plausible derives `user_id` from a salt that rotates daily, so the
  same visitor gets a new id every day and unique visitor counts can't be
  deduplicated across days. When `ENABLE_PERSISTENT_TRACKING=true`, the
  ingestion pipeline uses this module instead and derives a stable id:

    * Tier 1 - the event carries a device id custom property (`deviceId` by
      default, configurable via `PERSISTENT_TRACKING_DEVICE_ID_PROP`):
      `hash("device", site_id, device_id)`
    * Tier 2 - no device id: `hash("fp", site_id, user_agent, remote_ip)`

  Fields are length-prefixed before hashing, so distinct inputs can't collide
  by concatenation.

  Both tiers are keyed with `PERSISTENT_SALT_SECRET`, so IP addresses and
  device ids can't be brute-forced back out of `user_id`. Note that the device
  id itself is still stored as a regular custom property. The result is a
  UInt64, the same representation upstream stores in ClickHouse.

  When the feature is disabled (the default) this module is not used and the
  daily salt rotation applies unchanged (Tier 3).
  """

  use Plausible

  alias Plausible.Ingestion.Request

  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(config(), :enabled, false) == true
  end

  @spec device_id_prop() :: String.t()
  def device_id_prop do
    Keyword.get(config(), :device_id_prop) || "deviceId"
  end

  @spec device_id(Request.t()) :: String.t() | nil
  def device_id(%Request{props: %{} = props}) do
    case Map.get(props, device_id_prop()) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def device_id(_request), do: nil

  @spec generate(pos_integer(), Request.t()) :: non_neg_integer()
  def generate(site_id, %Request{} = request) do
    fields =
      case device_id(request) do
        nil -> ["fp", to_string(site_id), request.user_agent || "", request.remote_ip || ""]
        device_id -> ["device", to_string(site_id), device_id]
      end

    SipHash.hash!(key(), encode(fields ++ replay_session_id(request)))
  end

  # Length-prefixes every field so that no two different field lists can
  # produce the same hash input (e.g. "device-1" + "23" vs "device-12" + "3").
  defp encode(fields) do
    Enum.map_join(fields, fn field -> "#{byte_size(field)}:#{field}" end)
  end

  on_ee do
    defp replay_session_id(%Request{replay_session_id: nil}), do: []
    defp replay_session_id(request), do: [to_string(request.replay_session_id)]
  else
    defp replay_session_id(_request), do: []
  end

  defp key do
    case Keyword.get(config(), :secret) do
      secret when is_binary(secret) and secret != "" ->
        :crypto.hash(:sha256, secret) |> binary_part(0, 16)

      _ ->
        raise ArgumentError,
              "PERSISTENT_SALT_SECRET must be set when ENABLE_PERSISTENT_TRACKING=true"
    end
  end

  defp config do
    Application.get_env(:plausible, __MODULE__, [])
  end
end
