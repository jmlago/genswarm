defmodule Genswarm.Telemetry do
  @moduledoc """
  Telemetry metrics and handlers for Genswarm.

  Tracks:
  - Swarm lifecycle events (start, stop)
  - Agent lifecycle events (start, stop, error)
  - Message routing events
  - Backend health
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the list of telemetry metrics for LiveDashboard.
  """
  def metrics do
    [
      # Phoenix metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.stop.duration",
        unit: {:native, :millisecond}
      ),

      # Swarm metrics
      counter("genswarm.swarm.swarm_started.count",
        tags: [:swarm]
      ),
      counter("genswarm.swarm.swarm_stopped.count",
        tags: [:swarm]
      ),
      last_value("genswarm.swarm.agent_count",
        tags: [:swarm]
      ),

      # Agent metrics
      counter("genswarm.agent.agent_started.count",
        tags: [:swarm, :agent]
      ),
      counter("genswarm.agent.agent_stopped.count",
        tags: [:swarm, :agent]
      ),
      counter("genswarm.agent.agent_error.count",
        tags: [:swarm, :agent]
      ),
      counter("genswarm.agent.task_sent.count",
        tags: [:swarm, :agent]
      ),
      counter("genswarm.agent.message_delivered.count",
        tags: [:swarm, :agent]
      ),

      # Router metrics
      counter("genswarm.router.message_routed.count",
        tags: [:swarm]
      ),
      counter("genswarm.router.message_broadcast.count",
        tags: [:swarm]
      ),
      counter("genswarm.router.invalid_route.count",
        tags: [:swarm]
      ),

      # VM metrics
      summary("vm.memory.total", unit: {:byte, :megabyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_swarms, []}
    ]
  end

  @doc false
  def measure_swarms do
    # Guard against SwarmManager not running (e.g., in CLI commands)
    try do
      swarms = Genswarm.SwarmManager.list()

      Enum.each(swarms, fn swarm ->
        :telemetry.execute(
          [:genswarm, :swarm, :agent_count],
          %{agent_count: swarm.agent_count},
          %{swarm: swarm.name}
        )
      end)
    catch
      :exit, {:noproc, _} -> :ok
    end
  end
end
