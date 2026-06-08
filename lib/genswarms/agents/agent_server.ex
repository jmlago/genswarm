defmodule Genswarms.Agents.AgentServer do
  @moduledoc """
  GenServer wrapping a single agent process/container/connection.

  Responsibilities:
  - Manages the backend (Port/Docker/SSH)
  - Maintains an inbox queue for incoming messages
  - Decodes agent output and routes to Router
  - Handles Port/SSH messages
  - Tracks agent state (idle/working/error)
  """

  use GenServer
  require Logger

  alias Genswarms.Agents.{AgentProtocol, Inbox}
  alias Genswarms.Observability.LogStore
  alias Genswarms.Config.SwarmConfig
  alias Genswarms.Routing.Router

  defstruct [
    :name,
    :swarm_name,
    :backend_module,
    :backend_ref,
    :backend_config,
    :inbox,
    :skills,
    :skills_dir,
    :log_watcher,
    state: :initializing,
    buffer: "",
    message_count: 0,
    file_inbox_seq: 0,
    history: [],
    started_at: nil,
    last_activity: nil
  ]

  @type state :: :initializing | :idle | :working | :error | :stopped
  @type t :: %__MODULE__{
          name: atom(),
          swarm_name: String.t(),
          backend_module: module(),
          backend_ref: term(),
          backend_config: map(),
          inbox: Inbox.t(),
          skills: [String.t()],
          skills_dir: String.t() | nil,
          state: state(),
          buffer: binary(),
          message_count: non_neg_integer(),
          started_at: DateTime.t() | nil,
          last_activity: DateTime.t() | nil
        }

  # Client API

  @doc """
  Starts an agent server.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    swarm_name = Keyword.fetch!(opts, :swarm_name)
    registry_name = via_tuple(swarm_name, name)
    GenServer.start_link(__MODULE__, opts, name: registry_name)
  end

  @doc """
  Returns the via tuple for Registry lookup.
  """
  def via_tuple(swarm_name, agent_name) do
    {:via, Registry, {Genswarms.AgentRegistry, {swarm_name, agent_name}, :agent}}
  end

  @doc """
  Sends a task to the agent.
  """
  def send_task(swarm_name, agent_name, task) do
    GenServer.call(via_tuple(swarm_name, agent_name), {:send_task, task})
  end

  @doc """
  Delivers a message from another agent.
  """
  def deliver_message(swarm_name, agent_name, from, content) do
    GenServer.cast(via_tuple(swarm_name, agent_name), {:deliver_message, from, content})
  end

  @doc """
  Gets the current state of the agent.
  """
  def get_state(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_state)
  end

  @doc """
  Gets agent status info.
  """
  def get_status(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_status)
  end

  @doc """
  Gets agent message history.
  """
  def get_history(swarm_name, agent_name, limit \\ 100) do
    GenServer.call(via_tuple(swarm_name, agent_name), {:get_history, limit})
  end

  @doc """
  Gets agent skills content (reads the markdown files).
  """
  def get_skills_content(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_skills_content)
  end

  @doc """
  Updates a skill file for an agent.
  """
  def update_skill(swarm_name, agent_name, skill_name, content) do
    GenServer.call(via_tuple(swarm_name, agent_name), {:update_skill, skill_name, content})
  end

  @doc """
  Gets the agent's conversation logs (from subzeroclaw log files).
  """
  def get_logs(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_logs)
  end

  @doc """
  Stops the agent.
  """
  def stop(swarm_name, agent_name) do
    GenServer.stop(via_tuple(swarm_name, agent_name))
  end

  # Server callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    swarm_name = Keyword.fetch!(opts, :swarm_name)
    backend = Keyword.fetch!(opts, :backend)
    skills = Keyword.get(opts, :skills, [])
    model = Keyword.get(opts, :model)
    endpoint = Keyword.get(opts, :endpoint)
    presets = Keyword.get(opts, :presets, [])
    agent_config = Keyword.get(opts, :config, %{})
    connections = Keyword.get(opts, :connections, [])

    backend_module = SwarmConfig.backend_module(backend)

    # Separate backend-relevant keys from domain-specific keys
    # Backend keys control the execution environment (workspace, mounts, resources)
    # Domain keys are application-specific (population_size, max_iterations, etc.)
    backend_keys = ~w(workspace extra_path extra_ro_binds extra_rw_binds extra_env
                      memory_limit cpu_shares tasks_max subzeroclaw_path presets network)a

    {backend_overrides, _domain_config} = Map.split(agent_config, backend_keys)

    backend_config =
      SwarmConfig.backend_config(backend)
      |> Map.merge(backend_overrides)
      |> maybe_put(:model, model)
      |> maybe_put(:endpoint, endpoint)
      |> maybe_put(:presets, presets)
      |> maybe_put(:connections, connections)

    state = %__MODULE__{
      name: name,
      swarm_name: swarm_name,
      backend_module: backend_module,
      backend_config: backend_config,
      inbox: Inbox.new(),
      skills: skills,
      started_at: DateTime.utc_now()
    }

    # Start backend asynchronously
    send(self(), :start_backend)

    {:ok, state}
  end

  @impl true
  def handle_info(:start_backend, state) do
    Logger.info("[#{state.swarm_name}/#{state.name}] Starting backend...")

    skills_dir = prepare_skills(state)

    config =
      state.backend_config
      |> Map.put(:skills_dir, skills_dir)
      |> Map.put(:swarm_name, state.swarm_name)

    case state.backend_module.start(to_string(state.name), config) do
      {:ok, ref} ->
        Logger.info("[#{state.swarm_name}/#{state.name}] Backend started")
        emit_telemetry(:agent_started, state, %{backend: state.backend_module.backend_type()})

        # Start log watcher for message routing
        log_dir = skills_dir |> Path.dirname() |> Path.join("logs")

        {:ok, watcher} =
          Genswarms.Agents.LogWatcher.start_link(
            swarm_name: state.swarm_name,
            agent_name: state.name,
            log_dir: log_dir,
            workspace: Map.get(state.backend_config, :workspace)
          )

        {:noreply,
         %{
           state
           | backend_ref: ref,
             skills_dir: skills_dir,
             state: :idle,
             last_activity: DateTime.utc_now(),
             log_watcher: watcher
         }}

      {:error, reason} ->
        Logger.error(
          "[#{state.swarm_name}/#{state.name}] Failed to start backend: #{inspect(reason)}"
        )

        emit_telemetry(:agent_error, state, %{
          reason: inspect(reason),
          backend: state.backend_module.backend_type()
        })

        {:noreply, %{state | state: :error}}
    end
  end

  # Handle Port messages
  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{backend_ref: %{port: port}} = state) do
    handle_agent_output(line, state)
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{backend_ref: %{port: port}} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{backend_ref: %{port: port}} = state) do
    Logger.warning("[#{state.swarm_name}/#{state.name}] Port exited with status #{status}")

    # Buffer tail kept for debugging an unexpected exit.
    buffer_tail =
      if byte_size(state.buffer) > 0 do
        String.slice(state.buffer, -500, 500)
      else
        nil
      end

    emit_telemetry(:agent_stopped, state, %{
      exit_status: status,
      buffer_tail: buffer_tail,
      level: :warning
    })

    {:noreply, %{state | state: :stopped}}
  end

  # Generic port message handling
  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    handle_agent_output(data, state)
  end

  def handle_info(msg, state) do
    Logger.debug("[#{state.swarm_name}/#{state.name}] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:send_task, task}, _from, state) do
    case state.state do
      s when s in [:idle, :working] ->
        message = AgentProtocol.encode_task(task)
        send_to_backend(state, message)
        emit_telemetry(:task_sent, state, %{task: task})

        # Add to history
        history_entry = %{
          type: :task,
          content: task,
          timestamp: DateTime.utc_now()
        }

        new_history = [history_entry | state.history]

        {:reply, :ok,
         %{state | state: :working, history: new_history, last_activity: DateTime.utc_now()}}

      :error ->
        {:reply, {:error, :agent_error}, state}

      :stopped ->
        {:reply, {:error, :agent_stopped}, state}

      :initializing ->
        {:reply, {:error, :agent_initializing}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      name: state.name,
      swarm_name: state.swarm_name,
      state: state.state,
      backend: state.backend_module.backend_type(),
      inbox_size: Inbox.size(state.inbox),
      message_count: state.message_count,
      skills: state.skills,
      started_at: state.started_at,
      last_activity: state.last_activity
    }

    {:reply, status, state}
  end

  def handle_call({:get_history, limit}, _from, state) do
    history = Enum.take(state.history, limit)
    {:reply, history, state}
  end

  def handle_call(:get_skills_content, _from, state) do
    skills_content =
      if state.skills_dir && File.dir?(state.skills_dir) do
        state.skills_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn filename ->
          path = Path.join(state.skills_dir, filename)
          content = File.read!(path)
          %{name: filename, content: content, path: path}
        end)
      else
        []
      end

    {:reply, skills_content, state}
  end

  def handle_call({:update_skill, skill_name, content}, _from, state) do
    if state.skills_dir do
      path = Path.join(state.skills_dir, skill_name)

      case File.write(path, content) do
        :ok -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :no_skills_dir}, state}
    end
  end

  def handle_call(:get_logs, _from, state) do
    logs =
      if state.skills_dir do
        # Logs are in sibling directory to skills
        logs_dir = state.skills_dir |> Path.dirname() |> Path.join("logs")

        if File.dir?(logs_dir) do
          logs_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".txt"))
          |> Enum.sort()
          |> Enum.flat_map(fn filename ->
            path = Path.join(logs_dir, filename)
            content = File.read!(path)
            parse_subzeroclaw_log(content, filename)
          end)
        else
          []
        end
      else
        []
      end

    {:reply, logs, state}
  end

  @impl true
  def handle_cast({:deliver_message, from, content}, state) do
    # Log incoming message
    content_preview =
      if String.length(content) > 100 do
        String.slice(content, 0, 100) <> "..."
      else
        content
      end

    LogStore.log(
      :info,
      :agent,
      :message_received,
      "Message received from #{from}: #{content_preview}",
      swarm: state.swarm_name,
      agent: state.name,
      metadata: %{from: from, content: content}
    )

    # Add to history
    history_entry = %{
      type: :incoming,
      from: from,
      content: content,
      timestamp: DateTime.utc_now()
    }

    case Inbox.push(state.inbox, %{from: from, content: content, received_at: DateTime.utc_now()}) do
      {:ok, new_inbox} ->
        new_history = [history_entry | state.history]

        # Write to file-inbox (parallel delivery for bwrap agents)
        seq = state.file_inbox_seq + 1
        write_file_inbox(state, seq, from, content)

        # Send to agent immediately if idle
        if state.state == :idle do
          message = AgentProtocol.encode_message(content, from)
          send_to_backend(state, message)
          emit_telemetry(:message_delivered, state, %{from: from})

          {:noreply,
           %{
             state
             | inbox: new_inbox,
               history: new_history,
               file_inbox_seq: seq,
               state: :working,
               last_activity: DateTime.utc_now()
           }}
        else
          {:noreply, %{state | inbox: new_inbox, history: new_history, file_inbox_seq: seq}}
        end

      {:error, :inbox_full} ->
        Logger.warning(
          "[#{state.swarm_name}/#{state.name}] Inbox full, dropping message from #{from}"
        )

        LogStore.log(:warning, :agent, :inbox_full, "Inbox full, dropped message from #{from}",
          swarm: state.swarm_name,
          agent: state.name,
          metadata: %{from: from, content_preview: content_preview}
        )

        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.backend_ref do
      state.backend_module.stop(state.backend_ref)
    end

    :ok
  end

  # Private functions

  defp handle_agent_output(data, state) do
    full_data = state.buffer <> data

    # Check for API errors in output
    case detect_api_error(full_data) do
      {error_type, error_msg} ->
        LogStore.log(:error, :system, error_type, error_msg,
          swarm: state.swarm_name,
          agent: state.name,
          metadata: %{output_snippet: String.slice(full_data, 0, 200)}
        )

      nil ->
        :ok
    end

    # Check for completion signals:
    # - "<<TURN_COMPLETE>>" after a turn finishes
    # - "> " prompt when agent is idle (initial startup or waiting)
    turn_complete = String.contains?(full_data, "<<TURN_COMPLETE>>")

    initial_idle =
      (String.ends_with?(full_data, "> ") or full_data == "> ") and state.state == :starting

    if turn_complete or initial_idle do
      # Remove markers from output before processing
      full_data =
        full_data
        |> String.replace("<<TURN_COMPLETE>>", "")
        |> String.replace(~r/\n?> $/, "")

      # Log stdout output to LogStore
      unless full_data == "" or String.trim(full_data) == "" do
        output_preview =
          if String.length(full_data) > 200 do
            String.slice(full_data, 0, 200) <> "..."
          else
            full_data
          end

        LogStore.log(
          :info,
          :agent,
          :stdout,
          "Agent output: #{String.replace(output_preview, "\n", " ")}",
          swarm: state.swarm_name,
          agent: state.name,
          metadata: %{
            output: full_data,
            output_length: String.length(full_data)
          }
        )
      end

      # Agent finished output - now parse for @mentions and route messages
      # This ensures we capture the COMPLETE message before routing
      messages = AgentProtocol.parse_output(full_data)

      # Route messages
      Logger.debug("[#{state.swarm_name}/#{state.name}] Parsed #{length(messages)} messages")

      Enum.each(messages, fn msg ->
        Logger.debug("[#{state.swarm_name}/#{state.name}] Routing: #{inspect(msg)}")
        route_message(msg, state)
      end)

      # Add to history
      history_entries =
        Enum.map(messages, fn msg ->
          %{
            type: :outgoing,
            message_type: msg.type,
            to: Map.get(msg, :to),
            content: msg.content,
            timestamp: DateTime.utc_now()
          }
        end)

      new_state = %{
        state
        | buffer: "",
          state: :idle,
          message_count: state.message_count + length(messages),
          history: history_entries ++ state.history,
          last_activity: DateTime.utc_now()
      }

      # Process next inbox message if any
      new_state = maybe_process_inbox(new_state)
      {:noreply, new_state}
    else
      # Still receiving output - just accumulate in buffer
      {:noreply, %{state | buffer: full_data, last_activity: DateTime.utc_now()}}
    end
  end

  defp route_message(%{type: :send, to: to, content: content}, state) do
    Router.route(state.swarm_name, state.name, to, content)
  end

  defp route_message(%{type: :broadcast, content: content}, state) do
    Router.broadcast(state.swarm_name, state.name, content)
  end

  defp route_message(%{type: :output, content: content}, state) do
    # Broadcast output to subscribers
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{state.swarm_name}:output",
      {:agent_output, state.name, content}
    )
  end

  defp route_message(%{type: :status, state: agent_state}, state) do
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{state.swarm_name}:status",
      {:agent_status, state.name, agent_state}
    )

    # Return the new state to update - handled specially in handle_agent_output
    {:update_state, String.to_atom(agent_state)}
  end

  defp route_message(_msg, _state), do: :ok

  defp maybe_process_inbox(%{state: :idle, inbox: inbox} = state) do
    case Inbox.pop(inbox) do
      {:ok, %{from: from, content: content}, new_inbox} ->
        message = AgentProtocol.encode_message(content, from)
        send_to_backend(state, message)
        %{state | inbox: new_inbox, state: :working}

      {:empty, _} ->
        state
    end
  end

  defp maybe_process_inbox(state), do: state

  defp send_to_backend(%{backend_ref: %{port: port}}, message) do
    Port.command(port, message <> "\n")
  end

  defp send_to_backend(%{backend_module: module, backend_ref: ref}, message) do
    module.send_input(ref, message)
  end

  # Write message to file-inbox at {workspace}/.inbox/{seq}_{from}.json
  # This provides a reliable file-based delivery channel for bwrap agents
  # that may not parse stdin JSON messages correctly.
  defp write_file_inbox(state, seq, from, content) do
    workspace = Map.get(state.backend_config, :workspace)

    if workspace && workspace != "" do
      inbox_dir = Path.join(Path.expand(workspace), ".inbox")

      try do
        File.mkdir_p!(inbox_dir)

        filename = String.pad_leading(Integer.to_string(seq), 4, "0") <> "_#{from}.json"
        file_path = Path.join(inbox_dir, filename)

        msg_data =
          Jason.encode!(%{
            from: from,
            content: content,
            seq: seq,
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        File.write!(file_path, msg_data)
      rescue
        e ->
          Logger.debug(
            "[#{state.swarm_name}/#{state.name}] File-inbox write failed: #{inspect(e)}"
          )
      end
    end
  end

  defp prepare_skills(state) do
    skills_base =
      Application.get_env(:genswarms, :swarm_data_dir, "~/.subzeroclaw/swarms")

    skills_dir = Path.expand("#{skills_base}/#{state.swarm_name}/#{state.name}/skills")

    File.mkdir_p!(skills_dir)

    # Copy skills - handle absolute, relative (./), and simple paths
    priv_skills = Application.get_env(:genswarms, :skills_dir, "priv/skills")
    project_root = Application.get_env(:genswarms, :project_root) || File.cwd!()

    Enum.each(state.skills, fn skill_file ->
      # Resolve the source path
      src =
        cond do
          # Absolute path
          String.starts_with?(skill_file, "/") ->
            skill_file

          # Relative path (./something or ../something)
          String.starts_with?(skill_file, ".") ->
            Path.expand(skill_file, project_root)

          # Simple filename - look in priv/skills
          true ->
            Path.join(priv_skills, skill_file)
        end

      # Use basename for the destination
      dst = Path.join(skills_dir, Path.basename(skill_file))

      # Create parent directory if needed
      File.mkdir_p!(Path.dirname(dst))

      if File.exists?(src) do
        # Copy and resolve template variables
        content = File.read!(src)
        workspace = Map.get(state.backend_config, :workspace, "")

        resolved =
          content
          |> String.replace("{{agent_name}}", to_string(state.name))
          |> String.replace("{{swarm_name}}", to_string(state.swarm_name))
          |> String.replace("{{workspace}}", to_string(workspace))

        File.write!(dst, resolved)
        Logger.debug("[#{state.swarm_name}/#{state.name}] Copied skill: #{src} -> #{dst}")
      else
        Logger.warning("Skill file not found: #{src}")
      end
    end)

    skills_dir
  end

  # Parse subzeroclaw log file format
  # Format: [timestamp] ROLE: content
  # Roles: USER, TOOL, RES, ASST, COMPACT, SYS
  defp parse_subzeroclaw_log(content, session_id) do
    lines = String.split(content, "\n")

    # Skip header line (=== session_id timestamp)
    lines = Enum.drop_while(lines, &String.starts_with?(&1, "==="))

    # Parse entries - they can be multi-line
    parse_log_entries(lines, session_id, [])
  end

  defp parse_log_entries([], _session_id, acc), do: Enum.reverse(acc)

  defp parse_log_entries([line | rest], session_id, acc) do
    # Try to match [timestamp] ROLE: content
    case Regex.run(~r/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (\w+): (.*)$/, line) do
      [_, timestamp, role, content] ->
        # Collect continuation lines (lines that don't start with [timestamp])
        {continuation, remaining} =
          Enum.split_while(rest, fn l ->
            not Regex.match?(~r/^\[\d{4}-\d{2}-\d{2}/, l) and l != ""
          end)

        full_content = [content | continuation] |> Enum.join("\n")

        entry = %{
          session_id: session_id,
          timestamp: timestamp,
          role: String.downcase(role),
          content: full_content
        }

        parse_log_entries(remaining, session_id, [entry | acc])

      nil ->
        # Skip non-matching lines (empty lines, etc.)
        parse_log_entries(rest, session_id, acc)
    end
  end

  # Detect API errors in agent output
  defp detect_api_error(output) do
    cond do
      String.contains?(output, "401") and String.contains?(output, "Unauthorized") ->
        {:api_key_invalid, "API authentication failed (401 Unauthorized)"}

      String.contains?(output, "invalid_api_key") or String.contains?(output, "Invalid API Key") ->
        {:api_key_invalid, "Invalid API key"}

      (String.contains?(output, "API_KEY") or String.contains?(output, "api_key")) and
          String.contains?(output, "not set") ->
        {:api_key_missing, "API key not configured"}

      String.contains?(output, "SUBZEROCLAW_API_KEY") and String.contains?(output, "required") ->
        {:api_key_missing, "SUBZEROCLAW_API_KEY environment variable required"}

      String.contains?(output, "rate_limit") or String.contains?(output, "Rate limit") or
          String.contains?(output, "429") ->
        {:rate_limit, "API rate limit exceeded"}

      String.contains?(output, "insufficient_quota") or String.contains?(output, "quota exceeded") ->
        {:quota_exceeded, "API quota exceeded"}

      true ->
        nil
    end
  end

  defp emit_telemetry(event, state, metadata) do
    :telemetry.execute(
      [:genswarms, :agent, event],
      %{time: System.system_time()},
      Map.merge(metadata, %{agent: state.name, swarm: state.swarm_name})
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
