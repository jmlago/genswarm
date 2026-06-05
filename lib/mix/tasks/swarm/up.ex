defmodule Mix.Tasks.Swarm.Up do
  @shortdoc "Start the Phoenix frontend server"

  @moduledoc """
  Starts the Phoenix frontend server in background mode.

  ## Usage

      mix swarm up [options]

  ## Options

      --port PORT    Port to run the server on (default: 4000 or $PORT)
      --foreground   Run in foreground instead of background

  ## Examples

      mix swarm up                # Start on default port
      mix swarm up --port 3000    # Start on port 3000
      mix swarm up --foreground   # Run in foreground
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, ServerManager, EnvManager}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [port: :integer, foreground: :boolean, help: :boolean],
        aliases: [p: :port, f: :foreground, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      # Load environment
      EnvManager.auto_load()

      if opts[:foreground] do
        run_foreground(opts)
      else
        run_background(opts)
      end
    end
  end

  defp run_foreground(opts) do
    port = opts[:port] || get_port()
    System.put_env("PORT", to_string(port))

    Output.info("Starting Phoenix server on port #{port}")
    Output.info("Press Ctrl+C to stop")
    Output.newline()

    # Just run the standard Phoenix server
    Mix.Task.run("phx.server")
  end

  defp run_background(opts) do
    port = opts[:port] || get_port()

    # Check current status
    case ServerManager.get_server_status() do
      {:running, pid} ->
        Output.warning("Server already running (PID: #{pid})")
        Output.info("URL: #{ServerManager.server_url(port)}")
        Output.newline()
        Output.dim("Use 'swarm down' to stop it")

      {:stale, pid} ->
        Output.warning("Found stale PID file (PID: #{pid})")
        Output.info("Cleaning up and starting fresh...")
        ServerManager.remove_pid_file()
        do_start(port)

      :stopped ->
        do_start(port)
    end
  end

  defp do_start(port) do
    Output.info("Starting Phoenix server on port #{port}...")

    # We need to compile first if needed
    ensure_compiled()

    case ServerManager.start_server(port: port) do
      {:ok, pid} ->
        # Wait a moment for server to be ready
        wait_for_server(port, 10)

        Output.success("Server started (PID: #{pid})")
        Output.newline()
        Output.puts("  URL: #{Output.colorize(ServerManager.server_url(port), :cyan)}")
        Output.puts("  Logs: #{Output.colorize(".swarm/phoenix.log", :dim)}")
        Output.newline()
        Output.dim("Use 'swarm status' to check status")
        Output.dim("Use 'swarm down' to stop the server")

      {:error, {:already_running, pid}} ->
        Output.warning("Server already running (PID: #{pid})")

      {:error, reason} ->
        Output.error("Failed to start server: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp ensure_compiled do
    # Run compilation in a clean way
    Mix.Task.run("compile", [])
  end

  defp wait_for_server(_port, 0) do
    Output.warning("Server may not be ready yet")
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
