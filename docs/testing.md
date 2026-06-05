# Testing and development

Genswarms ships two layers of tests: fast ExUnit unit tests for individual modules
and an end-to-end harness (`mix genswarms.test`) that validates and runs the example
swarm configurations. A mock backend lets you exercise topologies and routing
without any LLM API calls. This page covers both, plus formatting and the
development server.

## Unit tests

Run the ExUnit suite with `mix test`:

```bash
mix test                                            # run all tests
mix test --cover                                    # run with coverage report
mix test test/genswarms/routing/router_test.exs     # a single file
mix test test/genswarms/routing/router_test.exs:42  # a single test by line
mix test --only tag_name                            # only tests with a given tag
```

Tests run with the synchronous `EventStore.Sqlite` backend (set in `config/test.exs`
via `config :genswarms, :event_store, Genswarms.Observability.EventStore.Sqlite`) so
that persist→query is deterministic, rather than the buffered default. The same
config disables the Phoenix endpoint (`server: false`) and lowers the log level to
`:warning`. Key test files include:

| File | Covers |
|---|---|
| `test/genswarms/agents/agent_protocol_test.exs` | `@agent:` message parsing |
| `test/genswarms/routing/router_test.exs` | message routing (incl. system objects) |
| `test/genswarms/config/loader_test.exs` | config loading (`.exs`/`.json`/`.yaml`/`.yml`) |
| `test/genswarms/config/swarm_config_test.exs` | config validation |
| `test/genswarms/agents/inbox_test.exs` | the message queue |

## Formatting

```bash
mix format    # format all source per .formatter.exs
```

Run `mix format` before committing; CI and reviewers expect formatted code.

## End-to-end harness

`mix genswarms.test` discovers, validates, and runs every example. It:

1. Discovers all swarm configs (`.exs`) and sim files (`.sim`) recursively under `examples/`.
2. Validates each one.
3. Runs each (starts the swarm, waits the full timeout, then stops it).
4. Captures a per-example log.
5. Reports pass/fail/skip for each, with a combined summary.

```bash
mix genswarms.test                           # validate + run all examples
mix genswarms.test --validate-only           # only validate configs, don't run
mix genswarms.test --example tic-tac-toe     # test a specific example
mix genswarms.test --mock script.json        # run real agents with the mock script (no LLM)
mix genswarms.test --timeout 60000           # custom timeout per swarm (ms)
mix genswarms.test --steps 3                 # steps for .sim examples
mix genswarms.test --logs-dir /tmp/logs      # custom logs directory
mix genswarms.test --quiet                   # suppress per-example info lines
```

### Flags

All flags use `--flag value` (single dash, hyphenated) form and are parsed in
strict mode — unknown flags are dropped silently.

| Flag | Type | Default | Purpose |
|---|---|---|---|
| `--validate-only` | boolean | off | Validate configs only; skip running. No logs directory or `summary.log` is written. |
| `--example <name>` | string | all | Keep only files whose path contains the literal substring `/<name>/` |
| `--timeout <ms>` | integer | `60000` | Per-swarm/per-sim run timeout in milliseconds |
| `--steps <n>` | integer | `3` | Number of steps for `.sim` examples (ignored by `.exs` configs) |
| `--mock <path>` | string | none | Expand `<path>` and export it as `SUBZEROCLAW_MOCK_SCRIPT` for LLM-free runs |
| `--logs-dir <path>` | string | `.test-logs` | Directory for captured run logs (expanded with `Path.expand/1`) |
| `--quiet` | boolean | off | Suppress per-example info output (failures are still printed) |

The `--example` filter matches a path *segment*, so it works against the
directory name. For instance, `--example tic-tac-toe` selects
`examples/tic-tac-toe/tic_tac_toe_swarm.exs` because the path contains
`/tic-tac-toe/`. The bundled example directories are: `bridge`, `bwrap-skills`,
`dynamic-swarm`, `massive-swarm`, `party`, and `tic-tac-toe`.

### Output

Unless `--validate-only` is set, each example writes a `<name>.log` to the logs
directory (default `.test-logs/`), plus a combined `summary.log`. The log
filename is derived from the swarm **name** (the config `:name`, not the file
path), sanitized by replacing every character outside `[a-zA-Z0-9_-]` with `_`
(so hyphens and underscores are preserved). For the bundled examples, whose
config names are `tic-tac-toe` and `party-test`, the resulting files are:

```
.test-logs/
├── tic-tac-toe.log
├── party-test.log
└── summary.log
```

A per-example `.log` records the relative path, swarm name, agent/object counts,
topology, timeout, and the final status (or `TIMEOUT` / `ERROR`). The
`summary.log` contains the `N passed, N failed, N skipped` header followed by one
`✓`/`✗`/`⊘` line per example.

Exit codes:

- `0` — all examples passed (or were skipped).
- `1` — at least one example failed, **or** no `.exs`/`.sim` files were found under `examples/`.

With `--validate-only`, no logs directory is created and no `summary.log` is
written — results are printed to the console only.

A run is a **skip** (`⊘`) when an `.exs` file evaluates to something that is **not
a map** (the `(not a swarm config)` case), or when a `.sim` file is found but
`SubzeroSim` is not available in the project. Note that an `.exs` file evaluating
to a map *without* a `:name` key is **not** a skip — it counts as a **pass**
(reported as `(valid map config)`); only a swarm config (a map *with* a `:name`
key) is actually started and run.

## Testing without an LLM

There are two distinct ways to avoid real LLM calls; they serve different goals.

### The `:mock` backend — test orchestration

`backend: :mock` is a stub that spawns no external process and produces no agent
output. It is for testing swarm **orchestration** — topology, routing, and
dynamic add/remove/scale — deterministically and instantly:

```elixir
%{
  name: "test-swarm",
  agents: [
    %{name: :researcher, backend: :mock},
    %{name: :coder, backend: :mock}
  ],
  topology: [{:researcher, :coder}]
}
```

`MockBackend.send_input/2` and `deploy_skills/2` are no-ops, and `handle_output/2`
always returns empty output, so the backend does not exercise agent reasoning —
only the machinery around agents. An optional `%{script: [...]}` (via
`{:mock, %{script: [...]}}`) is stored on the backend struct for introspection
but is never used to generate responses. See [backends.md](backends.md).

### `--mock` / `SUBZEROCLAW_MOCK_SCRIPT` — run real agents with canned responses

To run *real* agents (local/docker/bwrap) end to end without calling an LLM, give
subzeroclaw a mock script:

```bash
mix genswarms.test --mock path/to/script.json
```

The task expands the path with `Path.expand/1` and exports it as
`SUBZEROCLAW_MOCK_SCRIPT`, which is passed through to the agents (including bwrap
sandboxes). The `subzeroclaw` runtime — not Genswarms — reads the script and
returns canned responses instead of calling the API. The script format is
defined by subzeroclaw.

You can also set `SUBZEROCLAW_MOCK_SCRIPT` directly in the environment to get the
same behavior outside the test harness.

## Development server

Start the Phoenix API server (REST + WebSocket, no HTML) for local development:

```bash
mix phx.server
```

The server defaults to port `4000` (override with the `PORT` environment variable).
A typical loop is to start the server, then drive it from the CLI or HTTP client:

```bash
genswarms start examples/tic-tac-toe/tic_tac_toe_swarm.exs   # start a swarm as a daemon
genswarms events --follow                                     # watch the event stream live
```

## See also

- [backends.md](backends.md) — backend types including the mock backend
- [cli.md](cli.md) — `genswarms` command reference
- [configuration.md](configuration.md) — swarm config DSL and validation
