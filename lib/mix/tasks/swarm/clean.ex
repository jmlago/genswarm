defmodule Mix.Tasks.Swarm.Clean do
  @shortdoc "Clean up stopped/crashed swarms"

  @moduledoc """
  Cleans up stopped and crashed swarms from the registry.

  This command removes swarms that are no longer running and deletes
  their associated files (logs, data directories).

  ## Usage

      mix swarm clean [options]

  ## Options

      --all        Also clear all events from the database
      --force, -f  Skip confirmation prompt
      --help, -h   Show this help

  ## Examples

      mix swarm clean              # Clean stopped/crashed swarms
      mix swarm clean --all        # Also clear all events
      mix swarm clean --force      # Skip confirmation
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, SwarmRegistry}

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        strict: [all: :boolean, force: :boolean, help: :boolean],
        aliases: [f: :force, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      load_env()
      SwarmRegistry.init()
      clean_swarms(opts)
    end
  end

  defp clean_swarms(opts) do
    swarms = SwarmRegistry.list_swarms()

    # Find stopped/crashed swarms
    to_clean = Enum.filter(swarms, fn s -> s.status in [:stopped, :crashed] end)

    if Enum.empty?(to_clean) do
      Output.info("No stopped or crashed swarms to clean")

      if opts[:all] do
        clean_events(opts)
      end
    else
      Output.header("Swarms to clean")
      Enum.each(to_clean, fn s ->
        status_str = if s.status == :crashed, do: Output.colorize("crashed", :red), else: Output.colorize("stopped", :dim)
        Output.puts("  #{s.name}: #{status_str}")
      end)
      Output.newline()

      if opts[:force] || confirm_clean(length(to_clean), opts[:all]) do
        do_clean(to_clean, opts)
      else
        Output.info("Cancelled")
      end
    end
  end

  defp confirm_clean(count, clear_events) do
    msg = if clear_events do
      "This will delete #{count} swarm(s) and clear all events."
    else
      "This will delete #{count} swarm(s) and their files."
    end

    Output.warning(msg)
    response = Mix.shell().prompt("Are you sure? [y/N]") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end

  defp do_clean(swarms, opts) do
    # Delete each swarm
    Enum.each(swarms, fn swarm ->
      Output.info("Deleting #{swarm.name}...")
      SwarmRegistry.delete_swarm(swarm.name)
      SwarmRegistry.delete_swarm_files(swarm.name)
    end)

    Output.success("Cleaned #{length(swarms)} swarm(s)")

    # Clear events if --all
    if opts[:all] do
      clean_events(opts)
    end
  end

  defp clean_events(_opts) do
    Output.info("Clearing all events...")
    SwarmRegistry.clear_all_events()
    Output.success("Events cleared")
  end

  defp load_env do
    alias Genswarm.CLI.EnvManager
    case EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[Genswarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end
  end
end
