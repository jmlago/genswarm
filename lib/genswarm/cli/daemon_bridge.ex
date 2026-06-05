defmodule Genswarm.CLI.DaemonBridge do
  @moduledoc """
  Helper used by the Mix-task CLI commands to detect whether a swarm is
  running as a daemon (separate OS process) and route mutations through
  the SQLite `swarm_commands` queue when so.

  When the swarm exists in the local SwarmManager state, the call is made
  in-process directly.
  """

  alias Genswarm.SwarmManager
  alias Genswarm.CLI.SwarmRegistry

  @default_timeout 10_000
  @poll_interval 100

  @spec dispatch(String.t(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(swarm_name, op, payload, opts \\ []) do
    cond do
      in_process?(swarm_name) ->
        local_call(swarm_name, op, payload)

      daemon?(swarm_name) ->
        queue_and_wait(swarm_name, op, payload, opts)

      true ->
        {:error, :swarm_not_found}
    end
  end

  defp in_process?(swarm_name) do
    case SwarmManager.status(swarm_name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp daemon?(swarm_name) do
    case SwarmRegistry.get_swarm(swarm_name) do
      {:ok, %{status: :running, pid: pid}} when is_integer(pid) ->
        SwarmRegistry.process_alive?(pid)

      _ ->
        false
    end
  end

  defp local_call(swarm_name, :scale_agent_group, %{base_name: base, target_count: n}) do
    SwarmManager.scale_agent_group(swarm_name, base, n, persist: true)
  end

  defp local_call(swarm_name, :add_agent, payload) do
    {connections, payload} = Map.pop(payload, :_connections, [])
    {incoming, spec} = Map.pop(payload, :_incoming, [])
    SwarmManager.add_agent(swarm_name, spec, connections: connections, incoming: incoming, persist: true)
  end

  defp local_call(swarm_name, :remove_agent, %{name: name}) do
    SwarmManager.remove_agent(swarm_name, name, persist: true)
  end

  defp local_call(swarm_name, :add_object, payload) do
    {connections, payload} = Map.pop(payload, :_connections, [])
    {incoming, spec} = Map.pop(payload, :_incoming, [])
    SwarmManager.add_object(swarm_name, spec, connections: connections, incoming: incoming, persist: true)
  end

  defp local_call(swarm_name, :remove_object, %{name: name}) do
    SwarmManager.remove_object(swarm_name, name, persist: true)
  end

  defp local_call(swarm_name, :add_topology_edges, %{edges: edges}) do
    SwarmManager.add_topology_edges(swarm_name, edges, persist: true)
  end

  defp local_call(swarm_name, :remove_topology_edges, %{edges: edges}) do
    SwarmManager.remove_topology_edges(swarm_name, edges, persist: true)
  end

  defp queue_and_wait(swarm_name, op, payload, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    {:ok, cmd_id} = SwarmRegistry.enqueue_command(swarm_name, op, payload)
    wait_for_result(cmd_id, timeout)
  end

  defp wait_for_result(cmd_id, timeout_remaining) when timeout_remaining > 0 do
    case SwarmRegistry.get_command_result(cmd_id) do
      {:done, result} -> decode_daemon_result(result)
      {:pending, _} ->
        Process.sleep(@poll_interval)
        wait_for_result(cmd_id, timeout_remaining - @poll_interval)
      _ ->
        Process.sleep(@poll_interval)
        wait_for_result(cmd_id, timeout_remaining - @poll_interval)
    end
  end

  defp wait_for_result(_cmd_id, _) do
    {:error, :daemon_timeout}
  end

  defp decode_daemon_result(%{status: "ok", value: value}), do: {:ok, value}
  defp decode_daemon_result(%{status: "ok"}), do: :ok
  defp decode_daemon_result(%{status: "error", reason: reason}), do: {:error, reason}
  defp decode_daemon_result(other), do: {:ok, other}
end
