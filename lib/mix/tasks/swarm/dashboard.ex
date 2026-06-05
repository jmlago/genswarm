defmodule Mix.Tasks.Swarm.Dashboard do
  @shortdoc "Manage the web dashboard"

  @moduledoc """
  Start, stop, or check status of the Phoenix web dashboard.

  The dashboard provides a web interface for monitoring and managing swarms.
  It runs independently of swarms - swarms can run without the dashboard.

  ## Usage

      mix swarm dashboard [subcommand] [options]

  ## Subcommands

      start       Start the dashboard (default if no subcommand)
      stop        Stop the dashboard
      status      Check if dashboard is running

  ## Options (for start)

      --port PORT    Port to run on (default: 4000 or $PORT)
      --foreground   Run in foreground instead of background

  ## Examples

      mix swarm dashboard              # Start dashboard
      mix swarm dashboard start        # Start dashboard
      mix swarm dashboard start -p 3000  # Start on port 3000
      mix swarm dashboard stop         # Stop dashboard
      mix swarm dashboard status       # Check status
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, EnvManager, ServerManager}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [port: :integer, foreground: :boolean, help: :boolean],
        aliases: [p: :port, f: :foreground, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      # Load environment
      EnvManager.auto_load()

      case rest do
        [] ->
          do_start(opts)

        ["start" | _] ->
          do_start(opts)

        ["stop" | _] ->
          do_stop()

        ["status" | _] ->
          do_status()

        [subcommand | _] ->
          Output.error("Unknown subcommand: #{subcommand}")
          Output.info("Available: start, stop, status")
      end
    end
  end

  defp do_start(opts) do
    port = opts[:port] || get_port()

    if opts[:foreground] do
      # For foreground, start the app and run inline
      {:ok, _} = Application.ensure_all_started(:genswarm)
      start_foreground(port)
    else
      # For background, use ServerManager to spawn separate process
      start_background(port)
    end
  end

  defp start_foreground(port) do
    case Genswarm.Application.start_web_server(port: port) do
      {:ok, _pid} ->
        Output.success("Dashboard started on port #{port}")
        Output.puts("  URL: #{Output.colorize("http://localhost:#{port}", :cyan)}")
        Output.newline()
        Output.info("Press Ctrl+C to stop")

        # Keep the process alive
        Process.sleep(:infinity)

      {:error, :already_running} ->
        Output.warning("Dashboard already running")
        Output.puts("  URL: #{Output.colorize("http://localhost:#{port}", :cyan)}")

      {:error, reason} ->
        Output.error("Failed to start dashboard: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp start_background(port) do
    case ServerManager.start_server(port: port) do
      {:ok, pid} ->
        # Wait for server to be ready
        wait_for_server(port, 20)

        Output.success("Dashboard started (PID: #{pid})")
        Output.newline()
        Output.puts("  URL: #{Output.colorize("http://localhost:#{port}", :cyan)}")
        Output.puts("  Log: #{Output.colorize(".swarm/phoenix.log", :dim)}")
        Output.newline()
        Output.dim("Use 'swarm dashboard status' to check status")
        Output.dim("Use 'swarm dashboard stop' to stop")

      {:error, {:already_running, pid}} ->
        Output.warning("Dashboard already running (PID: #{pid})")
        Output.puts("  URL: #{Output.colorize("http://localhost:#{port}", :cyan)}")

      {:error, reason} ->
        Output.error("Failed to start dashboard: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_stop do
    case ServerManager.stop_server() do
      :ok ->
        Output.success("Dashboard stopped")

      {:error, :not_running} ->
        Output.info("Dashboard is not running")

      {:error, reason} ->
        Output.error("Failed to stop dashboard: #{inspect(reason)}")
    end
  end

  defp do_status do
    case ServerManager.get_server_status() do
      {:running, pid} ->
        port = get_port()
        Output.success("Dashboard is running (PID: #{pid})")
        Output.puts("  URL: #{Output.colorize("http://localhost:#{port}", :cyan)}")

      {:stale, pid} ->
        Output.warning("Dashboard has stale PID file (PID: #{pid})")
        Output.dim("Cleaning up...")
        ServerManager.remove_pid_file()
        Output.info("Dashboard is not running")

      :stopped ->
        Output.info("Dashboard is not running")
        Output.dim("Use 'swarm dashboard start' to start it")
    end
  end

  defp wait_for_server(_port, 0) do
    Output.warning("Dashboard may not be ready yet")
  end

  defp wait_for_server(port, attempts) do
    case :gen_tcp.connect(~c"localhost", port, [], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        Process.sleep(500)
        wait_for_server(port, attempts - 1)
    end
  end

  defp get_port do
    case System.get_env("PORT") do
      nil ->
        4000

      port_str ->
        case Integer.parse(port_str) do
          {port, _} -> port
          :error -> 4000
        end
    end
  end
end
