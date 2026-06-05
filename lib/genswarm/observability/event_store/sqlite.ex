defmodule Genswarm.Observability.EventStore.Sqlite do
  @moduledoc """
  SQLite-backed `EventStore` — the default backend.

  Thin adapter over the events table in `.swarm/swarms.db` (managed by
  `SwarmRegistry`). Stateless: each call opens a short-lived connection, so it
  needs no supervised process (`child_specs/0` is not implemented).

  This is fine up to moderate load. Past that, the connect-per-write pattern and
  single-writer locking become the bottleneck — that is the point to introduce a
  batching/pooled backend (or Postgres), behind this same behaviour. See
  `Genswarm.Observability.EventStore`.
  """

  @behaviour Genswarm.Observability.EventStore

  alias Genswarm.CLI.SwarmRegistry

  @impl true
  def persist(event) do
    SwarmRegistry.log_event(
      event.level,
      event.category,
      event.event_type,
      event.message,
      swarm: event[:swarm],
      agent: event[:agent],
      metadata: event[:metadata] || %{}
    )

    :ok
  end

  @impl true
  def query(opts), do: SwarmRegistry.query_events(opts)

  @impl true
  def events_since(since_id, limit), do: SwarmRegistry.events_since(since_id, limit)

  @impl true
  def max_event_id, do: SwarmRegistry.max_event_id()
end
