# Backends

A backend is how Genswarms actually runs a subzeroclaw agent. Every agent in a swarm config declares a `backend:`, and Genswarms uses the matching backend module to start the process, send it input, deploy skills, and health-check it. All backends implement the same `Genswarms.Backends.BackendBehaviour` contract, so they are interchangeable from the swarm's point of view — you can move an agent from `:local` to `{:docker, "researcher"}` to `:bwrap` without changing anything else in your topology.

This guide covers each backend: how it runs, the config it accepts, and what you need on the host.

## The backend contract

Every backend implements `Genswarms.Backends.BackendBehaviour` (`lib/genswarms/backends/backend_behaviour.ex`). The required callbacks are:

| Callback | Purpose |
|----------|---------|
| `start/2` | Start the agent process; returns `{:ok, ref}` |
| `stop/1` | Stop the running agent |
| `send_input/2` | Write a message to the agent's stdin |
| `deploy_skills/2` | Make skills available to the agent |
| `health_check/1` | Report whether the agent is alive |
| `backend_type/0` | Return the backend's atom (e.g. `:local`) |
| `handle_output/2` | Optional; parse raw output into messages |

All backends share the same wire protocol: subzeroclaw is run through the `szc-wrapper` script, which translates between JSON lines and subzeroclaw's plain-text interface. Output is parsed line-by-line into JSON messages (invalid lines fall back to `%{"type" => "output", "content" => line}`).

## Choosing a backend

| Backend | When to use | Isolation level |
|---------|-------------|-----------------|
| `:local` | Development, debugging, single-host runs | None (plain subprocess) |
| `{:docker, "name"}` | Reproducible tool environments, per-agent images | Container (namespaces + image) |
| `{:ssh, "user@host"}` | Bare-metal / remote NixOS machines | Remote host |
| `:bwrap` | Massive scale (10k+ agents on one box) | Lightweight sandbox (user namespaces) |
| `:mock` | Tests without LLM calls | None (no process spawned) |

Common environment variables are honoured by all real backends and fall back to the process environment when not set in config: `SUBZEROCLAW_API_KEY`, `SUBZEROCLAW_MODEL`, and `SUBZEROCLAW_ENDPOINT`.

## Local

The local backend (`lib/genswarms/backends/local_backend.ex`) spawns subzeroclaw as an Elixir `Port` subprocess and communicates over stdin/stdout. It is the simplest backend and the easiest to debug, but provides no isolation — the agent runs as your user with full access to the host.

```elixir
%{
  name: :researcher,
  backend: :local,
  skills: ["research.md"],
  model: "anthropic/claude-sonnet-4"
}
```

It launches the `szc-wrapper` script, which in turn runs the `subzeroclaw` binary. Both paths are resolved from config or application environment:

| Config key | Purpose | Default |
|------------|---------|---------|
| `wrapper_path` | Path to the wrapper script | `priv/szc-wrapper-fifo.sh`, or `:wrapper_path` app env |
| `subzeroclaw_path` | Path to the subzeroclaw binary | `"subzeroclaw"` (from PATH), or `:subzeroclaw_path` app env |
| `api_key` | LLM API key | `SUBZEROCLAW_API_KEY` env |
| `model` | Model identifier | `SUBZEROCLAW_MODEL` env |
| `endpoint` | LLM endpoint | `SUBZEROCLAW_ENDPOINT` env |

Skills, when present, are passed to the wrapper and exported as `SUBZEROCLAW_SKILLS`.

Requirements: a `subzeroclaw` binary on the host (on `PATH` or via `subzeroclaw_path`).

## Docker

The Docker backend (`lib/genswarms/backends/docker_backend.ex`) runs each agent in a NixOS-based container. It is the right choice when agents need specific, reproducible tool sets, since the tools are baked into the image rather than your host.

```elixir
%{
  name: :coder,
  backend: {:docker, "coder"},
  presets: [:base, :code],
  skills: ["code.md"]
}
```

You can also pass options as a third tuple element:

```elixir
%{
  name: :coder,
  backend: {:docker, "coder", %{memory_limit: "512m", network: "swarmnet"}},
  skills: ["code.md"]
}
```

### Container naming and multi-swarm namespacing

Containers are named `szc-{swarm}-{agent}` unless you override the name with the `container` key. The swarm name is part of the name, so the same agent name in two different swarms maps to two distinct containers and they never collide. On start, if a container with that name already exists (running, paused, exited, or otherwise), it is forcibly removed and recreated.

### Image selection

The image is chosen in this order: an explicit `image` key, then the `container` name as an image, then a pre-built image matched from `presets`, and finally the default `szc-agent-base:latest`. If the chosen image is not present locally, the backend attempts to build it with `nix build .#agentContainer-<preset>` and `docker load`, falling back to the base image if the build fails.

### Docker options

| Config key | Purpose |
|------------|---------|
| `container` | Explicit container name / image |
| `image` | Explicit image to run |
| `presets` | NixOS tool presets used to pick/build the image |
| `workspace` | Host path mounted at `/workspace` (default `/tmp/szc-workspace`) |
| `volumes` | Extra mounts as `[{host_path, container_path}]` |
| `network` | Docker network to attach (`--network`) |
| `memory_limit` | Memory cap (`--memory`) |
| `cpu_limit` | CPU cap (`--cpus`) |
| `env` | Extra env vars; `${VAR}` / `$VAR` are expanded from the host |
| `cmd` | Override the in-container command |
| `api_key` / `model` / `endpoint` | LLM settings (fall back to env) |

The skills directory is mounted read-only at `/skills`, a logs directory is mounted under `/root/.subzeroclaw/logs`, `/tmp` is shared, and the subzeroclaw source is mounted read-only for in-container compilation. Topology connections are exported as `SWARM_TOPOLOGY` so `swarm-msg list` works inside the container.

Requirements: Docker, and Nix if you want images built on demand. For details on NixOS containers, presets, and how the images are assembled, see [containers.md](containers.md).

## SSH

The SSH backend (`lib/genswarms/backends/ssh_backend.ex`) runs subzeroclaw on a remote machine over an SSH connection. It targets bare-metal NixOS hosts that have been provisioned with the agent module (tools installed, skills directory and `subzeroclaw` user set up), but also works on plain hosts.

```elixir
%{
  name: :researcher,
  backend: {:ssh, "agent@192.168.1.51", %{
    key_path: "~/.ssh/id_ed25519",
    nixos: true
  }},
  presets: [:base, :web],
  skills: ["web.md"]
}
```

### SSH options

| Config key | Purpose | Default |
|------------|---------|---------|
| `host` | `user@host` (taken from the tuple) | required |
| `port` | SSH port | `22` |
| `key_path` | Private key path | `~/.ssh` keys |
| `password` | Password auth (alternative to key) | none |
| `nixos` | Treat host as a provisioned NixOS machine | `true` |
| `remote_skills_dir` | Where skills are deployed | `/var/lib/subzeroclaw/skills` (NixOS) or `~/.subzeroclaw/skills` |
| `remote_user` | User to run the agent as | `subzeroclaw` (NixOS) |
| `subzeroclaw_path` | Remote binary path | `subzeroclaw` |
| `api_key` / `model` / `endpoint` | LLM settings (fall back to env) | — |

When `nixos: true`, the agent is launched as the `subzeroclaw` user via `sudo`; on non-NixOS hosts set `nixos: false` and ensure subzeroclaw and its tools are installed manually. If a local `skills_dir` is set, its files are copied to the remote skills directory over SFTP. Host keys are accepted automatically (`silently_accept_hosts`).

Requirements: SSH access to the host; on non-NixOS hosts, subzeroclaw and tools installed yourself.

## Bwrap

The bubblewrap backend (`lib/genswarms/backends/bwrap_backend.ex`) sandboxes each agent with Linux user namespaces instead of a full container. It is built for scale — roughly 500KB RAM and ~50ms startup per agent — which is what makes 10k+ agents on a single NixOS machine practical, with no external daemon.

```elixir
# Defaults
%{
  name: :researcher,
  backend: :bwrap,
  skills: ["web.md"]
}

# With options
%{
  name: :coder,
  backend: {:bwrap, %{memory_limit: "256M", presets: [:base, :code]}},
  skills: ["code.md"]
}
```

### Backend keys

Bwrap config separates backend keys (which control the sandbox) from domain keys (your application logic). The backend reads:

| Config key | Purpose | Default |
|------------|---------|---------|
| `workspace` | Host dir bound at `/workspace` | `/tmp/szc-workspace/{sandbox_id}` |
| `extra_path` | Extra dirs prepended to `PATH` inside the sandbox | `[]` |
| `extra_ro_binds` | Read-only mounts as `[{host_path, container_path}]` | `[]` |
| `extra_env` | Extra environment variables injected into the sandbox | `[]` |
| `memory_limit` | cgroup memory cap | `"256M"` |
| `cpu_shares` | cgroup CPU shares | `100` |
| `tasks_max` | Max tasks/processes in the cgroup | `50` |
| `subzeroclaw_path` | Explicit binary path | resolved (see below) |
| `presets` | Sandbox base layers to overlay | `[:base]` |

Resource limits are enforced by wrapping the bwrap command in a `systemd-run` cgroup scope. The skills directory is bind-mounted read-only at `/root/.subzeroclaw/skills`, logs are bound at `/root/.subzeroclaw/logs`, and the Nix store is mounted read-only so binaries resolve.

> Note: `extra_rw_binds` is documented as a bwrap backend key in the project conventions, but the current backend implements only `extra_ro_binds` (read-only) for extra mounts. Use `workspace` for the agent's writable area.

### Binary path resolution

The bwrap backend locates the `subzeroclaw` binary in this order (first existing regular file wins):

1. Explicit `subzeroclaw_path` in config, or the `:subzeroclaw_path` application env.
2. `../subzeroclaw/subzeroclaw` relative to the current working directory (sibling checkout).
3. `../subzeroclaw/subzeroclaw` relative to the Genswarms source dir (when Genswarms is used as a dependency).
4. The `SUBZEROCLAW_PATH` environment variable.
5. The system `PATH` (via `which subzeroclaw`).

### Mock and recording inside the sandbox

If `mock_script` is set in config or `SUBZEROCLAW_MOCK_SCRIPT` is set in the environment, it is passed into the sandbox as `SUBZEROCLAW_MOCK_SCRIPT`, so bwrap agents can run without LLM calls. If `SUBZEROCLAW_RECORD_SCRIPT` is set, responses are recorded to `/workspace/.recorded_responses.json` inside the sandbox.

Requirements: NixOS with bubblewrap and fuse-overlayfs, unprivileged user namespaces enabled, and pre-built sandbox base layers. For the NixOS setup, preset/base-layer internals, and overlay/cgroup details, see [containers.md](containers.md).

## Mock

The mock backend (`lib/genswarms/backends/mock_backend.ex`) spawns no external process at all. It is a stub: it accepts input, produces no output, and stores what it received so tests can introspect it. Use it to exercise swarm orchestration — topology, routing, dynamic add/remove/scale — without any agent runtime or LLM cost.

```elixir
%{name: :worker, backend: :mock}
```

It also accepts an optional `script` (`{:mock, %{script: [...]}}`), but the backend only stores that script for introspection — it does **not** match against it or generate responses. The bare `:mock` form is what the test suite and examples use.

> Producing canned LLM responses (with a `match`/`response` script) is a feature of **subzeroclaw**, not of the `:mock` backend. To run *real* agents (local/docker/bwrap) without calling an LLM, point them at a subzeroclaw mock script via the `SUBZEROCLAW_MOCK_SCRIPT` environment variable, or use `mix genswarms.test --mock script.json`. See [testing.md](testing.md).

## See also

- [configuration.md](configuration.md) — the swarm config DSL and how `backend:` fits in
- [containers.md](containers.md) — NixOS containers, tool presets, and bwrap base-layer internals
- [testing.md](testing.md) — using the mock backend with `mix genswarms.test`
- [troubleshooting.md](troubleshooting.md) — diagnosing backend startup and connection failures
