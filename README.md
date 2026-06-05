# Genswarms

An Elixir/OTP orchestrator for managing swarms of subzeroclaw agents with
pluggable backends, arbitrary directed-graph topologies, per-agent skills, and
fault tolerance via OTP supervision trees.

> 📚 **Full documentation lives in [`docs/`](docs/README.md).** This page is an
> overview and quick start; each topic has its own guide.

## Features

- **Pluggable backends** — Local (Port), Docker (NixOS containers), SSH, Bwrap (bubblewrap), Mock.
- **Arbitrary topologies** — define directed graphs for inter-agent communication.
- **Per-agent skills** — markdown skill files deployed per agent, with `{{agent_name}}` / `{{swarm_name}}` / `{{workspace}}` templating.
- **Objects** — non-agentic Elixir components that participate in the topology and run deterministic code.
- **Bwrap sandboxing** — lightweight bubblewrap isolation for large agent pools on a single NixOS machine.
- **NixOS-based containers** — minimal, declarative images carrying only the tools each agent needs.
- **File-based messaging** — reliable delivery to sandboxed agents via `.inbox/` and `.outbox/`.
- **Daemon-based swarms** — swarms run as independent OS processes, coordinated through SQLite.
- **REST API + WebSocket** — full programmatic control and real-time event streaming (JSON only, CORS enabled).
- **Runtime scaling** — grow or shrink agent groups in a live swarm.
- **Centralized observability** — query and stream events and logs via CLI or API.
- **Mock backend** — test swarm logic without any LLM calls.
- **Fault tolerance** — OTP supervision for resilient operation.

## How it works

Swarms run as independent daemon processes, separate from the optional API
server. The API server and CLI coordinate with running daemons through a SQLite
database (`.genswarms/swarms.db`): they query state and queue tasks, and each
daemon polls that queue.

```text
External frontend / scripts          Phoenix API server (optional)
   (React, Vue, curl, …)                    │
        │  HTTP / WebSocket                  ├── REST API (/api/*)
        ├───────────────────────────────────┤── WebSocket (/swarm)
        │                                    └── reads/writes SQLite
        │
        │                             Daemon process  (genswarms start)
        │                                    ├── SwarmManager
        └── (optional) ──────────────────────┤── Agents / Objects / Backends
                                             └── reads/writes SQLite
                                                       │
                                    .genswarms/swarms.db  (state + task queue)
```

For the real OTP supervision tree and the per-swarm process layout, see
[docs/architecture.md](docs/architecture.md).

## Installation

Genswarms requires **Elixir 1.14+** and **Erlang/OTP 27+** (`mix.exs` pins
`elixir: "~> 1.14"`). The Nix dev shell pins the exact versions used in CI —
Elixir 1.17 / Erlang 27 / Node 20 — so it is the recommended setup.

```bash
# With Nix (recommended): enter the dev shell
nix develop

# Install dependencies
mix deps.get

# Build the genswarms CLI escript (creates ./genswarms)
mix escript.build

# Optionally install it on your PATH
cp genswarms ~/.local/bin/        # or: sudo cp genswarms /usr/local/bin/
```

Node.js 20 is only needed if you build agent container images.

See [docs/getting-started.md](docs/getting-started.md) for the full setup,
container builds, and environment variables.

## Quick start

```bash
# 1. Start the API server (background)
genswarms up

# 2. Create a new project with example configs
genswarms init my-project
cd my-project
cp .env.example .env        # then add your API keys

# 3. Start a swarm from a config file (runs as a daemon)
genswarms start swarms/example_swarm.exs

# 4. Check status
genswarms status                    # server + all swarms
genswarms status example-swarm      # one swarm's details

# 5. Send a task to an agent
genswarms task example-swarm researcher "Find papers on transformers"

# 6. Stream logs
genswarms logs example-swarm              # all agents
genswarms logs example-swarm researcher   # one agent
genswarms logs example-swarm -f           # follow

# 7. Stop the swarm, or everything
genswarms stop example-swarm
genswarms down
```

Every subcommand is also available as a Mix task, e.g. `mix genswarms.status`.
A few lifecycle commands are **Mix-task only** today — see the note under
[CLI overview](#cli-overview).

## CLI overview

These commands are wired into the `genswarms` escript binary:

| Command | Description |
|---------|-------------|
| `genswarms up` / `down` | Start / stop the API server (`up` is an alias for `dashboard start`; `down` stops the server and all swarms) |
| `genswarms dashboard [start\|stop\|status]` | Manage the API/dashboard server explicitly |
| `genswarms init [dir]` | Scaffold a new project |
| `genswarms start <config>` | Start a swarm as a daemon (`--foreground` to run inline) |
| `genswarms stop <name>` / `restart <name>` | Swarm lifecycle (`restart --delete` for a clean slate) |
| `genswarms status [name]` | Show server and swarm status |
| `genswarms task <swarm> <agent> <msg>` | Send a task to an agent |
| `genswarms msg <swarm> <from> <to> <msg>` | Route a message between agents |
| `genswarms logs [swarm] [agent]` | Stream agent logs |
| `genswarms events` | Query and stream events |
| `genswarms scale <swarm> <base> <n>` | Scale an agent group |
| `genswarms snapshot` / `overlay` | Snapshots and bwrap overlays |
| `genswarms build [--all]` | Build agent container images via nix |
| `genswarms env [list\|get\|set]` | Manage environment variables |
| `genswarms config validate <file>` / `check <file>` | Validate a config |
| `genswarms list-skills` | List available skills |

**Mix-task only commands.** The following are *not* dispatched by the `genswarms`
escript — running `genswarms pause …` falls through to "Unknown command". Invoke
them through Mix instead:

| Command | Description |
|---------|-------------|
| `mix genswarms.pause <name>` / `mix genswarms.resume <name>` | Freeze / unfreeze the swarm's Docker containers |
| `mix genswarms.delete <name>` | Delete a swarm and all its data (`--force` to skip the prompt) |
| `mix genswarms.clean` | Remove stopped/crashed swarms (`--all` also clears events) |
| `mix genswarms.restart_agent <swarm> <agent>` | Restart a single agent (requires the API server) |

Many additional runtime operations (restart a single agent, pause/resume,
add/remove agents, edit skills, fetch topology) are exposed through the
[REST API](docs/rest-api.md) rather than the CLI.

See the [full CLI reference](docs/cli.md) for every command, flag, and example.

## Configuration

A swarm is defined by agents, optional objects, and a topology. Configs may be
`.exs`, `.json`, or `.yaml`.

```elixir
%{
  name: "example-swarm",
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

The full DSL — every agent/object key, backend value forms, and bwrap config
separation — is documented in [docs/configuration.md](docs/configuration.md).

## Backends

| Backend | Config value | Use for |
|---------|--------------|---------|
| Local | `:local` | Development, single-host agents |
| Docker | `{:docker, "name"}` | Isolated NixOS-based containers |
| SSH | `{:ssh, "user@host"}` | Remote / bare-metal agents |
| Bwrap | `:bwrap` | Lightweight sandboxes at large scale |
| Mock | `{:mock, %{script: [...]}}` | Testing without LLM calls |

See [docs/backends.md](docs/backends.md) and [docs/containers.md](docs/containers.md).

## Documentation

**Getting started**
- [Getting started](docs/getting-started.md) — install, first swarm, environment variables
- [Configuration](docs/configuration.md) — the swarm config DSL
- [CLI reference](docs/cli.md) — every command and flag

**Core concepts**
- [Architecture](docs/architecture.md) — supervision tree, daemon model, deployment
- [Messaging & routing](docs/messaging.md) — `@agent:` syntax, topology, inbox/outbox
- [Objects](docs/objects.md) — non-agentic components
- [Skills](docs/skills.md) — per-agent skills and templating

**Backends & deployment**
- [Backends](docs/backends.md) — Local / Docker / SSH / Bwrap / Mock
- [Containers](docs/containers.md) — NixOS images, tool presets, bwrap internals

**APIs**
- [REST API](docs/rest-api.md) — the JSON HTTP API
- [WebSocket API](docs/websocket.md) — real-time streams
- [Programmatic usage](docs/programmatic.md) — Genswarms as an Elixir library

**Operations**
- [Observability](docs/observability.md) — events, logging, telemetry
- [Testing](docs/testing.md) — unit tests, e2e harness, mock backend
- [Troubleshooting](docs/troubleshooting.md) — common problems

## Development

```bash
mix test            # run the test suite
mix test --cover    # with coverage
mix format          # format code
mix phx.server      # run the API server in the foreground
```

See [docs/testing.md](docs/testing.md) for the e2e harness (`mix genswarms.test`)
and mock-backend testing.

## License

See [LICENSE](LICENSE).
