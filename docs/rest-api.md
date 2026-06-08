---
description: The GenSwarms REST API — create and control swarms, send tasks, manage agents and topology, and query events over JSON HTTP.
---

# REST API

GenSwarms exposes a pure JSON REST API served by Phoenix (no HTML/frontend is included). The same server also hosts a WebSocket endpoint for real-time streaming — see [websocket.md](websocket.md).

All routes are defined in `lib/genswarms_web/router.ex` and implemented by the controllers in `lib/genswarms_web/controllers/`. This page documents every route, derived directly from those sources.

## Base URL and conventions

- Base URL: `http://localhost:4000` (the port is set by the `PORT` env var, default `4000`).
- The API pipeline accepts `application/json` only. Send request bodies as JSON and set `Content-Type: application/json`.
- **Authentication:** when `GENSWARMS_API_TOKEN` is set, every request must send `Authorization: Bearer <token>`; when unset, only loopback callers are accepted. The CLI attaches the token automatically. See [Security](security.md).
- CORS is restricted to an allowlist (`GENSWARMS_CORS_ORIGINS`, default local dev origins) via Corsica — see [Security](security.md#cors).
- Successful responses return a JSON object. Errors return a JSON object with an `error` (string) or `errors`/`valid` field and an appropriate HTTP status (`400`, `404`, `500`).
- Most endpoints work for both in-process swarms and daemon swarms; the controller falls back to the SQLite registry / Docker when a swarm runs in a separate OS process.

## API info

| Method | Path | Description |
|--------|------|-------------|
| GET | / | API metadata: name, version, endpoint index, and a WebSocket/route summary |

The root returns a static descriptor including `name`, `version` (`"1.0.0"`), `description`, an `endpoints` map, a `websocket` section, and a `documentation` map summarizing the main route groups. The `websocket` section advertises the channel URL (`/swarm`), the channel topic pattern (`swarm:{swarm_name}`), and the client→server / server→client event lists (see [websocket.md](websocket.md) for details).

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

- `GET /api/swarms` returns `{"swarms": [ ... ]}`.
- `POST /api/swarms` accepts either `{"config": { ... }}` (an inline swarm config object) or `{"config_path": "path/to/config.exs"}`. On success it returns `201 Created` with `{"status": "created", "swarm_name": "..."}`. On a config/start error it returns `400` with `{"error": "..."}`. Missing both fields returns `400` with `{"error": "Missing 'config' or 'config_path' parameter"}`.
- `GET /api/swarms/:name` enriches the status with `topology`, per-agent `backend_type`, `skills_paths`, `container_name`, `container_status`, per-object `handler_module`/`source_file`, and a `file_paths` map (`config`, `data_dir` = `~/.subzeroclaw/swarms/<name>`, `log` = `.genswarms/logs/<name>.log`). Returns `404` with `{"error": "Swarm not found"}` if the swarm is unknown.
- `DELETE /api/swarms/:name` returns `{"status": "stopped"|"purged", "swarm_name": "...", "config_path": ...}`. With `?purge=true` it also deletes swarm files and registry rows. Returns `404` for an unknown swarm.
- `POST .../pause` and `.../resume` return a count: `{"status": "paused", "swarm_name": "...", "containers_paused": N}` / `{"status": "resumed", "swarm_name": "...", "containers_resumed": N}`. A `404` is returned for an unknown swarm; a backend failure returns `500`.
- `POST .../restart` reads the saved config path from the registry; `?delete=true` deletes data before restarting. Returns `{"status": "restarted", "swarm_name": "...", "delete_data": bool}`. Returns `404` if the swarm (or its config path) is unknown.
- `POST /api/swarms/:name/message` requires `{"from": "...", "to": "...", "content": "..."}` and returns `{"status": "routed", "from", "to", "swarm"}`. Missing fields return `400` with `{"error": "Missing 'from', 'to', or 'content' parameter"}`.
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

- `POST .../task` requires `{"task": "..."}` and returns `{"status": "sent", "agent", "task"}`. For daemon swarms the task is queued in SQLite for the daemon to pick up. Missing `task` returns `400` with `{"error": "Missing 'task' parameter"}`.
- `GET .../agents` returns `{"agents": [ ... ]}`; `GET .../agents/:agent` returns the status map directly, or `404` with `{"error": "Agent not found"}`.
- `POST .../agents/:agent/restart` returns `{"status": "restarted", "agent": "..."}`, `404` if the swarm is unknown, or `500` on failure.
- `GET .../history` and `GET .../logs` return `{"history": [...]}` / `{"logs": [...]}`. `GET .../skills` returns `{"skills": ...}`. A missing agent returns `404`.
- `PUT .../skills/:skill` requires `{"content": "..."}` and returns `{"status": "updated", "skill": "..."}`. A failure returns `500`.

> Adding and removing agents at runtime uses `POST /api/swarms/:name/agents` and `DELETE /api/swarms/:name/agents/:agent` — see [Dynamic topology and scaling](#dynamic-topology-and-scaling) below.

## Messages

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/messages | Get the swarm's recent inter-agent message log |

Notes:

- `GET /api/swarms/:name/messages` returns `{"messages": [ ... ]}` from the router's message log. Accepts `?limit=` (default 100). This is the routed-message history (who sent what to whom); for structured observability events use the [Events](#events) endpoints instead.

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
- `PATCH .../topology` accepts `{"add": [...], "remove": [...]}`. Each edge may be `["from", "to"]` or `{"from": "...", "to": "..."}`; both endpoints of an edge must be strings, and any edge that doesn't parse is silently ignored. Returns `{"status": "ok", "added": N, "removed": M}` (the counts reflect the parsed edges actually applied). A mutation error returns `400`.
- `POST .../agents` accepts an agent spec (`name`, `backend`, `skills`, `model`, `endpoint`, `presets`, `config`) plus optional `connections` (outgoing targets) and `incoming` (sources). `backend` may be a string (e.g. `"local"`, `"mock"`) or an object: `{"type": "docker", "image": "coder"}`, `{"type": "ssh", "host": "user@host"}`, `{"type": "bwrap", "opts": { ... }}`, or `{"type": "mock"}`. Returns `201 Created` with `{"status": "added", "name": "..."}`, or `400` with `{"error": "..."}` on failure.
- `DELETE .../agents/:agent` returns `{"status": "removed", "name": "..."}` or `404` with `{"error": "..."}`.
- `POST .../agents/:base/scale` requires an integer `{"count": N}` (`count >= 0`) and returns `{"status": "ok", "result": {"added": [...], "removed": [...], "failed": [{"name", "reason"}]}}` (the `added`/`removed`/`failed[].name` values are strings). A missing/non-integer/negative `count` returns `400` with `{"error": "Missing or invalid 'count'"}`; a scaling error returns `400` with `{"error": "..."}`.

## Objects

Objects are the non-agentic components of a swarm. See [objects.md](objects.md).

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/objects | List objects with their lifecycle state |
| POST | /api/swarms/:name/objects | Add an object to a running swarm |
| GET | /api/swarms/:name/objects/:object | Get an object's live read-only state |
| DELETE | /api/swarms/:name/objects/:object | Remove an object from a running swarm |

Notes:

- `GET .../objects` returns `{"objects": [{"name", "state", "handler"}, ...]}`, where `name` is a string and `handler` is the inspected handler module (or `null`).
- `POST .../objects` accepts an object spec (`name`, `handler` module name, `backend`, `config`) plus optional `connections`/`incoming`. Returns `201 Created` with `{"status": "added", "name": "..."}`, or `400` with `{"error": "..."}` on failure.
- `GET .../objects/:object` returns `{"object": "...", "state": <handler domain state>}`. The framework imposes no schema on the state. An unknown object returns `404` with `{"error": "Object not found"}`.
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
- `POST .../snapshot` responds with `Content-Type: text/x-elixir` and `200`, with the effective config rendered as a `.exs` source body (not JSON; produced by `Genswarms.Config.ExsWriter`). Returns `404` with a JSON `{"error": "..."}` if the swarm is unknown.

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
| category | `backend`, `routing`, `agent`, `swarm`, or `system` (see note) |
| swarm | Swarm name (implied on the scoped routes) |
| agent | Agent name (implied on the agent route) |
| event_type | A specific event type |
| minutes | Only events from the last N minutes |
| limit | Max events to return (default 100) |

Each response includes `events` (a list) and `count`. `GET /api/events` also echoes the normalized filters as a `query` map; the scoped routes echo `swarm` (and `agent` on the agent route). Every event is `{id, timestamp, level, category, swarm, agent, event_type, message, metadata}`; timestamps are ISO-8601 strings.

> Note: `category` is resolved with `String.to_existing_atom/1`, so only category names that already exist as atoms in the running system are accepted. The controller's documented set is `backend, routing, agent, swarm, system`, but the broader observability taxonomy and the CLI also emit an `object` category — passing `category=object` works as long as that atom has been created (e.g. after any object event has been logged). See [observability.md](observability.md) for the full taxonomy.

## Skills

See [skills.md](skills.md).

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/skills | List available skill files (`?path=` overrides the search root) |
| GET | /api/skills/:name | Get a skill's content by name |

Notes:

- `GET /api/skills` searches the configured skills directory (the `:genswarms`/`:skills_dir` app env, default `priv/skills`, expanded to an absolute path) recursively and returns `{"skills": [{"name", "path", "relative_path", "category"}, ...], "base_path", "count"}`. `category` is the relative subdirectory (or `"default"` for files at the root). Pass `?path=` to search a different root.
- `GET /api/skills/:name` returns `{"name", "path", "content", "size"}` (`size` is the byte length), or `404` with `{"error": "Skill not found"}` if the skill is not found. The `.md` extension is optional in the name, and nested skills are matched by a recursive search.

## Config validation

See [configuration.md](configuration.md).

| Method | Path | Description |
|--------|------|-------------|
| POST | /api/config/validate | Validate a swarm config |

`POST /api/config/validate` accepts one of:

- `{"config": { ... }}` — an inline config object (must be a JSON object).
- `{"config_path": "path/to/config.exs"}` — a `.exs`, `.json`, or `.yaml` file path.
- `{"content": "...", "format": "exs"|"json"|"yaml"}` — a raw config string (`"yml"` is accepted as an alias for `yaml`; an unrecognized format falls back to `exs`).

On success it returns `{"valid": true, "config": <summary>}` (the `config_path` / `format` form also echoes that input field) where the summary includes `name`, `agent_count`, `object_count`, `topology_edges`, and per-agent (`name`, `backend`, `skills`, `model`), per-object (`name`, `handler`), and `topology` (`from`/`to`) details. On a validation failure it returns `400` with `{"valid": false, "errors": [...]}`. A non-existent `config_path` returns `404` with `{"valid": false, "errors": ["File not found: ..."]}`. Sending none of the accepted fields returns `400` with `{"error": "...", "usage": { ... }}`.

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

Add an agent to a running swarm and wire it into the topology:

```bash
curl -X POST http://localhost:4000/api/swarms/my-swarm/agents \
  -H "Content-Type: application/json" \
  -d '{"name": "reviewer", "backend": {"type": "docker", "image": "code"}, "incoming": ["coder"]}'
```

Snapshot the effective (seed ⊕ overlay) config as runnable Elixir:

```bash
curl -X POST http://localhost:4000/api/swarms/my-swarm/snapshot -o my-swarm.exs
```

## See also

- [cli.md](cli.md) — the `swarm` CLI, which wraps many of these endpoints.
- [websocket.md](websocket.md) — real-time streaming over the WebSocket channel.
- [programmatic.md](programmatic.md) — driving swarms directly from Elixir.
- [configuration.md](configuration.md) — the swarm config DSL used by create/validate.
- [observability.md](observability.md) — the event categories and levels surfaced by the Events endpoints.
