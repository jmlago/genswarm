---
name: operating-genswarms
description: Operate and orchestrate genswarms agent swarms — author swarm configs (.exs/.json/.yaml), build the CLI, and start/manage/observe/scale swarms via the genswarms CLI or REST API. Use when working in a genswarms repo, defining or running a swarm, wiring agent topologies/backends/skills, or driving swarms over HTTP/WebSocket. Do NOT use for developing the genswarms Elixir codebase itself, or for unrelated multi-agent frameworks.
---

# genswarms

GenSwarms is an Elixir/OTP orchestrator for swarms of `subzeroclaw` agents. A swarm is a
declarative set of **agents** (pluggable backends: Local / Docker / SSH / Bwrap / Mock),
optional non-agentic **objects**, and a directed-graph **topology** connecting them. Swarms run
as independent daemon processes; an optional Phoenix server exposes a JSON REST API + WebSocket.
The CLI, API, and daemons coordinate through SQLite at `.genswarms/swarms.db`.

Full docs live in [`docs/`](docs/README.md) — link out rather than duplicating. This skill is the
how-to-operate quick path.

## Prerequisites & install

Requires **Elixir 1.14+** and **Erlang/OTP 27+** (Nix dev shell pins Elixir 1.17 / OTP 27 / Node 20).
Node 20 is only needed to build agent container images.

```bash
nix develop              # recommended dev shell (or install Elixir/OTP yourself)
mix deps.get
mix escript.build        # produces ./genswarms escript binary
cp genswarms ~/.local/bin/   # optional: put it on PATH
```

Every subcommand also runs via Mix: `genswarms status` == `mix genswarms.status`
(hyphens become underscores, e.g. `list-skills` → `mix genswarms.list_skills`).
See [docs/getting-started.md](docs/getting-started.md).

Only `SUBZEROCLAW_API_KEY` is required to run real agents. The CLI auto-loads `.env` from the
working directory (searching up to 5 parents). Key env vars (full list in getting-started.md):

| Var | Purpose | Default |
|-----|---------|---------|
| `SUBZEROCLAW_API_KEY` | LLM provider key (required) | — |
| `SUBZEROCLAW_MODEL` | Default agent model | `anthropic/claude-sonnet-4` |
| `SUBZEROCLAW_MOCK_SCRIPT` | Run real agents w/o LLM (canned responses) | — |
| `PORT` | API server port | `4000` |
| `SWARM_API_URL` | Base URL CLI uses to reach the server | `http://localhost:4000` |
| `GENSWARMS_API_TOKEN` | Bearer token securing the REST + WebSocket API | — (unset = loopback-only) |

## Core workflow

Copy this checklist and check off each step as you go:

```
Swarm bring-up:
- [ ] 1. Scaffold a project        (genswarms init)
- [ ] 2. Set SUBZEROCLAW_API_KEY   (cp .env.example .env)
- [ ] 3. Validate the config       (genswarms config validate)
- [ ] 4. Start the API server      (genswarms up — optional)
- [ ] 5. Start the swarm daemon    (genswarms start)
- [ ] 6. Inspect status            (genswarms status)
- [ ] 7. Task an agent             (genswarms task)
- [ ] 8. Observe logs/events       (genswarms logs -f / events)
- [ ] 9. Stop                      (genswarms stop / down)
```

```bash
# 1. Scaffold a project (swarms/, skills/, docker/, .env.example, .genswarms/)
genswarms init my-project && cd my-project
cp .env.example .env            # add SUBZEROCLAW_API_KEY

# 2. Validate the config before running it
genswarms config validate swarms/example_swarm.exs

# 3. Start the API server (background) — optional but enables HTTP/WS + restart-agent
genswarms up                    # --port N to override; --foreground to run inline

# 4. Start the swarm as a daemon (name comes from the config's name:, not the filename)
genswarms start swarms/example_swarm.exs

# 5. Inspect
genswarms status                # server + all swarms
genswarms status example-swarm  # agents, objects, topology, backends, skills

# 6. Task an agent (queued in SQLite, daemon polls every 500ms)
genswarms task example-swarm researcher "Find papers on transformers"

# 7. Observe
genswarms logs example-swarm -f         # follow live logs (use this for live streaming)
genswarms events --errors               # one-shot error query

# 8. Stop
genswarms stop example-swarm            # one swarm
genswarms down                          # all swarms + the API server
```

Walkthrough: [docs/getting-started.md](docs/getting-started.md).

## Minimal swarm config

A config is a map (`.exs`, `.json`, or `.yaml`). The swarm name comes from `name:`.

```elixir
%{
  name: "example-swarm",
  agents: [
    %{name: :researcher, backend: :local, skills: ["web.md"], model: "anthropic/claude-sonnet-4"},
    %{name: :coder, backend: {:docker, "coder"}, skills: ["code.md"], presets: [:base, :code]}
  ],
  objects: [
    # optional deterministic, non-agentic components
    %{name: :evaluator, handler: MyApp.Objects.Evaluator, config: %{}}
  ],
  topology: [
    {:researcher, :coder},   # directed edge: researcher may send to coder
    {:coder, :evaluator},
    {:evaluator, :researcher}
  ]
}
```

Key facts (see [docs/configuration.md](docs/configuration.md)):
- `name` and `agents` (non-empty) are required; `objects` and `topology` default to `[]`.
- `backend` defaults to `:bwrap` if omitted. Forms: `:local`, `{:docker, "name"}`,
  `{:docker, "name", %{opts}}`, `{:ssh, "user@host"}`, `{:ssh, "user@host", %{opts}}`,
  `:bwrap`, `{:bwrap, %{opts}}`, `:mock`, `{:mock, %{script: [...]}}`.
- **JSON/YAML only support scalar-string backends** (`"local"`, `"bwrap"`, `"mock"`). Docker/SSH
  and option-map backends require `.exs`.
- Topology is directional — declare both directions for two-way comms. System objects
  `:metrics`, `:tick`, `:gateway` are always routable without an edge.
- There is **no `count:` key** — one agent def == one agent. Run pools via runtime scaling.
- For bwrap agents, `config:` is split into backend keys (`workspace`, `extra_path`,
  `extra_ro_binds`, `extra_env`, `memory_limit`, `cpu_shares`, `tasks_max`, `subzeroclaw_path`,
  `presets`) and domain keys (anything else, passed through to the agent).

Backends in depth: [docs/backends.md](docs/backends.md). Objects: [docs/objects.md](docs/objects.md).
Driving swarms from Elixir directly: [docs/programmatic.md](docs/programmatic.md).

## Essential CLI commands

These are dispatched by the `genswarms` **escript binary** (verified against `lib/genswarms/cli.ex`):

| Command | Purpose |
|---------|---------|
| `genswarms init [dir]` | Scaffold a project (`--force` to overwrite) |
| `genswarms up` / `down` | Start API server / stop server + swarms (`up` = `dashboard start`) |
| `genswarms dashboard [start\|stop\|status]` | Manage the API/dashboard server explicitly |
| `genswarms start <config>` | Start a swarm daemon (`--foreground` to run inline) |
| `genswarms stop <name>` | Stop a swarm daemon |
| `genswarms restart <name>` | Restart, reloading config (`--delete` for clean slate) |
| `genswarms status [name]` | Server + swarm status |
| `genswarms task <swarm> <agent> <msg>` | Send a task to an agent |
| `genswarms msg <swarm> <from> <to> <msg>` | Route a message (validated against topology) |
| `genswarms logs [swarm] [agent]` | View/stream logs (`-f` follow, `--tail N`, `--stdout`, `--events`, `--all`) |
| `genswarms events` | One-shot event query (`--errors`, `-s <swarm>`, `-a <agent>`, `--category`, `--type`, `--limit`) |
| `genswarms scale <swarm> <base> <n>` | Scale an agent group to N (`base_1`, `base_2`, …) |
| `genswarms overlay <swarm>` / `snapshot <swarm>` | Inspect/clear runtime overlay; emit effective `.exs` |
| `genswarms config validate <file>` (alias `check`) | Validate a config |
| `genswarms list-skills` | List available skills |
| `genswarms build [img\|--all]` | Build agent container images via Nix |
| `genswarms env [list\|get\|set\|unset]` | Manage `.env` variables |

**Mix-task only** (NOT escript subcommands — `genswarms clean`/`pause`/etc. error with "Unknown command"):

| Command | Purpose |
|---------|---------|
| `mix genswarms.pause <name>` / `mix genswarms.resume <name>` | Freeze / unfreeze the swarm's Docker containers |
| `mix genswarms.delete <name>` | Delete a swarm + all its data (`--force` to skip prompt) |
| `mix genswarms.clean [--all]` | Remove stopped/crashed swarms (`--all` also clears events) |
| `mix genswarms.restart_agent <swarm> <agent>` | Restart one agent (requires the API server) |

Note: `genswarms events --follow`/`--stats` are silent no-ops today — use `genswarms logs <swarm> -f`
for live streaming. Full reference: [docs/cli.md](docs/cli.md).

## Driving via REST API

Server runs at `http://localhost:4000` (JSON only). Start it with `genswarms up`.
Many runtime ops (add/remove agents, edit topology, restart-agent, edit skills) are API-only.
When `GENSWARMS_API_TOKEN` is set, send `Authorization: Bearer $GENSWARMS_API_TOKEN`
on every request (the CLI does this automatically); unset, the API accepts
loopback callers only. See [Security](docs/security.md) before exposing the server.

```bash
curl http://localhost:4000/api/swarms                          # list swarms

curl -X POST http://localhost:4000/api/swarms \                # create from server-side config
  -H 'Content-Type: application/json' \
  -d '{"config_path": "swarms/example_swarm.exs"}'             # or {"config": {...}} inline

curl -X POST http://localhost:4000/api/swarms/example-swarm/agents/researcher/task \
  -H 'Content-Type: application/json' \
  -d '{"task": "Summarize the latest results."}'

curl -X POST http://localhost:4000/api/swarms/example-swarm/agents \   # add + wire a live agent
  -H 'Content-Type: application/json' \
  -d '{"name": "reviewer", "backend": {"type": "docker", "image": "code"}, "incoming": ["coder"]}'
```

Other useful routes: `GET /api/swarms/:name` (detailed status), `GET .../topology`,
`PATCH .../topology` (`{"add":[...],"remove":[...]}`), `POST .../agents/:base/scale` (`{"count":N}`),
`GET /api/events` (filterable), `POST /api/config/validate`, `GET /api/skills`. Real-time streaming is
over the WebSocket channel `swarm:{name}` at `/swarm`. Full reference:
[docs/rest-api.md](docs/rest-api.md) and [WebSocket](docs/websocket.md).

## Defining skills for agents

Skills are plain markdown files (no schema) that become an agent's instructions. Reference them by
the `skills:` list in config; a simple filename resolves against the skills dir (`priv/skills`, set by
`SKILLS_DIR`), and `./`-relative or absolute paths are also accepted.

Three template variables are substituted per agent at deploy time, so one file serves a whole pool:
`{{agent_name}}`, `{{swarm_name}}`, `{{workspace}}`.

```markdown
# Planner Skill
You are {{agent_name}}, the planner for {{swarm_name}}.
Break tasks into steps and delegate them with @agent_name: prefixes.
Write output to {{workspace}}.
```

Built-ins: `web.md`, `code.md`, `review.md`, `swarm_architect.md`, `swarm-fixer.md`, `secret.md`.
List/read/edit deployed skills over the API (`GET /api/skills`, `PUT .../agents/:agent/skills/:skill`).
Authoring details: [docs/skills.md](docs/skills.md). Inter-agent messaging (`@agent:`, `@all:`,
`.inbox/`/`.outbox/`): [docs/messaging.md](docs/messaging.md).

## Common gotchas

- **`genswarms clean` is not a real escript command** — it errors. Use `mix genswarms.clean` or
  `POST /api/swarms/clean`. Same for `pause`/`resume`/`delete`/`restart-agent` (Mix-task only).
- **Swarm name ≠ filename.** `swarms/example_swarm.exs` defines a swarm named `example-swarm` (from
  `name:`). Use the file path to `start`/`validate`, the hyphenated name everywhere else.
- **Agent won't start:** confirm the `subzeroclaw` binary is reachable (config → `../subzeroclaw/subzeroclaw`
  → `SUBZEROCLAW_PATH` → PATH) and `SUBZEROCLAW_API_KEY` is set (or `SUBZEROCLAW_MOCK_SCRIPT` for no-LLM).
- **Messages not routing:** the topology must permit `source -> target` (directional). Check the agent
  emits correct `@agent:` syntax; inspect `GET /api/swarms/:name/messages`.
- **`:mock` backend is a no-op stub** (spawns nothing, no responses). To run *real* agents without an
  LLM, set `SUBZEROCLAW_MOCK_SCRIPT` instead.
- **Tasks to daemon swarms are async** — queued in `.genswarms/swarms.db` (`tasks` table), polled every
  500ms. Confirm the daemon is up (`genswarms status`) and check `genswarms events --category agent`.
- **Docker agents** are named `szc-{swarm}-{agent}` and run with `--rm` (no container left on crash —
  check `genswarms events --category backend`).

More: [docs/troubleshooting.md](docs/troubleshooting.md) and [docs/observability.md](docs/observability.md).
