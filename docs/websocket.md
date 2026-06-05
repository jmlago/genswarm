# WebSocket API

Genswarms exposes a Phoenix WebSocket alongside its [REST API](rest-api.md) for real-time, per-swarm communication: sending tasks, fetching status, and streaming logs and events as they happen.

The implementation lives in `lib/genswarms_web/channels/swarm_socket.ex` (the socket) and `lib/genswarms_web/channels/swarm_channel.ex` (the channel). This page is derived directly from those sources.

## Connection

- Socket mount path: `/swarm` (so the URL is typically `ws://localhost:4000/swarm/websocket`, port from `PORT`, default `4000`).
- Channel topic: `swarm:<swarm_name>` (the socket declares `channel "swarm:*"`).
- No authentication is performed on connect; `connect/3` accepts all clients and the socket has no per-connection id.
- Joining a topic verifies the swarm exists (checking both the in-process `SwarmManager` and the SQLite registry). If it does not exist, the join is rejected with `{"reason": "swarm_not_found"}`. On success the join reply is `{"swarm": "<swarm_name>"}`.

On join the channel subscribes to the swarm's internal PubSub topics so that output, routing, status, and lifecycle messages are pushed to the client automatically. Log and event streams are opt-in via the subscribe events below.

## Events

| Event | Direction | Description |
|-------|-----------|-------------|
| send_task | client → server | Send a task to an agent. Payload `{"agent": "...", "task": "..."}`. Reply `{"status": "sent"}` or an error. |
| get_status | client → server | Get the swarm status. Reply is the status map or an error. |
| subscribe_logs | client → server | Subscribe to the log stream. Payload `{"agent": "..."}` (or `{}` for all agents). Reply includes `subscribed`, `agent`, and `recent_logs` (last 50). |
| unsubscribe_logs | client → server | Stop the log subscription. Payload `{"agent": "..."}` or `{}`. Reply `{"unsubscribed": true, "agent": ...}`. |
| subscribe_events | client → server | Subscribe to the event stream. Payload `{"filters": {"level": ..., "category": ..., "event_type": ...}}`. Reply includes `subscribed`, `filters`, and `recent_events` (last 50). |
| unsubscribe_events | client → server | Stop the event subscription. Reply `{"unsubscribed": true}`. |
| agent_output | server → client | Raw agent output: `{"agent": ..., "content": ...}`. |
| message_routed | server → client | A directed message was routed between components. |
| message_broadcast | server → client | A broadcast message was routed. |
| agent_status | server → client | An agent changed state: `{"agent": ..., "state": ...}`. |
| swarm_started | server → client | The swarm started: `{"status": ...}`. |
| swarm_stopped | server → client | The swarm stopped. |
| agent_added | server → client | An agent was added at runtime: `{"name": ..., "spec": {...}}`. |
| agent_removed | server → client | An agent was removed at runtime: `{"name": ...}`. |
| topology_changed | server → client | The topology was modified at runtime. |
| log_entry | server → client | A streamed log line (only for matching `subscribe_logs` filters). |
| event | server → client | A streamed event (only for matching `subscribe_events` filters). |

Notes:

- `log_entry` is pushed only while a `subscribe_logs` subscription is active and the event's agent matches (a `subscribe_logs` with no `agent` matches all agents).
- `event` is pushed only while a `subscribe_events` subscription is active and the event matches the subscribed `filters` (`level`, `category`, `event_type`).
- `subscribe_logs`/`subscribe_events` return recent history immediately in their reply (`recent_logs` / `recent_events`, up to 50 entries) from the durable `EventStore`, so daemon swarms in other BEAM nodes are visible; the live stream then arrives as `log_entry` / `event` pushes.
- A `log_entry` payload is `{id, timestamp, level, agent, event_type, message, metadata}`. An `event` payload additionally includes `category` and `swarm`.

## JavaScript example

Using the Phoenix JS client (`phoenix` npm package):

```javascript
import { Socket } from "phoenix"

const socket = new Socket("ws://localhost:4000/swarm")
socket.connect()

const channel = socket.channel("swarm:my-swarm", {})

channel.join()
  .receive("ok", resp => console.log("joined", resp))
  .receive("error", resp => console.error("join failed", resp))

// Stream events (e.g. only errors)
channel.push("subscribe_events", { filters: { level: "error" } })
  .receive("ok", ({ recent_events }) => console.log("recent", recent_events))

channel.on("event", e => console.log("event", e))
channel.on("agent_output", o => console.log(o.agent, o.content))

// Send a task to an agent
channel.push("send_task", { agent: "researcher", task: "Summarize results." })
  .receive("ok", () => console.log("task sent"))
```

## See also

- [rest-api.md](rest-api.md) — the JSON REST API on the same server.
- [observability.md](observability.md) — events, logs, and the `EventStore`.
- [cli.md](cli.md) — the `swarm` CLI, including `swarm logs` and `swarm events --follow`.
