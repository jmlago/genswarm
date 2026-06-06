# Genswarms documentation

Genswarms is an Elixir/OTP orchestrator for swarms of `subzeroclaw` agents, with
pluggable backends, arbitrary directed-graph topologies, per-agent skills, and
fault tolerance via OTP supervision trees.

This is the documentation index. If you are new, start with
[Getting started](getting-started.md) and work through the area you need.

## Entry points

- [`README.md`](https://github.com/genlayerlabs/genswarms#readme) (repo root) — project overview and quick start.
- [`SKILL.md`](https://github.com/genlayerlabs/genswarms/blob/main/SKILL.md) (repo root) — the how-to-operate quick path for driving swarms via the `genswarms` CLI and REST API.
- [Getting started](getting-started.md) — the full first-swarm walkthrough.

## Getting started

- [Getting started](getting-started.md) — install, build the `genswarms` CLI, run your first swarm, and the key environment variables.
- [Configuration](configuration.md) — the swarm config DSL: agents, objects, topology, backends, and the `.exs` / `.json` / `.yaml` formats.
- [CLI reference](cli.md) — every `genswarms` / `mix genswarms.*` command with its flags and examples.

## Operating

- [Messaging](messaging.md) — the `@agent:` syntax, topology-gated routing, file inbox/outbox, and the `swarm-msg` helper.
- [Skills](skills.md) — per-agent markdown skills and the `{{agent_name}}` / `{{swarm_name}}` / `{{workspace}}` template variables.
- [Objects](objects.md) — non-agentic Elixir components that participate in the topology and run deterministic code.
- [Observability](observability.md) — the event spine: events, logging, telemetry, and streaming.
- [Testing and development](testing.md) — ExUnit unit tests, the e2e harness (`mix genswarms.test`), and the Mock backend.
- [Troubleshooting](troubleshooting.md) — common problems with startup, routing, backends, tasks, and the API server.

## Architecture and internals

- [Architecture](architecture.md) — the OTP supervision tree, the daemon model, and supported deployment topologies.
- [Backends](backends.md) — the Local, Docker, SSH, Bwrap, and Mock execution backends and the shared backend contract.
- [Containers and sandboxes](containers.md) — NixOS container images, tool presets, and the bwrap sandbox internals.

## Reference

- [REST API](rest-api.md) — the complete pure-JSON HTTP API served by Phoenix.
- [WebSocket API](websocket.md) — real-time agent output, message routing, and event streams over the `swarm:{name}` channel.
- [Programmatic API](programmatic.md) — driving Genswarms directly as an Elixir library.
