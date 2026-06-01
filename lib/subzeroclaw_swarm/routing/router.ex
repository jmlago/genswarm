defmodule SubzeroclawSwarm.Routing.Router do
  @moduledoc """
  GenServer for inter-agent message routing.

  Maintains topology as adjacency map and validates messages
  against allowed edges before delivering to target agents.
  """

  use GenServer
  require Logger

  alias SubzeroclawSwarm.Agents.AgentServer
  alias SubzeroclawSwarm.Observability.LogStore
  alias SubzeroclawSwarm.Config.SwarmConfig
  alias SubzeroclawSwarm.Objects.ObjectServer

  defstruct topologies: %{}, message_log: []

  @type topology :: %{atom() => [atom()]}
  @type t :: %__MODULE__{
          topologies: %{String.t() => topology()},
          message_log: [map()]
        }

  # Maximum messages to keep in log
  @max_log_size 1000

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Registers a swarm topology.
  """
  @spec register_topology(String.t(), [SwarmConfig.topology_edge()]) :: :ok
  def register_topology(swarm_name, topology) do
    GenServer.call(__MODULE__, {:register_topology, swarm_name, topology})
  end

  @doc """
  Unregisters a swarm topology.
  """
  @spec unregister_topology(String.t()) :: :ok
  def unregister_topology(swarm_name) do
    GenServer.call(__MODULE__, {:unregister_topology, swarm_name})
  end

  @doc """
  Adds edges to an existing swarm topology. Idempotent — already-present
  edges are silently ignored.
  """
  @spec add_edges(String.t(), [SwarmConfig.topology_edge()]) ::
          :ok | {:error, :unknown_swarm}
  def add_edges(swarm_name, edges) when is_list(edges) do
    GenServer.call(__MODULE__, {:add_edges, swarm_name, edges})
  end

  @doc """
  Removes edges from an existing swarm topology. Edges that aren't present
  are silently ignored.
  """
  @spec remove_edges(String.t(), [SwarmConfig.topology_edge()]) ::
          :ok | {:error, :unknown_swarm}
  def remove_edges(swarm_name, edges) when is_list(edges) do
    GenServer.call(__MODULE__, {:remove_edges, swarm_name, edges})
  end

  @doc """
  Removes a node entirely from the topology — every edge that touches the
  node (incoming or outgoing) is dropped.
  """
  @spec remove_node(String.t(), atom()) :: :ok | {:error, :unknown_swarm}
  def remove_node(swarm_name, node) when is_atom(node) do
    GenServer.call(__MODULE__, {:remove_node, swarm_name, node})
  end

  @doc """
  Routes a message from one agent to another.

  Validates the route against the topology before delivering.
  """
  @spec route(String.t(), atom(), atom(), String.t()) :: :ok
  def route(swarm_name, from, to, content) do
    GenServer.cast(__MODULE__, {:route, swarm_name, from, to, content})
  end

  @doc """
  Broadcasts a message from an agent to all connected agents.
  """
  @spec broadcast(String.t(), atom(), String.t()) :: :ok
  def broadcast(swarm_name, from, content) do
    GenServer.cast(__MODULE__, {:broadcast, swarm_name, from, content})
  end

  @doc """
  Gets the topology for a swarm.
  """
  @spec get_topology(String.t()) :: {:ok, topology()} | {:error, :unknown_swarm}
  def get_topology(swarm_name) do
    GenServer.call(__MODULE__, {:get_topology, swarm_name})
  end

  @doc """
  Gets connected agents for a source agent.
  """
  @spec get_connections(String.t(), atom()) :: {:ok, [atom()]} | {:error, term()}
  def get_connections(swarm_name, agent_name) do
    GenServer.call(__MODULE__, {:get_connections, swarm_name, agent_name})
  end

  @doc """
  Gets recent message log entries for a swarm.
  """
  @spec get_message_log(String.t(), non_neg_integer()) :: [map()]
  def get_message_log(swarm_name, limit \\ 100) do
    GenServer.call(__MODULE__, {:get_message_log, swarm_name, limit})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register_topology, swarm_name, topology}, _from, state) do
    adjacency_map = SwarmConfig.build_adjacency_map(topology)
    new_topologies = Map.put(state.topologies, swarm_name, adjacency_map)
    Logger.info("Registered topology for swarm #{swarm_name}: #{inspect(adjacency_map)}")
    {:reply, :ok, %{state | topologies: new_topologies}}
  end

  def handle_call({:unregister_topology, swarm_name}, _from, state) do
    new_topologies = Map.delete(state.topologies, swarm_name)
    Logger.info("Unregistered topology for swarm #{swarm_name}")
    {:reply, :ok, %{state | topologies: new_topologies}}
  end

  def handle_call({:add_edges, swarm_name, edges}, _from, state) do
    case Map.get(state.topologies, swarm_name) do
      nil ->
        {:reply, {:error, :unknown_swarm}, state}

      adjacency ->
        new_adjacency =
          Enum.reduce(edges, adjacency, fn {from, to}, acc ->
            targets = Map.get(acc, from, [])
            if to in targets, do: acc, else: Map.put(acc, from, [to | targets])
          end)

        new_topologies = Map.put(state.topologies, swarm_name, new_adjacency)
        {:reply, :ok, %{state | topologies: new_topologies}}
    end
  end

  def handle_call({:remove_edges, swarm_name, edges}, _from, state) do
    case Map.get(state.topologies, swarm_name) do
      nil ->
        {:reply, {:error, :unknown_swarm}, state}

      adjacency ->
        new_adjacency =
          Enum.reduce(edges, adjacency, fn {from, to}, acc ->
            case Map.get(acc, from) do
              nil ->
                acc

              targets ->
                case List.delete(targets, to) do
                  [] -> Map.delete(acc, from)
                  remaining -> Map.put(acc, from, remaining)
                end
            end
          end)

        new_topologies = Map.put(state.topologies, swarm_name, new_adjacency)
        {:reply, :ok, %{state | topologies: new_topologies}}
    end
  end

  def handle_call({:remove_node, swarm_name, node}, _from, state) do
    case Map.get(state.topologies, swarm_name) do
      nil ->
        {:reply, {:error, :unknown_swarm}, state}

      adjacency ->
        new_adjacency =
          adjacency
          |> Map.delete(node)
          |> Enum.map(fn {from, targets} -> {from, List.delete(targets, node)} end)
          |> Enum.reject(fn {_from, targets} -> targets == [] end)
          |> Map.new()

        new_topologies = Map.put(state.topologies, swarm_name, new_adjacency)
        {:reply, :ok, %{state | topologies: new_topologies}}
    end
  end

  def handle_call({:get_topology, swarm_name}, _from, state) do
    case Map.get(state.topologies, swarm_name) do
      nil -> {:reply, {:error, :unknown_swarm}, state}
      topology -> {:reply, {:ok, topology}, state}
    end
  end

  def handle_call({:get_connections, swarm_name, agent_name}, _from, state) do
    case Map.get(state.topologies, swarm_name) do
      nil ->
        {:reply, {:error, :unknown_swarm}, state}

      topology ->
        connections = Map.get(topology, agent_name, [])
        {:reply, {:ok, connections}, state}
    end
  end

  def handle_call({:get_message_log, swarm_name, limit}, _from, state) do
    filtered =
      state.message_log
      |> Enum.filter(fn entry -> entry.swarm == swarm_name end)
      |> Enum.take(limit)

    {:reply, filtered, state}
  end

  @impl true
  def handle_cast({:route, swarm_name, from, to, content}, state) do
    case Map.get(state.topologies, swarm_name) do
      nil ->
        Logger.warning("Unknown swarm: #{swarm_name}")
        {:noreply, state}

      topology ->
        if can_route?(topology, from, to) do
          # Deliver message to target (agent or object) - async
          deliver_to_target(swarm_name, to, from, content)

          # Log the message
          log_entry = %{
            timestamp: DateTime.utc_now(),
            swarm: swarm_name,
            from: from,
            to: to,
            type: :direct,
            content_preview: String.slice(content, 0, 100)
          }

          emit_telemetry(:message_routed, log_entry)
          broadcast_to_subscribers(swarm_name, :message_routed, log_entry)

          new_state = add_to_log(state, log_entry)
          {:noreply, new_state}
        else
          Logger.warning("Invalid route: #{from} -> #{to} in swarm #{swarm_name}")
          emit_telemetry(:invalid_route, %{swarm: swarm_name, from: from, to: to})

          # Log with topology context
          allowed_targets = Map.get(topology, from, [])

          LogStore.log(
            :warning,
            :routing,
            :invalid_route,
            "Invalid route: #{from} -> #{to} (allowed: #{inspect(allowed_targets)})",
            swarm: swarm_name,
            agent: from,
            metadata: %{from: from, to: to, allowed_targets: allowed_targets}
          )

          {:noreply, state}
        end
    end
  end

  def handle_cast({:broadcast, swarm_name, from, content}, state) do
    case Map.get(state.topologies, swarm_name) do
      nil ->
        Logger.warning("Unknown swarm for broadcast: #{swarm_name}")
        {:noreply, state}

      topology ->
        # Get all targets (agents/objects) that `from` can send to
        targets = Map.get(topology, from, [])

        # Deliver to all connected targets
        Enum.each(targets, fn to ->
          deliver_to_target(swarm_name, to, from, content)
        end)

        log_entry = %{
          timestamp: DateTime.utc_now(),
          swarm: swarm_name,
          from: from,
          to: targets,
          type: :broadcast,
          content_preview: String.slice(content, 0, 100)
        }

        emit_telemetry(:message_broadcast, log_entry)
        broadcast_to_subscribers(swarm_name, :message_broadcast, log_entry)

        new_state = add_to_log(state, log_entry)
        {:noreply, new_state}
    end
  end

  # Private functions

  # System objects (:metrics, :tick, :gateway) are always routable targets
  # so objects don't need explicit topology edges to send state_reports etc.
  @system_objects [:metrics, :tick, :gateway]

  defp can_route?(topology, from, to) do
    targets = Map.get(topology, from, [])
    to in targets or to in @system_objects
  end

  # Deliver message to target (either agent or object)
  # Uses Registry metadata to determine target type (no blocking calls)
  defp deliver_to_target(swarm_name, to, from, content) do
    case Registry.lookup(SubzeroclawSwarm.AgentRegistry, {swarm_name, to}) do
      [{_pid, :agent}] ->
        AgentServer.deliver_message(swarm_name, to, from, content)

      [{_pid, :object}] ->
        ObjectServer.deliver_message(swarm_name, to, from, content)

      [{_pid, _other}] ->
        # Fallback for old registrations without type metadata
        AgentServer.deliver_message(swarm_name, to, from, content)

      [] ->
        Logger.warning("Target #{to} not found in swarm #{swarm_name}")

        LogStore.log(
          :warning,
          :routing,
          :target_not_found,
          "Target #{to} not found in swarm #{swarm_name}",
          swarm: swarm_name,
          agent: from,
          metadata: %{from: from, to: to}
        )
    end
  end

  defp add_to_log(state, entry) do
    new_log = [entry | state.message_log] |> Enum.take(@max_log_size)
    %{state | message_log: new_log}
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:subzeroclaw_swarm, :router, event],
      %{time: System.system_time()},
      metadata
    )
  end

  defp broadcast_to_subscribers(swarm_name, event, data) do
    Phoenix.PubSub.broadcast(
      SubzeroclawSwarm.PubSub,
      "swarm:#{swarm_name}:routing",
      {event, data}
    )
  end
end
