# CLI reference

The `genswarms` command-line interface manages the full lifecycle of a swarm: creating projects, starting and stopping swarms, sending tasks and messages, querying events, and performing advanced runtime operations like scaling and snapshotting. This page documents every subcommand, grounded in the actual task modules under `lib/mix/tasks/genswarms/`.

## Building and invoking the CLI

Build the standalone escript binary with Mix:

```bash
mix escript.build   # produces ./genswarms in the project root
```

Every subcommand can be invoked two ways, with the same arguments and flags:

```bash
# As the escript binary
genswarms status
genswarms start swarms/example-swarm.exs

# As a Mix task (dot-separated subcommand)
mix genswarms.status
mix genswarms.start swarms/example-swarm.exs
```

A `.env` file in the working directory is auto-loaded before most commands run.

### Global help and version

```bash
genswarms                 # print help (command list + examples)
genswarms help            # same as above
genswarms version         # print version
genswarms --version       # print version
genswarms -v              # print version
```

Most commands also accept `--help` / `-h` for command-specific usage:

```bash
genswarms start --help
genswarms events -h
```

## Command table

| Command | Description |
|---------|-------------|
| `init` | Create a new swarm project with standard directory structure |
| `up` | Start the Phoenix server (REST API + WebSocket) in the background |
| `down` | Stop the dashboard and/or running swarms |
| `dashboard` | Start, stop, or check the web dashboard |
| `start` | Start a swarm from a config file (daemon by default) |
| `stop` | Stop a running swarm daemon |
| `restart` | Restart a swarm, reloading its config |
| `restart-agent` | Restart a single agent in a running swarm (via the API server) |
| `pause` | Pause a swarm by freezing its Docker containers |
| `resume` | Resume a paused swarm |
| `delete` | Delete a swarm and all of its data |
| `clean` | Remove stopped/crashed swarms (optionally clear all events) |
| `status` | Show status of all swarms or one swarm in detail |
| `logs` | View or stream agent logs and conversation history |
| `events` | Query and stream events from the centralized event store |
| `task` | Send a task to an agent |
| `msg` | Route a message between two agents |
| `env` | Manage environment variables in `.env` files |
| `build` | Build agent Docker images via Nix |
| `config validate` | Validate one or more config files (alias: `check`) |
| `list-skills` | List available skills |
| `scale` | Scale an agent group in a running swarm to a target count |
| `overlay` | Inspect or clear a swarm's dynamic-mutation overlay |
| `snapshot` | Emit a swarm's effective config (seed + overlay) as `.exs` |

## Server

### `up`

Start the Phoenix server (REST API + WebSocket, plus the dev dashboard) in the background. Pass `--foreground` to run it inline instead.

```bash
genswarms up                 # start on default port (4000 or $PORT)
genswarms up --port 3000     # custom port
genswarms up --foreground    # run inline instead of backgrounding
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--port PORT` | `-p` | Port to run on (default: 4000 or `$PORT`) |
| `--foreground` | `-f` | Run in foreground instead of background |

### `down`

Stop running services. With no flags it stops both swarms and the dashboard.

```bash
genswarms down                   # stop everything
genswarms down --dashboard-only  # only the dashboard
genswarms down --swarms-only     # only swarms
```

| Flag | Description |
|------|-------------|
| `--dashboard-only` | Only stop the dashboard |
| `--swarms-only` | Only stop swarms |

### `dashboard`

Start, stop, or check the web dashboard. The dashboard runs independently of swarms.

```bash
genswarms dashboard               # start (default subcommand)
genswarms dashboard start -p 3000 # start on port 3000
genswarms dashboard stop          # stop
genswarms dashboard status        # check whether it is running
```

Subcommands: `start` (default), `stop`, `status`.

| Flag | Alias | Description |
|------|-------|-------------|
| `--port PORT` | `-p` | Port to run on (default: 4000 or `$PORT`) |
| `--foreground` | `-f` | Run in foreground instead of background |

## Swarm lifecycle

### `init`

Scaffold a new project (`.env`, `swarms/`, `skills/`, `docker/`, etc.).

```bash
genswarms init                  # in the current directory
genswarms init my-project       # into a new directory
genswarms init ~/projects/swarm # absolute path
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--force` | `-f` | Overwrite existing files in a non-empty directory |

### `start`

Start a swarm from a config file (`.exs` / `.json` / `.yaml`). Runs as a background daemon by default; state is tracked in `.genswarms/swarms.db`.

```bash
genswarms start swarms/example-swarm.exs
genswarms start swarms/example-swarm.exs --foreground
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--foreground` | `-f` | Run in foreground instead of daemon mode |

### `stop`

Stop a running swarm daemon (sends SIGTERM and updates the registry).

```bash
genswarms stop example-swarm
```

### `restart`

Stop then start a swarm, reloading its config file so config changes take effect.

```bash
genswarms restart example-swarm           # normal restart
genswarms restart example-swarm --delete  # clean restart (wipe old logs/events/data)
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--delete` | `-d` | Delete all logs, events, and data before restarting |

### `pause`

Freeze every Docker container belonging to the swarm (`docker pause szc-<swarm>-<agent>`). Processes are suspended but containers stay alive.

```bash
genswarms pause example-swarm
```

### `resume`

Unfreeze all paused Docker containers in the swarm.

```bash
genswarms resume example-swarm
```

### `delete`

Stop the swarm if running, remove it from the registry, and delete all of its events, logs, and data files.

```bash
genswarms delete example-swarm
genswarms delete example-swarm --force
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--force` | `-f` | Skip the confirmation prompt |

### `clean`

Remove all stopped and crashed swarms (and their files) from the registry.

```bash
genswarms clean           # clean stopped/crashed swarms
genswarms clean --all     # also clear all events from the database
genswarms clean --force   # skip confirmation
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--all` | | Also clear all events from the database |
| `--force` | `-f` | Skip the confirmation prompt |

### `status`

Show all registered swarms, or detailed status (agents, objects, topology, backends, skills) for one.

```bash
genswarms status                # all swarms
genswarms status example-swarm  # detailed view of one swarm
```

## Agent operations

### `task`

Send a task to a specific agent. If the API server is running the task is delivered over HTTP; otherwise it is queued in SQLite for the daemon to pick up.

```bash
genswarms task example-swarm researcher "Summarize the latest findings"
```

Usage: `genswarms task <swarm> <agent> <task>`

### `msg`

Route a message from one agent to another. The route is validated against the swarm topology before sending; an invalid route lists the valid targets and exits non-zero.

```bash
genswarms msg example-swarm researcher coder "Can you review this code?"
```

Usage: `genswarms msg <swarm> <from> <to> <message>`

### `restart-agent`

Restart a single agent in a running swarm. This requires the API server to be running.

```bash
genswarms restart-agent example-swarm researcher
```

Usage: `genswarms restart-agent <swarm> <agent>`

### `logs`

View or stream agent logs and conversation history.

```bash
genswarms logs example-swarm                # all agents, conversation only
genswarms logs example-swarm researcher     # one agent
genswarms logs example-swarm researcher -f  # stream in real time
genswarms logs example-swarm --stdout       # show stdout output
genswarms logs example-swarm --events       # all agent events
genswarms logs example-swarm --all          # everything
genswarms logs example-swarm --tail 100     # last 100 entries
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--follow` | `-f` | Stream logs in real time |
| `--tail N` | `-n` | Show the last N entries (default: 50) |
| `--stdout` | | Show agent stdout output |
| `--events` | | Show all agent events (tasks, messages, lifecycle) |
| `--conversation` | | Show conversation only (default) |
| `--all` | | Show all log types |

## Observability and events

### `events`

Query and stream events from the centralized event store. With no flags it prints the last 50 events.

```bash
genswarms events                          # last 50 events
genswarms events --errors                 # errors only
genswarms events --errors -n 5            # errors from the last 5 minutes
genswarms events -s example-swarm         # filter by swarm
genswarms events -s example-swarm -a coder# filter by swarm + agent
genswarms events --category backend       # backend events only
genswarms events --type message_routed    # filter by event type
genswarms events --limit 200              # raise the result cap
genswarms events --follow                 # stream in real time
genswarms events --stats                  # event statistics
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--errors` | `-e` | Show only error-level events |
| `--warnings` | `-w` | Show warnings and errors |
| `--minutes N` | `-n` | Only events from the last N minutes |
| `--swarm NAME` | `-s` | Filter by swarm name |
| `--agent NAME` | `-a` | Filter by agent name |
| `--category CAT` | | Filter by category: `backend`, `routing`, `agent`, `object`, `swarm`, `system` |
| `--type TYPE` | | Filter by event type (e.g. `stdout`, `message_routed`, `task_sent`) |
| `--limit N` | | Maximum events to return (default: 50) |
| `--follow` | `-f` | Stream events in real time |
| `--stats` | | Show event statistics |

See [observability.md](observability.md) for the full category/event-type catalog.

## Config and skills

### `config validate`

Validate one or more config files using the real loader: file format, required fields, agent/object config, topology validity, skill-file existence, and handler-module existence. Globs are expanded. `check` is a shorthand alias.

```bash
genswarms config validate swarms/example-swarm.exs
genswarms config validate "swarms/*.exs"
genswarms config validate config.json --quiet
genswarms check swarms/example-swarm.exs   # alias
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--quiet` | `-q` | Only output errors |

### `list-skills`

List all skills available in the skills repository.

```bash
genswarms list-skills
```

### `env`

Manage variables in a `.env` file. Sensitive values (matching key, secret, token, etc.) are masked in `list` output.

```bash
genswarms env list                          # list all variables
genswarms env get SUBZEROCLAW_API_KEY       # read one variable
genswarms env set PORT 3000                 # set a variable
genswarms env unset DEBUG                    # remove a variable
genswarms env list --file .env.production    # use a different file
```

Subcommands: `list` (default), `get <key>`, `set <key> <value>`, `unset <key>`.

| Flag | Alias | Description |
|------|-------|-------------|
| `--file FILE` | `-f` | Use a specific `.env` file (default: `.env`) |

### `build`

Build agent Docker images via Nix (falling back to a `docker build` if no flake is found). Available images: `base`, `python`, `node`, `elixir`.

```bash
genswarms build base              # build one image
genswarms build --all             # build all images
genswarms build base --push       # build and push (requires DOCKER_REGISTRY)
genswarms build base --tag v1.0   # custom tag
genswarms build base --no-cache   # rebuild without cache
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--all` | `-a` | Build all images |
| `--push` | `-p` | Push to registry after building |
| `--tag TAG` | `-t` | Custom tag (default: `latest`) |
| `--no-cache` | | Build without cache |

## Advanced: dynamic swarm operations

These commands operate on the runtime state of a swarm. Additions and removals are recorded in an *overlay* that is replayed at start so dynamic state survives a restart.

### `scale`

Scale an agent group to a target count. The group is identified by `base-name`; members are named `<base-name>_1`, `<base-name>_2`, .... Extra members are stopped, missing ones are created from an existing member's spec.

```bash
genswarms scale example-swarm researcher 20
```

Usage: `genswarms scale <swarm> <base-name> <count>` — `count` must be a non-negative integer. This command takes no flags.

### `overlay`

Inspect or clear the dynamic-mutation overlay (the event log of runtime additions/removals).

```bash
genswarms overlay example-swarm           # list overlay events
genswarms overlay example-swarm --clear   # wipe the overlay
```

| Flag | Description |
|------|-------------|
| `--clear` | Wipe the overlay, returning the swarm to its pure seed state |

### `snapshot`

Emit a swarm's effective configuration (seed combined with overlay) as an `.exs` source. This does not modify the original config file; the output is a declarative seed you can load with `start`.

```bash
genswarms snapshot example-swarm                    # write to stdout
genswarms snapshot example-swarm --output seed.exs  # write to a file
```

| Flag | Alias | Description |
|------|-------|-------------|
| `--output FILE` | `-o` | Write the snapshot to a file instead of stdout |

## See also

- [getting-started.md](getting-started.md) — first swarm, end to end
- [rest-api.md](rest-api.md) — HTTP API behind several of these commands
- [configuration.md](configuration.md) — the config DSL validated by `config validate`
- [observability.md](observability.md) — event categories and types for `events`
