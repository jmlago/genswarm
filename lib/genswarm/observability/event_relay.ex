defmodule Genswarm.Observability.EventRelay do
  @moduledoc """
  Bridges the durable SQLite event log to the live PubSub stream.

  In the multi-swarm topology each swarm runs as its own daemon (its own BEAM),
  so its in-memory PubSub broadcasts never reach a central monitor in a different
  process. The one thing every swarm shares is the SQLite `events` table, which
  every swarm writes to via `LogStore` (fed by the telemetry bridge).

  This GenServer runs on the **monitor / API node**. It tails that table and
  re-broadcasts each newly-persisted event onto the exact PubSub topics that
  `LogStore` uses in-node, so the existing `SwarmChannel` delivers them to
  WebSocket clients unchanged. Polling turns the durable log into a live push at
  the edge — no clustering required.

  ## Where to run it

  Start it only where it is the bridge: a monitor/API node that does NOT host
  swarms in-process. On such a node the in-node `LogStore` never broadcasts swarm
  events (they happen in the daemons), so the relay is the sole live source and
  there is no double-delivery. It is started by `Application.start_web_server/1`
  for exactly this reason; daemons don't start the web server.

  Latency is bounded by `:interval` (default 500ms). See `docs/observability.md`.
  """

  use GenServer
  require Logger

  alias Genswarm.Observability.EventStore

  @default_interval 500
  @batch 500
  # Must match Genswarm.Observability.LogStore's @pubsub_topic.
  @pubsub_topic "log_store:events"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Child spec helper so it can be started/stopped under the app supervisor."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    # Start from the current tip: the relay streams NEW events going forward;
    # clients get prior history from the snapshot on subscribe.
    state = %{interval: interval, last_id: safe_max_id()}
    schedule(interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_last =
      state.last_id
      |> EventStore.events_since(@batch)
      |> Enum.reduce(state.last_id, fn event, _acc ->
        relay(event)
        event.id
      end)

    schedule(state.interval)
    {:noreply, %{state | last_id: new_last}}
  rescue
    err ->
      Logger.warning("EventRelay poll failed: #{inspect(err)}")
      schedule(state.interval)
      {:noreply, state}
  end

  # Mirror LogStore.broadcast_event/1 exactly: general topic + per-swarm topic.
  defp relay(event) do
    Phoenix.PubSub.broadcast(Genswarm.PubSub, @pubsub_topic, {:log_event, event})

    if event.swarm do
      Phoenix.PubSub.broadcast(
        Genswarm.PubSub,
        "#{@pubsub_topic}:#{event.swarm}",
        {:log_event, event}
      )
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp safe_max_id do
    EventStore.max_event_id()
  rescue
    _ -> 0
  end
end
