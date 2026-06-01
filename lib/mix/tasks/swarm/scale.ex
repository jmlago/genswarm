defmodule Mix.Tasks.Swarm.Scale do
  @moduledoc """
  Scale an agent group in a running swarm to a target count.

      mix swarm scale <swarm-name> <base-name> <count>

  Examples:

      mix swarm scale my-swarm fixer 20
      mix swarm scale evo pop_gen 4

  The agent group is identified by `base-name`. New agents are named
  `<base-name>_1`, `<base-name>_2`, ... `<base-name>_<count>`.
  Existing extras are stopped, missing ones are created using an existing
  group member's spec as the template.
  """

  use Mix.Task

  alias SubzeroclawSwarm.CLI.{DaemonBridge, Output}

  @shortdoc "Scale an agent group to a target count"

  @impl Mix.Task
  def run([swarm, base, count_str]) do
    case Integer.parse(count_str) do
      {n, ""} when n >= 0 ->
        Application.ensure_all_started(:subzeroclaw_swarm)
        scale(swarm, String.to_atom(base), n)

      _ ->
        Output.error("Count must be a non-negative integer, got: #{count_str}")
        System.halt(1)
    end
  end

  def run(_) do
    Output.error("Usage: swarm scale <swarm-name> <base-name> <count>")
    System.halt(1)
  end

  defp scale(swarm, base, n) do
    case DaemonBridge.dispatch(swarm, :scale_agent_group,
           %{base_name: base, target_count: n}) do
      {:ok, %{added: added, removed: removed, failed: failed}} ->
        Output.info("Scaled #{base} to #{n}")
        Output.info("  added:   #{format_list(added)}")
        Output.info("  removed: #{format_list(removed)}")

        if failed != [] do
          Output.error("  failed:")

          Enum.each(failed, fn {name, reason} ->
            Output.error("    - #{name}: #{inspect(reason)}")
          end)

          System.halt(1)
        end

      {:ok, value} ->
        Output.info("Scaled (raw result): #{inspect(value)}")

      {:error, reason} ->
        Output.error("Failed to scale: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp format_list([]), do: "(none)"
  defp format_list(list), do: list |> Enum.map_join(", ", &to_string/1)
end
