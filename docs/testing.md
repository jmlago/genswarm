# Testing and development

Genswarms ships two layers of tests: fast ExUnit unit tests for individual modules
and an end-to-end harness (`mix genswarms.test`) that validates and runs the example
swarm configurations. A mock backend lets you exercise topologies and routing
without any LLM API calls. This page covers both, plus formatting, static analysis,
and the development server.

## Unit tests

Run the ExUnit suite with `mix test`:

```bash
mix test                                            # run all tests
mix test --cover                                    # run with coverage report
mix test test/genswarms/routing/router_test.exs     # a single file
mix test test/genswarms/routing/router_test.exs:42  # a single test by line
mix test --only tag_name                            # only tests with a given tag
```

Tests run with the synchronous `EventStore.Sqlite` backend (configured in
`config/test.exs`) for determinism, rather than the buffered default. Key test
files include:

| File | Covers |
|---|---|
| `test/genswarms/agents/agent_protocol_test.exs` | `@agent:` message parsing |
| `test/genswarms/routing/router_test.exs` | message routing (incl. system objects) |
| `test/genswarms/config/loader_test.exs` | config loading (`.exs`/`.json`/`.yaml`) |
| `test/genswarms/config/swarm_config_test.exs` | config validation |
| `test/genswarms/agents/inbox_test.exs` | the message queue |

## Formatting

```bash
mix format    # format all source per .formatter.exs
```

Run `mix format` before committing; CI and reviewers expect formatted code.

## End-to-end harness

`mix genswarms.test` discovers, validates, and runs every example. It:

1. Discovers all swarm configs (`.exs`) and sim files (`.sim`) under `examples/`.
2. Validates each one.
3. Runs each (starts the swarm, waits for completion or the timeout).
4. Captures full logs per example.
5. Reports pass/fail for each, with a combined summary.

```bash
mix genswarms.test                           # validate + run all examples
mix genswarms.test --validate-only           # only validate configs, don't run
mix genswarms.test --example tic-tac-toe     # test a specific example
mix genswarms.test --mock script.json        # run with the mock backend (no LLM)
mix genswarms.test --timeout 60000           # custom timeout per swarm (ms)
mix genswarms.test --steps 3                 # steps for .sim examples
mix genswarms.test --logs-dir /tmp/logs      # custom logs directory
mix genswarms.test --quiet                   # suppress per-example info lines
```

### Flags

| Flag | Type | Default | Purpose |
|---|---|---|---|
| `--validate-only` | boolean | off | Validate configs only; skip running |
| `--example <name>` | string | all | Only examples whose path contains `/<name>/` |
| `--timeout <ms>` | integer | `60000` | Per-swarm run timeout in milliseconds |
| `--steps <n>` | integer | `3` | Steps for `.sim` examples |
| `--mock <path>` | string | none | Set `SUBZEROCLAW_MOCK_SCRIPT` for LLM-free runs |
| `--logs-dir <path>` | string | `.test-logs` | Directory for captured run logs |
| `--quiet` | boolean | off | Suppress per-example info output |

### Output

Each example writes a `<name>.log` to the logs directory (default `.test-logs/`),
plus a combined `summary.log`:

```
.test-logs/
├── tic_tac_toe_swarm.log
├── party_swarm.log
└── summary.log
```

The task exits with code `0` if all examples pass and `1` if any fail. With
`--mock`, the given script path is expanded and exported as `SUBZEROCLAW_MOCK_SCRIPT`
so agents use canned responses instead of calling the LLM API.

## Testing without an LLM

There are two distinct ways to avoid real LLM calls; they serve different goals.

### The `:mock` backend — test orchestration

`backend: :mock` is a stub that spawns no process and produces no agent output.
It is for testing swarm **orchestration** — topology, routing, and dynamic
add/remove/scale — deterministically and instantly:

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

It does not generate responses (see [backends.md](backends.md)), so it does not
exercise agent reasoning — only the machinery around agents.

### `--mock` / `SUBZEROCLAW_MOCK_SCRIPT` — run real agents with canned responses

To run *real* agents (local/docker/bwrap) end to end without calling an LLM, give
subzeroclaw a mock script:

```bash
mix genswarms.test --mock path/to/script.json
```

This expands the path and exports it as `SUBZEROCLAW_MOCK_SCRIPT`, which is passed
through to the agents (including bwrap sandboxes). Subzeroclaw — not Genswarms —
reads the script and returns canned responses instead of calling the API. The
script format is defined by subzeroclaw.

## Development server

Start the Phoenix API server (REST + WebSocket, no HTML) for local development:

```bash
mix phx.server
```

The server defaults to port `4000` (override with the `PORT` environment variable).
A typical loop is to start the server, then drive it from the CLI or HTTP client:

```bash
genswarms start examples/tic-tac-toe/swarm.exs   # start a swarm as a daemon
genswarms events --follow                         # watch the event stream live
```

## See also

- [backends.md](backends.md) — backend types including the mock backend
- [cli.md](cli.md) — `genswarms` command reference
- [configuration.md](configuration.md) — swarm config DSL and validation
