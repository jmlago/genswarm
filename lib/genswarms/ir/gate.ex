defmodule Genswarms.IR.Gate do
  @moduledoc """
  Makes the IR the default control plane: a thin validation/policy gate the
  orchestrator calls at its existing entry points, so every swarm definition is
  IR-validated and every dynamic mutation is IR-policy-checked — without changing
  how agents are spawned.

  Strict (fail-closed): a config the IR cannot validate/translate is rejected,
  and a mutation that violates `IR.OpPolicy` is rejected. The orchestrator just
  calls `validate_*` and aborts on `{:error, _}`.

    * `validate_start/1`     — config → `IR.FromConfig` + §6 validation.
    * `validate_add_agent/2` — proposed agent vs the live config (cap #28,
      host-escape config keys #24, via `IR.OpPolicy`).
    * `validate_scale/3`     — proposed group size vs the cap (#28).
  """

  alias Genswarms.IR.{FromConfig, OpPolicy}
  alias Genswarms.IR.Overlay.Event

  @doc "Gate a swarm start: the config must translate to a valid `swarm.state`."
  @spec validate_start(map()) :: :ok | {:error, term()}
  def validate_start(config) do
    case FromConfig.from_config(config) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, {:ir_validation_failed, reason}}
    end
  end

  @doc "Gate an add_agent mutation against the live swarm config."
  @spec validate_add_agent(map(), map()) :: :ok | {:error, term()}
  def validate_add_agent(swarm_config, agent_spec) do
    with {:ok, state} <- current_state(swarm_config) do
      event = %Event{
        seq: 0,
        op: :add_agent,
        payload: %{"config" => string_keys(Map.get(agent_spec, :config, %{}))}
      }

      OpPolicy.validate(event, state)
    end
  end

  @doc "Gate a scale_agent_group mutation against the agent cap."
  @spec validate_scale(map(), term(), non_neg_integer()) :: :ok | {:error, term()}
  def validate_scale(swarm_config, _base_name, target_count) do
    with {:ok, state} <- current_state(swarm_config) do
      event = %Event{seq: 0, op: :scale_agent_group, payload: %{"target_count" => target_count}}
      OpPolicy.validate(event, state)
    end
  end

  defp current_state(swarm_config) do
    case FromConfig.from_config(swarm_config) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:ir_validation_failed, reason}}
    end
  end

  defp string_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp string_keys(other), do: other
end
