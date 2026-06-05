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
