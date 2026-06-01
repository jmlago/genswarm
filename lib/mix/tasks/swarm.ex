defmodule Mix.Tasks.Swarm do
  @shortdoc "SubzeroclawSwarm CLI commands"

  @moduledoc """
  CLI commands for managing SubzeroclawSwarm.

  ## Commands

      mix swarm init [dir]              # Create new project structure
      mix swarm dashboard               # Start/stop web dashboard
      mix swarm start config.exs        # Start a swarm from config
      mix swarm stop swarm_name         # Stop a running swarm
      mix swarm restart swarm_name      # Restart a swarm
      mix swarm pause swarm_name        # Pause a swarm (freeze containers)
      mix swarm resume swarm_name       # Resume a paused swarm
      mix swarm status                  # Show status of swarms
      mix swarm events                  # Query/stream events
      mix swarm logs swarm [agent]      # View agent conversation logs
      mix swarm task swarm agent task   # Send a task to an agent
      mix swarm msg swarm from to msg   # Send message between agents
      mix swarm env [list|get|set]      # Manage environment variables
      mix swarm build [--all]           # Build Docker images via nix
      mix swarm config validate file    # Validate config files
  """

  use Mix.Task

  alias SubzeroclawSwarm.CLI.Output

  def run(args) do
    case args do
      ["init" | rest] -> Mix.Tasks.Swarm.Init.run(rest)
      ["up" | rest] -> Mix.Tasks.Swarm.Up.run(rest)
      ["dashboard" | rest] -> Mix.Tasks.Swarm.Dashboard.run(rest)
      ["down" | rest] -> Mix.Tasks.Swarm.Down.run(rest)
      ["start" | rest] -> Mix.Tasks.Swarm.Start.run(rest)
      ["stop" | rest] -> Mix.Tasks.Swarm.Stop.run(rest)
      ["delete" | rest] -> Mix.Tasks.Swarm.Delete.run(rest)
      ["clean" | rest] -> Mix.Tasks.Swarm.Clean.run(rest)
      ["restart" | rest] -> Mix.Tasks.Swarm.Restart.run(rest)
      ["pause" | rest] -> Mix.Tasks.Swarm.Pause.run(rest)
      ["resume" | rest] -> Mix.Tasks.Swarm.Resume.run(rest)
      ["restart-agent" | rest] -> Mix.Tasks.Swarm.RestartAgent.run(rest)
      ["status" | rest] -> Mix.Tasks.Swarm.Status.run(rest)
      ["logs" | rest] -> Mix.Tasks.Swarm.Logs.run(rest)
      ["events" | rest] -> Mix.Tasks.Swarm.Events.run(rest)
      ["task" | rest] -> Mix.Tasks.Swarm.Task.run(rest)
      ["msg" | rest] -> Mix.Tasks.Swarm.Msg.run(rest)
      ["env" | rest] -> Mix.Tasks.Swarm.Env.run(rest)
      ["build" | rest] -> Mix.Tasks.Swarm.Build.run(rest)
      ["config" | rest] -> dispatch_config(rest)
      ["list-skills" | rest] -> Mix.Tasks.Swarm.ListSkills.run(rest)
      ["scale" | rest] -> Mix.Tasks.Swarm.Scale.run(rest)
      ["overlay" | rest] -> Mix.Tasks.Swarm.Overlay.run(rest)
      ["snapshot" | rest] -> Mix.Tasks.Swarm.Snapshot.run(rest)
      _ -> print_help()
    end
  end

  defp dispatch_config(args) do
    case args do
      ["validate" | rest] ->
        Mix.Tasks.Swarm.Config.Validate.run(rest)

      [] ->
        Output.error("Missing config subcommand")
        Output.info("Available: validate")

      [cmd | _] ->
        Output.error("Unknown config subcommand: #{cmd}")
        Output.info("Available: validate")
    end
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end

defmodule Mix.Tasks.Swarm.Start do
  @shortdoc "Start a swarm from configuration"

  @moduledoc """
  Starts a swarm as a background daemon.

  ## Usage

      mix swarm start path/to/config.exs [options]

  ## Options

      --foreground    Run in foreground instead of daemon mode

  The swarm runs as a daemon process. State is tracked in .swarm/swarms.db.
  Use `swarm status` to check running swarms, `swarm stop` to stop them.
  """

  use Mix.Task

  alias SubzeroclawSwarm.CLI.{Output, SwarmRegistry, EnvManager}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [foreground: :boolean, help: :boolean],
        aliases: [f: :foreground, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      case rest do
        [config_path] ->
          EnvManager.auto_load()
          start_swarm(config_path, opts)

        _ ->
          Output.error("Usage: mix swarm start <config_path> [--foreground]")
      end
    end
  end

  defp start_swarm(config_path, opts) do
    abs_path = Path.expand(config_path)

    unless File.exists?(abs_path) do
      Output.error("Config file not found: #{abs_path}")
      System.halt(1)
    end

    # Initialize registry
    SwarmRegistry.init()

    if opts[:foreground] do
      start_foreground(abs_path)
    else
      start_daemon(abs_path)
    end
  end

  defp start_foreground(config_path) do
    Output.info("Starting swarm in foreground...")
    {:ok, _} = Application.ensure_all_started(:subzeroclaw_swarm)

    case SubzeroclawSwarm.start_swarm(config_path) do
      {:ok, swarm_name} ->
        # Register in SQLite
        SwarmRegistry.register_swarm(swarm_name, System.pid() |> String.to_integer(), config_path)

        Output.success("Started swarm: #{swarm_name}")
        Output.info("Press Ctrl+C to stop")

        # Keep alive
        Process.sleep(:infinity)

      {:error, reason} ->
        Output.error("Failed to start swarm: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp start_daemon(config_path) do
    Output.info("Starting swarm daemon...")

    # Build command to run swarm in background
    cmd = build_daemon_command(config_path)
    log_dir = Path.join(File.cwd!(), ".swarm/logs")
    File.mkdir_p!(log_dir)

    # Extract swarm name from config for log file
    swarm_name = extract_swarm_name(config_path) || "swarm"
    log_file = Path.join(log_dir, "#{swarm_name}.log")

    # Spawn daemon
    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:cd, File.cwd!()}
      ])

    # Read PID from stdout
    pid = receive_daemon_pid(port)

    case pid do
      {:ok, daemon_pid} ->
        # Wait a moment for swarm to start
        Process.sleep(2000)

        # Check if process is still alive
        if SwarmRegistry.process_alive?(daemon_pid) do
          Output.success("Started swarm daemon (PID: #{daemon_pid})")
          Output.puts("  Config: #{Output.colorize(config_path, :dim)}")
          Output.puts("  Log: #{Output.colorize(log_file, :dim)}")
          Output.newline()
          Output.dim("Use 'swarm status' to check status")
          Output.dim("Use 'swarm stop #{swarm_name}' to stop")
        else
          Output.error("Swarm daemon exited unexpectedly")
          Output.info("Check log: #{log_file}")
          System.halt(1)
        end

      :error ->
        Output.error("Failed to start daemon")
        System.halt(1)
    end
  end

  defp build_daemon_command(config_path) do
    swarm_name = extract_swarm_name(config_path) || "swarm"
    log_file = ".swarm/logs/#{swarm_name}.log"

    # Run mix swarm start --foreground in background, capture PID
    ~s(sh -c 'nohup mix swarm.start.daemon "#{config_path}" > #{log_file} 2>&1 & echo $!')
  end

  defp extract_swarm_name(config_path) do
    try do
      {config, _} = Code.eval_file(config_path)
      config[:name] || config["name"]
    rescue
      _ -> nil
    end
  end

  defp receive_daemon_pid(port) do
    receive do
      {^port, {:data, data}} ->
        case Integer.parse(String.trim(data)) do
          {pid, _} -> {:ok, pid}
          :error -> :error
        end

      {^port, {:exit_status, _}} ->
        :error
    after
      5000 -> :error
    end
  end
end

# Internal daemon task (runs in foreground, called by start_daemon)
defmodule Mix.Tasks.Swarm.Start.Daemon do
  @moduledoc false
  use Mix.Task

  alias SubzeroclawSwarm.CLI.{SwarmRegistry, EnvManager}
  alias SubzeroclawSwarm.SwarmManager

  # Poll for tasks every 500ms
  @task_poll_interval 500

  @impl Mix.Task
  def run([config_path]) do
    EnvManager.auto_load()
    SwarmRegistry.init()

    {:ok, _} = Application.ensure_all_started(:subzeroclaw_swarm)

    case SubzeroclawSwarm.start_swarm(config_path) do
      {:ok, swarm_name} ->
        pid = System.pid() |> String.to_integer()
        SwarmRegistry.register_swarm(swarm_name, pid, config_path)

        SwarmRegistry.log_event(
          :info,
          :swarm,
          :daemon_started,
          "Swarm #{swarm_name} started as daemon (PID: #{pid})",
          swarm: swarm_name,
          metadata: %{pid: pid, config: config_path}
        )

        IO.puts("[#{swarm_name}] Swarm running (PID: #{pid})")

        # Keep alive, poll for tasks, and handle shutdown
        ref = Process.monitor(Process.whereis(SubzeroclawSwarm.Supervisor))
        daemon_loop(swarm_name, ref)

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start swarm: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp daemon_loop(swarm_name, ref) do
    receive do
      {:DOWN, ^ref, :process, _, reason} ->
        SwarmRegistry.mark_crashed(swarm_name)

        SwarmRegistry.log_event(
          :error,
          :swarm,
          :daemon_crashed,
          "Swarm #{swarm_name} crashed: #{inspect(reason)}",
          swarm: swarm_name,
          metadata: %{reason: inspect(reason)}
        )
    after
      @task_poll_interval ->
        # Poll for pending tasks and dynamic-swarm commands
        process_pending_tasks(swarm_name)
        process_pending_commands(swarm_name)
        daemon_loop(swarm_name, ref)
    end
  end

  defp process_pending_commands(swarm_name) do
    commands = SwarmRegistry.get_pending_commands(swarm_name)

    Enum.each(commands, fn cmd ->
      result = apply_command(swarm_name, cmd.op, cmd.payload)
      SwarmRegistry.mark_command_done(cmd.id, normalize_result(result))
    end)
  end

  defp apply_command(swarm_name, :add_agent, payload) do
    {connections, payload} = Map.pop(payload, :_connections, [])
    {incoming, spec} = Map.pop(payload, :_incoming, [])
    SwarmManager.add_agent(swarm_name, spec, connections: connections, incoming: incoming, persist: true)
  end

  defp apply_command(swarm_name, :remove_agent, %{name: name}) do
    SwarmManager.remove_agent(swarm_name, name, persist: true)
  end

  defp apply_command(swarm_name, :add_object, payload) do
    {connections, payload} = Map.pop(payload, :_connections, [])
    {incoming, spec} = Map.pop(payload, :_incoming, [])
    SwarmManager.add_object(swarm_name, spec, connections: connections, incoming: incoming, persist: true)
  end

  defp apply_command(swarm_name, :remove_object, %{name: name}) do
    SwarmManager.remove_object(swarm_name, name, persist: true)
  end

  defp apply_command(swarm_name, :add_topology_edges, %{edges: edges}) do
    SwarmManager.add_topology_edges(swarm_name, normalize_edges(edges), persist: true)
  end

  defp apply_command(swarm_name, :remove_topology_edges, %{edges: edges}) do
    SwarmManager.remove_topology_edges(swarm_name, normalize_edges(edges), persist: true)
  end

  defp apply_command(swarm_name, :scale_agent_group, %{base_name: base, target_count: n}) do
    SwarmManager.scale_agent_group(swarm_name, base, n, persist: true)
  end

  defp apply_command(swarm_name, :get_full_config, _payload) do
    case SwarmManager.get_full_config(swarm_name) do
      {:ok, config} ->
        # Serialize the SwarmConfig struct as a plain map for transit
        {:ok, Map.from_struct(config) |> Map.drop([:created_at])}

      err ->
        err
    end
  end

  defp apply_command(_swarm_name, op, payload) do
    {:error, {:unknown_command, op, payload}}
  end

  defp normalize_edges(edges) do
    Enum.map(edges, fn
      [f, t] -> {f, t}
      {f, t} -> {f, t}
    end)
  end

  defp normalize_result(:ok), do: %{status: "ok"}
  defp normalize_result({:ok, value}), do: %{status: "ok", value: value}
  defp normalize_result({:error, reason}), do: %{status: "error", reason: inspect(reason)}
  defp normalize_result(other), do: %{status: "other", value: inspect(other)}

  defp process_pending_tasks(swarm_name) do
    tasks = SwarmRegistry.get_pending_tasks(swarm_name)

    Enum.each(tasks, fn task ->
      case SwarmManager.send_task(swarm_name, task.agent, task.task) do
        :ok ->
          SwarmRegistry.mark_task_processed(task.id)

          SwarmRegistry.log_event(:info, :agent, :task_received, "Task sent to #{task.agent}",
            swarm: swarm_name,
            agent: task.agent,
            metadata: %{task_id: task.id, task: String.slice(task.task, 0, 100)}
          )

        {:error, reason} ->
          # Leave task pending for retry, but log the error
          SwarmRegistry.log_event(
            :warning,
            :agent,
            :task_failed,
            "Failed to send task to #{task.agent}: #{inspect(reason)}",
            swarm: swarm_name,
            agent: task.agent,
            metadata: %{task_id: task.id, reason: inspect(reason)}
          )
      end
    end)
  end
end

defmodule Mix.Tasks.Swarm.Stop do
  @shortdoc "Stop a running swarm"

  @moduledoc """
  Stops a running swarm daemon.

  ## Usage

      mix swarm stop <swarm_name>

  Sends SIGTERM to the swarm daemon and updates the registry.
  """

  use Mix.Task

  alias SubzeroclawSwarm.CLI.{Output, SwarmRegistry}

  @impl Mix.Task
  def run([swarm_name]) do
    SwarmRegistry.init()

    case SwarmRegistry.get_swarm(swarm_name) do
      {:ok, %{status: :running, pid: pid}} when not is_nil(pid) ->
        stop_daemon(swarm_name, pid)

      {:ok, %{status: :running, pid: nil}} ->
        Output.warning("Swarm #{swarm_name} has no PID recorded")
        SwarmRegistry.mark_stopped(swarm_name)
        Output.info("Marked as stopped")

      {:ok, %{status: status}} ->
        Output.info("Swarm #{swarm_name} is not running (status: #{status})")

      {:error, :not_found} ->
        Output.error("Swarm not found: #{swarm_name}")
    end
  end

  def run(_) do
    Output.error("Usage: mix swarm stop <swarm_name>")
  end

  defp stop_daemon(swarm_name, pid) do
    Output.info("Stopping swarm #{swarm_name} (PID: #{pid})...")

    # Send SIGTERM
    case System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        # Wait for process to exit
        wait_for_exit(pid, 10)
        SwarmRegistry.mark_stopped(swarm_name)

        SwarmRegistry.log_event(:info, :swarm, :stopped, "Swarm #{swarm_name} stopped",
          swarm: swarm_name,
          metadata: %{pid: pid}
        )

        Output.success("Stopped swarm: #{swarm_name}")

      {_, _} ->
        # Process might already be dead
        SwarmRegistry.mark_stopped(swarm_name)
        Output.success("Stopped swarm: #{swarm_name}")
    end
  end

  defp wait_for_exit(_pid, 0), do: :ok

  defp wait_for_exit(pid, attempts) do
    if SwarmRegistry.process_alive?(pid) do
      Process.sleep(500)
      wait_for_exit(pid, attempts - 1)
    else
      :ok
    end
  end
end

defmodule Mix.Tasks.Swarm.Status do
  @shortdoc "Show swarm status"

  @moduledoc """
  Shows the status of swarms from the registry.

  ## Usage

      mix swarm status             # Show all swarms
      mix swarm status swarm_name  # Show specific swarm
  """

  use Mix.Task

  alias SubzeroclawSwarm.CLI.{Output, SwarmRegistry}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [help: :boolean],
        aliases: [h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      load_env()
      SwarmRegistry.init()
      SwarmRegistry.cleanup_stale()

      case rest do
        [] -> show_all_swarms()
        [swarm_name] -> show_swarm_detail(swarm_name)
        _ -> Output.error("Usage: mix swarm status [swarm_name]")
      end
    end
  end

  defp load_env do
    alias SubzeroclawSwarm.CLI.EnvManager
    case EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[SubzeroclawSwarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end
  end

  defp show_all_swarms do
    Output.header("Swarms")

    swarms = SwarmRegistry.list_swarms()

    if Enum.empty?(swarms) do
      Output.dim("No swarms registered")
      Output.dim("Start one with: swarm start <config.exs>")
    else
      # Table format
      headers = ["Name", "Status", "PID", "Started"]

      rows =
        Enum.map(swarms, fn swarm ->
          status_str = format_status(swarm.status, swarm.pid)
          pid_str = if swarm.pid, do: to_string(swarm.pid), else: "-"
          started = if swarm.started_at, do: format_time(swarm.started_at), else: "-"
          [swarm.name, status_str, pid_str, started]
        end)

      Output.table(headers, rows)

      running = Enum.count(swarms, &(&1.status == :running))
      Output.newline()
      Output.dim("#{running} running, #{length(swarms)} total")
    end
  end

  defp show_swarm_detail(swarm_name) do
    case SwarmRegistry.get_swarm(swarm_name) do
      {:ok, swarm} ->
        Output.header("Swarm: #{swarm.name}")
        Output.newline()

        Output.puts(Output.kv("Status", format_status(swarm.status, swarm.pid)))
        Output.puts(Output.kv("PID", swarm.pid || "-"))
        Output.puts(Output.kv("Config", swarm.config_path || "-"))
        Output.puts(Output.kv("Log", Path.join([File.cwd!(), ".swarm", "logs", "#{swarm.name}.log"])))
        Output.puts(Output.kv("Data", Path.join([System.user_home!(), ".subzeroclaw", "swarms", swarm.name])))
        Output.puts(Output.kv("Started", swarm.started_at || "-"))

        if swarm.stopped_at do
          Output.puts(Output.kv("Stopped", swarm.stopped_at))
        end

        # Show agents and objects if config is available
        if swarm.config_path && File.exists?(swarm.config_path) do
          show_swarm_components(swarm)
        end

      {:error, :not_found} ->
        Output.error("Swarm not found: #{swarm_name}")
    end
  end

  defp show_swarm_components(swarm) do
    try do
      {config, _} = Code.eval_file(swarm.config_path)
      config_dir = Path.dirname(swarm.config_path)

      # Show agents
      agents = config[:agents] || []
      if agents != [] do
        Output.newline()
        Output.puts(Output.colorize("Agents:", :bold))

        Enum.each(agents, fn agent_config ->
          agent_name = agent_config[:name]
          backend = agent_config[:backend] || :local
          status = get_agent_status(swarm.name, agent_name, backend, swarm.status)
          status_str = format_agent_status(status)
          Output.puts("  #{agent_name}: #{status_str}")

          # Show backend
          backend = agent_config[:backend] || :local
          backend_str = format_backend(backend)
          Output.puts("    #{Output.colorize("backend:", :dim)} #{backend_str}")

          # Show skills paths
          skills = agent_config[:skills] || []
          Enum.each(skills, fn skill_path ->
            # Resolve relative paths against config directory
            full_path = if Path.type(skill_path) == :relative do
              Path.join(config_dir, skill_path)
            else
              skill_path
            end
            Output.puts("    #{Output.colorize("skill:", :dim)} #{full_path}")
          end)
        end)
      end

      # Show objects
      objects = config[:objects] || []
      if objects != [] do
        Output.newline()
        Output.puts(Output.colorize("Objects:", :bold))

        Enum.each(objects, fn object_config ->
          object_name = object_config[:name]
          handler = object_config[:handler]
          status = if swarm.status == :running, do: :running, else: :stopped
          status_str = format_object_status(status)
          Output.puts("  #{object_name}: #{status_str}")

          # Show handler module and try to find its source file
          if handler do
            handler_str = inspect(handler)
            Output.puts("    #{Output.colorize("handler:", :dim)} #{handler_str}")

            # Try to find the handler source file
            handler_path = find_handler_path(handler, config_dir)
            if handler_path do
              Output.puts("    #{Output.colorize("source:", :dim)} #{handler_path}")
            end
          end
        end)
      end

      # Show topology
      topology = config[:topology] || []
      if topology != [] do
        Output.newline()
        Output.puts(Output.colorize("Topology:", :bold))
        Enum.each(topology, fn {from, to} ->
          Output.puts("  #{from} #{Output.colorize("→", :dim)} #{to}")
        end)
      end
    rescue
      _ -> :ok
    end
  end

  defp get_agent_status(_swarm_name, _agent_name, _backend, swarm_status)
       when swarm_status != :running do
    :stopped
  end

  defp get_agent_status(swarm_name, agent_name, :bwrap, _swarm_status) do
    # For bwrap, check systemd service status
    # The scope name pattern is: szc-{swarm_name}-{agent_name}-{timestamp}
    # We list active services and check if any match our agent
    case System.cmd("systemctl", ["--user", "list-units", "--type=service", "--state=running", "--plain", "--no-legend"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        prefix = "szc-#{swarm_name}-#{agent_name}-"
        if String.contains?(output, prefix), do: :running, else: :stopped
      _ ->
        :stopped
    end
  end

  defp get_agent_status(swarm_name, agent_name, {:bwrap, _opts}, swarm_status) do
    get_agent_status(swarm_name, agent_name, :bwrap, swarm_status)
  end

  defp get_agent_status(swarm_name, agent_name, {:docker, _image}, _swarm_status) do
    get_docker_container_status("szc-#{swarm_name}-#{agent_name}")
  end

  defp get_agent_status(swarm_name, agent_name, {:docker, _image, _opts}, _swarm_status) do
    get_docker_container_status("szc-#{swarm_name}-#{agent_name}")
  end

  defp get_agent_status(_swarm_name, _agent_name, _backend, _swarm_status) do
    # For local/ssh backends, we can't easily check status from CLI
    # Default to running if the swarm is running
    :running
  end

  defp get_docker_container_status(container_name) do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Status}}", container_name], stderr_to_stdout: true) do
      {"running\n", 0} -> :running
      {"paused\n", 0} -> :paused
      _ -> :stopped
    end
  end

  defp format_agent_status(:running), do: Output.colorize("running", :green)
  defp format_agent_status(:paused), do: Output.colorize("paused", :yellow)
  defp format_agent_status(:stopped), do: Output.colorize("stopped", :dim)
  defp format_agent_status(status), do: to_string(status)

  defp format_object_status(:running), do: Output.colorize("running", :green)
  defp format_object_status(:stopped), do: Output.colorize("stopped", :dim)
  defp format_object_status(status), do: to_string(status)

  defp format_backend(:local), do: "local"
  defp format_backend({:docker, image}), do: "docker (#{image})"
  defp format_backend({:docker, image, _opts}), do: "docker (#{image})"
  defp format_backend({:ssh, host}), do: "ssh (#{host})"
  defp format_backend({:ssh, host, _opts}), do: "ssh (#{host})"
  defp format_backend(other), do: inspect(other)

  defp find_handler_path(handler, config_dir) do
    # Convert module name to potential file paths
    # e.g., Bridge.Objects.Bridge -> bridge/objects/bridge.ex or objects/bridge.ex
    module_parts = handler |> Module.split() |> Enum.map(&Macro.underscore/1)

    # Try common patterns
    candidates = [
      # objects/<last_part>.ex
      Path.join([config_dir, "objects", List.last(module_parts) <> ".ex"]),
      # <full_path>.ex
      Path.join([config_dir | module_parts]) <> ".ex",
      # lib/<full_path>.ex
      Path.join(["lib" | module_parts]) <> ".ex"
    ]

    Enum.find(candidates, &File.exists?/1)
  end

  defp format_status(:running, pid) do
    if SwarmRegistry.process_alive?(pid) do
      Output.colorize("running", :green)
    else
      Output.colorize("dead", :red)
    end
  end

  defp format_status(:stopped, _), do: Output.colorize("stopped", :dim)
  defp format_status(:crashed, _), do: Output.colorize("crashed", :red)
  defp format_status(status, _), do: to_string(status)

  defp format_time(datetime_str) do
    # SQLite datetime format: "2024-03-24 10:30:00"
    case String.split(datetime_str, " ") do
      [_date, time] -> String.slice(time, 0, 8)
      _ -> datetime_str
    end
  end
end

defmodule Mix.Tasks.Swarm.Task do
  @shortdoc "Send a task to an agent"

  @moduledoc """
  Sends a task to a specific agent.

  ## Usage

      mix swarm task swarm_name agent_name "task content"
  """

  use Mix.Task

  alias SubzeroclawSwarm.CLI.{Output, APIClient, SwarmRegistry}

  @impl Mix.Task
  def run([swarm_name, agent_name, task]) do
    # Only need SQLite for task queueing, not full app
    load_env()
    SwarmRegistry.init()

    # Check if server is running (uses httpc, not full app)
    :inets.start()
    :ssl.start()

    if APIClient.server_running?() do
      send_via_api(swarm_name, agent_name, task)
    else
      # For daemon swarms, queue task in SQLite
      SwarmRegistry.queue_task(swarm_name, agent_name, task)
      Output.success("Task sent to #{agent_name}")
    end
  end

  def run(_) do
    Output.error("Usage: mix swarm task <swarm_name> <agent_name> <task>")
  end

  defp load_env do
    alias SubzeroclawSwarm.CLI.EnvManager
    case EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[SubzeroclawSwarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end
  end

  defp send_via_api(swarm_name, agent_name, task) do
    case APIClient.send_task(swarm_name, agent_name, task) do
      {:ok, _} ->
        Output.success("Task sent to #{agent_name}")

      {:error, {:http_error, 404, _}} ->
        Output.error("Swarm or agent not found")

      {:error, reason} ->
        Output.error("Failed to send task: #{inspect(reason)}")
    end
  end
end

defmodule Mix.Tasks.Swarm.ListSkills do
  @shortdoc "List available skills"

  @moduledoc """
  Lists all available skills in the skills repository.

  ## Usage

      mix swarm list-skills
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # SkillsManager needs full app
    {:ok, _} = Application.ensure_all_started(:subzeroclaw_swarm)

    skills = SubzeroclawSwarm.Skills.SkillsManager.list_skills()

    if Enum.empty?(skills) do
      Mix.shell().info("No skills found in priv/skills/")
    else
      Mix.shell().info("Available skills:")

      for skill <- skills do
        Mix.shell().info("  #{skill}")
      end
    end
  end
end
