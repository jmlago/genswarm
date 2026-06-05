# Getting started

This guide walks you through installing Genswarms, building the `genswarms` CLI, and running your first swarm end to end. By the end you will have an API server running, a swarm started from config, and a task delivered to an agent.

## Prerequisites

Genswarms is an Elixir/OTP application. You can get the toolchain either through the bundled Nix dev shell or by installing the runtimes yourself.

### With Nix (recommended)

The flake's dev shell pins the exact versions used by the project:

| Tool | Version |
|------|---------|
| Elixir | 1.17 |
| Erlang/OTP | 27 |
| Node.js | 20 |

```bash
nix develop
```

The dev shell also provides `git`, `inotify-tools`, and `colmena` (for bare-metal deploys), and sets `MIX_HOME`/`HEX_HOME` inside the project directory.

### Without Nix

Install the runtimes manually:

- Elixir 1.14+ (`mix.exs` requires `~> 1.14`; the Nix dev shell pins 1.17)
- Erlang/OTP 27+

Node.js 20 is only needed if you build agent container images.

## Install dependencies

From the project root:

```bash
mix deps.get
```

## Build the CLI

Genswarms ships a single `genswarms` CLI, built as an Elixir escript:

```bash
mix escript.build
```

This produces a `./genswarms` binary. Install it somewhere on your `PATH`:

```bash
sudo cp genswarms /usr/local/bin/   # system-wide
cp genswarms ~/.local/bin/          # user-local (ensure ~/.local/bin is on PATH)
```

### Running commands through Mix instead of the binary

Most CLI commands are also available through Mix as `mix genswarms.<cmd>`, if you
prefer not to install the binary. The escript dispatches each command to a
matching `Mix.Tasks.Genswarms.*` task (see [`lib/genswarms/cli.ex`](../lib/genswarms/cli.ex)).

For hyphenated commands the Mix task name uses an underscore, not a hyphen:

| CLI command | Mix task |
|-------------|----------|
| `genswarms start` | `mix genswarms.start` |
| `genswarms status` | `mix genswarms.status` |
| `genswarms task` | `mix genswarms.task` |
| `genswarms list-skills` | `mix genswarms.list_skills` |

> Note: `genswarms up` and `genswarms down` are convenience aliases. `up` maps to
> `mix genswarms.dashboard start`, and `down` maps to `mix genswarms.down`.
> A few task modules (such as `mix genswarms.restart_agent`) exist only as Mix
> tasks and are not wired as top-level `genswarms` subcommands.

## Quick start

### 1. Create a project

Scaffold a new project directory with example configs and an `.env.example`:

```bash
genswarms init my-project
cd my-project
```

This creates `swarms/example_swarm.exs` (a two-agent demo), example skills under
`skills/`, a `docker/` directory, and a `.genswarms/` runtime directory.

> Note: `genswarms init` prints a "Next steps" hint that still uses the legacy
> binary name `swarm` (e.g. `swarm up`, `swarm start ...`). Use `genswarms`
> instead — the commands are otherwise identical.

### 2. Configure your environment

Copy the example file and add your LLM provider API key:

```bash
cp .env.example .env
# edit .env and set SUBZEROCLAW_API_KEY
```

The CLI auto-loads `.env` from the current directory (searching up to 5 parent
directories) on every invocation; you can also `source .env` yourself. To confirm
which file was loaded, run with `SWARM_DEBUG` set — the CLI prints
`Loaded environment from <path>`.

### 3. Start the API server

The Phoenix API server runs in the background and exposes the REST API and WebSocket:

```bash
genswarms up
genswarms status
```

The server listens on `http://localhost:4000` by default (override the port with
`PORT` or `genswarms up --port <n>`).

### 4. Start a swarm

Start a swarm from a config file. Swarms run as independent daemon processes, separate from the API server:

```bash
genswarms start swarms/example_swarm.exs
```

Check its status:

```bash
genswarms status                 # server + all swarms
genswarms status example-swarm   # one swarm in detail
```

> The swarm's name (`example-swarm`) comes from the `name:` field inside the
> config, not the filename.

### 5. Send a task to an agent

```bash
genswarms task example-swarm researcher "find papers on transformers"
```

Tasks sent to a daemon swarm are queued in SQLite and picked up by the daemon, which polls the queue every 500ms.

### 6. View logs and status

```bash
genswarms logs example-swarm              # all agents
genswarms logs example-swarm researcher   # one agent
genswarms logs example-swarm -f           # follow mode
```

### 7. Stop things

```bash
genswarms stop example-swarm   # stop one swarm
genswarms down                 # stop all swarms and the API server
```

## Local data directory

Genswarms keeps cross-process state under `.genswarms/` in the project directory, including the SQLite database at `.genswarms/swarms.db` plus events and logs. This is where swarm state, the task queue, and the event log live.

## Environment variables

Set these in `.env` (or your shell). Only `SUBZEROCLAW_API_KEY` is required to run real agents. The defaults below are the values read by the code; entries marked "(production release)" only apply to the bundled release runtime config, not the CLI dev path.

| Variable | Description | Default |
|----------|-------------|---------|
| `SUBZEROCLAW_API_KEY` | API key for the LLM provider (OpenRouter, Anthropic, OpenAI, etc.) | - |
| `SUBZEROCLAW_MODEL` | Default model for agents | `anthropic/claude-sonnet-4` |
| `SUBZEROCLAW_ENDPOINT` | API endpoint URL passed through to the agent backend | Provider default (from `subzeroclaw`) |
| `SUBZEROCLAW_PATH` | Path to the `subzeroclaw` binary | `subzeroclaw` (resolved from PATH) |
| `SUBZEROCLAW_SRC` | Source directory used when building Docker containers | `../subzeroclaw` |
| `SUBZEROCLAW_MOCK_SCRIPT` | Path to a mock script JSON; passed through to the bwrap sandbox so the agent returns canned responses instead of calling the LLM | - |
| `SUBZEROCLAW_RECORD_SCRIPT` | Path passed through to the bwrap sandbox to record agent interactions for later mock replay | - |
| `SWARM_DATA_DIR` | Swarm data directory (`:swarm_data_dir` app config) | `~/.subzeroclaw/swarms` |
| `SKILLS_DIR` | Skills directory (`:skills_dir` app config) | `priv/skills` |
| `SWARM_TOPOLOGY` | (Container only) comma-separated targets for `swarm-msg list`; set automatically per agent | Auto-set |
| `SWARM_API_URL` | Base URL the CLI uses to reach the API server | `http://localhost:4000` |
| `SWARM_DEBUG` | When set, the CLI prints the loaded `.env` path on startup | - |
| `PORT` | HTTP port for the API server | `4000` |
| `SECRET_KEY_BASE` | Phoenix secret key (production release; required, no default) | - |
| `PHX_HOST` | Phoenix host. CLI/dev path defaults to `localhost`; the production release runtime defaults to `example.com` | `localhost` (CLI) / `example.com` (production release) |

## See also

- [Configuration](configuration.md)
- [CLI reference](cli.md)
- [Backends](backends.md)
- [Troubleshooting](troubleshooting.md)
