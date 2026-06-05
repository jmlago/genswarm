# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Genswarm is an Elixir/OTP orchestrator for managing swarms of AI agents with pluggable backends (Local/Docker/SSH/Bwrap/Mock), arbitrary directed graph topologies, per-agent skills with template variable resolution, file-based messaging (inbox/outbox), and fault tolerance via OTP supervision trees.

## Build & Development Commands

```bash
# Enter Nix dev shell (Elixir 1.17, Erlang 27, Node 20)
nix develop

# Install dependencies
mix deps.get

# Build CLI escript (creates ./swarm binary)
mix escript.build

# Run tests
mix test
mix test --cover

# Format code
mix format

# Static analysis
mix credo

# Start Phoenix API server (development)
mix phx.server

# Run a single test file
mix test test/genswarm/routing/router_test.exs

# Run tests matching pattern
mix test --only tag_name
```

### Building Container Images

```bash
nix build .#agentContainer-base   # Base NixOS container
nix build .#agentContainer-web    # Web tools container
nix build .#agentContainer-code   # Code tools container
nix build .#agentContainer-data   # Data tools container
nix build .#agentContainer-full   # Full tools container
docker load < result              # Load into Docker
```

### CLI Commands (after `mix escript.build`)

```bash
# Server
swarm up                          # Start Phoenix API server
swarm down                        # Stop everything

# Swarm Management
swarm start <config.exs>          # Start swarm as daemon (background process)
swarm stop <name>                 # Stop swarm
swarm restart <name>              # Restart swarm
swarm restart <name> --delete     # Restart with clean slate (delete old data)
swarm pause <name>                # Pause swarm (freeze containers)
swarm resume <name>               # Resume paused swarm
swarm status [name]               # Show status
swarm delete <name>               # Delete swarm and all its data
swarm clean                       # Clean up stopped/crashed swarms
swarm clean --all                 # Also clear all events

# Agent Operations
swarm logs [swarm] [agent]        # Stream logs
swarm task <swarm> <agent> <msg>  # Send task to agent

# Observability
swarm events                      # View recent events
swarm events --errors             # Filter error events
swarm events -s <swarm>           # Filter by swarm
swarm events --follow             # Stream in real-time

# Configuration
swarm config validate <file>      # Validate config

# Testing
mix swarm.test                    # Validate + run all examples
mix swarm.test --validate-only    # Only validate configs
mix swarm.test --mock script.json # Run with mock backend (no LLM)
mix swarm.test --example name     # Test a specific example
mix swarm.test --timeout 60000    # Custom timeout (ms)
mix swarm.test --steps 3          # Steps for .sim examples
```

## Architecture

```
Application
    │
    ├── SwarmManager (GenServer) ─── manages swarm lifecycle
    │       │
    │       ├── Registry ─── tracks agent/object processes
    │       ├── Router ─── inter-agent message routing via topology
    │       ├── SkillsManager ─── ETS-backed skill file management
    │       └── AgentDynamicSupervisor
    │               │
    │               └── AgentServer (per agent)
    │                       ├── Backend (Local Port / Docker / SSH / Bwrap / Mock)
    │                       └── LogWatcher (polls logs + .outbox/ for routing)
    │
    ├── ObjectSupervisor ─── manages non-agentic Elixir objects
    │       └── ObjectServer (per object)
    │
    ├── Phoenix (REST API + WebSocket only, no HTML)
    │
    ├── SwarmRegistry (SQLite) ─── cross-process state & task queue
    │
    ├── LogStore (ETS) ─── centralized event logging
    │
    └── Telemetry
```

### API-First Architecture

The Phoenix server exposes a pure JSON REST API and WebSocket for real-time events. No HTML/frontend is included.

```
External Frontend                   Phoenix API Server
(React, Vue, etc.)                         │
        │                                  ├── REST API (/api/*)
        ├── HTTP ─────────────────────────►├── WebSocket (/swarm)
        │                                  └── CORS enabled
        │
        │                           Daemon Process (swarm start)
        │                                  │
        └── (optional) ───────────────────►├── SwarmManager
                                           ├── Agents/Containers
                                           └── SwarmRegistry (SQLite)
```

### Daemon Architecture

Swarms run as independent OS processes (daemons), separate from the API server:

```
API Server (Phoenix)                 Daemon Process (swarm start)
        │                                      │
        ├── REST API                           ├── SwarmManager
        ├── WebSocket                          ├── Agents/Containers
        └── SwarmRegistry ◄──── SQLite ────► SwarmRegistry
              (query state)                    (write state)
              (queue tasks)                    (poll tasks)
```

- API server queries SQLite for swarm state (running/stopped/crashed)
- Tasks sent via API are queued in SQLite
- Daemon polls task queue every 500ms and delivers to agents
- Pause/resume for daemon swarms uses Docker commands directly

### Key Modules

| Module | Location | Purpose |
|--------|----------|---------|
| `Genswarm` | `lib/genswarm.ex` | Main public API |
| `SwarmManager` | `lib/genswarm/swarm_manager.ex` | Swarm lifecycle orchestration |
| `Router` | `lib/genswarm/routing/router.ex` | Message routing via topology adjacency map |
| `AgentServer` | `lib/genswarm/agents/agent_server.ex` | Individual agent lifecycle |
| `AgentProtocol` | `lib/genswarm/agents/agent_protocol.ex` | Parses `@agent:` message syntax |
| `LocalBackend` | `lib/genswarm/backends/local_backend.ex` | Elixir Port subprocess |
| `DockerBackend` | `lib/genswarm/backends/docker_backend.ex` | Docker container management |
| `SSHBackend` | `lib/genswarm/backends/ssh_backend.ex` | SSH remote execution |
| `ObjectHandler` | `lib/genswarm/objects/object_handler.ex` | Behaviour for custom objects |
| `ObjectServer` | `lib/genswarm/objects/object_server.ex` | GenServer wrapper for object handlers (supports :send_many) |
| `LogWatcher` | `lib/genswarm/agents/log_watcher.ex` | Polls agent logs + .outbox/ for message routing |
| `BwrapBackend` | `lib/genswarm/backends/bwrap_backend.ex` | Bubblewrap sandbox backend |
| `Loader` | `lib/genswarm/config/loader.ex` | Loads .exs/.json/.yaml configs |
| `CLI` | `lib/genswarm/cli/cli.ex` | Main escript entry point |
| `SwarmRegistry` | `lib/genswarm/cli/swarm_registry.ex` | SQLite-backed cross-process state & task queue |
| `LogStore` | `lib/genswarm/observability/log_store.ex` | Centralized ETS-backed event logging |
| `SwarmController` | `lib/genswarm_web/controllers/swarm_controller.ex` | REST API for swarm management |
| `SwarmChannel` | `lib/genswarm_web/channels/swarm_channel.ex` | WebSocket for real-time events |

### Inter-Agent Communication

Agents communicate using `@agent_name:` prefixes in output. The `AgentProtocol` parses these patterns and `Router` validates/routes according to topology.

```
ASST: I've analyzed this. @coder: Please implement the algorithm.
```

Broadcast to all connected: `@all: message`

**System object routing**: Router always allows messages to `:metrics`, `:tick`, `:gateway` without explicit topology edges (defined in `@system_objects` in `router.ex`).

**File-inbox**: Messages delivered to agents are also written to `{workspace}/.inbox/{seq}_{from}.json` for reliable delivery to bwrap agents.

**File-outbox**: LogWatcher polls `{workspace}/.outbox/` for JSON files (`{"to":"target","content":"msg"}`) and routes them. Agents can write outbox files instead of using `@agent:` syntax. The `swarm-msg outbox <target> <msg>` command writes to `.outbox/`.

## REST API Reference

### Swarm Management
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms | List all swarms |
| POST | /api/swarms | Create swarm |
| GET | /api/swarms/:name | Get detailed status |
| DELETE | /api/swarms/:name | Stop swarm (?purge=true to delete all) |
| POST | /api/swarms/:name/pause | Pause containers |
| POST | /api/swarms/:name/resume | Resume containers |
| POST | /api/swarms/:name/restart | Restart (?delete=true for clean) |
| POST | /api/swarms/:name/message | Route message between agents |
| POST | /api/swarms/clean | Clean stopped/crashed (?all=true to clear events) |

### Agent Operations
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/agents | List agents |
| GET | /api/swarms/:name/agents/:agent | Get agent status |
| POST | /api/swarms/:name/agents/:agent/task | Send task |
| POST | /api/swarms/:name/agents/:agent/restart | Restart agent |
| GET | /api/swarms/:name/agents/:agent/logs | Get logs |
| GET | /api/swarms/:name/agents/:agent/history | Get history |
| GET | /api/swarms/:name/agents/:agent/skills | Get skills |
| PUT | /api/swarms/:name/agents/:agent/skills/:skill | Update skill |

### Topology & Events
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/swarms/:name/topology | Get topology |
| GET | /api/swarms/:name/messages | Get message log |
| GET | /api/events | Query events (with filters) |
| GET | /api/swarms/:name/events | Swarm events |

### Skills & Config
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/skills | List available skills |
| GET | /api/skills/:name | Get skill content |
| POST | /api/config/validate | Validate config |

### WebSocket (swarm:* channel)
| Event | Direction | Description |
|-------|-----------|-------------|
| send_task | client→server | Send task to agent |
| get_status | client→server | Get swarm status |
| subscribe_logs | client→server | Subscribe to log stream |
| unsubscribe_logs | client→server | Unsubscribe from logs |
| subscribe_events | client→server | Subscribe to event stream |
| unsubscribe_events | client→server | Unsubscribe from events |
| agent_output | server→client | Agent output |
| message_routed | server→client | Message routed |
| log_entry | server→client | Real-time log line |
| event | server→client | Real-time event |

## Configuration DSL

Swarm configs define agents, objects, and topology. Supports `.exs`, `.json`, `.yaml` formats.

```elixir
%{
  name: "my-swarm",
  agents: [
    %{name: :researcher, backend: :local, skills: ["web.md"], model: "anthropic/claude-sonnet-4"},
    %{name: :coder, backend: {:docker, "coder"}, skills: ["code.md"], presets: [:base, :code]}
  ],
  objects: [
    %{name: :evaluator, handler: MyApp.Objects.Evaluator, config: %{}}
  ],
  topology: [
    {:researcher, :coder},
    {:coder, :evaluator},
    {:evaluator, :researcher}
  ]
}
```

Backend types: `:local`, `{:docker, "name"}`, `{:docker, "name", %{opts}}`, `{:ssh, "user@host"}`, `{:ssh, "user@host", %{opts}}`, `:bwrap`, `{:bwrap, %{opts}}`, `:mock`, `{:mock, %{script: [...]}}`

### Bwrap Config Separation

For bwrap agents, backend keys are separated from domain keys in agent config. Backend keys control the execution environment, domain keys are application-specific:

```elixir
%{
  name: :fixer,
  backend: :bwrap,
  config: %{
    # Backend keys (passed to BwrapBackend)
    workspace: "/tmp/workspace",
    extra_path: ["/opt/tools/bin"],
    extra_ro_binds: [{"/home/user/project", "/project"}],
    memory_limit: "512M",
    # Domain keys (available to skills/agent logic)
    population_size: 10,
    max_iterations: 50
  }
}
```

Backend keys: `workspace`, `extra_path`, `extra_ro_binds`, `extra_rw_binds`, `memory_limit`, `cpu_shares`, `tasks_max`, `subzeroclaw_path`, `presets`

### Skill Templating

Skills support template variables resolved at deploy time:
- `{{agent_name}}` - the agent's name (e.g., `fixer_3`)
- `{{workspace}}` - the agent's workspace path
- `{{swarm_name}}` - the swarm name

### Per-Agent Workspaces

When `count: N` is used, workspace path is auto-appended with agent name:
- `agent :fixer, count: 20` with `workspace: "/tmp/ws"` gives `fixer_1` the path `/tmp/ws/fixer_1/`

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `SUBZEROCLAW_API_KEY` | LLM provider API key |
| `SUBZEROCLAW_MODEL` | Default model (e.g., `anthropic/claude-sonnet-4`) |
| `SUBZEROCLAW_PATH` | Path to subzeroclaw binary |
| `SUBZEROCLAW_MOCK_SCRIPT` | Path to mock script JSON (skips LLM API calls, passed through to bwrap) |
| `SECRET_KEY_BASE` | Phoenix secret (production) |
| `PORT` | HTTP port (default: 4000) |
| `SWARM_TOPOLOGY` | (Container only) Comma-separated list of connected targets for `swarm-msg list` |

## Test Files

- `test/genswarm/agents/agent_protocol_test.exs` - Message parsing
- `test/genswarm/routing/router_test.exs` - Message routing (including system object routing)
- `test/genswarm/config/loader_test.exs` - Config loading
- `test/genswarm/config/swarm_config_test.exs` - Config validation
- `test/genswarm/agents/inbox_test.exs` - Message queue
- `lib/mix/tasks/swarm/test.ex` - E2E test task implementation

### Binary Path Resolution

The bwrap backend searches for the `subzeroclaw` binary in order: explicit config, `../subzeroclaw/subzeroclaw` (sibling checkout), `SUBZEROCLAW_PATH` env var, system PATH.

## Nix Tool Presets

Defined in `nix/tool-presets.nix`. Available presets for agents:
- `:base` - coreutils, bash, grep, sed, awk
- `:web` - curl, wget, httpie, jq, yq, w3m
- `:code` - git, gcc, make, ripgrep, fd, bat
- `:python` - python3, pip, virtualenv, pandas, numpy
- `:node` - nodejs, npm, yarn, pnpm
- `:data` - jq, csvkit, miller, sqlite, duckdb

## Objects (Non-Agentic Components)

Objects are Elixir modules implementing `ObjectHandler` behaviour. They participate in topology but execute deterministic code instead of LLM calls.

```elixir
defmodule MyApp.Objects.MyHandler do
  @behaviour Genswarm.Objects.ObjectHandler

  @impl true
  def init(config), do: {:ok, %{}}

  @impl true
  def handle_message(from, content, state) do
    # Return: {:reply, response, state} | {:send, to, msg, state} |
    #         {:broadcast, msg, state} | {:noreply, state} |
    #         {:send_many, [{target, msg}], state} |
    #         {:multi, [{:send, to, msg} | {:broadcast, msg}], state}
  end

  # Optional: handle process messages (timers, etc.)
  @impl true
  def handle_info(msg, state) do
    # Same return values as handle_message
  end

  @impl true
  def interface(), do: %{action: %{input: "desc", output: "desc"}}
end
```

### ObjectServer `:send_many`

Objects can return `{:send_many, [{target, msg}], state}` from `handle_message/3` or `handle_info/2` to send multiple messages at once. Supports both `{target, msg}` tuples and tagged `{:send, to, msg}` / `{:broadcast, msg}` tuples.

### Mock Backend for Testing

Use `backend: :mock` (or `{:mock, %{script: [...]}}`) to test without LLM calls. Pattern-matches incoming messages and returns canned responses. The `SUBZEROCLAW_MOCK_SCRIPT` env var is passed through to bwrap sandboxes.

### E2E Testing (`mix swarm.test`)

```bash
mix swarm.test                    # Validate + run all examples
mix swarm.test --validate-only    # Only validate configs
mix swarm.test --mock script.json # Run with mock backend
```

Logs saved to `.test-logs/`. Exit code 0 if all pass, 1 if any fail.

## Cross-Process Communication

The API server and CLI communicate with daemon swarms via SQLite:

### SwarmRegistry (SQLite)

Location: `.swarm/swarms.db` (project directory)

Tables:
- `swarms` - Running swarm state (name, pid, config_path, status, started_at)
- `events` - Centralized event log with timestamps
- `tasks` - Task queue for cross-process task delivery

### Task Queue Flow

1. API/CLI calls `SwarmRegistry.queue_task(swarm, agent, task)`
2. Task inserted into SQLite with status "pending"
3. Daemon polls every 500ms via `SwarmRegistry.get_pending_tasks(swarm)`
4. Daemon delivers task via `SwarmManager.send_task/3`
5. Task marked as processed via `SwarmRegistry.mark_task_processed(id)`

### Pause/Resume for Daemon Swarms

Since `SwarmManager.pause/1` requires GenServer access, daemon swarms use Docker directly:
- Pause: `docker pause szc-{swarm}-{agent}` for each container
- Resume: `docker unpause szc-{swarm}-{agent}` for each container

## Critical Files

- `priv/szc-wrapper` - Agent communication wrapper escript (JSON protocol translation)
- `priv/szc-wrapper.sh` - Shell wrapper script
- `priv/szc-wrapper-fifo.sh` - FIFO-based wrapper (preferred for bwrap sandboxes)
- `swarm-msg` - Shell script for agent-side messaging (send, outbox, broadcast, list)
- `nix/tool-presets.nix` - Tool/preset definitions for NixOS containers
- `nix/container.nix` - Container builder configuration
- `.swarm/swarms.db` - SQLite database for cross-process state
- `.test-logs/` - E2E test output from `mix swarm.test`
