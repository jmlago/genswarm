defmodule Mix.Tasks.Swarm.Overlay do
  @moduledoc """
  Inspect or clear the dynamic-mutation overlay for a swarm.

      mix swarm overlay <swarm-name>           # list events
      mix swarm overlay <swarm-name> --clear   # wipe overlay

  The overlay is the event log of runtime additions/removals applied to the
  seed swarm config. It is replayed at swarm start so that dynamic state
  survives `swarm restart`. Use `--clear` (or `swarm restart --delete`) to
  return the swarm to its pure seed state.
  """

  use Mix.Task

  alias SubzeroclawSwarm.CLI.{Output, SwarmRegistry}

  @shortdoc "Inspect or clear the swarm overlay"

  @impl Mix.Task
  def run([swarm_name, "--clear"]) do
    Application.ensure_all_started(:subzeroclaw_swarm)
    :ok = SwarmRegistry.clear_overlay(swarm_name)
    Output.info("Overlay cleared for swarm '#{swarm_name}'")
  end

  def run([swarm_name]) do
    Application.ensure_all_started(:subzeroclaw_swarm)
    events = SwarmRegistry.load_overlay(swarm_name)

    if events == [] do
      Output.info("Overlay for '#{swarm_name}' is empty")
    else
      Output.info("Overlay for '#{swarm_name}' (#{length(events)} events):")

      Enum.with_index(events, 1)
      |> Enum.each(fn {{op, payload}, i} ->
        Output.info("  #{i}. #{op} #{inspect(payload, pretty: false)}")
      end)
    end
  end

  def run(_) do
    Output.error("Usage: swarm overlay <swarm-name> [--clear]")
    System.halt(1)
  end
end
