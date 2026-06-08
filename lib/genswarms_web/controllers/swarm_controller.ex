defmodule GenswarmsWeb.SwarmController do
  @moduledoc """
  REST API controller for swarm management.
  """

  use GenswarmsWeb, :controller

  alias Genswarms.SwarmManager
  alias Genswarms.Agents.{AgentSupervisor, AgentServer}
  alias Genswarms.Objects.{ObjectSupervisor, ObjectServer}
  alias Genswarms.Routing.Router
  alias Genswarms.CLI.SwarmRegistry

  @doc """
  Lists all swarms.

  GET /api/swarms
  """
  def index(conn, _params) do
    swarms = SwarmManager.list()
    json(conn, %{swarms: swarms})
  end

  @doc """
  Creates a new swarm from configuration.

  POST /api/swarms
  Body: { "config": { ... } } or { "config_path": "path/to/config.exs" }
  """
  def create(conn, %{"config" => config}) do
    case SwarmManager.start_from_config(config) do
      {:ok, swarm_name} ->
        conn
        |> put_status(:created)
        |> json(%{status: "created", swarm_name: swarm_name})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: format_error(reason)})
    end
  end

  def create(conn, %{"config_path" => path}) do
    # config_path is attacker-controlled and gets loaded (and, for .exs,
    # evaluated). Restrict it to the allowed config directory so it cannot read
    # or execute arbitrary files on the host.
    case Genswarms.Config.PathGuard.safe_config_path(path) do
      {:ok, safe_path} ->
        case SwarmManager.start_swarm(safe_path) do
          {:ok, swarm_name} ->
            conn
            |> put_status(:created)
            |> json(%{status: "created", swarm_name: swarm_name})

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: format_error(reason)})
        end

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid config_path"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'config' or 'config_path' parameter"})
  end

  @doc """
  Gets swarm status with detailed information.

  GET /api/swarms/:name
  """
  def show(conn, %{"name" => name}) do
    # Try in-process SwarmManager first, fall back to SQLite registry for daemon swarms
    result =
      try do
        SwarmManager.status(name)
      catch
        :exit, {:noproc, _} ->
          get_daemon_swarm_status(name)
      end

    case result do
      {:ok, status} ->
        # Get detailed topology
        topology =
          case Router.get_topology(name) do
            {:ok, topo} -> serialize_topology(topo)
            _ -> parse_topology_from_config(status[:config_path])
          end

        # Get file paths
        file_paths = %{
          config: status[:config_path],
          data_dir: Path.join([System.user_home!(), ".subzeroclaw", "swarms", name]),
          log: Path.join([File.cwd!(), ".genswarms", "logs", "#{name}.log"])
        }

        # Enhance agent info with details
        agents =
          (status[:agents] || [])
          |> Enum.map(fn agent ->
            Map.merge(agent, %{
              backend_type: format_backend_type(Map.get(agent, :backend)),
              skills_paths: get_agent_skills_paths(name, agent[:name]),
              container_name: "szc-#{name}-#{agent[:name]}",
              container_status: get_container_status(name, agent[:name])
            })
          end)

        # Enhance object info
        objects =
          (status[:objects] || [])
          |> Enum.map(fn object ->
            Map.merge(object, %{
              handler_module: inspect(Map.get(object, :handler)),
              source_file: get_handler_source(Map.get(object, :handler))
            })
          end)

        enhanced_status =
          status
          |> Map.put(:agents, agents)
          |> Map.put(:objects, objects)
          |> Map.put(:topology, topology)
          |> Map.put(:file_paths, file_paths)

        json(conn, enhanced_status)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Swarm not found"})
    end
  end

  @doc """
  Stops and optionally purges a swarm.

  DELETE /api/swarms/:name
  Query params:
    - purge: true to delete all data (files, events, tasks)
  """
  def delete(conn, %{"name" => name} = params) do
    purge = params["purge"] == "true"

    result =
      try do
        SwarmManager.stop(name)
      catch
        :exit, {:noproc, _} ->
          # Daemon swarm - stop containers directly
          stop_daemon_swarm(name)
      end

    case result do
      {:ok, config_path} ->
        if purge do
          # Delete all swarm data
          SwarmRegistry.delete_swarm(name)
          SwarmRegistry.delete_swarm_files(name)
          json(conn, %{status: "purged", swarm_name: name, config_path: config_path})
        else
          json(conn, %{status: "stopped", swarm_name: name, config_path: config_path})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Swarm not found"})
    end
  end

  @doc """
  Pauses a swarm (freezes all containers).

  POST /api/swarms/:name/pause
  """
  def pause(conn, %{"name" => name}) do
    result =
      try do
        SwarmManager.pause(name)
      catch
        :exit, {:noproc, _} ->
          # Daemon swarm - pause containers directly
          pause_containers(name)
      end

    case result do
      {:ok, count} ->
        json(conn, %{status: "paused", swarm_name: name, containers_paused: count})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Swarm not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: format_error(reason)})
    end
  end

  @doc """
  Resumes a paused swarm.

  POST /api/swarms/:name/resume
  """
  def resume(conn, %{"name" => name}) do
    result =
      try do
        SwarmManager.resume(name)
      catch
        :exit, {:noproc, _} ->
          # Daemon swarm - resume containers directly
          resume_containers(name)
      end

    case result do
      {:ok, count} ->
        json(conn, %{status: "resumed", swarm_name: name, containers_resumed: count})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Swarm not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: format_error(reason)})
    end
  end

  @doc """
  Restarts a swarm.

  POST /api/swarms/:name/restart
  Query params:
    - delete: true to clean slate (delete old data before restart)
  """
  def restart(conn, %{"name" => name} = params) do
    delete_data = params["delete"] == "true"

    # Get config path before stopping
    config_path =
      case SwarmRegistry.get_swarm(name) do
        {:ok, swarm} -> swarm.config_path
        _ -> nil
      end

    if is_nil(config_path) do
      conn
      |> put_status(:not_found)
      |> json(%{error: "Swarm not found or no config path"})
    else
      # Stop the swarm
      try do
        SwarmManager.stop(name)
      catch
        :exit, {:noproc, _} ->
          stop_daemon_swarm(name)
      end

      # Delete data if requested
      if delete_data do
        SwarmRegistry.delete_swarm(name)
        SwarmRegistry.delete_swarm_files(name)
      end

      # Restart from config
      case SwarmManager.start_swarm(config_path) do
        {:ok, new_name} ->
          json(conn, %{status: "restarted", swarm_name: new_name, delete_data: delete_data})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: format_error(reason)})
      end
    end
  end

  @doc """
  Routes a message between agents in a swarm.

  POST /api/swarms/:name/message
  Body: { "from": "agent1", "to": "agent2", "content": "message" }
  """
  def route_message(conn, %{"name" => name, "from" => from, "to" => to, "content" => content}) do
    from_atom = String.to_atom(from)
    to_atom = String.to_atom(to)

    Router.route(name, from_atom, to_atom, content)
    json(conn, %{status: "routed", from: from, to: to, swarm: name})
  end

  def route_message(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'from', 'to', or 'content' parameter"})
  end

  @doc """
  Cleans up stopped/crashed swarms.

  POST /api/swarms/clean
  Query params:
    - all: true to also clear all events
  """
  def clean(conn, params) do
    clear_events = params["all"] == "true"

    # Cleanup stale swarm entries
    SwarmRegistry.cleanup_stale()

    # Get list of stopped/crashed swarms
    swarms = SwarmRegistry.list_swarms()

    stopped_swarms =
      swarms
      |> Enum.filter(fn s -> s.status in [:stopped, :crashed] end)

    # Delete stopped/crashed swarm entries
    cleaned_count =
      Enum.reduce(stopped_swarms, 0, fn swarm, acc ->
        SwarmRegistry.delete_swarm(swarm.name)
        SwarmRegistry.delete_swarm_files(swarm.name)
        acc + 1
      end)

    # Clear all events if requested
    if clear_events do
      SwarmRegistry.clear_all_events()
    end

    json(conn, %{
      status: "cleaned",
      swarms_removed: cleaned_count,
      events_cleared: clear_events
    })
  end

  @doc """
  Lists agents in a swarm.

  GET /api/swarms/:swarm_name/agents
  """
  def list_agents(conn, %{"swarm_name" => swarm_name}) do
    agents = AgentSupervisor.list_agents(swarm_name)

    agent_details =
      Enum.map(agents, fn %{name: name} ->
        case AgentServer.get_status(swarm_name, name) do
          status when is_map(status) -> status
          _ -> %{name: name, state: :unknown}
        end
      end)

    json(conn, %{agents: agent_details})
  end

  @doc """
  Gets status of a specific agent.

  GET /api/swarms/:swarm_name/agents/:agent_name
  """
  def show_agent(conn, %{"swarm_name" => swarm_name, "agent_name" => agent_name}) do
    agent_name = String.to_atom(agent_name)

    case AgentServer.get_status(swarm_name, agent_name) do
      status when is_map(status) ->
        json(conn, status)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  rescue
    _ ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Agent not found"})
  end

  @doc """
  Sends a task to an agent.

  POST /api/swarms/:swarm_name/agents/:agent_name/task
  Body: { "task": "..." }
  """
  def send_task(conn, %{"swarm_name" => swarm_name, "agent_name" => agent_name, "task" => task}) do
    alias Genswarms.CLI.SwarmRegistry

    # Try in-process first, fall back to task queue for daemon swarms
    result =
      try do
        SwarmManager.send_task(swarm_name, agent_name, task)
      catch
        :exit, {:noproc, _} ->
          # Daemon swarm - queue task in SQLite for daemon to pick up
          SwarmRegistry.queue_task(swarm_name, agent_name, task)
      end

    case result do
      :ok ->
        json(conn, %{status: "sent", agent: agent_name, task: task})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: format_error(reason)})
    end
  end

  def send_task(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'task' parameter"})
  end

  @doc """
  Restarts an agent.

  POST /api/swarms/:swarm_name/agents/:agent_name/restart
  """
  def restart_agent(conn, %{"swarm_name" => swarm_name, "agent_name" => agent_name}) do
    agent_name_atom = String.to_atom(agent_name)

    # Get current status to retrieve config
    case SwarmManager.status(swarm_name) do
      {:ok, %{config: _config}} ->
        # Find agent config (simplified - would need full config in real impl)
        case AgentSupervisor.restart_agent(swarm_name, agent_name_atom, %{name: agent_name_atom}) do
          {:ok, _pid} ->
            json(conn, %{status: "restarted", agent: agent_name})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: format_error(reason)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Swarm not found"})
    end
  end

  @doc """
  Gets the topology of a swarm.

  GET /api/swarms/:swarm_name/topology
  """
  def topology(conn, %{"swarm_name" => swarm_name}) do
    case Router.get_topology(swarm_name) do
      {:ok, topology} ->
        # Convert to serializable format
        serializable =
          Enum.map(topology, fn {from, targets} ->
            %{from: from, targets: targets}
          end)

        json(conn, %{topology: serializable})

      {:error, :unknown_swarm} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Swarm not found"})
    end
  end

  @doc """
  Lists the non-agentic objects in a swarm with their lifecycle state.

  GET /api/swarms/:swarm_name/objects
  """
  def list_objects(conn, %{"swarm_name" => swarm_name}) do
    objects =
      swarm_name
      |> ObjectSupervisor.list_objects()
      |> Enum.map(fn o ->
        %{
          name: to_string(o.name),
          state: o.state,
          handler: o.handler && inspect(o.handler)
        }
      end)

    json(conn, %{objects: objects})
  end

  @doc """
  Gets the live read-only state of a single object.

  Generic introspection: returns whatever the object handler keeps as its domain
  state via `ObjectServer.get_state/2`. The framework imposes no schema on it.

  GET /api/swarms/:swarm_name/objects/:object_name
  """
  def show_object(conn, %{"swarm_name" => swarm_name, "object_name" => object_name}) do
    name = String.to_existing_atom(object_name)

    state = ObjectServer.get_state(swarm_name, name)
    json(conn, %{object: object_name, state: state})
  rescue
    ArgumentError ->
      conn |> put_status(:not_found) |> json(%{error: "Object not found"})
  catch
    :exit, _ ->
      conn |> put_status(:not_found) |> json(%{error: "Object not found"})
  end

  @doc """
  Gets recent messages for a swarm.

  GET /api/swarms/:swarm_name/messages
  """
  def messages(conn, %{"swarm_name" => swarm_name} = params) do
    limit = Map.get(params, "limit", "100") |> String.to_integer()
    messages = Router.get_message_log(swarm_name, limit)

    json(conn, %{messages: messages})
  end

  @doc """
  Gets agent conversation logs (from subzeroclaw log files).

  GET /api/swarms/:swarm_name/agents/:agent_name/logs
  """
  def agent_logs(conn, %{"swarm_name" => swarm_name, "agent_name" => agent_name}) do
    agent_name = String.to_atom(agent_name)

    try do
      logs = AgentServer.get_logs(swarm_name, agent_name)
      json(conn, %{logs: logs})
    rescue
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  @doc """
  Gets agent message history.

  GET /api/swarms/:swarm_name/agents/:agent_name/history
  """
  def agent_history(conn, %{"swarm_name" => swarm_name, "agent_name" => agent_name} = params) do
    agent_name = String.to_atom(agent_name)
    limit = Map.get(params, "limit", "100") |> String.to_integer()

    try do
      history = AgentServer.get_history(swarm_name, agent_name, limit)
      json(conn, %{history: history})
    rescue
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  @doc """
  Gets agent skills content.

  GET /api/swarms/:swarm_name/agents/:agent_name/skills
  """
  def agent_skills(conn, %{"swarm_name" => swarm_name, "agent_name" => agent_name}) do
    agent_name = String.to_atom(agent_name)

    try do
      skills = AgentServer.get_skills_content(swarm_name, agent_name)
      json(conn, %{skills: skills})
    rescue
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  @doc """
  Updates an agent skill.

  PUT /api/swarms/:swarm_name/agents/:agent_name/skills/:skill_name
  Body: { "content": "..." }
  """
  def update_skill(conn, %{
        "swarm_name" => swarm_name,
        "agent_name" => agent_name,
        "skill_name" => skill_name,
        "content" => content
      }) do
    agent_name_atom = String.to_atom(agent_name)

    case AgentServer.update_skill(swarm_name, agent_name_atom, skill_name, content) do
      :ok ->
        json(conn, %{status: "updated", skill: skill_name})

      {:error, :invalid_skill_name} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid skill name"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: format_error(reason)})
    end
  end

  # Private helpers

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error({:invalid_topology, errors}), do: "Invalid topology: #{inspect(errors)}"
  defp format_error({:partial_start, errors}), do: "Partial start: #{inspect(errors)}"
  defp format_error(reason), do: inspect(reason)

  # Get daemon swarm status from SQLite registry
  defp get_daemon_swarm_status(name) do
    case SwarmRegistry.get_swarm(name) do
      {:ok, swarm} ->
        is_alive = SwarmRegistry.process_alive?(swarm.pid)
        status = if is_alive, do: swarm.status, else: :stopped

        # Get agents/objects from config
        {agents, objects} = get_agents_from_config(swarm.config_path)

        {:ok,
         %{
           name: swarm.name,
           status: status,
           started_at: swarm.started_at,
           config_path: swarm.config_path,
           agents: agents,
           objects: objects
         }}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp get_agents_from_config(nil), do: {[], []}

  defp get_agents_from_config(config_path) do
    if File.exists?(config_path) do
      try do
        {config, _} = Code.eval_file(config_path)

        agents =
          Map.get(config, :agents, [])
          |> Enum.map(fn agent ->
            %{
              name: agent.name,
              state: :unknown,
              backend: Map.get(agent, :backend, :local),
              model: Map.get(agent, :model),
              skills: Map.get(agent, :skills, [])
            }
          end)

        objects =
          Map.get(config, :objects, [])
          |> Enum.map(fn object ->
            %{
              name: object.name,
              state: :idle,
              handler: Map.get(object, :handler)
            }
          end)

        {agents, objects}
      rescue
        _ -> {[], []}
      end
    else
      {[], []}
    end
  end

  defp stop_daemon_swarm(name) do
    prefix = "szc-#{name}-"

    case System.cmd(
           "docker",
           ["ps", "-a", "--filter", "name=#{prefix}", "--format", "{{.Names}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, prefix))

        Enum.each(containers, fn container ->
          System.cmd("docker", ["stop", container], stderr_to_stdout: true)
          System.cmd("docker", ["rm", container], stderr_to_stdout: true)
        end)

        SwarmRegistry.mark_stopped(name)

        config_path =
          case SwarmRegistry.get_swarm(name) do
            {:ok, swarm} -> swarm.config_path
            _ -> nil
          end

        {:ok, config_path}

      _ ->
        {:error, :not_found}
    end
  end

  defp pause_containers(swarm_name) do
    prefix = "szc-#{swarm_name}-"

    case System.cmd("docker", ["ps", "--filter", "name=#{prefix}", "--format", "{{.Names}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, prefix))

        count =
          Enum.reduce(containers, 0, fn container, acc ->
            case System.cmd("docker", ["pause", container], stderr_to_stdout: true) do
              {_, 0} -> acc + 1
              _ -> acc
            end
          end)

        {:ok, count}

      _ ->
        {:error, "Failed to list containers"}
    end
  end

  defp resume_containers(swarm_name) do
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

        count =
          Enum.reduce(containers, 0, fn container, acc ->
            case System.cmd("docker", ["unpause", container], stderr_to_stdout: true) do
              {_, 0} -> acc + 1
              _ -> acc
            end
          end)

        {:ok, count}

      _ ->
        {:error, "Failed to list containers"}
    end
  end

  defp serialize_topology(topology) do
    Enum.map(topology, fn {from, targets} ->
      %{from: from, targets: targets}
    end)
  end

  defp parse_topology_from_config(nil), do: []

  defp parse_topology_from_config(config_path) do
    if File.exists?(config_path) do
      try do
        {config, _} = Code.eval_file(config_path)
        topology_list = Map.get(config, :topology, [])

        Enum.map(topology_list, fn {from, to} ->
          %{from: from, to: to}
        end)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp format_backend_type(:local), do: "local"
  defp format_backend_type({:docker, _}), do: "docker"
  defp format_backend_type({:docker, _, _}), do: "docker"
  defp format_backend_type({:ssh, _}), do: "ssh"
  defp format_backend_type({:ssh, _, _}), do: "ssh"
  defp format_backend_type(_), do: "unknown"

  defp get_agent_skills_paths(swarm_name, agent_name) do
    skills_dir =
      Path.join([
        System.user_home!(),
        ".subzeroclaw",
        "swarms",
        swarm_name,
        to_string(agent_name),
        "skills"
      ])

    if File.dir?(skills_dir) do
      case File.ls(skills_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(skills_dir, &1))

        _ ->
          []
      end
    else
      []
    end
  end

  defp get_container_status(swarm_name, agent_name) do
    container_name = "szc-#{swarm_name}-#{agent_name}"

    case System.cmd("docker", ["inspect", "-f", "{{.State.Status}}", container_name],
           stderr_to_stdout: true
         ) do
      {status, 0} -> String.trim(status)
      _ -> "not_found"
    end
  end

  defp get_handler_source(nil), do: nil

  defp get_handler_source(module) when is_atom(module) do
    case module.module_info(:compile)[:source] do
      source when is_list(source) -> to_string(source)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp get_handler_source(_), do: nil

  # -- Dynamic swarm endpoints --

  @doc """
  PATCH /api/swarms/:swarm_name/topology
  Body: { "add": [["from","to"], ...], "remove": [...] }
  """
  def patch_topology(conn, %{"swarm_name" => swarm} = params) do
    add = Map.get(params, "add", []) |> Enum.map(&parse_edge/1) |> Enum.reject(&is_nil/1)
    remove = Map.get(params, "remove", []) |> Enum.map(&parse_edge/1) |> Enum.reject(&is_nil/1)

    with :ok <- maybe_op(add, &SwarmManager.add_topology_edges(swarm, &1, persist: true)),
         :ok <- maybe_op(remove, &SwarmManager.remove_topology_edges(swarm, &1, persist: true)) do
      json(conn, %{status: "ok", added: length(add), removed: length(remove)})
    else
      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: format_error(reason)})
    end
  end

  @doc """
  POST /api/swarms/:swarm_name/agents
  Body: agent spec (name, backend, skills, ...) plus optional "connections", "incoming"
  """
  def add_agent(conn, %{"swarm_name" => swarm} = params) do
    {opts, spec_params} = extract_topology_opts(params)
    spec = parse_agent_spec(spec_params)

    case SwarmManager.add_agent(swarm, spec, Keyword.put(opts, :persist, true)) do
      {:ok, name} ->
        conn |> put_status(:created) |> json(%{status: "added", name: name})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: format_error(reason)})
    end
  end

  @doc """
  DELETE /api/swarms/:swarm_name/agents/:agent_name
  """
  def remove_agent(conn, %{"swarm_name" => swarm, "agent_name" => name}) do
    case SwarmManager.remove_agent(swarm, name, persist: true) do
      :ok ->
        json(conn, %{status: "removed", name: name})

      {:error, reason} ->
        conn |> put_status(:not_found) |> json(%{error: format_error(reason)})
    end
  end

  @doc """
  POST /api/swarms/:swarm_name/agents/:base_name/scale
  Body: { "count": N }
  """
  def scale_agent_group(conn, %{"swarm_name" => swarm, "base_name" => base, "count" => count})
      when is_integer(count) and count >= 0 do
    case SwarmManager.scale_agent_group(swarm, base, count, persist: true) do
      {:ok, result} ->
        json(conn, %{status: "ok", result: serialize_scale_result(result)})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: format_error(reason)})
    end
  end

  def scale_agent_group(conn, _) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing or invalid 'count'"})
  end

  @doc """
  POST /api/swarms/:swarm_name/objects
  """
  def add_object(conn, %{"swarm_name" => swarm} = params) do
    {opts, spec_params} = extract_topology_opts(params)
    spec = parse_object_spec(spec_params)

    case SwarmManager.add_object(swarm, spec, Keyword.put(opts, :persist, true)) do
      {:ok, name} ->
        conn |> put_status(:created) |> json(%{status: "added", name: name})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: format_error(reason)})
    end
  end

  @doc """
  DELETE /api/swarms/:swarm_name/objects/:object_name
  """
  def remove_object(conn, %{"swarm_name" => swarm, "object_name" => name}) do
    case SwarmManager.remove_object(swarm, name, persist: true) do
      :ok ->
        json(conn, %{status: "removed", name: name})

      {:error, reason} ->
        conn |> put_status(:not_found) |> json(%{error: format_error(reason)})
    end
  end

  @doc """
  GET /api/swarms/:swarm_name/overlay
  """
  def show_overlay(conn, %{"swarm_name" => swarm}) do
    events =
      SwarmRegistry.load_overlay(swarm)
      |> Enum.map(fn {op, payload} -> %{op: op, payload: payload} end)

    json(conn, %{swarm: swarm, events: events})
  end

  @doc """
  DELETE /api/swarms/:swarm_name/overlay
  """
  def clear_overlay(conn, %{"swarm_name" => swarm}) do
    :ok = SwarmRegistry.clear_overlay(swarm)
    json(conn, %{status: "cleared", swarm: swarm})
  end

  @doc """
  POST /api/swarms/:swarm_name/snapshot
  Returns the swarm's effective config (seed ⊕ overlay) as text/elixir.
  """
  def snapshot(conn, %{"swarm_name" => swarm}) do
    case SwarmManager.get_full_config(swarm) do
      {:ok, config} ->
        source = Genswarms.Config.ExsWriter.to_exs_source(config)

        conn
        |> put_resp_content_type("text/x-elixir")
        |> send_resp(200, source)

      {:error, reason} ->
        conn |> put_status(:not_found) |> json(%{error: format_error(reason)})
    end
  end

  # -- Helpers for dynamic endpoints --

  defp maybe_op([], _fun), do: :ok
  defp maybe_op(items, fun), do: fun.(items)

  defp parse_edge([from, to]) when is_binary(from) and is_binary(to) do
    {String.to_atom(from), String.to_atom(to)}
  end

  defp parse_edge(%{"from" => from, "to" => to}) when is_binary(from) and is_binary(to) do
    {String.to_atom(from), String.to_atom(to)}
  end

  defp parse_edge(_), do: nil

  defp extract_topology_opts(params) do
    connections =
      params
      |> Map.get("connections", [])
      |> Enum.map(&safe_atom/1)
      |> Enum.reject(&is_nil/1)

    incoming =
      params
      |> Map.get("incoming", [])
      |> Enum.map(&safe_atom/1)
      |> Enum.reject(&is_nil/1)

    {[connections: connections, incoming: incoming],
     Map.drop(params, ["connections", "incoming", "swarm_name"])}
  end

  defp parse_agent_spec(params) do
    %{
      name: safe_atom(params["name"]),
      backend: parse_backend(params["backend"]),
      skills: params["skills"] || [],
      model: params["model"],
      endpoint: params["endpoint"],
      presets: (params["presets"] || []) |> Enum.map(&safe_atom/1),
      config: params["config"] || %{}
    }
  end

  defp parse_object_spec(params) do
    %{
      name: safe_atom(params["name"]),
      handler: safe_module(params["handler"]),
      backend: parse_backend(params["backend"]),
      config: params["config"] || %{}
    }
  end

  defp parse_backend(nil), do: nil
  defp parse_backend(b) when is_binary(b), do: safe_atom(b)
  defp parse_backend(%{"type" => "docker", "image" => img}), do: {:docker, img}
  defp parse_backend(%{"type" => "ssh", "host" => host}), do: {:ssh, host}
  defp parse_backend(%{"type" => "mock"}), do: :mock
  defp parse_backend(%{"type" => "bwrap", "opts" => opts}), do: {:bwrap, opts}
  defp parse_backend(%{"type" => t}), do: safe_atom(t)
  defp parse_backend(other), do: other

  defp safe_atom(nil), do: nil
  defp safe_atom(a) when is_atom(a), do: a

  defp safe_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> String.to_atom(s)
    end
  end

  defp safe_module(nil), do: nil
  defp safe_module(m) when is_atom(m), do: m

  defp safe_module(s) when is_binary(s) do
    try do
      Module.concat([s])
    rescue
      _ -> nil
    end
  end

  defp serialize_scale_result(%{added: a, removed: r, failed: f}) do
    %{
      added: Enum.map(a, &to_string/1),
      removed: Enum.map(r, &to_string/1),
      failed:
        Enum.map(f, fn {name, reason} -> %{name: to_string(name), reason: inspect(reason)} end)
    }
  end
end
