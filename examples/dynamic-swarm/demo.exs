# Dynamic swarm demo — exercises the runtime-mutation API end-to-end with
# the :mock backend (no LLM required).
#
# Run with:
#
#     mix run examples/dynamic-swarm/demo.exs
#
# Demonstrates:
#   1. Starting a swarm from a tiny seed
#   2. Adding an ad-hoc observer object at runtime
#   3. Scaling an agent group up and back down
#   4. Inspecting the overlay event log
#   5. Stop + restart preserves overlay (state survives)
#   6. Snapshotting the effective config to a .exs

alias SubzeroclawSwarm.SwarmManager
alias SubzeroclawSwarm.Routing.Router
alias SubzeroclawSwarm.CLI.SwarmRegistry
alias SubzeroclawSwarm.Config.{Loader, ExsWriter}

defmodule Demo.Observer do
  @moduledoc "An object that just counts messages it receives."
  @behaviour SubzeroclawSwarm.Objects.ObjectHandler

  @impl true
  def init(_config), do: {:ok, %{count: 0}}

  @impl true
  def handle_message(from, content, state) do
    IO.puts("  [observer] got from=#{from}: #{inspect(content)}")
    {:noreply, %{state | count: state.count + 1}}
  end

  @impl true
  def interface(), do: %{}
end

defmodule Demo do
  def banner(text) do
    line = String.duplicate("=", 60)
    IO.puts("\n#{line}\n  #{text}\n#{line}")
  end

  def show_state(swarm) do
    {:ok, status} = SwarmManager.status(swarm)
    {:ok, topology} = Router.get_topology(swarm)

    agent_names =
      status.agents
      |> Enum.map(&to_string(&1.name))
      |> Enum.sort()
      |> Enum.join(", ")

    object_names =
      status.objects
      |> Enum.map(&to_string(&1.name))
      |> Enum.sort()
      |> Enum.join(", ")

    IO.puts("  agents   (#{length(status.agents)}): #{agent_names}")
    IO.puts("  objects  (#{length(status.objects)}): #{object_names}")
    IO.puts("  topology: #{inspect(topology)}")
  end
end

# --- 1. Start swarm from seed ---
Demo.banner("Starting swarm from seed.exs (1 worker, no objects)")

seed_path = Path.join(__DIR__, "seed.exs")
# Make sure a previous demo run is cleaned up
SwarmManager.stop("dynamic-demo")
SwarmRegistry.clear_overlay("dynamic-demo")

{:ok, swarm} = SwarmManager.start_swarm(seed_path)
Demo.show_state(swarm)

# --- 2. Add an observer object at runtime ---
Demo.banner("Adding :observer object with incoming edge from :worker_1")

{:ok, :observer} =
  SwarmManager.add_object(
    swarm,
    %{name: :observer, handler: Demo.Observer},
    incoming: [:worker_1],
    persist: true
  )

Demo.show_state(swarm)

# Send a routed message worker_1 -> observer to prove the edge works
Router.route(swarm, :worker_1, :observer, "hello from worker_1")
Process.sleep(50)

# --- 3. Scale the worker group up to 4 ---
Demo.banner("Scaling :worker to 4 (was 1, target 4)")

{:ok, result} = SwarmManager.scale_agent_group(swarm, :worker, 4, persist: true)
IO.puts("  added:   #{inspect(result.added)}")
IO.puts("  removed: #{inspect(result.removed)}")
IO.puts("  failed:  #{inspect(result.failed)}")
Demo.show_state(swarm)

# --- 4. Scale back down to 2 ---
Demo.banner("Scaling :worker to 2 (extras get stopped)")

{:ok, result} = SwarmManager.scale_agent_group(swarm, :worker, 2, persist: true)
IO.puts("  added:   #{inspect(result.added)}")
IO.puts("  removed: #{inspect(result.removed)}")
Demo.show_state(swarm)

# --- 5. Inspect the overlay event log ---
Demo.banner("Overlay event log (what persisted)")

SwarmRegistry.load_overlay(swarm)
|> Enum.with_index(1)
|> Enum.each(fn {{op, payload}, i} ->
  IO.puts("  #{i}. #{op}  payload=#{inspect(payload, pretty: false)}")
end)

# --- 6. Stop and restart — overlay should replay ---
Demo.banner("Stopping and restarting (overlay should replay)")

{:ok, _} = SwarmManager.stop(swarm)
IO.puts("  stopped.")

{:ok, ^swarm} = SwarmManager.start_swarm(seed_path)
IO.puts("  restarted. effective state:")
Demo.show_state(swarm)

# --- 7. Snapshot effective config to .exs ---
Demo.banner("Snapshotting effective config (seed ⊕ overlay) to .exs")

{:ok, config} = SwarmManager.get_full_config(swarm)
snapshot = ExsWriter.to_exs_source(config)
snapshot_path = Path.join(__DIR__, "snapshot.exs")
File.write!(snapshot_path, snapshot)

IO.puts("  written to #{snapshot_path}")
IO.puts("")
IO.puts(snapshot)

# Verify round-trip
{:ok, reloaded} = Loader.load(snapshot_path)
IO.puts("  ✓ snapshot reloads via Loader (#{length(reloaded.agents)} agents, " <>
          "#{length(reloaded.objects)} objects, #{length(reloaded.topology)} edges)")

# --- Cleanup ---
Demo.banner("Cleanup")
{:ok, _} = SwarmManager.stop(swarm)
SwarmRegistry.clear_overlay(swarm)
File.rm(snapshot_path)
IO.puts("  done.")
