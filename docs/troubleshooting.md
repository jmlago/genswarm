# Troubleshooting

Common problems running Genswarms and how to fix them. Most issues fall into agent startup, message routing, backend setup, task delivery, or the API server.

## Agent not starting

1. Confirm the `subzeroclaw` binary is reachable: it must be on `PATH` or pointed to by `SUBZEROCLAW_PATH`. The bwrap backend also searches `../subzeroclaw/subzeroclaw` (a sibling checkout) before falling back to `PATH`.
2. Verify your LLM provider key is set (`SUBZEROCLAW_API_KEY`), since agents need it to call the model.
3. Inspect the swarm and agent state:

```bash
genswarms status example-swarm
genswarms logs example-swarm researcher
```

## Messages not routing

1. Make sure the topology allows the edge `source -> target`. The `Router` only routes along configured topology edges (system objects like `:metrics`, `:tick`, and `:gateway` are always allowed).
2. Check the agent is emitting the correct `@agent:` syntax, for example `@coder: please implement this`. Use `@all:` to broadcast to all connected agents.
3. Review the message log:

```bash
curl http://localhost:4000/api/swarms/example-swarm/messages
```

4. As an alternative to `@agent:` syntax, agents can drop a JSON file into `{workspace}/.outbox/`; the LogWatcher polls that directory and routes it.

## SSH backend fails

1. Confirm key-based SSH works first: `ssh user@host` should connect without a password prompt.
2. Verify the remote `subzeroclaw` path is correct on the target host.
3. Ensure the remote skills/workspace directory is writable for the SSH user.

## Docker backend fails

1. Check the Docker daemon is up: `docker ps`.
2. Confirm the agent image exists: `docker images`. Build images with `nix build .#agentContainer-<preset>` and `docker load < result`.
3. Inspect a container's logs directly. Genswarms names containers `szc-{swarm}-{agent}`:

```bash
docker logs szc-example-swarm-coder
```

## Tasks not delivered to daemon swarms

Daemon swarms receive tasks through a SQLite-backed queue, not directly. The daemon polls the queue every 500ms.

1. Confirm the daemon is actually running: `genswarms status`.
2. Look for queued/processed task activity in the event log:

```bash
genswarms events --category agent
```

3. Inspect the queue itself in `.genswarms/swarms.db` (the `tasks` table) to confirm rows are being inserted and marked processed.
4. Check for errors:

```bash
genswarms events --errors
```

## API returns errors

1. Confirm the API server is up:

```bash
curl http://localhost:4000/
```

2. If a browser frontend is failing, verify CORS allows your origin (CORS is enabled on the API server).
3. Read the server output for the detailed error; start it in the foreground with `mix phx.server` while debugging.

## See also

- [CLI reference](cli.md)
- [Backends](backends.md)
- [Observability](observability.md)
