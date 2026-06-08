defmodule Genswarms.IR.OpPolicy do
  @moduledoc """
  Security policy for *proposed* overlay ops — enforced by the single writer
  (§5.1) before an op is assigned a `seq` and folded into the log.

  `IR.Fold` checks an op's structural preconditions (names, edges, digest guard).
  This layer adds the resource/authority limits the audit hardened on the old
  REST mutation surface, now centralized at the single point every mutation
  funnels through instead of scattered across controllers:

    * **per-swarm agent cap** on `add_agent` / `scale_agent_group` —
      resource-exhaustion DoS (audit #28); and
    * **rejection of host-escape backend config keys** in `add_agent`
      (`subzeroclaw_path`, `extra_ro_binds`, `extra_rw_binds`, `extra_path`) —
      audit #24.

  Pure: `validate/3` takes the proposed event and the current desired state.
  The endpoint allowlist (audit #30) is intentionally *not* here — in the IR a
  model is a logical ref (`openrouter:…`), so the host it resolves to is only
  known at resolve/actuation time; that check belongs there.
  """

  alias Genswarms.IR.State
  alias Genswarms.IR.Overlay.Event

  @default_max_agents 100

  # Backend config keys that grant host access; never settable through a proposed
  # op (an operator-authored seed may still use them — this guards the dynamic
  # control-plane surface, like #24 guarded the add_agent API).
  @forbidden_config_keys ~w(subzeroclaw_path extra_ro_binds extra_rw_binds extra_path)

  @doc """
  Validates a proposed op against the current state and policy.

  Options: `:max_agents` overrides the per-swarm cap (defaults to
  `config :genswarms, :max_agents_per_swarm`, else #{@default_max_agents}).
  """
  @spec validate(Event.t(), State.t(), keyword()) :: :ok | {:error, term()}
  def validate(event, state, opts \\ [])

  def validate(%Event{op: :add_agent, payload: p}, %State{agents: agents}, opts) do
    with :ok <- within_cap(length(agents) + 1, opts),
         :ok <- no_forbidden_keys(Map.get(p, "config", %{})) do
      :ok
    end
  end

  def validate(%Event{op: :scale_agent_group, payload: %{"target_count" => target}}, _state, opts) do
    within_cap(target, opts)
  end

  def validate(%Event{}, _state, _opts), do: :ok

  @doc "The host-escape backend config keys rejected on a proposed op."
  @spec forbidden_config_keys() :: [String.t()]
  def forbidden_config_keys, do: @forbidden_config_keys

  defp within_cap(count, opts) do
    max =
      Keyword.get(opts, :max_agents) ||
        Application.get_env(:genswarms, :max_agents_per_swarm, @default_max_agents)

    if count <= max, do: :ok, else: {:error, {:agent_cap_exceeded, count, max}}
  end

  defp no_forbidden_keys(config) when is_map(config) do
    offending =
      config
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in @forbidden_config_keys))
      |> Enum.uniq()
      |> Enum.sort()

    if offending == [], do: :ok, else: {:error, {:forbidden_config_keys, offending}}
  end

  defp no_forbidden_keys(_), do: :ok
end
