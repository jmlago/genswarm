defmodule Mix.Tasks.Swarm.Restart do
  @shortdoc "Restart a swarm"

  @moduledoc """
  Restarts a swarm by stopping and starting it again.

  This reloads the configuration file, so any changes made to the
  config will take effect after restart.

  ## Usage

      mix swarm restart <swarm_name> [options]

  ## Options

      --delete, -d   Delete all logs and events before restarting (clean restart)
      --help, -h     Show this help

  ## Examples

      mix swarm restart my-swarm           # Normal restart
      mix swarm restart my-swarm --delete  # Clean restart (delete old logs/events)
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, SwarmRegistry}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [delete: :boolean, help: :boolean],
        aliases: [d: :delete, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      case rest do
        [swarm_name] ->
          load_env()
          SwarmRegistry.init()
          restart_swarm(swarm_name, opts)

        [] ->
          Output.error("Missing swarm name")
          Output.info("Usage: mix swarm restart <swarm_name> [--delete]")

        _ ->
          Output.error("Usage: mix swarm restart <swarm_name> [--delete]")
      end
    end
  end

  defp restart_swarm(swarm_name, opts) do
    case SwarmRegistry.get_swarm(swarm_name) do
      {:ok, swarm} ->
        config_path = swarm.config_path

        unless config_path && File.exists?(config_path) do
          Output.error("Config file not found: #{config_path || "none"}")
          System.halt(1)
        end

        # Stop if running
        if swarm.status == :running and swarm.pid do
          Output.info("Stopping swarm...")
          System.cmd("kill", ["-TERM", to_string(swarm.pid)], stderr_to_stdout: true)
          wait_for_exit(swarm.pid, 10)
          SwarmRegistry.mark_stopped(swarm_name)
        end

        # Delete data if requested
        if opts[:delete] do
          Output.info("Cleaning up old data...")
          SwarmRegistry.delete_swarm(swarm_name)
          SwarmRegistry.delete_swarm_files(swarm_name)
        end

        # Start the swarm again
        Output.info("Starting swarm...")
        start_daemon(config_path)

      {:error, :not_found} ->
        Output.error("Swarm not found: #{swarm_name}")
        Output.info("Use 'swarm start <config.exs>' to start a new swarm")
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

  defp start_daemon(config_path) do
    # Use the same daemon start logic as Mix.Tasks.Swarm.Start
    swarm_name = extract_swarm_name(config_path) || "swarm"
    log_file = Path.join([File.cwd!(), ".swarm", "logs", "#{swarm_name}.log"])
    File.mkdir_p!(Path.dirname(log_file))

    cmd = ~s(sh -c 'nohup mix swarm.start.daemon "#{config_path}" > #{log_file} 2>&1 & echo $!')

    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:cd, File.cwd!()}
      ])

    case receive_daemon_pid(port) do
      {:ok, daemon_pid} ->
        Process.sleep(2000)

        if SwarmRegistry.process_alive?(daemon_pid) do
          Output.success("Restarted swarm: #{swarm_name} (PID: #{daemon_pid})")
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

  defp load_env do
    alias Genswarm.CLI.EnvManager
    case EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[Genswarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end
  end
end
