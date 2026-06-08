defmodule Genswarms.SwarmManager do
  @moduledoc """
  GenServer for managing multiple swarms.

  Handles swarm lifecycle:
  - Starting swarms from configuration files
  - Stopping swarms
  - Tracking swarm status
  - Coordinating agent startup
  """

  use GenServer
  require Logger

  alias Genswarms.Agents.{AgentSupervisor, AgentServer}
  alias Genswarms.Observability.LogStore
  alias Genswarms.Config.{Loader, SwarmConfig}
  alias Genswarms.Objects.ObjectSupervisor
  alias Genswarms.Routing.Router

  defstruct swarms: %{}

  @type swarm_info :: %{
          config: SwarmConfig.t(),
          config_path: String.t() | nil,
          started_at: DateTime.t(),
          status: :starting | :running | :stopping | :stopped | :error
        }

  @type t :: %__MODULE__{
          swarms: %{String.t() => swarm_info()}
        }

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Starts a swarm from a configuration file.
  """
  @spec start_swarm(String.t()) :: {:ok, String.t()} | {:error, term()}
  def start_swarm(config_path) do
    GenServer.call(__MODULE__, {:start_swarm, config_path}, 60_000)
  end

  @doc """
  Starts a swarm from a configuration map.
  """
  @spec start_from_config(map()) :: {:ok, String.t()} | {:error, term()}
  def start_from_config(config) do
    GenServer.call(__MODULE__, {:start_from_config, config}, 60_000)
  end

  @doc """
  Stops a running swarm.
  """
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(swarm_name) do
    GenServer.call(__MODULE__, {:stop, swarm_name})
  end

  @doc """
  Gets the status of a swarm.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(swarm_name) do
    GenServer.call(__MODULE__, {:status, swarm_name})
  end

  @doc """
  Lists all swarms.
  """
  @spec list() :: [map()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Sends a task to an agent in a swarm.
  """
  @spec send_task(String.t(), atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def send_task(swarm_name, agent_name, task) do
    agent_name = if is_binary(agent_name), do: String.to_atom(agent_name), else: agent_name
    AgentServer.send_task(swarm_name, agent_name, task)
  end

  @doc """
  Gets the topology of a swarm.
  """
  @spec get_topology(String.t()) :: {:ok, map()} | {:error, term()}
  def get_topology(swarm_name) do
    Router.get_topology(swarm_name)
  end

  @doc """
  Pauses a swarm (freezes all Docker containers).
  """
  @spec pause(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def pause(swarm_name) do
    GenServer.call(__MODULE__, {:pause, swarm_name})
  end

  @doc """
  Resumes a paused swarm.
  """
  @spec resume(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def resume(swarm_name) do
    GenServer.call(__MODULE__, {:resume, swarm_name})
  end

  @doc """
  Checks if a swarm is paused.
  """
  @spec paused?(String.t()) :: boolean()
  def paused?(swarm_name) do
    GenServer.call(__MODULE__, {:paused?, swarm_name})
  end

  @doc """
  Adds an agent to a running swarm at runtime.

  ## Spec

  Same shape as an entry in the `agents:` list of the swarm config:
  `%{name: :foo, backend: :bwrap, skills: [...], ...}`

  ## Options

  - `connections: [atom]` — add edges `agent → x` for each x
  - `incoming: [atom]`    — add edges `x → agent`
  - `persist: boolean`    — persist to overlay log (default false)
  """
  @spec add_agent(String.t(), map(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def add_agent(swarm_name, agent_spec, opts \\ []) do
    GenServer.call(__MODULE__, {:add_agent, swarm_name, agent_spec, opts}, 60_000)
  end

  @doc """
  Removes an agent from a running swarm.
  """
  @spec remove_agent(String.t(), atom() | String.t(), keyword()) ::
          :ok | {:error, term()}
  def remove_agent(swarm_name, agent_name, opts \\ []) do
    GenServer.call(__MODULE__, {:remove_agent, swarm_name, normalize_name(agent_name), opts})
  end

  @doc """
  Adds an object to a running swarm at runtime.
  """
  @spec add_object(String.t(), map(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def add_object(swarm_name, object_spec, opts \\ []) do
    GenServer.call(__MODULE__, {:add_object, swarm_name, object_spec, opts}, 60_000)
  end

  @doc """
  Removes an object from a running swarm.
  """
  @spec remove_object(String.t(), atom() | String.t(), keyword()) ::
          :ok | {:error, term()}
  def remove_object(swarm_name, object_name, opts \\ []) do
    GenServer.call(__MODULE__, {:remove_object, swarm_name, normalize_name(object_name), opts})
  end

  @doc """
  Adds topology edges to a running swarm.
  """
  @spec add_topology_edges(String.t(), [{atom(), atom()}], keyword()) ::
          :ok | {:error, term()}
  def add_topology_edges(swarm_name, edges, opts \\ []) do
    GenServer.call(__MODULE__, {:add_topology_edges, swarm_name, edges, opts})
  end

  @doc """
  Removes topology edges from a running swarm.
  """
  @spec remove_topology_edges(String.t(), [{atom(), atom()}], keyword()) ::
          :ok | {:error, term()}
  def remove_topology_edges(swarm_name, edges, opts \\ []) do
    GenServer.call(__MODULE__, {:remove_topology_edges, swarm_name, edges, opts})
  end

  @doc """
  Scales an agent group to a target count. The group is identified by
  `base_name` and matches agents named `base_name`, `base_name_1`,
  `base_name_2`, etc.

  Uses an existing agent's spec as the template for new agents.
  Returns partial success: agents that fail to start are reported in
  `:failed` rather than rolling back the whole operation.
  """
  @spec scale_agent_group(String.t(), atom() | String.t(), pos_integer(), keyword()) ::
          {:ok, %{added: [atom()], removed: [atom()], failed: [{atom(), term()}]}}
          | {:error, term()}
  def scale_agent_group(swarm_name, base_name, target_count, opts \\ [])
      when is_integer(target_count) and target_count >= 0 do
    GenServer.call(
      __MODULE__,
      {:scale_agent_group, swarm_name, normalize_name(base_name), target_count, opts},
      120_000
    )
  end

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: String.to_atom(name)

  @doc """
  Returns the effective in-memory SwarmConfig for a swarm (seed ⊕ overlay).
  """
  @spec get_full_config(String.t()) :: {:ok, map()} | {:error, :swarm_not_found}
  def get_full_config(swarm_name) do
    GenServer.call(__MODULE__, {:get_full_config, swarm_name})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:start_swarm, config_path}, _from, state) do
    case Loader.load(config_path) do
      {:ok, config} ->
        do_start_swarm(config, config_path, state)

      {:error, reason} ->
        LogStore.log(
          :error,
          :swarm,
          :config_load_failed,
          "Failed to load config from #{config_path}: #{inspect(reason)}",
          metadata: %{config_path: config_path, reason: inspect(reason)}
        )

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_from_config, config_map}, _from, state) do
    case SwarmConfig.parse(config_map) do
      {:ok, config} ->
        do_start_swarm(config, nil, state)

      {:error, reason} ->
        LogStore.log(
          :error,
          :swarm,
          :config_parse_failed,
          "Failed to parse swarm config: #{inspect(reason)}",
          metadata: %{reason: inspect(reason)}
        )

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, swarm_name}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        LogStore.log(:warning, :swarm, :not_found, "Cannot stop swarm '#{swarm_name}': not found",
          swarm: swarm_name
        )

        {:reply, {:error, :not_found}, state}

      swarm_info ->
        Logger.info("Stopping swarm #{swarm_name}")

        # Stop all agents and objects
        AgentSupervisor.stop_all_agents(swarm_name)
        ObjectSupervisor.stop_all_objects(swarm_name)

        # Unregister topology
        Router.unregister_topology(swarm_name)

        # Broadcast stop event
        Phoenix.PubSub.broadcast(
          Genswarms.PubSub,
          "swarm:#{swarm_name}",
          {:swarm_stopped, swarm_name}
        )

        emit_telemetry(:swarm_stopped, %{
          swarm: swarm_name,
          agent_count: length(swarm_info.config.agents),
          object_count: length(swarm_info.config.objects || [])
        })

        # Remove swarm from state entirely (allows clean restart)
        new_swarms = Map.delete(state.swarms, swarm_name)
        {:reply, {:ok, swarm_info.config_path}, %{state | swarms: new_swarms}}
    end
  end

  def handle_call({:status, swarm_name}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      swarm_info ->
        agents = AgentSupervisor.list_agents(swarm_name)
        agent_counts = AgentSupervisor.count_by_state(swarm_name)
        objects = ObjectSupervisor.list_objects(swarm_name)

        status = %{
          name: swarm_name,
          status: swarm_info.status,
          started_at: swarm_info.started_at,
          config_path: Map.get(swarm_info, :config_path),
          agents: agents,
          objects: objects,
          agent_counts: agent_counts,
          config: %{
            agent_count: length(swarm_info.config.agents),
            object_count: length(swarm_info.config.objects || []),
            topology_edges: length(swarm_info.config.topology)
          }
        }

        {:reply, {:ok, status}, state}
    end
  end

  def handle_call(:list, _from, state) do
    swarms =
      Enum.map(state.swarms, fn {name, info} ->
        %{
          name: name,
          status: info.status,
          started_at: info.started_at,
          agent_count: length(info.config.agents),
          object_count: length(info.config.objects || [])
        }
      end)

    {:reply, swarms, state}
  end

  def handle_call({:pause, swarm_name}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _swarm_info ->
        case do_pause_containers(swarm_name) do
          {:ok, count} ->
            Logger.info("Paused #{count} containers for swarm #{swarm_name}")
            {:reply, {:ok, count}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:resume, swarm_name}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _swarm_info ->
        case do_resume_containers(swarm_name) do
          {:ok, count} ->
            Logger.info("Resumed #{count} containers for swarm #{swarm_name}")
            {:reply, {:ok, count}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:paused?, swarm_name}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, false, state}

      _swarm_info ->
        {:reply, check_containers_paused(swarm_name), state}
    end
  end

  def handle_call({:add_agent, swarm_name, spec, opts}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :swarm_not_found}, state}

      swarm_info ->
        with :ok <- Genswarms.IR.Gate.validate_add_agent(swarm_info.config, spec),
             {:ok, name, new_info} <- do_add_agent(swarm_name, swarm_info, spec, opts) do
          new_state = put_swarm(state, swarm_name, new_info)
          maybe_persist(opts, swarm_name, :add_agent, normalize_spec_for_overlay(spec, opts))
          broadcast_topology_changed(swarm_name)
          {:reply, {:ok, name}, new_state}
        else
          {:error, _} = err -> {:reply, err, state}
        end
    end
  end

  def handle_call({:remove_agent, swarm_name, agent_name, opts}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :swarm_not_found}, state}

      swarm_info ->
        case do_remove_agent(swarm_name, swarm_info, agent_name) do
          {:ok, new_info} ->
            new_state = put_swarm(state, swarm_name, new_info)
            maybe_persist(opts, swarm_name, :remove_agent, %{name: agent_name})
            broadcast_topology_changed(swarm_name)
            {:reply, :ok, new_state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:add_object, swarm_name, spec, opts}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :swarm_not_found}, state}

      swarm_info ->
        case do_add_object(swarm_name, swarm_info, spec, opts) do
          {:ok, name, new_info} ->
            new_state = put_swarm(state, swarm_name, new_info)
            maybe_persist(opts, swarm_name, :add_object, normalize_spec_for_overlay(spec, opts))
            broadcast_topology_changed(swarm_name)
            {:reply, {:ok, name}, new_state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:remove_object, swarm_name, object_name, opts}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :swarm_not_found}, state}

      swarm_info ->
        case do_remove_object(swarm_name, swarm_info, object_name) do
          {:ok, new_info} ->
            new_state = put_swarm(state, swarm_name, new_info)
            maybe_persist(opts, swarm_name, :remove_object, %{name: object_name})
            broadcast_topology_changed(swarm_name)
            {:reply, :ok, new_state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:add_topology_edges, swarm_name, edges, opts}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :swarm_not_found}, state}

      swarm_info ->
        case Router.add_edges(swarm_name, edges) do
          :ok ->
            new_config =
              update_in_config_topology(swarm_info.config, edges, &Enum.uniq(&1 ++ edges))

            new_info = %{swarm_info | config: new_config}
            new_state = put_swarm(state, swarm_name, new_info)
            maybe_persist(opts, swarm_name, :add_topology_edges, %{edges: edges})
            broadcast_topology_changed(swarm_name)
            {:reply, :ok, new_state}

          err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:remove_topology_edges, swarm_name, edges, opts}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :swarm_not_found}, state}

      swarm_info ->
        case Router.remove_edges(swarm_name, edges) do
          :ok ->
            new_topology = swarm_info.config.topology -- edges
            new_config = %{swarm_info.config | topology: new_topology}
            new_info = %{swarm_info | config: new_config}
            new_state = put_swarm(state, swarm_name, new_info)
            maybe_persist(opts, swarm_name, :remove_topology_edges, %{edges: edges})
            broadcast_topology_changed(swarm_name)
            {:reply, :ok, new_state}

          err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:get_full_config, swarm_name}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil -> {:reply, {:error, :swarm_not_found}, state}
      swarm_info -> {:reply, {:ok, swarm_info.config}, state}
    end
  end

  def handle_call({:scale_agent_group, swarm_name, base_name, target_count, opts}, _from, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        {:reply, {:error, :swarm_not_found}, state}

      swarm_info ->
        with :ok <- Genswarms.IR.Gate.validate_scale(swarm_info.config, base_name, target_count),
             {:ok, result, new_info} <-
               do_scale_agent_group(swarm_name, swarm_info, base_name, target_count, opts) do
          new_state = put_swarm(state, swarm_name, new_info)

          maybe_persist(opts, swarm_name, :scale_agent_group, %{
            base_name: base_name,
            target_count: target_count
          })

          broadcast_topology_changed(swarm_name)
          {:reply, {:ok, result}, new_state}
        else
          {:error, _} = err -> {:reply, err, state}
        end
    end
  end

  # Private functions

  defp do_start_swarm(config, config_path, state) do
    swarm_name = config.name

    case Genswarms.IR.Gate.validate_start(config) do
      {:error, reason} ->
        LogStore.log(
          :error,
          :swarm,
          :ir_validation_failed,
          "Refusing to start swarm '#{swarm_name}': IR validation failed",
          swarm: swarm_name,
          metadata: %{config_path: config_path, reason: inspect(reason)}
        )

        {:reply, {:error, reason}, state}

      :ok ->
        start_validated_swarm(config, config_path, state, swarm_name)
    end
  end

  defp start_validated_swarm(config, config_path, state, swarm_name) do
    if Map.has_key?(state.swarms, swarm_name) do
      LogStore.log(
        :error,
        :swarm,
        :already_running,
        "Cannot start swarm '#{swarm_name}': already running",
        swarm: swarm_name,
        metadata: %{config_path: config_path}
      )

      {:reply, {:error, :already_exists}, state}
    else
      object_count = length(config.objects || [])

      Logger.info(
        "Starting swarm #{swarm_name} with #{length(config.agents)} agents and #{object_count} objects"
      )

      swarm_info = %{
        config: config,
        config_path: config_path,
        started_at: DateTime.utc_now(),
        status: :starting
      }

      new_state = %{state | swarms: Map.put(state.swarms, swarm_name, swarm_info)}

      # Register topology
      Router.register_topology(swarm_name, config.topology)

      # Build adjacency map to get connections for each agent
      adjacency_map = SwarmConfig.build_adjacency_map(config.topology)

      # Start agents
      agent_results =
        Enum.map(config.agents, fn agent ->
          # Get connections for this agent from topology
          connections = Map.get(adjacency_map, agent.name, [])

          agent_config = %{
            name: agent.name,
            swarm_name: swarm_name,
            backend: agent.backend,
            skills: Map.get(agent, :skills, []),
            model: Map.get(agent, :model),
            endpoint: Map.get(agent, :endpoint),
            presets: Map.get(agent, :presets, []),
            config: Map.get(agent, :config, %{}),
            connections: connections
          }

          AgentSupervisor.start_agent(agent_config)
        end)

      # Start objects
      object_results =
        Enum.map(config.objects || [], fn object ->
          object_config = %{
            name: object.name,
            swarm_name: swarm_name,
            handler: Map.get(object, :handler),
            backend: Map.get(object, :backend),
            config: Map.get(object, :config, %{})
          }

          ObjectSupervisor.start_object(object_config)
        end)

      # Check if all agents and objects started successfully
      all_results = agent_results ++ object_results
      errors = Enum.filter(all_results, &match?({:error, _}, &1))

      final_status = if Enum.empty?(errors), do: :running, else: :error

      updated_info = %{swarm_info | status: final_status}
      final_state = %{new_state | swarms: Map.put(new_state.swarms, swarm_name, updated_info)}

      # Broadcast start event
      Phoenix.PubSub.broadcast(
        Genswarms.PubSub,
        "swarm:#{swarm_name}",
        {:swarm_started, swarm_name, final_status}
      )

      error_details = Enum.map(errors, fn {:error, reason} -> inspect(reason) end)

      emit_telemetry(:swarm_started, %{
        swarm: swarm_name,
        agent_count: length(config.agents),
        object_count: object_count,
        status: final_status,
        error_count: length(errors),
        errors: error_details,
        level: if(errors == [], do: :info, else: :error)
      })

      if Enum.empty?(errors) do
        # Replay overlay events on top of the freshly started seed
        replayed_state = replay_overlay(swarm_name, final_state)

        {:reply, {:ok, swarm_name}, replayed_state}
      else
        {:reply, {:error, {:partial_start, errors}}, final_state}
      end
    end
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:genswarms, :swarm, event],
      %{time: System.system_time()},
      metadata
    )
  end

  defp do_pause_containers(swarm_name) do
    prefix = "szc-#{swarm_name}-"

    case System.cmd("docker", ["ps", "--filter", "name=#{prefix}", "--format", "{{.Names}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, prefix))

        if containers == [] do
          {:ok, 0}
        else
          results =
            Enum.map(containers, fn container ->
              case System.cmd("docker", ["pause", container], stderr_to_stdout: true) do
                {_, 0} -> :ok
                _ -> :error
              end
            end)

          {:ok, Enum.count(results, &(&1 == :ok))}
        end

      {err, _} ->
        {:error, err}
    end
  end

  defp do_resume_containers(swarm_name) do
    prefix = "szc-#{swarm_name}-"

    case System.cmd(
           "docker",
           [
             "ps",
             "--filter",
             "name=#{prefix}",
             "--filter",
             "status=paused",
             "--format",
             "{{.Names}}"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, prefix))

        if containers == [] do
          {:ok, 0}
        else
          results =
            Enum.map(containers, fn container ->
              case System.cmd("docker", ["unpause", container], stderr_to_stdout: true) do
                {_, 0} -> :ok
                _ -> :error
              end
            end)

          {:ok, Enum.count(results, &(&1 == :ok))}
        end

      {err, _} ->
        {:error, err}
    end
  end

  # -- Overlay replay --

  defp replay_overlay(swarm_name, state) do
    events = Genswarms.CLI.SwarmRegistry.load_overlay(swarm_name)

    if events == [] do
      state
    else
      Logger.info("Replaying #{length(events)} overlay events for swarm #{swarm_name}")

      Enum.reduce(events, state, fn {op, payload}, acc_state ->
        apply_overlay_event(swarm_name, op, payload, acc_state)
      end)
    end
  end

  defp apply_overlay_event(swarm_name, :add_agent, payload, state) do
    {connections, payload} = Map.pop(payload, :_connections, [])
    {incoming, spec} = Map.pop(payload, :_incoming, [])

    case Map.get(state.swarms, swarm_name) do
      nil ->
        state

      swarm_info ->
        case do_add_agent(swarm_name, swarm_info, spec,
               connections: connections,
               incoming: incoming
             ) do
          {:ok, _name, new_info} ->
            put_swarm(state, swarm_name, new_info)

          {:error, reason} ->
            Logger.warning(
              "Overlay replay: failed to apply add_agent #{inspect(spec[:name])}: #{inspect(reason)}"
            )

            state
        end
    end
  end

  defp apply_overlay_event(swarm_name, :remove_agent, %{name: name}, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        state

      swarm_info ->
        case do_remove_agent(swarm_name, swarm_info, name) do
          {:ok, new_info} -> put_swarm(state, swarm_name, new_info)
          _ -> state
        end
    end
  end

  defp apply_overlay_event(swarm_name, :add_object, payload, state) do
    {connections, payload} = Map.pop(payload, :_connections, [])
    {incoming, spec} = Map.pop(payload, :_incoming, [])

    case Map.get(state.swarms, swarm_name) do
      nil ->
        state

      swarm_info ->
        case do_add_object(swarm_name, swarm_info, spec,
               connections: connections,
               incoming: incoming
             ) do
          {:ok, _name, new_info} ->
            put_swarm(state, swarm_name, new_info)

          {:error, reason} ->
            Logger.warning(
              "Overlay replay: failed to apply add_object #{inspect(spec[:name])}: #{inspect(reason)}"
            )

            state
        end
    end
  end

  defp apply_overlay_event(swarm_name, :remove_object, %{name: name}, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        state

      swarm_info ->
        case do_remove_object(swarm_name, swarm_info, name) do
          {:ok, new_info} -> put_swarm(state, swarm_name, new_info)
          _ -> state
        end
    end
  end

  defp apply_overlay_event(swarm_name, :add_topology_edges, %{edges: edges}, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        state

      swarm_info ->
        edges_tuples =
          Enum.map(edges, fn
            [f, t] -> {f, t}
            {f, t} -> {f, t}
          end)

        Router.add_edges(swarm_name, edges_tuples)
        new_config = update_in_config_topology(swarm_info.config, edges_tuples, nil)
        put_swarm(state, swarm_name, %{swarm_info | config: new_config})
    end
  end

  defp apply_overlay_event(swarm_name, :remove_topology_edges, %{edges: edges}, state) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        state

      swarm_info ->
        edges_tuples =
          Enum.map(edges, fn
            [f, t] -> {f, t}
            {f, t} -> {f, t}
          end)

        Router.remove_edges(swarm_name, edges_tuples)
        new_topology = swarm_info.config.topology -- edges_tuples

        put_swarm(state, swarm_name, %{
          swarm_info
          | config: %{swarm_info.config | topology: new_topology}
        })
    end
  end

  defp apply_overlay_event(
         swarm_name,
         :scale_agent_group,
         %{base_name: base, target_count: n},
         state
       ) do
    case Map.get(state.swarms, swarm_name) do
      nil ->
        state

      swarm_info ->
        case do_scale_agent_group(swarm_name, swarm_info, base, n, []) do
          {:ok, _result, new_info} -> put_swarm(state, swarm_name, new_info)
          _ -> state
        end
    end
  end

  defp apply_overlay_event(swarm_name, op, payload, state) do
    Logger.warning(
      "Overlay replay: unknown op #{inspect(op)} for swarm #{swarm_name}: #{inspect(payload)}"
    )

    state
  end

  # -- Dynamic mutation helpers --

  defp do_add_agent(swarm_name, swarm_info, spec, opts) do
    spec = normalize_agent_spec(spec)
    name = spec.name
    connections = Keyword.get(opts, :connections, [])
    incoming = Keyword.get(opts, :incoming, [])

    cond do
      already_registered?(swarm_name, name) ->
        {:error, {:already_exists, name}}

      true ->
        # Compute new edges (skip duplicates against current topology)
        existing = swarm_info.config.topology
        out_edges = Enum.map(connections, fn t -> {name, t} end)
        in_edges = Enum.map(incoming, fn s -> {s, name} end)
        all_new_edges = Enum.uniq(out_edges ++ in_edges) -- existing

        # Edges first (so first message after start can route)
        case Router.add_edges(swarm_name, all_new_edges) do
          :ok ->
            agent_config = %{
              name: name,
              swarm_name: swarm_name,
              backend: Map.get(spec, :backend),
              skills: Map.get(spec, :skills, []),
              model: Map.get(spec, :model),
              endpoint: Map.get(spec, :endpoint),
              presets: Map.get(spec, :presets, []),
              config: Map.get(spec, :config, %{}),
              connections: connections
            }

            case AgentSupervisor.start_agent(agent_config) do
              {:ok, _pid} ->
                new_config = %{
                  swarm_info.config
                  | agents: swarm_info.config.agents ++ [spec],
                    topology: existing ++ all_new_edges
                }

                broadcast_agent_added(swarm_name, name, spec)
                emit_telemetry(:agent_added, %{swarm: swarm_name, agent: name})
                {:ok, name, %{swarm_info | config: new_config}}

              {:error, reason} ->
                # Rollback edges
                Router.remove_edges(swarm_name, all_new_edges)
                {:error, {:agent_start_failed, reason}}
            end

          err ->
            err
        end
    end
  end

  defp do_remove_agent(swarm_name, swarm_info, agent_name) do
    case AgentSupervisor.stop_agent(swarm_name, agent_name) do
      :ok ->
        # Remove from topology in both Router and config
        Router.remove_node(swarm_name, agent_name)

        new_topology =
          Enum.reject(swarm_info.config.topology, fn {f, t} ->
            f == agent_name or t == agent_name
          end)

        new_agents = Enum.reject(swarm_info.config.agents, &spec_has_name?(&1, agent_name))

        new_config = %{
          swarm_info.config
          | agents: new_agents,
            topology: new_topology
        }

        broadcast_agent_removed(swarm_name, agent_name)
        emit_telemetry(:agent_removed, %{swarm: swarm_name, agent: agent_name})
        {:ok, %{swarm_info | config: new_config}}

      err ->
        err
    end
  end

  defp do_add_object(swarm_name, swarm_info, spec, opts) do
    spec = normalize_object_spec(spec)
    name = spec.name
    connections = Keyword.get(opts, :connections, [])
    incoming = Keyword.get(opts, :incoming, [])

    cond do
      already_registered?(swarm_name, name) ->
        {:error, {:already_exists, name}}

      true ->
        existing = swarm_info.config.topology
        out_edges = Enum.map(connections, fn t -> {name, t} end)
        in_edges = Enum.map(incoming, fn s -> {s, name} end)
        all_new_edges = Enum.uniq(out_edges ++ in_edges) -- existing

        case Router.add_edges(swarm_name, all_new_edges) do
          :ok ->
            object_config = %{
              name: name,
              swarm_name: swarm_name,
              handler: Map.get(spec, :handler),
              backend: Map.get(spec, :backend),
              config: Map.get(spec, :config, %{})
            }

            case ObjectSupervisor.start_object(object_config) do
              {:ok, _pid} ->
                new_objects = (swarm_info.config.objects || []) ++ [spec]

                new_config = %{
                  swarm_info.config
                  | objects: new_objects,
                    topology: existing ++ all_new_edges
                }

                emit_telemetry(:object_added, %{swarm: swarm_name, object: name})
                {:ok, name, %{swarm_info | config: new_config}}

              {:error, reason} ->
                Router.remove_edges(swarm_name, all_new_edges)
                {:error, {:object_start_failed, reason}}
            end

          err ->
            err
        end
    end
  end

  defp do_remove_object(swarm_name, swarm_info, object_name) do
    case ObjectSupervisor.stop_object(swarm_name, object_name) do
      :ok ->
        Router.remove_node(swarm_name, object_name)

        new_topology =
          Enum.reject(swarm_info.config.topology, fn {f, t} ->
            f == object_name or t == object_name
          end)

        new_objects =
          Enum.reject(swarm_info.config.objects || [], &spec_has_name?(&1, object_name))

        new_config = %{
          swarm_info.config
          | objects: new_objects,
            topology: new_topology
        }

        emit_telemetry(:object_removed, %{swarm: swarm_name, object: object_name})
        {:ok, %{swarm_info | config: new_config}}

      err ->
        err
    end
  end

  defp do_scale_agent_group(swarm_name, swarm_info, base_name, target_count, _opts) do
    existing_members = find_group_members(swarm_name, base_name)

    case find_template_spec(swarm_info.config.agents, base_name) do
      nil ->
        {:error, {:no_template, base_name}}

      template ->
        # Target names: base_name_1..base_name_target_count
        target_names =
          if target_count == 0 do
            []
          else
            Enum.map(1..target_count, fn i -> :"#{base_name}_#{i}" end)
          end

        to_add = target_names -- existing_members
        to_remove = existing_members -- target_names

        # Remove extras first (frees names, frees workspaces)
        {removed, info_after_remove} =
          Enum.reduce(to_remove, {[], swarm_info}, fn name, {acc, info} ->
            case do_remove_agent(swarm_name, info, name) do
              {:ok, new_info} -> {[name | acc], new_info}
              {:error, _} -> {acc, info}
            end
          end)

        # Add new agents
        {added, failed, info_final} =
          Enum.reduce(to_add, {[], [], info_after_remove}, fn name, {add_acc, fail_acc, info} ->
            new_spec = derive_agent_spec(template, base_name, name)

            # Auto-connect new agent matching existing template's topology edges
            connections = derived_connections(swarm_info.config.topology, template_name(template))
            incoming = derived_incoming(swarm_info.config.topology, template_name(template))

            opts = [connections: connections, incoming: incoming]

            case do_add_agent(swarm_name, info, new_spec, opts) do
              {:ok, _name, new_info} -> {[name | add_acc], fail_acc, new_info}
              {:error, reason} -> {add_acc, [{name, reason} | fail_acc], info}
            end
          end)

        {:ok,
         %{
           added: Enum.reverse(added),
           removed: Enum.reverse(removed),
           failed: Enum.reverse(failed)
         }, info_final}
    end
  end

  # -- spec / template helpers --

  defp normalize_agent_spec(spec) when is_map(spec) do
    Map.update!(spec, :name, fn n ->
      cond do
        is_atom(n) -> n
        is_binary(n) -> String.to_atom(n)
      end
    end)
  end

  defp normalize_object_spec(spec) when is_map(spec) do
    normalize_agent_spec(spec)
  end

  defp spec_has_name?(spec, name) do
    case Map.get(spec, :name) do
      ^name -> true
      n when is_binary(n) -> String.to_atom(n) == name
      _ -> false
    end
  end

  defp template_name(spec), do: Map.get(spec, :name)

  defp find_template_spec(agents, base_name) do
    # Prefer `base_name_1`, fall back to `base_name`, fall back to any `base_name_*`
    Enum.find(agents, &spec_has_name?(&1, :"#{base_name}_1")) ||
      Enum.find(agents, &spec_has_name?(&1, base_name)) ||
      Enum.find(agents, fn spec ->
        n = Map.get(spec, :name) |> to_string()
        String.starts_with?(n, "#{base_name}_")
      end)
  end

  defp derive_agent_spec(template, base_name, new_name) do
    template
    |> Map.put(:name, new_name)
    |> maybe_rename_workspace(template_name(template), new_name, base_name)
  end

  defp maybe_rename_workspace(spec, old_name, new_name, _base_name) do
    case get_in(spec, [:config, :workspace]) do
      nil ->
        spec

      ws ->
        old_str = to_string(old_name)
        new_str = to_string(new_name)

        new_ws =
          cond do
            String.ends_with?(ws, "/" <> old_str) ->
              String.replace_suffix(ws, "/" <> old_str, "/" <> new_str)

            true ->
              # Append new agent name to workspace base
              Path.join(ws, new_str)
          end

        put_in(spec, [:config, :workspace], new_ws)
    end
  end

  defp derived_connections(topology, template_name) do
    topology
    |> Enum.filter(fn {f, _t} -> f == template_name end)
    |> Enum.map(fn {_f, t} -> t end)
    |> Enum.uniq()
  end

  defp derived_incoming(topology, template_name) do
    topology
    |> Enum.filter(fn {_f, t} -> t == template_name end)
    |> Enum.map(fn {f, _t} -> f end)
    |> Enum.uniq()
  end

  defp find_group_members(swarm_name, base_name) do
    prefix_re = ~r/^#{Regex.escape(to_string(base_name))}(_\d+)?$/

    Registry.select(Genswarms.AgentRegistry, [
      {{{swarm_name, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
    |> Enum.filter(fn name -> Regex.match?(prefix_re, to_string(name)) end)
  end

  defp already_registered?(swarm_name, name) do
    case Registry.lookup(Genswarms.AgentRegistry, {swarm_name, name}) do
      [] -> false
      _ -> true
    end
  end

  defp update_in_config_topology(config, edges, _merge_fun) do
    %{config | topology: Enum.uniq(config.topology ++ edges)}
  end

  defp put_swarm(state, swarm_name, swarm_info) do
    %{state | swarms: Map.put(state.swarms, swarm_name, swarm_info)}
  end

  defp maybe_persist(opts, swarm_name, op, payload) do
    if Keyword.get(opts, :persist, false) do
      Genswarms.CLI.SwarmRegistry.append_overlay(swarm_name, op, payload)
    else
      :ok
    end
  end

  defp normalize_spec_for_overlay(spec, opts) do
    spec
    |> Map.new()
    |> Map.put(:_connections, Keyword.get(opts, :connections, []))
    |> Map.put(:_incoming, Keyword.get(opts, :incoming, []))
  end

  defp broadcast_agent_added(swarm_name, name, spec) do
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{swarm_name}",
      {:agent_added, swarm_name, name, spec}
    )
  end

  defp broadcast_agent_removed(swarm_name, name) do
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{swarm_name}",
      {:agent_removed, swarm_name, name}
    )
  end

  defp broadcast_topology_changed(swarm_name) do
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{swarm_name}",
      {:topology_changed, swarm_name}
    )
  end

  defp check_containers_paused(swarm_name) do
    prefix = "szc-#{swarm_name}-"

    case System.cmd(
           "docker",
           [
             "ps",
             "--filter",
             "name=#{prefix}",
             "--filter",
             "status=paused",
             "--format",
             "{{.Names}}"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, prefix))

        length(containers) > 0

      _ ->
        false
    end
  end
end
