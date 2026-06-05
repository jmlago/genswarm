# Observability

Genswarms exposes everything that happens in a swarm through a single event spine.
Every observable state transition emits a `:telemetry` event, a bridge funnels
those into a centralized store, and the store persists, streams, and serves them.
Understanding that spine is the key to building any dashboard, monitor, or alerting
on top of the framework.

## The single spine

There is one rule: every observable state transition emits a `:telemetry` event,
and nothing else logs it. A telemetry bridge funnels those events into `LogStore`,
which both persists them (ETS + durable store) and streams them over PubSub /
WebSocket.

A transition is logged in exactly one place: its `emit_telemetry/2,3` call. The
emitter never also calls `LogStore.log` for the same moment. `LogStore.log` is
reserved for diagnostics and I/O that have no transition event: backend container
ops, raw agent stdout, received messages, config-load failures. Those are
single-source, so they never double up with the bridge.

```
emit_telemetry(:agent_started, ...)              # emitters (swarm_manager, agent_server, ...)
        |  [:genswarms, :agent, :agent_started]
        v
Genswarms.Observability.TelemetryBridge            # single :telemetry handler
        |  LogStore.log(:info, :agent, :agent_started, "agent fixer_1 started", ...)
        v
Genswarms.Observability.LogStore
        |-- ETS ring buffer        -> LogStore.query / GET /api/events (fast, in-node)
        |-- EventStore (durable)   -> cross-process / `genswarms events` CLI
        +-- PubSub {:log_event, e} -> SwarmChannel "event" / "log_entry" push (live)
```

To make a new transition observable, emit a telemetry event under
`[:genswarms, <domain>, <event>]` and add it to
`Genswarms.Observability.TelemetryBridge` `known_events/0`. Nothing else: no
controller, no broadcast, no `LogStore` call at the call site.

The bridge derives the log `level` from the event name. When the level depends on
the outcome (a partial swarm start, an unexpected agent exit), the emitter passes
`level:` in the telemetry metadata to set it explicitly; the bridge strips that key
before persisting, so it never leaks into the payload.

## Event taxonomy

`level` is derived from the event name (`*error*`/`*failed*` -> `:error`,
`*invalid*`/`*not_found*`/`*full*` -> `:warning`, otherwise `:info`). `category` is
the telemetry domain (`:router` is normalized to `:routing`).

| Domain (category) | Event | Level | Meaning |
|---|---|---|---|
| `swarm` | `swarm_started` | info | swarm finished starting (metadata `:status` = `running`/`error`) |
| `swarm` | `swarm_stopped` | info | swarm torn down |
| `agent` | `agent_started` | info | agent process up |
| `agent` | `agent_stopped` | info | agent process exited (metadata `:exit_status`) |
| `agent` | `agent_error` | error | agent backend/runtime error |
| `agent` | `agent_added` | info | agent added to a running swarm |
| `agent` | `agent_removed` | info | agent removed from a running swarm |
| `agent` | `task_sent` | info | task delivered to an agent |
| `agent` | `message_delivered` | info | message delivered to target inbox |
| `object` | `object_started` | info | object handler initialized |
| `object` | `object_stopped` | info | object handler stopped |
| `object` | `object_error` | error | object handler crashed/errored |
| `object` | `object_added` | info | object added to a running swarm |
| `object` | `object_removed` | info | object removed from a running swarm |
| `routing` | `message_routed` | info | direct message routed (`:from`, `:to`) |
| `routing` | `message_broadcast` | info | broadcast routed (`:from`) |
| `routing` | `invalid_route` | warning | message rejected by topology |

Every event carries `:swarm` in its metadata; agent/object events also carry
`:agent`/`:object` (lifted to dedicated columns by `LogStore`). Remaining metadata
is kept JSON-friendly in the event's `metadata` blob.

## Telemetry events and metrics

Raw telemetry events are emitted under `[:genswarms, <domain>, <event>]` with
metadata that always includes `:swarm` (and `:agent` for agent events). The
`Genswarms.Telemetry` supervisor declares a set of `Telemetry.Metrics` definitions
(consumable by LiveDashboard or any reporter). Metric names follow
`genswarms.<domain>.<event>`:

| Metric | Type | Tags | Source event |
|---|---|---|---|
| `genswarms.swarm.swarm_started.count` | counter | `:swarm` | `[:genswarms, :swarm, :swarm_started]` |
| `genswarms.swarm.swarm_stopped.count` | counter | `:swarm` | `[:genswarms, :swarm, :swarm_stopped]` |
| `genswarms.swarm.agent_count` | last_value | `:swarm` | `[:genswarms, :swarm, :agent_count]` |
| `genswarms.agent.agent_started.count` | counter | `:swarm`, `:agent` | `[:genswarms, :agent, :agent_started]` |
| `genswarms.agent.agent_stopped.count` | counter | `:swarm`, `:agent` | `[:genswarms, :agent, :agent_stopped]` |
| `genswarms.agent.agent_error.count` | counter | `:swarm`, `:agent` | `[:genswarms, :agent, :agent_error]` |
| `genswarms.agent.task_sent.count` | counter | `:swarm`, `:agent` | `[:genswarms, :agent, :task_sent]` |
| `genswarms.agent.message_delivered.count` | counter | `:swarm`, `:agent` | `[:genswarms, :agent, :message_delivered]` |
| `genswarms.router.message_routed.count` | counter | `:swarm` | `[:genswarms, :router, :message_routed]` |
| `genswarms.router.message_broadcast.count` | counter | `:swarm` | `[:genswarms, :router, :message_broadcast]` |
| `genswarms.router.invalid_route.count` | counter | `:swarm` | `[:genswarms, :router, :invalid_route]` |

The `genswarms.swarm.agent_count` last-value is produced by a periodic
`telemetry_poller` measurement (every 10s) that polls `SwarmManager.list/0`.
Standard Phoenix and BEAM VM metrics (`phoenix.*`, `vm.memory.total`,
`vm.total_run_queue_lengths.*`) are also registered.

## The EventStore behaviour

The durable, cross-process log sits behind one swappable interface,
`Genswarms.Observability.EventStore` (a behaviour plus a facade). Everything that
persists, reads, or tails events goes through it (`LogStore`, `EventRelay`, the
controllers, the channel, and the CLI), never a concrete backend. The backend is a
single config knob.

The callbacks are: `persist/1`, `query/1`, `events_since/2`, `max_event_id/0`, an
optional `persist_many/1` (bulk write), and an optional `child_specs/0` (processes
the backend needs supervised; the app splices them into its tree at boot).

```elixir
@callback persist(event()) :: :ok
@callback persist_many([event()]) :: :ok          # optional
@callback query(keyword()) :: [event()]
@callback events_since(since_id :: non_neg_integer(), limit :: pos_integer()) :: [event()]
@callback max_event_id() :: non_neg_integer()
@callback child_specs() :: [Supervisor.child_spec()]  # optional
```

### Backends

| Backend | Role |
|---|---|
| `EventStore.Sqlite` | Thin adapter over the `events` table in `.genswarms/swarms.db` (managed by `SwarmRegistry`). Stateless, synchronous; no supervised process. |
| `EventStore.Buffered` | Engine-independent write-batching decorator wrapping any inner backend. The default. |

The default in `config/config.exs` batches writes on top of SQLite:

```elixir
config :genswarms, :event_store, Genswarms.Observability.EventStore.Buffered

config :genswarms, Genswarms.Observability.EventStore.Buffered,
  inner: Genswarms.Observability.EventStore.Sqlite,
  interval_ms: 100,
  max_buffer: 1_000
```

`EventStore.Buffered` enqueues each `persist/1` into a `Writer` GenServer and
flushes the batch via the inner backend's `persist_many/1` on a 100ms timer (or
sooner when `max_buffer` is reached). This keeps disk writes off `LogStore`'s
critical path and lets the inner backend amortize them: with `EventStore.Sqlite`,
one `open -> BEGIN -> inserts -> COMMIT -> close` per flush instead of a connection
per event. The tradeoff is a small durability window (at most one flush interval)
on a hard crash; the live in-node path (ETS + PubSub) is synchronous and
unaffected. The buffer is flushed on graceful shutdown.

Tests run with the plain synchronous `EventStore.Sqlite` backend for determinism
(`config/test.exs`).

To raise throughput under load, tune the buffer (fewer, larger commits in exchange
for a slightly larger latency/durability window):

```elixir
config :genswarms, Genswarms.Observability.EventStore.Buffered,
  inner: Genswarms.Observability.EventStore.Sqlite,
  interval_ms: 250,
  max_buffer: 5_000
```

Because every caller goes through the facade, a future `EventStore.Postgres` or a
Redis/streaming backend can be swapped in transparently: only the backend module
changes, not the emitters, the bridge, the channel, or `EventRelay`.

## Cross-process event stream

A BEAM's in-memory machinery (PubSub, the process `Registry`, the ETS `LogStore`)
is node-local and invisible from another OS process. Genswarms supports two
deployment shapes.

Co-located: the swarm runs in the same BEAM as the Phoenix endpoint (for example,
started in-process via `POST /api/swarms`). Live PubSub, the WebSocket stream, and
the live snapshot endpoints all work directly. Nothing special is needed.

Monitor + daemons: the usual shape at scale. Each swarm runs as its own daemon
(`genswarms start`, its own BEAM), and a separate monitor/API node observes all of
them. The only thing the processes share is the SQLite `events` table in
`.genswarms/swarms.db`.

```
daemon swarm A --+  emit_telemetry -> LogStore -> SQLite events  --+
daemon swarm B --+                                                 +--> shared .genswarms/swarms.db
daemon swarm C --+                                                 --+
                                                                   |
                  monitor / API node ---- EventRelay polls events_since --+
                                                                   |       |
                  REST /api/events  -- reads SQLite ---------------+       v
                  WS swarm:<name>   <- EventRelay re-broadcasts {:log_event} onto
                                       the same LogStore PubSub topics -> SwarmChannel push
```

- `GET /api/events` (and the swarm/agent variants) read SQLite, so they surface
  every swarm, daemon or in-process.
- `Genswarms.Observability.EventRelay` runs on the monitor node. It tails new
  SQLite rows every ~500ms (batches of 500) via `EventStore.events_since/2` and
  re-broadcasts them onto the in-node PubSub topics, so the existing `SwarmChannel`
  pushes them to WebSocket clients live, with no clustering required. Latency is
  approximately the poll interval. Disable it with
  `config :genswarms, :event_relay, false`.
- A WebSocket client gets recent history from the snapshot on subscribe (also read
  from SQLite) and the live tail from the relay.

Run the relay only on a monitor node that does not host swarms in-process. There
the in-node `LogStore` never broadcasts swarm events (they happen in the daemons),
so the relay is the sole live source and there is no double-delivery.

### Still node-local (known limits)

- Live process-state pulls (`GET /objects/:name`, `/agents/:name`) call into the
  in-node `Registry`, so they only reach swarms in the same BEAM. For daemon
  swarms, rely on the event stream (and `GET /swarms/:name`, which has a SQLite
  fallback) instead of synchronous state pulls.
- Object internal state changes do not emit events (only object lifecycle does), so
  a live object-state feed is not available: poll `GET /objects/:name` in a
  co-located setup, or have the object emit on change.
- For true sub-second push or cross-host fan-out without polling, swap
  `Phoenix.PubSub` to its Redis adapter; the single spine means only the transport
  changes, not the emitters, bridge, or channel.

## Querying events

### CLI

`genswarms events` reads the durable spine, so it surfaces daemon swarms running in
other BEAMs by reading the `events` table in `.genswarms/swarms.db`.

```bash
genswarms events                      # recent events across all swarms
genswarms events -s my-swarm          # one swarm
genswarms events --category routing   # filter by category (backend|routing|agent|object|swarm|system)
genswarms events --errors             # errors only
genswarms events --follow             # stream in real time
```

The `--category` values map 1:1 to the taxonomy above. See [cli.md](cli.md) for the
full command reference.

### REST API

History endpoints are backed by the same spine and read from SQLite, so they cover
every swarm:

| Endpoint | Returns |
|---|---|
| `GET /api/events` | recent events, filterable by `level`/`category`/`event_type` |
| `GET /api/swarms/:name/events` | events for one swarm |
| `GET /api/swarms/:name/agents/:agent_name/events` | events for one agent |

Snapshot endpoints (current state) complement the history:

| Endpoint | Returns |
|---|---|
| `GET /api/swarms/:name` | swarm status, agents, objects, counts |
| `GET /api/swarms/:name/topology` | topology adjacency |
| `GET /api/swarms/:name/objects` | objects + lifecycle state |
| `GET /api/swarms/:name/objects/:object_name` | one object's live domain state |
| `GET /api/swarms/:name/agents/:agent_name` | one agent's status |

See [rest-api.md](rest-api.md) for full details.

### Real-time (WebSocket / PubSub)

On the `swarm:<name>` channel, subscribe and patch a view from the push stream:

| Push | Source |
|---|---|
| `event`, `log_entry` | `LogStore` (the whole taxonomy, after `subscribe_events`/`subscribe_logs`) |
| `agent_output` | agent stdout |
| `agent_status` | agent state transition |
| `message_routed`, `message_broadcast` | router |
| `swarm_started`, `swarm_stopped` | swarm lifecycle |
| `agent_added`, `agent_removed`, `topology_changed` | dynamic mutations |

Within a single BEAM, code can subscribe directly with
`Genswarms.Observability.LogStore.subscribe/0` (all events as `{:log_event, event}`)
or `LogStore.subscribe/1` (one swarm). See [websocket.md](websocket.md) for the
channel protocol.

## Building a dashboard

A dashboard is a consumer, not framework code (the project is API-first and
headless by design; no HTML ships here):

1. Bootstrap from the snapshot endpoints (status + topology + objects).
2. Open the `swarm:<name>` channel, `subscribe_events` for the taxonomy, and patch
   the view from the push stream.
3. Domain-specific concepts (for example user "sessions" or conversation
   transcripts) live in the consumer and read from the consumer's own store; the
   framework stays generic and exposes only generic object state via the
   introspection endpoint above.

## See also

- [cli.md](cli.md) — `genswarms events` and the full CLI reference
- [rest-api.md](rest-api.md) — `/api/events` and snapshot endpoints
- [websocket.md](websocket.md) — real-time channel protocol
