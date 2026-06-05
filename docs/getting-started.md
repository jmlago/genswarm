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

Every CLI command is also available through Mix as `mix genswarms.<cmd>` if you prefer not to install the binary.

## Quick start

### 1. Create a project

Scaffold a new project directory with example configs and an `.env.example`:

```bash
genswarms init my-project
cd my-project
```

### 2. Configure your environment

Copy the example file and add your LLM provider API key:

```bash
cp .env.example .env
# edit .env and set SUBZEROCLAW_API_KEY
```

The CLI loads `.env` automatically; you can also `source .env` yourself.

### 3. Start the API server

The Phoenix API server runs in the background and exposes the REST API and WebSocket:

```bash
genswarms up
genswarms status
```

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

Set these in `.env` (or your shell). Only `SUBZEROCLAW_API_KEY` is required to run real agents.

| Variable | Description | Default |
|----------|-------------|---------|
| `SUBZEROCLAW_API_KEY` | API key for the LLM provider (OpenRouter, Anthropic, OpenAI, etc.) | - |
| `SUBZEROCLAW_MODEL` | Default model for agents | `anthropic/claude-sonnet-4` |
| `SUBZEROCLAW_ENDPOINT` | API endpoint URL | Auto-detected from key |
| `SUBZEROCLAW_PATH` | Path to the `subzeroclaw` binary | `subzeroclaw` (resolved from PATH) |
| `SUBZEROCLAW_SRC` | Source directory used when building Docker containers | `../subzeroclaw` |
| `SUBZEROCLAW_MOCK_SCRIPT` | Path to a mock script JSON; skips LLM calls and is passed through to bwrap | - |
| `SUBZEROCLAW_RECORD_SCRIPT` | Path to record agent interactions for later mock replay | - |
| `SWARM_DATA_DIR` | Directory for swarm data | `~/.subzeroclaw/swarms` |
| `SWARM_TOPOLOGY` | (Container only) comma-separated targets for `swarm-msg list`; set automatically per agent | Auto-set |
| `SWARM_API_URL` | Base URL the CLI uses to reach the API server | `http://localhost:4000` |
| `SWARM_DEBUG` | Enable debug logging when set | - |
| `SECRET_KEY_BASE` | Phoenix secret key (production) | - |
| `PHX_HOST` | Phoenix host (production) | `example.com` |
| `PORT` | HTTP port for the API server | `4000` |
| `SKILLS_DIR` | Directory for skill files | `priv/skills` |

## See also

- [Configuration](configuration.md)
- [CLI reference](cli.md)
- [Backends](backends.md)
- [Troubleshooting](troubleshooting.md)
