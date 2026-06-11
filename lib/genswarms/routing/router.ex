defmodule Genswarms.Routing.Router do
  @moduledoc """
  GenServer for inter-agent message routing.

  Maintains topology as adjacency map and validates messages
  against allowed edges before delivering to target agents.
  """

  use GenServer
  require Logger

  alias Genswarms.Agents.AgentServer
  alias Genswarms.Agents.Ask
  alias Genswarms.Observability.LogStore
  alias Genswarms.Config.SwarmConfig
  alias Genswarms.Objects.ObjectServer

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
  Routes a synchronous ask from an agent to an object (`swarm-msg ask`).

  Same topology validation as `route/4`, but the object's reply is wrapped in a
  typed envelope and written to the calling agent's reply file (via
  `AgentServer.deliver_ask_reply/4`) instead of being injected as a new turn —
  the blocked `swarm-msg ask` reads it inline in the SAME turn. Consequently
  this path never sets the awaiting-reply flag (there is no async reply to
  guard against), and every failure (unknown swarm, denied route, missing or
  non-object target) is answered with an `ok: false` envelope rather than a
  silent drop, so the asker never waits out its timeout for a knowable error.

  Interaction contract with the async mode: ask and the awaiting-reply gate
  are independent organs of two different modes. An agent MAY ask while its
  awaiting flag is set (the sync reply file is invisible to the gate), an ask
  neither sets nor clears the flag, and a `send` and an `ask` in the same
  turn do not interfere — the send takes the async path (guard applies), the
  ask takes this one. Neither mode may borrow the other's correlation
  mechanism: envelopes answer asks, turn injection answers sends.
  """
  @spec ask(String.t(), atom(), atom(), String.t(), String.t()) :: :ok
  def ask(swarm_name, from, to, content, correlation_id) do
    GenServer.cast(__MODULE__, {:route_ask, swarm_name, from, to, content, correlation_id})
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
    {:noreply, do_route(swarm_name, from, to, content, nil, state)}
  end

  def handle_cast({:route_ask, swarm_name, from, to, content, corr}, state) do
    cond do
      # Only agents can ask: the reply lands in the asker's workspace reply
      # file via AgentServer — answering a non-agent would cast an unknown
      # message into an ObjectServer (agents and objects share the Registry
      # keyspace) and crash it.
      sender_type(swarm_name, from) != :agent ->
        Logger.warning("Ask from non-agent #{from} in swarm #{swarm_name} — dropped")
        {:noreply, state}

      # Non-binary content is refused with a typed envelope BEFORE routing:
      # it originates inside the agent sandbox, and letting it through would
      # crash the singleton Router on String.slice (taking every swarm's
      # topology with it) and the target object's handler besides.
      not is_binary(content) ->
        ask_error(swarm_name, from, corr, "invalid_content", "ask content must be a string")
        {:noreply, state}

      true ->
        {:noreply, do_route(swarm_name, from, to, content, corr, state)}
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

        # Async-reply ordering guard (broadcast variant):
        # If the sender is an agent and ANY of the broadcast targets is a
        # reply-expecting object (has a back-edge to `from`), mark the agent
        # as awaiting.  We also handle the object→agent case symmetrically.
        case sender_type(swarm_name, from) do
          :agent ->
            if Enum.any?(targets, &reply_expecting?(topology, from, &1)) do
              AgentServer.set_awaiting(swarm_name, from)
            end

          :object ->
            # An object broadcasting to potentially multiple agents — awaiting is
            # cleared atomically inside each deliver_message call, so we do NOT
            # call clear_awaiting here (same race-closure rationale as the direct
            # route path above).
            :ok

          :unknown ->
            :ok
        end

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
    case Registry.lookup(Genswarms.AgentRegistry, {swarm_name, to}) do
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

  # The single routing body for BOTH modes. `corr` selects the mode:
  # nil = asynchronous route (fire-and-forget; the awaiting ordering guard
  # applies); a correlation id = synchronous ask (no guard; every failure
  # answers a typed envelope so the blocked asker returns immediately).
  # One body, so topology validation, delivery dispatch, logging and
  # telemetry cannot diverge between the modes.
  defp do_route(swarm_name, from, to, content, corr, state) do
    case Map.get(state.topologies, swarm_name) do
      nil ->
        Logger.warning("Unknown swarm: #{swarm_name}")

        if corr do
          ask_error(swarm_name, from, corr, "unknown_swarm", "unknown swarm #{swarm_name}")
        end

        state

      topology ->
        if can_route?(topology, from, to) do
          if corr == nil do
            # Async-reply ordering guard (async mode only — an ask's reply
            # returns inline through the reply file, inside the same agent
            # turn; there is no async reply for the guard to defend against):
            #
            # When an agent sends to an object that has a back-edge to the agent
            # (object is in the agent's incoming set), the agent is entering an
            # async request/reply cycle.  Mark the agent as awaiting so any new
            # user task arriving before the reply is queued rather than forwarded
            # to the backend immediately (which would mis-correlate turns).
            #
            # Conversely, when an object delivers a message to an agent, the reply
            # has arrived — clear the flag so queued tasks are released on the next
            # TURN_COMPLETE.
            case sender_type(swarm_name, from) do
              :agent ->
                # from=agent, to=object (or another agent): set awaiting if the
                # target can reply back (has a return edge to `from`).
                if reply_expecting?(topology, from, to) do
                  AgentServer.set_awaiting(swarm_name, from)
                end

              :object ->
                # from=object, to=agent: the reply has arrived.  clear_awaiting is
                # handled atomically inside deliver_message — do NOT call it here
                # to avoid a window where awaiting is cleared but the reply has not
                # yet been queued/delivered, which would allow a racing send_task to
                # bypass the gate.
                :ok

              :unknown ->
                :ok
            end
          end

          deliver(swarm_name, to, from, content, corr)

          log_entry = %{
            timestamp: DateTime.utc_now(),
            swarm: swarm_name,
            from: from,
            to: to,
            type: if(corr, do: :ask, else: :direct),
            content_preview: String.slice(content, 0, 100)
          }

          emit_telemetry(:message_routed, log_entry)
          broadcast_to_subscribers(swarm_name, :message_routed, log_entry)

          add_to_log(state, log_entry)
        else
          kind = if corr, do: "ask route", else: "route"
          Logger.warning("Invalid #{kind}: #{from} -> #{to} in swarm #{swarm_name}")

          emit_telemetry(:invalid_route, %{
            swarm: swarm_name,
            from: from,
            to: to,
            allowed_targets: Map.get(topology, from, [])
          })

          if corr do
            ask_error(swarm_name, from, corr, "route_denied", "no edge #{from} -> #{to}")
          end

          state
        end
    end
  end

  # Mode-specific delivery. Async (corr=nil) reaches any target type; an ask
  # is an object call — an agent cannot answer synchronously.
  defp deliver(swarm_name, to, from, content, nil) do
    deliver_to_target(swarm_name, to, from, content)
  end

  defp deliver(swarm_name, to, from, content, corr) do
    case Registry.lookup(Genswarms.AgentRegistry, {swarm_name, to}) do
      [{_pid, :object}] ->
        ObjectServer.deliver_ask(swarm_name, to, from, content, corr)

      [] ->
        Logger.warning("Ask target #{to} not found in swarm #{swarm_name}")
        ask_error(swarm_name, from, corr, "target_not_found", "no such object: #{to}")

      _agent_or_unknown ->
        ask_error(swarm_name, from, corr, "not_an_object", "#{to} is not an object")
    end
  end

  # Answer a failed ask with a typed error envelope so the blocked swarm-msg
  # ask returns immediately instead of waiting out its timeout.
  defp ask_error(swarm_name, from, corr, code, message) do
    AgentServer.deliver_ask_reply(
      swarm_name,
      from,
      corr,
      Ask.error_envelope(corr, code, message)
    )
  end

  defp add_to_log(state, entry) do
    new_log = [entry | state.message_log] |> Enum.take(@max_log_size)
    %{state | message_log: new_log}
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:genswarms, :router, event],
      %{time: System.system_time()},
      metadata
    )
  end

  defp broadcast_to_subscribers(swarm_name, event, data) do
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{swarm_name}:routing",
      {event, data}
    )
  end

  # Async-reply ordering guard helpers
  # -----------------------------------------------------------------------

  # Returns true if `object` has a back-edge to `agent` in the topology
  # (i.e., `object` can send messages back to `agent`).  This is how we
  # detect "reply-expecting" objects without hardcoding any names.
  # System objects are intentionally excluded: they receive one-way
  # notifications and never reply to the agent.
  defp reply_expecting?(topology, agent, object) do
    object not in @system_objects and
      agent in Map.get(topology, object, [])
  end

  # Look up a node's registration type in the Registry.
  # Returns :agent, :object, or :unknown.
  defp sender_type(swarm_name, name) do
    case Registry.lookup(Genswarms.AgentRegistry, {swarm_name, name}) do
      [{_pid, :agent}] -> :agent
      [{_pid, :object}] -> :object
      [{_pid, _other}] -> :agent
      [] -> :unknown
    end
  end
end
