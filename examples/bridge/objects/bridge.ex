defmodule Bridge.Objects.Bridge do
  @moduledoc """
  Bridge ObjectHandler for cross-swarm communication via SQLite task queue.

  This bridge allows agents in one daemon swarm to send messages to agents
  in another daemon swarm. Communication happens through the shared SQLite
  database that both daemons poll for tasks.

  Latency: ~500ms (daemon poll interval)
  """

  @behaviour Genswarm.Objects.ObjectHandler

  alias Genswarm.CLI.SwarmRegistry
  alias Genswarm.Objects.ObjectServer

  @impl true
  def init(config) do
    state = %{
      swarm_name: config[:swarm_name],
      # routing: local_agent => {remote_swarm, remote_agent}
      routing: Map.get(config, :routing, %{})
    }

    ObjectServer.log(
      :info,
      config[:swarm_name],
      :bridge,
      "Bridge initialized, routing: #{inspect(state.routing)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_message(from, content, state) do
    case Jason.decode(content) do
      {:ok, %{"to" => %{"swarm" => swarm, "agent" => agent}, "content" => msg}} ->
        # Explicit routing in message
        forward_to_remote(from, swarm, agent, msg, state)

      _ ->
        # Use pre-configured routing
        case Map.get(state.routing, from) do
          {remote_swarm, remote_agent} ->
            forward_to_remote(from, remote_swarm, to_string(remote_agent), content, state)

          nil ->
            {:reply, ~s({"error": "No routing configured for #{from}"}), state}
        end
    end
  end

  defp forward_to_remote(from, target_swarm, target_agent, content, state) do
    # Wrap with source info so remote agent knows where it came from
    wrapped =
      Jason.encode!(%{
        from_swarm: state.swarm_name,
        from_agent: from,
        content: content
      })

    # Queue task in SQLite for remote daemon to pick up
    SwarmRegistry.queue_task(target_swarm, target_agent, wrapped)

    ObjectServer.log(
      :info,
      state.swarm_name,
      :bridge,
      "Forwarded message from #{from} to #{target_swarm}/#{target_agent}"
    )

    {:noreply, state}
  end

  @impl true
  def interface do
    %{
      forward: %{
        input: ~s({"to": {"swarm": "swarm-b", "agent": "agent"}, "content": "..."}),
        output: "Queues message for agent in remote daemon swarm (~500ms delivery)"
      }
    }
  end
end
