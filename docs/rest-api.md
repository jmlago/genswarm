# REST API

Genswarms exposes a pure JSON REST API served by Phoenix (no HTML/frontend is included). The same server also hosts a WebSocket endpoint for real-time streaming — see [websocket.md](websocket.md).

All routes are defined in `lib/genswarms_web/router.ex` and implemented by the controllers in `lib/genswarms_web/controllers/`. This page documents every route, derived directly from those sources.

## Base URL and conventions

- Base URL: `http://localhost:4000` (the port is set by the `PORT` env var, default `4000`).
- The API pipeline accepts `application/json` only. Send request bodies as JSON and set `Content-Type: application/json`.
- CORS is enabled for all origins (`origins: "*"`, all headers and methods allowed) via Corsica, so browser-based frontends can call the API directly.
- Successful responses return a JSON object. Errors return a JSON object with an `error` (string) or `errors`/`valid` field and an appropriate HTTP status (`400`, `404`, `500`).
- Most endpoints work for both in-process swarms and daemon swarms; the controller falls back to the SQLite registry / Docker when a swarm runs in a separate OS process.

## API info

| Method | Path | Description |
|--------|------|-------------|
| GET | / | API metadata: name, version, endpoint index, and a WebSocket/route summary |

The root returns a static descriptor including `name`, `version`, an `endpoints` map, a `websocket` section, and a `documentation` map summarizing the main route groups.

## Swarm management

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms | List all swarms |
| POST | /api/swarms | Create a swarm from an inline config or a config path |
| GET | /api/swarms/:name | Get detailed swarm status |
| DELETE | /api/swarms/:name | Stop a swarm (`?purge=true` to delete all data) |
| POST | /api/swarms/:name/pause | Pause (freeze) all of the swarm's containers |
| POST | /api/swarms/:name/resume | Resume a paused swarm |
| POST | /api/swarms/:name/restart | Restart the swarm (`?delete=true` for a clean slate) |
| POST | /api/swarms/:name/message | Route a message between two agents |
| POST | /api/swarms/clean | Remove stopped/crashed swarms (`?all=true` also clears all events) |

Notes:

- `POST /api/swarms` accepts either `{"config": { ... }}` (an inline swarm config object) or `{"config_path": "path/to/config.exs"}`. On success it returns `201 Created` with `{"status": "created", "swarm_name": "..."}`. Missing both fields returns `400`.
- `GET /api/swarms/:name` enriches the status with `topology`, per-agent `backend_type`, `skills_paths`, `container_name`, `container_status`, per-object `handler_module`/`source_file`, and a `file_paths` map (`config`, `data_dir`, `log`). Returns `404` if the swarm is unknown.
- `DELETE /api/swarms/:name` returns `{"status": "stopped"|"purged", ...}`. With `?purge=true` it also deletes swarm files and registry rows.
- `POST .../pause` and `.../resume` return a count: `{"status": "paused", "containers_paused": N}` / `{"status": "resumed", "containers_resumed": N}`.
- `POST .../restart` reads the saved config path from the registry; `?delete=true` deletes data before restarting. Returns `{"status": "restarted", "swarm_name": "...", "delete_data": bool}`.
- `POST /api/swarms/:name/message` requires `{"from": "...", "to": "...", "content": "..."}` and returns `{"status": "routed", "from", "to", "swarm"}`. Missing fields return `400`.
- `POST /api/swarms/clean` returns `{"status": "cleaned", "swarms_removed": N, "events_cleared": bool}`.

## Agent operations

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/agents | List agents and their status |
| GET | /api/swarms/:name/agents/:agent | Get a single agent's status |
| POST | /api/swarms/:name/agents/:agent/task | Send a task to an agent |
| POST | /api/swarms/:name/agents/:agent/restart | Restart an agent |
| GET | /api/swarms/:name/agents/:agent/history | Get the agent's message history (`?limit=`, default 100) |
| GET | /api/swarms/:name/agents/:agent/logs | Get the agent's conversation logs |
| GET | /api/swarms/:name/agents/:agent/skills | Get the agent's skill contents |
| PUT | /api/swarms/:name/agents/:agent/skills/:skill | Update one of the agent's skill files |

Notes:

- `POST .../task` requires `{"task": "..."}` and returns `{"status": "sent", "agent", "task"}`. For daemon swarms the task is queued in SQLite for the daemon to pick up. Missing `task` returns `400`.
- `GET .../agents` returns `{"agents": [ ... ]}`; `GET .../agents/:agent` returns the status map directly (or `404`).
- `GET .../history` and `GET .../logs` return `{"history": [...]}` / `{"logs": [...]}`. `GET .../skills` returns `{"skills": ...}`. A missing agent returns `404`.
- `PUT .../skills/:skill` requires `{"content": "..."}` and returns `{"status": "updated", "skill": "..."}`.

> Adding and removing agents at runtime uses `POST /api/swarms/:name/agents` and `DELETE /api/swarms/:name/agents/:agent` — see [Dynamic topology and scaling](#dynamic-topology-and-scaling) below.

## Dynamic topology and scaling

These endpoints mutate a running swarm and persist the change as an overlay (see [Overlay and snapshot](#overlay-and-snapshot)).

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/topology | Get the swarm's topology (adjacency list) |
| PATCH | /api/swarms/:name/topology | Add and/or remove topology edges |
| POST | /api/swarms/:name/agents | Add a new agent to a running swarm |
| DELETE | /api/swarms/:name/agents/:agent | Remove an agent from a running swarm |
| POST | /api/swarms/:name/agents/:base/scale | Scale an agent group to a target count |

Notes:

- `GET .../topology` returns `{"topology": [{"from": ..., "targets": [...]}, ...]}` or `404` for an unknown swarm.
- `PATCH .../topology` accepts `{"add": [...], "remove": [...]}`. Each edge may be `["from", "to"]` or `{"from": "...", "to": "..."}`. Returns `{"status": "ok", "added": N, "removed": M}`.
- `POST .../agents` accepts an agent spec (`name`, `backend`, `skills`, `model`, `endpoint`, `presets`, `config`) plus optional `connections` (outgoing targets) and `incoming` (sources). `backend` may be a string (e.g. `"local"`, `"mock"`) or an object such as `{"type": "docker", "image": "coder"}`, `{"type": "ssh", "host": "user@host"}`, or `{"type": "bwrap", "opts": { ... }}`. Returns `201 Created` with `{"status": "added", "name": "..."}`.
- `DELETE .../agents/:agent` returns `{"status": "removed", "name": "..."}` or `404`.
- `POST .../agents/:base/scale` requires an integer `{"count": N}` (`count >= 0`) and returns `{"status": "ok", "result": {"added": [...], "removed": [...], "failed": [{"name", "reason"}]}}`. A missing/invalid `count` returns `400`.

## Objects

Objects are the non-agentic components of a swarm. See [objects.md](objects.md).

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/objects | List objects with their lifecycle state |
| POST | /api/swarms/:name/objects | Add an object to a running swarm |
| GET | /api/swarms/:name/objects/:object | Get an object's live read-only state |
| DELETE | /api/swarms/:name/objects/:object | Remove an object from a running swarm |

Notes:

- `GET .../objects` returns `{"objects": [{"name", "state", "handler"}, ...]}`.
- `POST .../objects` accepts an object spec (`name`, `handler` module name, `backend`, `config`) plus optional `connections`/`incoming`. Returns `201 Created` with `{"status": "added", "name": "..."}`.
- `GET .../objects/:object` returns `{"object": "...", "state": <handler domain state>}`. The framework imposes no schema on the state. An unknown object returns `404`.
- `DELETE .../objects/:object` returns `{"status": "removed", "name": "..."}` or `404`.

## Overlay and snapshot

A swarm's effective config is its seed config combined with an overlay of runtime mutations (added/removed agents, topology edits, scaling).

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/overlay | Show the recorded overlay events |
| DELETE | /api/swarms/:name/overlay | Clear the overlay |
| POST | /api/swarms/:name/snapshot | Return the effective config (seed ⊕ overlay) as Elixir source |

Notes:

- `GET .../overlay` returns `{"swarm": "...", "events": [{"op": ..., "payload": ...}, ...]}`.
- `DELETE .../overlay` returns `{"status": "cleared", "swarm": "..."}`.
- `POST .../snapshot` responds with `Content-Type: text/x-elixir` and the effective config rendered as a `.exs` source body (not JSON). Returns `404` if the swarm is unknown.

## Events

Event queries read from the durable, cross-process `EventStore` (SQLite by default), so events from daemon swarms in other BEAM nodes are visible. See [observability.md](observability.md).

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/events | Query events with filters |
| GET | /api/swarms/:name/events | Query events for one swarm |
| GET | /api/swarms/:name/agents/:agent/events | Query events for one agent |

Shared query params (all optional):

| Param | Description |
|-------|-------------|
| level | `error`, `warning`, `info`, or `debug` |
| category | `backend`, `routing`, `agent`, `swarm`, or `system` |
| swarm | Swarm name (implied on the scoped routes) |
| agent | Agent name (implied on the agent route) |
| event_type | A specific event type |
| minutes | Only events from the last N minutes |
| limit | Max events to return (default 100) |

Each response includes `events` (a list) and `count`. Every event is `{id, timestamp, level, category, swarm, agent, event_type, message, metadata}`; timestamps are ISO-8601 strings.

## Skills

See [skills.md](skills.md).

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/skills | List available skill files (`?path=` overrides the search root) |
| GET | /api/skills/:name | Get a skill's content by name |

Notes:

- `GET /api/skills` searches `priv/skills` recursively by default and returns `{"skills": [{"name", "path", "relative_path", "category"}, ...], "base_path", "count"}`.
- `GET /api/skills/:name` returns `{"name", "path", "content", "size"}`, or `404` if the skill is not found. The `.md` extension is optional in the name.

## Config validation

See [configuration.md](configuration.md).

| Method | Path | Description |
|--------|------|-------------|
| POST | /api/config/validate | Validate a swarm config |

`POST /api/config/validate` accepts one of:

- `{"config": { ... }}` — an inline config object.
- `{"config_path": "path/to/config.exs"}` — a `.exs`, `.json`, or `.yaml` file path.
- `{"content": "...", "format": "exs"|"json"|"yaml"}` — a raw config string.

On success it returns `{"valid": true, "config": <summary>}` where the summary includes `name`, `agent_count`, `object_count`, `topology_edges`, and per-agent/object/topology details. On failure it returns `400` with `{"valid": false, "errors": [...]}`. Sending none of the accepted fields returns `400` with a `usage` map.

## Examples

List all swarms:

```bash
curl http://localhost:4000/api/swarms
```

Create a swarm from a config file on the server:

```bash
curl -X POST http://localhost:4000/api/swarms \
  -H "Content-Type: application/json" \
  -d '{"config_path": "examples/research.exs"}'
```

Send a task to an agent:

```bash
curl -X POST http://localhost:4000/api/swarms/my-swarm/agents/researcher/task \
  -H "Content-Type: application/json" \
  -d '{"task": "Summarize the latest results."}'
```

## See also

- [cli.md](cli.md) — the `swarm` CLI, which wraps many of these endpoints.
- [websocket.md](websocket.md) — real-time streaming over the WebSocket channel.
- [programmatic.md](programmatic.md) — driving swarms directly from Elixir.
- [configuration.md](configuration.md) — the swarm config DSL used by create/validate.
