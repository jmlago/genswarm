# Genswarms documentation

The full documentation for Genswarms, an Elixir/OTP orchestrator for swarms of
subzeroclaw agents. Start with [getting started](getting-started.md), then dive
into the area you need.

## Getting started

- [Getting started](getting-started.md) — install, build the `genswarms` CLI, run your first swarm, environment variables.
- [Configuration](configuration.md) — the swarm config DSL: agents, objects, topology, backends, formats (`.exs`/`.json`/`.yaml`).
- [CLI reference](cli.md) — every `genswarms` / `mix genswarms.*` command with flags and examples.

## Core concepts

- [Architecture](architecture.md) — supervision tree, the daemon model, and deployment topologies.
- [Messaging & routing](messaging.md) — `@agent:` syntax, topology-gated routing, file inbox/outbox, the `swarm-msg` helper.
- [Objects](objects.md) — non-agentic Elixir components that participate in the topology.
- [Skills](skills.md) — per-agent markdown skills and template variables.

## Backends & deployment

- [Backends](backends.md) — Local, Docker, SSH, Bwrap, and Mock execution backends.
- [Containers](containers.md) — NixOS container images, tool presets, and bwrap sandbox internals.

## APIs

- [REST API](rest-api.md) — the complete JSON HTTP API.
- [WebSocket API](websocket.md) — real-time agent output, routing, and event streams.
- [Programmatic usage](programmatic.md) — driving Genswarms as an Elixir library.

## Operations

- [Observability](observability.md) — events, logging, and telemetry.
- [Testing](testing.md) — unit tests, the e2e harness, and the mock backend.
- [Troubleshooting](troubleshooting.md) — common problems and fixes.
