defmodule Mix.Tasks.Swarm.Snapshot do
  @moduledoc """
  Emit the current effective configuration of a swarm (seed ⊕ overlay) as
  a `.exs` file.

      mix swarm snapshot <swarm-name>                  # to stdout
      mix swarm snapshot <swarm-name> --output file.exs

  This does NOT modify the swarm's original config file. The output is an
  auto-generated declarative seed that you can load with `swarm start`.
  """

  use Mix.Task

  alias Genswarm.Config.{ExsWriter, SwarmConfig}
  alias Genswarm.CLI.{DaemonBridge, Output}

  @shortdoc "Emit current swarm config as .exs (seed ⊕ overlay)"

  @impl Mix.Task
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args, strict: [output: :string], aliases: [o: :output])

    case rest do
      [swarm] ->
        Application.ensure_all_started(:genswarm)
        snapshot(swarm, opts)

      _ ->
        Output.error("Usage: swarm snapshot <swarm-name> [--output file.exs]")
        System.halt(1)
    end
  end

  defp snapshot(swarm_name, opts) do
    case DaemonBridge.dispatch(swarm_name, :get_full_config, %{}) do
      {:ok, config_map} ->
        config = struct(SwarmConfig, Map.put(config_map, :created_at, DateTime.utc_now()))
        source = ExsWriter.to_exs_source(config)

        case Keyword.get(opts, :output) do
          nil ->
            IO.write(source)

          path ->
            File.write!(path, source)
            Output.info("Wrote snapshot to #{path}")
        end

      {:error, reason} ->
        Output.error("Failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
