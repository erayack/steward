defmodule Steward.QuarantinePolicy do
  @moduledoc "Deterministic crash classification policy for managed process workers."

  @default_policy [max_crashes: 3, window_ms: 60_000, cooldown_ms: 120_000]

  @spec classify_crash([integer()], integer(), keyword()) ::
          {:restart, [integer()]} | {:quarantine, integer(), [integer()]}
  def classify_crash(crash_timestamps_ms, now_ms, opts \\ [])
      when is_list(crash_timestamps_ms) and is_integer(now_ms) do
    policy = Keyword.merge(@default_policy, opts)
    window_ms = Keyword.fetch!(policy, :window_ms)
    max_crashes = Keyword.fetch!(policy, :max_crashes)
    cooldown_ms = Keyword.fetch!(policy, :cooldown_ms)

    recent_crashes =
      [now_ms | crash_timestamps_ms]
      |> Enum.filter(fn ts -> is_integer(ts) and now_ms - ts <= window_ms end)
      |> Enum.sort(:desc)

    if length(recent_crashes) > max_crashes do
      {:quarantine, cooldown_ms, recent_crashes}
    else
      {:restart, recent_crashes}
    end
  end
end
