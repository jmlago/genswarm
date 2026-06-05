defmodule Mix.Tasks.Swarm.Delete do
  @shortdoc "Delete a swarm and all its data"

  @moduledoc """
  Deletes a swarm and cleans up all associated files.

  This command:
  - Stops the swarm if it's running
  - Removes the swarm from the registry
  - Deletes all events and logs for the swarm
  - Removes swarm data files from ~/.subzeroclaw/swarms/

  ## Usage

      mix swarm delete <swarm_name>

  ## Options

      --force, -f    Skip confirmation prompt

  ## Examples

      mix swarm delete my-swarm
      mix swarm delete my-swarm --force
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, SwarmRegistry}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [force: :boolean, help: :boolean],
        aliases: [f: :force, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      case rest do
        [swarm_name] ->
          load_env()
          SwarmRegistry.init()
          delete_swarm(swarm_name, opts)

        _ ->
          Output.error("Usage: mix swarm delete <swarm_name> [--force]")
      end
    end
  end

  defp delete_swarm(swarm_name, opts) do
    case SwarmRegistry.get_swarm(swarm_name) do
      {:ok, swarm} ->
        # Confirm unless --force
        if opts[:force] || confirm_delete(swarm_name) do
          do_delete(swarm_name, swarm)
        else
          Output.info("Cancelled")
        end

      {:error, :not_found} ->
        Output.error("Swarm not found: #{swarm_name}")
    end
  end

  defp confirm_delete(swarm_name) do
    Output.warning("This will permanently delete swarm '#{swarm_name}' and all its data.")
    response = Mix.shell().prompt("Are you sure? [y/N]") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end

  defp do_delete(swarm_name, swarm) do
    # Stop if running
    if swarm.status == :running and swarm.pid do
      Output.info("Stopping swarm...")
      System.cmd("kill", ["-TERM", to_string(swarm.pid)], stderr_to_stdout: true)
      Process.sleep(1000)
    end

    # Delete from registry (swarms, events, tasks tables)
    Output.info("Removing from registry...")
    SwarmRegistry.delete_swarm(swarm_name)

    # Delete files
    Output.info("Deleting files...")
    SwarmRegistry.delete_swarm_files(swarm_name)

    Output.success("Deleted swarm: #{swarm_name}")
  end

  defp load_env do
    alias Genswarm.CLI.EnvManager
    case EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[Genswarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end
  end
end
