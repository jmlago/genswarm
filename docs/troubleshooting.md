# Troubleshooting

Common problems running Genswarms and how to fix them. Most issues fall into agent startup, message routing, backend setup, task delivery, or the API server.

Before digging in, two commands surface most problems:

```bash
genswarms status [name]          # Swarm/agent lifecycle state
genswarms events --errors        # Recent error events across all swarms
```

## Agent not starting

1. Confirm the `subzeroclaw` binary is reachable. The bwrap backend searches in this order: explicit config (`subzeroclaw_path`), `../subzeroclaw/subzeroclaw` (a sibling checkout), the `SUBZEROCLAW_PATH` env var, then `PATH`. If none resolve to a regular file, the agent fails to start.
2. Verify your LLM provider key is set (`SUBZEROCLAW_API_KEY`), since agents need it to call the model. (If you are running without an LLM for testing, set `SUBZEROCLAW_MOCK_SCRIPT` instead so subzeroclaw returns canned responses.)
3. Inspect the swarm and agent state:

```bash
genswarms status example-swarm
genswarms logs example-swarm researcher
```

## Messages not routing

1. Make sure the topology allows the edge `source -> target`. The `Router` only routes along configured topology edges (system objects `:metrics`, `:tick`, and `:gateway` are always allowed without an explicit edge).
2. Check the agent is emitting the correct `@agent:` syntax, for example `@coder: please implement this`. Use `@all:` to broadcast to all connected agents.
3. Review the message log (the `limit` query param defaults to 100):

```bash
curl http://localhost:4000/api/swarms/example-swarm/messages
curl "http://localhost:4000/api/swarms/example-swarm/messages?limit=20"
```

4. As an alternative to `@agent:` syntax, agents can drop a JSON file (`{"to":"target","content":"msg"}`) into `{workspace}/.outbox/`; the LogWatcher polls that directory and routes it. Inside a container, the `swarm-msg send <target> <msg>` helper writes these files for you (it JSON-encodes the message and writes it into `/workspace/.outbox/`).

## SSH backend fails

1. Confirm key-based SSH works first: `ssh user@host` should connect without a password prompt.
2. Verify the remote `subzeroclaw` path is correct on the target host. On NixOS machines the backend defaults to skills at `/var/lib/subzeroclaw/skills` and runs the agent as the `subzeroclaw` user (via `sudo -u`); for non-NixOS hosts set `nixos: false` in the backend opts so it uses `~/.subzeroclaw/skills` and runs as the login user.
3. Ensure the remote skills/workspace directory is writable for the SSH user — skills are copied over via SFTP at startup.

## Docker backend fails

1. Check the Docker daemon is up: `docker ps`.
2. Confirm the agent image exists: `docker images`. Build images with `nix build .#agentContainer-<preset>` and `docker load < result` (presets: `base`, `web`, `code`, `data`, `python`, `node`, `full`). If the expected image is missing, the backend tries to build it via `nix` and otherwise falls back to `szc-agent-base:latest`.
3. Inspect a container's logs directly. Genswarms names containers `szc-{swarm}-{agent}`:

```bash
docker logs szc-example-swarm-coder
```

4. Containers are run with `--rm`, so a crashed agent leaves no container behind. Catch the failure in the event log instead:

```bash
genswarms events --category backend
```

## Tasks not delivered to daemon swarms

Daemon swarms (started with `genswarms start`) receive tasks through a SQLite-backed queue, not directly. The daemon polls the queue every 500ms.

1. Confirm the daemon is actually running: `genswarms status`.
2. Look for queued/processed task activity in the event log:

```bash
genswarms events --category agent
```

3. Inspect the queue itself in `.genswarms/swarms.db` (the `tasks` table) to confirm rows are inserted with status `pending` and later flipped to `processed`.
4. Check for errors:

```bash
genswarms events --errors
```

> Valid `--category` values: `backend`, `routing`, `agent`, `object`, `swarm`, `system`. Add `-s <swarm>` to scope to one swarm. `genswarms events` performs a one-shot query and prints the matching events (default limit 50); it does not continuously tail.

## API returns errors

1. Confirm the API server is up (the root path returns API info):

```bash
curl http://localhost:4000/
```

2. If a browser frontend is failing, CORS is already permissive on the API server (`origins: "*"`, all methods and headers allowed), so a CORS rejection usually points to a wrong URL or the server being down rather than a CORS policy.
3. Read the server output for the detailed error; start it in the foreground with `mix phx.server` while debugging.

## Cleaning up stuck state

If swarms are left in a `stopped` or `crashed` state, or the database accumulates stale rows, clean them up via the mix task:

```bash
mix genswarms.clean          # Remove stopped/crashed swarm entries and their files
mix genswarms.clean --all    # Also clear the event log
```

> The `clean` operation is not exposed as an escript subcommand — `genswarms clean` is not a recognized command and will error. Use the `mix genswarms.clean` task or the API route below.

Via the API, `POST /api/swarms/clean` removes stopped/crashed swarms (add `?all=true` to also clear the event log). To remove a single swarm and all of its data, `DELETE /api/swarms/:name?purge=true` stops the swarm and deletes its files, events, and queued tasks.

## See also

- [CLI reference](cli.md)
- [Backends](backends.md)
- [Observability](observability.md)
