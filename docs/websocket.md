# WebSocket API

Genswarms exposes a Phoenix WebSocket alongside its [REST API](rest-api.md) for real-time, per-swarm communication: sending tasks, fetching status, and streaming logs and events as they happen.

The implementation lives in `lib/genswarms_web/channels/swarm_socket.ex` (the socket) and `lib/genswarms_web/channels/swarm_channel.ex` (the channel). This page is derived directly from those sources.

## Connection

- Socket mount path: `/swarm` (so the URL is typically `ws://localhost:4000/swarm/websocket`, port from `PORT`, default `4000`). Only the `websocket` transport is enabled; long polling is disabled (`longpoll: false` in `endpoint.ex`).
- Channel topic: `swarm:<swarm_name>` (the socket declares `channel "swarm:*"`).
- No authentication is performed on connect; `connect/3` accepts all clients and the socket has no per-connection id (`id/1` returns `nil`).
- Joining a topic verifies the swarm exists, checking the in-process `SwarmManager` first and falling back to the SQLite registry (`SwarmRegistry`). If it exists in neither, the join is rejected with `{"reason": "swarm_not_found"}`. On success the join reply is `{"swarm": "<swarm_name>"}`.

On join the channel subscribes to the swarm's internal PubSub topics (`swarm:<name>`, `:output`, `:routing`, `:status`) so that output, routing, status, and lifecycle messages are pushed to the client automatically — no extra subscribe call is needed for those. The log and event streams, by contrast, are opt-in via the `subscribe_logs` / `subscribe_events` events below.

## Inbound events (client → server)

Each of these is sent with `channel.push(event, payload)` and returns a reply.

| Event | Payload | Reply |
|-------|---------|-------|
| `send_task` | `{"agent": "...", "task": "..."}` | `ok` → `{"status": "sent"}`. `error` → `{"reason": "<inspected error>"}`. |
| `get_status` | ignored | `ok` → the swarm status map. `error` → `{"reason": "<inspected error>"}`. |
| `subscribe_logs` | `{"agent": "..."}`, or `{}` for all agents | `ok` → `{"subscribed": true, "agent": <agent-or-null>, "recent_logs": [...]}` (last 50, oldest first). |
| `unsubscribe_logs` | `{"agent": "..."}` or `{}` (must match the agent used to subscribe) | `ok` → `{"unsubscribed": true, "agent": <agent-or-null>}`. |
| `subscribe_events` | `{"filters": {"level": ..., "category": ..., "event_type": ...}}` (any subset; `{}` or omitted = no filtering) | `ok` → `{"subscribed": true, "filters": {...}, "recent_events": [...]}` (last 50, oldest first). |
| `unsubscribe_events` | ignored | `ok` → `{"unsubscribed": true}`. Clears **all** event subscriptions on the socket. |

Notes on the inbound events:

- `send_task` and `get_status` delegate to `SwarmManager`; on failure the reason is the Elixir term rendered with `inspect/1` (e.g. `":not_found"`), so treat it as an opaque diagnostic string, not a stable machine-readable code.
- `subscribe_logs` is keyed by agent: subscribing with `{"agent": "researcher"}` and then `{}` registers two independent subscriptions. `unsubscribe_logs` removes only the subscription whose `agent` matches (use `{}` to remove the all-agents subscription).
- `subscribe_events` accumulates filter sets: calling it twice adds a second subscription, and a `log_event` is pushed as `event` if it matches **any** registered filter set. `unsubscribe_events` discards every event subscription at once (it does not take an `agent`/`filters` argument).
- `recent_logs` / `recent_events` are returned synchronously in the reply, sourced from the durable `EventStore` (SQLite-backed by default). Because that store is shared across BEAM nodes, history from daemon swarms running in other processes is visible. The live stream then arrives as `log_entry` / `event` pushes.

## Outbound pushes (server → client)

Subscribe to these with `channel.on(event, callback)`. The lifecycle and output pushes start flowing on join; `log_entry` and `event` require an active subscription.

| Event | Payload | When |
|-------|---------|------|
| `agent_output` | `{"agent": ..., "content": ...}` | Raw agent output. |
| `message_routed` | routing data map | A directed message was routed between components. |
| `message_broadcast` | broadcast data map | A broadcast message (`@all:`) was routed. |
| `agent_status` | `{"agent": ..., "state": ...}` | An agent changed state. |
| `swarm_started` | `{"status": "<string>"}` | The swarm started (status is stringified). |
| `swarm_stopped` | `{}` | The swarm stopped. |
| `agent_added` | `{"name": ..., "spec": {...}}` | An agent was added at runtime; `spec` is the serialized agent spec. |
| `agent_removed` | `{"name": ...}` | An agent was removed at runtime. |
| `topology_changed` | `{}` | The topology was modified at runtime. |
| `log_entry` | see below | A streamed log line, pushed only while a matching `subscribe_logs` subscription is active. |
| `event` | see below | A streamed event, pushed only while a matching `subscribe_events` subscription is active. |

### Filtering semantics

- `log_entry` is pushed only while a `subscribe_logs` subscription is active **and** the event's agent matches. A `subscribe_logs` with no `agent` (`{}`) matches every agent.
- `event` is pushed only while a `subscribe_events` subscription is active **and** the event matches the subscribed `filters`. Each of `level`, `category`, and `event_type` present in the filter must equal the event's corresponding field (compared as atoms). An empty filter set (`{}`) matches every event.

### Payload shapes

A `log_entry` payload contains:

```json
{
  "id": "...",
  "timestamp": "2026-06-05T12:00:00Z",
  "level": "info",
  "agent": "researcher",
  "event_type": "agent_output",
  "message": "...",
  "metadata": {}
}
```

An `event` payload carries the same fields **plus** `category` and `swarm`:

```json
{
  "id": "...",
  "timestamp": "2026-06-05T12:00:00Z",
  "level": "info",
  "category": "routing",
  "swarm": "my-swarm",
  "agent": "researcher",
  "event_type": "message_routed",
  "message": "...",
  "metadata": {}
}
```

`timestamp` is rendered as an ISO 8601 string. The same field shapes are used for the `recent_logs` / `recent_events` entries returned by the subscribe replies.

## JavaScript example

Using the Phoenix JS client (`phoenix` npm package). Note that the client appends `/websocket` to the socket URL automatically, so pass `ws://localhost:4000/swarm`:

```javascript
import { Socket } from "phoenix"

const socket = new Socket("ws://localhost:4000/swarm")
socket.connect()

const channel = socket.channel("swarm:my-swarm", {})

channel.join()
  .receive("ok", resp => console.log("joined", resp))          // { swarm: "my-swarm" }
  .receive("error", resp => console.error("join failed", resp)) // { reason: "swarm_not_found" }

// Lifecycle/output pushes start automatically on join
channel.on("agent_output", o => console.log(o.agent, o.content))
channel.on("agent_status", s => console.log(s.agent, "→", s.state))

// Stream events (e.g. only errors); recent history comes back in the reply
channel.push("subscribe_events", { filters: { level: "error" } })
  .receive("ok", ({ recent_events }) => console.log("recent", recent_events))

channel.on("event", e => console.log("event", e))

// Send a task to an agent
channel.push("send_task", { agent: "researcher", task: "Summarize results." })
  .receive("ok", () => console.log("task sent"))
  .receive("error", ({ reason }) => console.error("send failed", reason))
```

## See also

- [rest-api.md](rest-api.md) — the JSON REST API on the same server.
- [observability.md](observability.md) — events, logs, and the `EventStore`.
- [cli.md](cli.md) — the `swarm` CLI, including `swarm logs` and `swarm events --follow`.
