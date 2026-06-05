# Architecture

Genswarms is an Elixir/OTP application that orchestrates swarms of subzeroclaw agents. This document describes the supervision tree, the per-swarm processes, the API-first design, the daemon model, and the supported deployment topologies.

## Overview

The OTP application (`:genswarms`, root module `Genswarms`) starts a single top-level supervisor (`Genswarms.Supervisor`, strategy `:one_for_one`) with a flat set of long-lived children. Swarms, agents, and objects are not separate static branches of the tree — they are started dynamically at runtime under shared application-level singletons, all keyed by swarm name.

A key consequence: there is **one** registry and **one** dynamic supervisor for the whole node. Agents and objects from every swarm coexist under them, distinguished by a `{swarm_name, name}` key.

## Supervision tree

The children below are started by `lib/genswarms/application.ex` in this order. The Phoenix endpoint is **not** part of the static tree — it is added dynamically (see [API-first design](#api-first-design)).

```text
Genswarms.Supervisor (one_for_one)
├── Genswarms.Telemetry                         (telemetry supervisor)
├── Phoenix.PubSub (name: Genswarms.PubSub)     (message broadcasting)
├── Genswarms.Observability.LogStore            (centralized event logging)
├── Genswarms.Backends.Bwrap.AgentTelemetry     (ETS ring buffer, 10k+ scale)
├── Registry (name: Genswarms.AgentRegistry)    (unique-key process lookup)
├── Genswarms.Skills.SkillsManager              (ETS-backed skill files)
├── Genswarms.Routing.Router                    (inter-agent message routing)
├── DynamicSupervisor (name: Genswarms.AgentSupervisor, one_for_one)
│       │   (shared by ALL agents AND objects, across all swarms)
│       ├── AgentServer {swarm, agent}  ── Backend + LogWatcher
│       ├── AgentServer {swarm, agent}  ── Backend + LogWatcher
│       └── ObjectServer {swarm, object}
├── Genswarms.SwarmManager                      (swarm lifecycle GenServer)
└── (EventStore.child_specs/0)                  (backend-dependent; none for
                                                 the default stateless SQLite)
```

After the tree is up, `Genswarms.Observability.TelemetryBridge.attach/0` wires the telemetry event stream into `LogStore` so events are durable, queryable, and streamable over WebSocket.

### How the real tree differs from the README diagram

The diagrams in `README.md` and `CLAUDE.md` are conceptual and do not match the actual process layout. Notable differences, verified against `application.ex`:

| README/CLAUDE diagram says | Actual tree |
|----------------------------|-------------|
| `Registry`, `Router`, `SkillsManager`, `AgentDynSup` are children of `SwarmManager` | They are direct children of the top-level `Genswarms.Supervisor`, siblings of `SwarmManager` |
| Each swarm has its own supervisor subtree | One shared `Genswarms.AgentSupervisor` and one shared `Genswarms.AgentRegistry` serve all swarms |
| Agents and objects have separate supervisors | Objects run under the **same** `Genswarms.AgentSupervisor` as agents (see `objects/object_supervisor.ex`) |
| `SwarmRegistry (SQLite)` is a child of the tree | `SwarmRegistry` is a stateless SQLite helper module, not a supervised process |
| Phoenix is a static child | Phoenix endpoint is started dynamically, not part of the static tree |

## Per-swarm processes

`Genswarms.SwarmManager` is the lifecycle GenServer. It loads configs, tracks per-swarm status (`:starting | :running | :stopping | :stopped | :error`), and starts agents and objects via thin helper modules that delegate to the shared dynamic supervisor.

```text
SwarmManager (single GenServer, tracks swarms: %{name => info})
   │  starts/stops children on the shared supervisor
   ▼
Genswarms.AgentSupervisor (DynamicSupervisor)
   ├── AgentServer  (per agent, registered as {swarm_name, agent_name})
   │      ├── Backend     (Local Port | Docker | SSH | Bwrap | Mock)
   │      └── LogWatcher  (polls logs + .outbox/ for message routing)
   └── ObjectServer (per object, registered as {swarm_name, object_name})
```

- **`Genswarms.Agents.AgentSupervisor`** and **`Genswarms.Objects.ObjectSupervisor`** are not GenServers; they are helper modules whose `start_*`/`stop_*`/`list_*` functions call `DynamicSupervisor.start_child/2` against the shared `Genswarms.AgentSupervisor` and look up processes in `Genswarms.AgentRegistry`.
- **`AgentServer`** (`lib/genswarms/agents/agent_server.ex`) is a GenServer per agent. On init it starts the configured backend and links a `Genswarms.Agents.LogWatcher`, which polls the agent's logs and `.outbox/` directory and routes outgoing messages through the `Router`.
- **`ObjectServer`** wraps a module implementing the `ObjectHandler` behaviour; objects participate in the same topology as agents but execute deterministic Elixir instead of LLM calls.
- **`Router`** validates and routes inter-agent messages according to the swarm's topology adjacency map. The system objects `:metrics`, `:tick`, and `:gateway` are always routable without explicit topology edges.

## API-first design

The Phoenix layer exposes a pure JSON REST API plus a WebSocket channel for real-time events. No HTML or bundled frontend is shipped — bring your own client (React, Vue, etc.) or use the CLI. CORS is enabled.

The endpoint is optional and lifecycle-managed at runtime rather than supervised statically:

- `Genswarms.Application.start_web_server/1` adds `GenswarmsWeb.Endpoint` as a dynamic child of `Genswarms.Supervisor` (default port `4000`, overridable via `PORT`).
- When the web server starts on the monitor/API node, it also starts `Genswarms.Observability.EventRelay`, which tails the shared SQLite event log and re-broadcasts new events to WebSocket clients — so the API node can stream events produced by daemon swarms running in other BEAM instances.
- `stop_web_server/0` terminates the relay and the endpoint.

```text
External client (React, Vue, CLI)        Genswarms API node (Phoenix)
        │                                        │
        ├── HTTP  ──────────────────────────────►├── REST API  (/api/*)
        ├── WS    ──────────────────────────────►├── WebSocket (swarm:* channel)
        │                                        ├── EventRelay (tails SQLite log)
        │                                        └── SwarmRegistry (SQLite reads/writes)
```

See `docs/rest-api.md` and `docs/observability.md` for the API surface and event model.

## Daemon model

Swarms run as **independent OS processes** (daemons), separate from the API node. This isolates a swarm's BEAM from the API server and from other swarms, and lets the CLI manage swarms without a running dashboard.

### Starting a daemon

`genswarms start <config>` (mix task `Mix.Tasks.Genswarms.Start`) does not run the swarm in its own process. It:

1. Initializes the SQLite registry (`SwarmRegistry.init/0`).
2. Spawns a detached background process via `nohup mix genswarms.start.daemon "<config>" > .genswarms/logs/<swarm>.log 2>&1 & echo $!`, capturing the child PID.
3. Waits briefly and confirms the daemon is alive.

The inner `mix genswarms.start.daemon` task (`Mix.Tasks.Genswarms.Start.Daemon`) is the actual long-running process: it starts the `:genswarms` application, starts the swarm, registers itself in SQLite, then enters a poll loop. (Use `genswarms start <config> --foreground` to run in the current process instead.)

### Coordination via SQLite

The API node and CLI never talk to a daemon's BEAM directly. They coordinate through a shared SQLite database at `.genswarms/swarms.db` (managed by `Genswarms.CLI.SwarmRegistry`).

```text
API node / CLI                         Daemon process (genswarms start)
   │                                          │
   ├── query swarm state ──┐        ┌── write swarm state (running/…)
   ├── queue tasks ────────┤ SQLite │── poll tasks every 500ms
   └── queue commands ─────┘ swarms │── poll commands every 500ms
                            .db ─────┘── log events
```

Tables in `.genswarms/swarms.db`:

| Table | Purpose |
|-------|---------|
| `swarms` | Daemon swarm state: `name`, `status` (running/stopped/crashed), `pid`, `config_path`, `log_path`, `started_at`, `stopped_at` |
| `events` | Centralized event log (`timestamp`, `level`, `category`, `swarm`, `agent`, `event_type`, `message`, `metadata`), indexed by swarm and timestamp |
| `tasks` | Cross-process task queue (`swarm`, `agent`, `task`, `status`, timestamps) |
| `swarm_overlays` | Dynamic-mutation event log for runtime swarm changes |
| `swarm_commands` | CLI → daemon command bridge (add/remove agents, topology edges, scaling, etc.) |

The database runs in WAL mode with a 5s busy timeout for concurrent readers/writers.

### Poll loop

The daemon's `daemon_loop/2` waits for the supervisor to go `:DOWN` (marking the swarm `crashed`); otherwise, every 500 ms it:

1. `process_pending_tasks/1` — drains `SwarmRegistry.get_pending_tasks/1` and delivers each via `SwarmManager.send_task/3`, marking processed or leaving pending for retry on failure.
2. `process_pending_commands/1` — applies queued mutation commands (add/remove agent or object, add/remove topology edges, scale agent group, fetch full config) and writes results back.

### Task delivery paths

`genswarms task <swarm> <agent> <msg>` chooses a path based on whether the API server is up:

- API server running → send over HTTP REST.
- No API server → enqueue in the `tasks` table; the daemon's poll loop picks it up within ~500 ms.

### Stop, pause, resume

- `genswarms stop <swarm>` sends `SIGTERM` to the recorded daemon PID, waits for exit, and marks the swarm stopped.
- Pause/resume for daemon swarms cannot use in-BEAM GenServer calls (the daemon is a separate process), so they act on the containers directly, e.g. `docker pause szc-<swarm>-<agent>` / `docker unpause …`.

## Deployment models

| Model | How agents run | Configuration |
|-------|----------------|---------------|
| Docker (NixOS) | Minimal NixOS containers, one per agent, namespaced `szc-<swarm>-<agent>` | `backend: {:docker, "<image>"}`; build with `nix build .#agentContainer-<preset>` |
| Bare metal (Colmena + NixOS) | Dedicated NixOS machines provisioned ahead of time, reached over SSH | `colmena apply` to provision, then `backend: {:ssh, "user@host"}` |
| Bwrap | Bubblewrap sandboxes on a single NixOS host (10k+ scale) | `backend: :bwrap` |
| Hybrid | Any mix of `:local`, `{:docker, …}`, `{:ssh, …}`, `:bwrap`, `:mock` in one swarm | per-agent `backend:` |

### Docker (NixOS containers)

Run many isolated agents on one machine using minimal NixOS containers that include only the tools declared via presets/tools. Containers are namespaced by swarm name (`szc-<swarm>-<agent>`), so multiple swarms run simultaneously without interference and pause/resume affects only the targeted swarm's containers.

### Bare metal (Colmena + NixOS)

Deploy fully configured NixOS machines with Colmena, then start the orchestrator, which connects to them over SSH:

```bash
colmena apply
mix genswarms start examples/bare_metal_swarm.exs
```

### Hybrid

Mix backends within a single swarm config:

```elixir
%{
  name: "example-swarm",
  agents: [
    %{name: :researcher, backend: :local},
    %{name: :coder, backend: {:docker, "coder"}},
    %{name: :remote_1, backend: {:ssh, "root@192.168.1.51"}}
  ]
}
```

See `docs/backends.md` and `docs/containers.md` for backend specifics and container builds.

## See also

- [backends.md](backends.md) — backend types and configuration
- [containers.md](containers.md) — NixOS container builds and presets
- [configuration.md](configuration.md) — swarm config DSL
- [observability.md](observability.md) — events, logging, and streaming
- [rest-api.md](rest-api.md) — REST API reference
