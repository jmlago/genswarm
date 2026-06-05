# Observability

Genswarm exposes everything that happens in a swarm through a **single event
spine**. Understanding that spine is the key to building any dashboard, monitor,
or alerting on top of the framework.

## The one rule

> Every observable **state transition** emits a `:telemetry` event — and nothing
> else logs it. A telemetry bridge funnels those into `LogStore`, which both
> **persists** them (ETS + SQLite) and **streams** them over WebSocket.

A transition is logged in exactly one place: its `emit_telemetry/2,3` call. The
emitter never also calls `LogStore.log` for the same moment — that was the old
duplication, now removed. `LogStore.log` is reserved for **diagnostics/IO that
have no transition event**: backend container ops, raw agent stdout, received
messages, config-load failures. Those are single-source, so they never double up
with the bridge.

The bridge derives the log `level` from the event name (see below). When the
level depends on the outcome (a partial swarm start, an unexpected agent exit),
the emitter passes `level:` in the telemetry metadata to set it explicitly; the
bridge strips that key before persisting, so it never leaks into the payload.

```
emit_telemetry(:agent_started, ...)            ← emitters (swarm_manager, agent_server, …)
        │  [:genswarm, :agent, :agent_started]
        ▼
Genswarm.Observability.TelemetryBridge          ← single :telemetry handler
        │  LogStore.log(:info, :agent, :agent_started, "agent fixer_1 started", …)
        ▼
Genswarm.Observability.LogStore
        ├── ETS ring buffer        → LogStore.query / GET /api/events (fast, in-node)
        ├── SQLite                 → cross-process / `swarm events` CLI
        └── PubSub {:log_event, e} → SwarmChannel "event" / "log_entry" push (live)
```

To make a new transition observable, **emit a telemetry event** under
`[:genswarm, <domain>, <event>]` and add it to
`Genswarm.Observability.TelemetryBridge` `known_events/0` (and the table below).
Nothing else — no controller, no broadcast, no LogStore call at the call site.

## Event taxonomy

`level` is derived from the event name (`*error*`/`*failed*` → `:error`,
`*invalid*`/`*not_found*`/`*full*` → `:warning`, otherwise `:info`).
`category` is the telemetry domain (`:router` is normalized to `:routing`).

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
| `object` | `object_started` | info | object handler initialized |
| `object` | `object_stopped` | info | object handler stopped |
| `object` | `object_error` | error | object handler crashed/errored |
| `object` | `object_added` | info | object added to a running swarm |
| `object` | `object_removed` | info | object removed from a running swarm |
| `routing` | `message_routed` | info | direct message routed (`:from`, `:to`) |
| `routing` | `message_delivered` | info | message delivered to target inbox |
| `routing` | `message_broadcast` | info | broadcast routed (`:from`) |
| `routing` | `invalid_route` | warning | message rejected by topology |

Every event carries `:swarm` in its metadata; agent/object events also carry
`:agent`/`:object` (lifted to dedicated columns by `LogStore`). Remaining
metadata is kept JSON-friendly in the event's `metadata` blob.

## Reading the stream

**Snapshot (current state)** — bootstrap a view, then follow the live stream:

| Endpoint | Returns |
|---|---|
| `GET /api/swarms/:name` | swarm status, agents, objects, counts |
| `GET /api/swarms/:name/topology` | topology adjacency |
| `GET /api/swarms/:name/objects` | objects + lifecycle state |
| `GET /api/swarms/:name/objects/:object_name` | one object's live domain state (generic introspection) |
| `GET /api/swarms/:name/agents/:agent_name` | one agent's status |

**History (what happened)** — backed by the spine above:

| Endpoint | Returns |
|---|---|
| `GET /api/events` | recent events, filterable by `level`/`category`/`event_type` |
| `GET /api/swarms/:name/events` | events for one swarm |
| `GET /api/swarms/:name/agents/:agent_name/events` | events for one agent |

**Live (WebSocket `swarm:<name>` channel)** — push messages:

| Push | Source |
|---|---|
| `event`, `log_entry` | `LogStore` (the whole taxonomy above, after `subscribe_events`/`subscribe_logs`) |
| `agent_output` | agent stdout |
| `agent_status` | agent state transition |
| `message_routed`, `message_broadcast` | router |
| `swarm_started`, `swarm_stopped` | swarm lifecycle |
| `agent_added`, `agent_removed`, `topology_changed` | dynamic mutations |

**CLI (`swarm events`)** — reads the spine too, no extra wiring:

```bash
swarm events                 # recent events across all swarms
swarm events -s my-swarm     # one swarm
swarm events --category routing   # filter by category (backend|routing|agent|object|swarm|system)
swarm events --errors        # errors only
swarm events --follow        # stream in real time
```

The CLI is a **cross-process** consumer: swarms run as separate daemon OS
processes, so the CLI can't read their in-node ETS. It reads the `events` table
in `.swarm/swarms.db` instead — which `LogStore` writes to on every `log/5` via
`persist_to_sqlite/7` → `SwarmRegistry.log_event`. Because the telemetry bridge
feeds `LogStore`, the daemon's full event taxonomy lands in that table
automatically, and `swarm events` surfaces it with **no CLI changes**. (The
`--category` values map 1:1 to the taxonomy above.)

This is the payoff of a single spine: feeding `LogStore` from the bridge improved
the CLI, the REST `/api/events` endpoints, and the WS stream at once — none of
them needed to be touched.

## Deployment topologies (one node vs. many daemons)

This matters because a BEAM's in-memory machinery (PubSub, the process `Registry`,
the ETS `LogStore`) is **node-local** — invisible from another OS process. Two
shapes:

**Co-located** — the swarm runs in the same BEAM as the Phoenix endpoint (e.g.
started in-process via `POST /api/swarms`). Live PubSub, the WS stream, and the
live snapshot endpoints all work directly. Nothing special needed.

**Monitor + daemons** — the usual shape at scale: each swarm runs as its own
daemon (`swarm start`, its own BEAM), and a separate monitor/API node observes
all of them. Here the only thing the processes share is the SQLite `events` table.
So observability crosses processes like this:

```
daemon swarm A ─┐  emit_telemetry → LogStore → SQLite events  ┐
daemon swarm B ─┤                                             ├─►  shared .swarm/swarms.db
daemon swarm C ─┘                                             ┘
                                                              │
                          monitor / API node ───── EventRelay polls `events_since` ──┐
                                                              │                       │
                          REST /api/events  ── reads SQLite ──┤                       ▼
                          WS swarm:<name>    ◄─ EventRelay re-broadcasts {:log_event} onto
                                                 the same LogStore PubSub topics → SwarmChannel push
```

- **`GET /api/events`** (and the swarm/agent variants) read SQLite, so they
  surface **every** swarm, daemon or in-process.
- **`Genswarm.Observability.EventRelay`** runs on the monitor node (started by
  `start_web_server/1`). It tails new SQLite rows every ~500ms and re-broadcasts
  them onto the in-node PubSub topics, so the existing `SwarmChannel` pushes them
  to WS clients live — **no clustering required**. Latency ≈ the poll interval
  (set `config :genswarm, :event_relay, false` to disable).
- A WS client gets recent history from the **snapshot on subscribe** (also read
  from SQLite) and the live tail from the relay.

> Run the relay only on a monitor node that does **not** host swarms in-process.
> There the in-node `LogStore` never broadcasts swarm events (they happen in the
> daemons), so the relay is the sole live source — no double-delivery.

### Still node-local (known limits)

- **Live process-state pulls** (`GET /objects/:name`, `/agents/:name`) call into
  the in-node `Registry`, so they only reach swarms in the **same** BEAM. For
  daemon swarms, rely on the event stream (and `GET /swarms/:name`, which has a
  SQLite fallback) instead of synchronous state pulls.
- **Object internal state** changes don't emit events (only object lifecycle
  does), so a live object-state feed isn't available — poll `GET /objects/:name`
  in a co-located setup, or have the object emit on change.
- Want true sub-second push or cross-host fan-out without polling? Swap
  `Phoenix.PubSub` to its **Redis adapter** — the single spine means only the
  transport changes, not the emitters, bridge, or channel.

## Scaling the store: the `EventStore` backend

The durable log sits behind one swappable interface,
`Genswarm.Observability.EventStore` (a behaviour + facade). Everything that
persists, reads, or tails events goes through it — `LogStore`, `EventRelay`, the
controllers, the channel and the CLI — never a concrete backend. Backend is
config:

```elixir
config :genswarm, :event_store, Genswarm.Observability.EventStore.Sqlite
```

The callbacks: `persist/1`, `query/1`, `events_since/2`, `max_event_id/0`, and an
optional `child_specs/0` (processes the backend needs supervised — the app splices
them into its tree at boot).

**Why this matters at scale.** The default `…EventStore.Sqlite` opens a
short-lived connection per write — fine at moderate load, but with, say, two
swarms of 500 agents the connect-per-write pattern and SQLite's single-writer lock
become the bottleneck (not the query volume). The fix is **not** just a different
engine; it's the write path. Because every caller already goes through the facade,
a new backend can add — transparently to callers:

- **Batching + pooling** — `persist/1` is fire-and-forget, so a backend may buffer
  writes and bulk-flush on a pooled connection. It declares its buffer/pool via
  `child_specs/0`.
- **Postgres** — Ecto/Postgrex pool, batched inserts, a time-partitioned table
  with retention. `LISTEN/NOTIFY` would let `EventRelay` drop polling for push.
- **Redis / streaming** — publish to Redis Streams / NATS for fan-out, with a
  relational sink for queryable history.

**Tiering, independent of backend.** At high agent counts, persisting every raw
stdout/conversation line into a relational table is questionable. Split by value:
keep structured transitions (lifecycle, routing, errors) in the queryable store;
send the high-volume firehose to a sampled / TTL'd / separate sink.

### When it saturates — a playbook

The default SQLite backend opens a short-lived connection **per write** and SQLite
allows **one writer at a time**. That is the ceiling. As a rough guide: LLM agents
emit modest event rates (model latency dominates), so ~1000 agents is typically a
few **thousand** events/sec at peak. Connect-per-write SQLite tops out around the
**hundreds–~1k writes/sec** before lock contention; batched SQLite does tens of
thousands/sec; pooled Postgres, more. So you will hit the wall via the *write
pattern*, not the engine — fix it in that order.

Work the steps top-down; each is independent and behind the `EventStore` facade,
so callers never change.

**Step 0 — Confirm it's the store.** Signals:

- `LogStore` mailbox backing up — `persist_durably/1` runs inside the `LogStore`
  cast, so a slow store grows its queue:
  `:erlang.process_info(Process.whereis(Genswarm.Observability.LogStore), :message_queue_len)`.
- `EventRelay` lag growing: `EventStore.max_event_id() - <relay last_id>` keeps
  climbing → the 500-row/500ms tail can't keep up.
- SQLite `database is locked` / 5s `busy_timeout` stalls in logs (multiple daemons
  contending on one file).
- `swarm events` / `/api/events` visibly lagging real time.

**Step 1 — Batch writes (biggest win, same engine).** Add a backend that buffers
and flushes in one transaction over a single held connection, instead of one
open-write-close per event. It's a process, declared via `child_specs/0`:

```elixir
# sketch — Genswarm.Observability.EventStore.SqliteBatched
@behaviour Genswarm.Observability.EventStore
def child_specs, do: [__MODULE__.Writer]          # a GenServer holding one conn
def persist(event), do: GenServer.cast(__MODULE__.Writer, {:enqueue, event})
def query(opts), do: SwarmRegistry.query_events(opts)        # reads unchanged
def events_since(id, n), do: SwarmRegistry.events_since(id, n)
def max_event_id, do: SwarmRegistry.max_event_id()
# Writer: accumulate casts, flush every ~100ms or N events in a BEGIN..COMMIT.
```

Then `config :genswarm, :event_store, …EventStore.SqliteBatched`. Nothing else
changes — `application.ex` starts the Writer from `child_specs/0`.

**Step 2 — Move to Postgres (pooled, partitioned).** When a single file / single
writer across multiple daemons is the limit, switch engines:

- `…EventStore.Postgres` over an Ecto/Postgrex **pool** (each node gets a pool;
  `child_specs/0` returns the Repo).
- **Batched multi-row inserts** (keep Step 1's buffer in front of the pool).
- A **time-partitioned** `events` table (e.g. daily partitions) + a retention job
  dropping old partitions — cheap pruning at volume.
- `config :genswarm, :event_store, …EventStore.Postgres`. Callers unchanged.

**Step 3 — Push instead of poll (retire the EventRelay loop).** With Postgres,
`NOTIFY` on insert and have the monitor `LISTEN` and re-broadcast to PubSub — drop
`EventRelay`'s polling entirely (no lag, no batch ceiling). With Redis, publish to
a Stream and subscribe. Either way only the *relay/transport* changes; the
`SwarmChannel` topics and pushes stay the same.

**Step 4 — Tier the firehose.** Stop writing raw stdout / conversation lines to the
queryable store: keep structured transitions there, route the high-volume stream
to a TTL'd table, object storage, or a log aggregator. This is the lever that
actually bounds growth — decide what *not* to store.

Order of impact: **Step 1 (batching) usually buys the most for the least work.**
Steps 2–3 are for multi-host / sub-second-push needs; Step 4 is for sustained
high volume regardless of engine.

## Building a dashboard

A dashboard is a **consumer**, not framework code (the project is API-first and
headless by design — no HTML ships here):

1. Bootstrap from the snapshot endpoints (status + topology + objects).
2. Open the `swarm:<name>` channel, `subscribe_events` for the taxonomy, and
   patch the view from the push stream.
3. Domain-specific concepts (e.g. user "sessions", conversation transcripts) live
   in the consumer and read from the consumer's own store — the framework stays
   generic and exposes only the generic object state via the introspection
   endpoint above.
