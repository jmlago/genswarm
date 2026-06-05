defmodule Mix.Tasks.Swarm.Down do
  @shortdoc "Stop all services (dashboard + swarms)"

  @moduledoc """
  Stops all running services including the dashboard and all swarms.

  ## Usage

      mix swarm down [options]

  ## Options

      --dashboard-only   Only stop the dashboard
      --swarms-only      Only stop swarms

  ## Examples

      mix swarm down                  # Stop everything
      mix swarm down --dashboard-only # Only stop dashboard
      mix swarm down --swarms-only    # Only stop swarms
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, ServerManager}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          dashboard_only: :boolean,
          server_only: :boolean,
          swarms_only: :boolean,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      cond do
        opts[:dashboard_only] == true or opts[:server_only] == true ->
          stop_dashboard()

        opts[:swarms_only] == true ->
          stop_swarms()

        true ->
          stop_all()
      end
    end
  end

  defp stop_all do
    Output.header("Stopping all services")

    # Stop swarms first (they need the application running)
    swarms_stopped = stop_swarms()

    # Then stop the dashboard
    dashboard_stopped = stop_dashboard()

    Output.newline()

    if swarms_stopped or dashboard_stopped do
      Output.success("All services stopped")
    else
      Output.info("No services were running")
    end
  end

  defp stop_swarms do
    # Need full app to interact with in-process swarms
    case Application.ensure_all_started(:genswarm) do
      {:ok, _} ->
        swarms = Genswarm.list_swarms()

        if Enum.empty?(swarms) do
          Output.dim("No swarms running")
          false
        else
          Output.info("Stopping #{length(swarms)} swarm(s)...")

          Enum.each(swarms, fn swarm ->
            case Genswarm.stop_swarm(swarm.name) do
              :ok ->
                Output.success("Stopped swarm: #{swarm.name}")

              {:error, reason} ->
                Output.warning("Failed to stop #{swarm.name}: #{inspect(reason)}")
            end
          end)

          true
        end

      {:error, _reason} ->
        # App might not be running, that's ok
        Output.dim("No swarms running (application not started)")
        false
    end
  end

  defp stop_dashboard do
    case ServerManager.get_server_status() do
      {:running, pid} ->
        Output.info("Stopping dashboard (PID: #{pid})...")

        case ServerManager.stop_server() do
          :ok ->
            Output.success("Dashboard stopped")
            true

          {:error, reason} ->
            Output.warning("Failed to stop dashboard: #{inspect(reason)}")
            false
        end

      {:stale, pid} ->
        Output.dim("Dashboard not running (cleaning stale PID: #{pid})")
        ServerManager.remove_pid_file()
        false

      :stopped ->
        Output.dim("Dashboard not running")
        false
    end
  end
end
