defmodule Genswarm.CLI do
  @moduledoc """
  Main entry point for the swarm CLI escript.

  This module serves as the escript main module, parsing arguments
  and dispatching to the appropriate Mix task implementations.
  """

  alias Genswarm.CLI.{Output, EnvManager}

  @version Mix.Project.config()[:version] || "0.1.0"

  @commands %{
    "init" => "Create a new swarm project",
    "dashboard" => "Start/stop the web dashboard",
    "start" => "Start a swarm from configuration",
    "stop" => "Stop a running swarm",
    "restart" => "Restart a swarm",
    "status" => "Show status of dashboard and swarms",
    "events" => "Query and stream swarm events",
    "logs" => "View agent conversation logs and output",
    "task" => "Send a task to an agent",
    "msg" => "Send a message between agents",
    "env" => "Manage environment variables",
    "build" => "Build Docker images via nix",
    "config" => "Configuration commands",
    "check" => "Validate swarm configuration files",
    "list-skills" => "List available skills",
    "help" => "Show this help message",
    "version" => "Show version"
  }

  @doc """
  Main entry point for the escript.
  """
  def main(args) do
    # Auto-load .env file
    case EnvManager.auto_load() do
      {:ok, path} ->
        if System.get_env("SWARM_DEBUG") do
          Output.dim("Loaded environment from #{path}")
        end

      {:error, :not_found} ->
        :ok
    end

    # Parse and dispatch
    case args do
      [] ->
        print_help()

      ["help" | _] ->
        print_help()

      ["version" | _] ->
        print_version()

      ["--version" | _] ->
        print_version()

      ["-v" | _] ->
        print_version()

      [command | rest] ->
        dispatch(command, rest)
    end
  end

  defp dispatch(command, args) do
    # Ensure application is started for most commands
    # Config validation doesn't need the full app (just Loader + SwarmConfig)
    unless command in ["init", "help", "version", "env", "config", "check", "dashboard"] do
      ensure_started()
    end

    case command do
      "init" ->
        Mix.Tasks.Swarm.Init.run(args)

      "dashboard" ->
        Mix.Tasks.Swarm.Dashboard.run(args)

      # Legacy aliases for up/down
      "up" ->
        Mix.Tasks.Swarm.Dashboard.run(["start"] ++ args)

      "down" ->
        Mix.Tasks.Swarm.Down.run(args)

      "events" ->
        Mix.Tasks.Swarm.Events.run(args)

      "start" ->
        Mix.Tasks.Swarm.Start.run(args)

      "stop" ->
        Mix.Tasks.Swarm.Stop.run(args)

      "restart" ->
        Mix.Tasks.Swarm.Restart.run(args)

      "status" ->
        Mix.Tasks.Swarm.Status.run(args)

      "logs" ->
        Mix.Tasks.Swarm.Logs.run(args)

      "task" ->
        Mix.Tasks.Swarm.Task.run(args)

      "msg" ->
        Mix.Tasks.Swarm.Msg.run(args)

      "env" ->
        Mix.Tasks.Swarm.Env.run(args)

      "build" ->
        Mix.Tasks.Swarm.Build.run(args)

      "config" ->
        dispatch_config(args)

      "check" ->
        # Shortcut for 'config validate'
        Mix.Tasks.Swarm.Config.Validate.run(args)

      "list-skills" ->
        Mix.Tasks.Swarm.ListSkills.run(args)

      "scale" ->
        Mix.Tasks.Swarm.Scale.run(args)

      "overlay" ->
        Mix.Tasks.Swarm.Overlay.run(args)

      "snapshot" ->
        Mix.Tasks.Swarm.Snapshot.run(args)

      _ ->
        Output.error("Unknown command: #{command}")
        Output.newline()
        print_help()
        System.halt(1)
    end
  end

  defp dispatch_config(args) do
    case args do
      ["validate" | rest] ->
        Mix.Tasks.Swarm.Config.Validate.run(rest)

      [] ->
        Output.error("Missing config subcommand")
        Output.info("Available: validate")

      [subcommand | _] ->
        Output.error("Unknown config subcommand: #{subcommand}")
        Output.info("Available: validate")
    end
  end

  defp ensure_started do
    # Start the application
    case Application.ensure_all_started(:genswarm) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Output.error("Failed to start application: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp print_help do
    Output.puts("swarm - Genswarm CLI v#{@version}")
    Output.newline()
    Output.puts(Output.colorize("USAGE:", :bold))
    Output.puts("  swarm <command> [options]")
    Output.newline()
    Output.puts(Output.colorize("COMMANDS:", :bold))

    max_cmd_len =
      @commands
      |> Map.keys()
      |> Enum.map(&String.length/1)
      |> Enum.max()

    @commands
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {cmd, desc} ->
      padded = String.pad_trailing(cmd, max_cmd_len + 2)
      Output.puts("  #{Output.colorize(padded, :cyan)}#{desc}")
    end)

    Output.newline()
    Output.puts(Output.colorize("EXAMPLES:", :bold))
    Output.puts("  swarm init my-project       # Create new project")
    Output.puts("  swarm start config.exs      # Start a swarm")
    Output.puts("  swarm logs my-swarm agent1  # View agent conversation")
    Output.puts("  swarm logs my-swarm -f      # Stream logs live")
    Output.puts("  swarm logs my-swarm --stdout # View stdout output")
    Output.puts("  swarm events --errors       # View error events")
    Output.puts("  swarm task my-swarm agent1 \"Hello\"")
    Output.newline()
    Output.puts("Run 'swarm <command> --help' for command-specific help.")
  end

  defp print_version do
    Output.puts("swarm #{@version}")
  end
end
