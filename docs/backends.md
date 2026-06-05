# Backends

A backend is how Genswarms actually runs a subzeroclaw agent. Every agent in a swarm config declares a `backend:`, and Genswarms uses the matching backend module to start the process, send it input, deploy skills, and health-check it. All backends implement the same `Genswarms.Backends.BackendBehaviour` contract, so they are interchangeable from the swarm's point of view — you can move an agent from `:local` to `{:docker, "researcher"}` to `:bwrap` without changing anything else in your topology.

This guide covers each backend: how it runs, the config it accepts, and what you need on the host.

## The backend contract

Every backend implements `Genswarms.Backends.BackendBehaviour` (`lib/genswarms/backends/backend_behaviour.ex`). The callbacks are:

| Callback | Required? | Purpose |
|----------|-----------|---------|
| `start/2` | yes | Start the agent process; returns `{:ok, ref}` or `{:error, term}` |
| `stop/1` | yes | Stop the running agent |
| `send_input/2` | yes | Write a message to the agent's stdin |
| `deploy_skills/2` | yes | Make skills available to the agent |
| `health_check/1` | yes | Report whether the agent is alive (`:ok` or `{:error, reason}`) |
| `backend_type/0` | yes | Return the backend's atom (e.g. `:local`) |
| `handle_output/2` | optional | Parse raw output into messages |

`handle_output/2` is the only `@optional_callbacks` entry. The behaviour declares its return as `{:ok, [map()]}`, but the backends that implement it (local and bwrap) actually return `{:ok, messages, remaining}` — the leftover `remaining` binary is the partial line carried into the next chunk.

All backends share the same wire protocol: subzeroclaw is run through the `szc-wrapper` script, which translates between JSON lines and subzeroclaw's plain-text interface. Output is parsed line-by-line into JSON messages; any line that is not valid JSON falls back to `%{"type" => "output", "content" => line}`.

## Choosing a backend

| Backend | When to use | Isolation level |
|---------|-------------|-----------------|
| `:local` | Development, debugging, single-host runs | None (plain subprocess) |
| `{:docker, "name"}` | Reproducible tool environments, per-agent images | Container (namespaces + image) |
| `{:ssh, "user@host"}` | Bare-metal / remote NixOS machines | Remote host |
| `:bwrap` | Massive scale (10k+ agents on one box) | Lightweight sandbox (user namespaces) |
| `:mock` | Tests without LLM calls | None (no process spawned) |

Three LLM settings are read by every *real* backend (local, docker, ssh, bwrap). Each one is taken from the agent config first and falls back to the process environment when not set: `api_key` / `SUBZEROCLAW_API_KEY`, `model` / `SUBZEROCLAW_MODEL`, and `endpoint` / `SUBZEROCLAW_ENDPOINT`. The `:mock` backend ignores them — it never spawns a process.

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

| Config key | Purpose | Resolution order |
|------------|---------|------------------|
| `wrapper_path` | Path to the wrapper script | config `:wrapper_path` → app env `:wrapper_path` → `priv/szc-wrapper-fifo.sh` |
| `subzeroclaw_path` | Path to the subzeroclaw binary | config `:subzeroclaw_path` → app env `:subzeroclaw_path` → `"subzeroclaw"` (from `PATH`) |
| `api_key` | LLM API key | config → `SUBZEROCLAW_API_KEY` env |
| `model` | Model identifier | config → `SUBZEROCLAW_MODEL` env |
| `endpoint` | LLM endpoint | config → `SUBZEROCLAW_ENDPOINT` env |

The wrapper is invoked as `<wrapper_path> <name> <subzeroclaw_path> <skills_dir>`. When a `skills_dir` is present, its expanded path is also exported to the subprocess as the `SUBZEROCLAW_SKILLS` environment variable; the agent name is exported as `SUBZEROCLAW_AGENT_NAME`.

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

Containers are named `szc-{swarm}-{agent}` unless you override the name with the `container` key. The swarm name is part of the name, so the same agent name in two different swarms maps to two distinct containers and they never collide. On start, if a container with that name already exists (running, paused, exited, or otherwise), it is forcibly removed (`docker rm -f`) and recreated. The container itself is run with `docker run -i --rm`, so it is also removed automatically when it exits.

### Image selection

The image is chosen in this order:

1. An explicit `image` key.
2. The `container` name used as an image.
3. A pre-built image matched from `presets` (sorted), e.g. `[:base, :web]` → `szc-agent-web:latest`. Unknown combinations fall back to `szc-agent-base:latest`.
4. The default `szc-agent-base:latest`.

If the chosen image is not present locally, the backend attempts to build it with `nix build .#agentContainer-<preset>` (where `<preset>` is derived from `presets`, defaulting to `full` for unrecognized combinations) and then `docker load -i result`. If the build fails the failure is logged and the backend proceeds with the originally selected image name — so make sure your preset images either build or already exist locally.

### Docker options

| Config key | Purpose |
|------------|---------|
| `container` | Explicit container name; also used as an image candidate |
| `image` | Explicit image to run |
| `presets` | NixOS tool presets used to pick/build the image |
| `workspace` | Host path mounted at `/workspace` (default `/tmp/szc-workspace`) |
| `volumes` | Extra mounts as `[{host_path, container_path}]` |
| `network` | Docker network to attach (`--network`) |
| `memory_limit` | Memory cap (`--memory`) |
| `cpu_limit` | CPU cap (`--cpus`) |
| `env` | Extra env vars (a map); `${VAR}` / `$VAR` are expanded from the host. Empty/`nil` values are dropped |
| `cmd` | Override the in-container command |
| `api_key` / `model` / `endpoint` | LLM settings (fall back to env) |

The skills directory, if set, is mounted read-only at `/skills`, and a sibling `logs/` directory is mounted at `/root/.subzeroclaw/logs`. The workspace is mounted at `/workspace` (unless your own `volumes` already mount something under `/workspace`), the host `/tmp` is shared, and the subzeroclaw source directory is mounted read-only at `/src/subzeroclaw` for in-container compilation. Agent name and LLM settings are passed as `-e` env vars, and topology connections are exported as `SWARM_TOPOLOGY` so `swarm-msg list` works inside the container.

Requirements: Docker, and Nix if you want images built on demand. For details on NixOS containers, presets, and how the images are assembled, see [containers.md](containers.md).

## SSH

The SSH backend (`lib/genswarms/backends/ssh_backend.ex`) runs subzeroclaw on a remote machine over an SSH connection. It targets bare-metal NixOS hosts that have been provisioned (via Colmena) with the agent module — tools installed, skills directory at `/var/lib/subzeroclaw/skills`, and a `subzeroclaw` user set up — but also works on plain hosts.

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
| `key_path` | Private key path | keys in `~/.ssh` |
| `password` | Password auth (added alongside any key) | none |
| `nixos` | Treat host as a provisioned NixOS machine | `true` |
| `remote_skills_dir` | Where skills are deployed | `/var/lib/subzeroclaw/skills` (NixOS) or `~/.subzeroclaw/skills` |
| `remote_user` | User to run the agent as (NixOS only) | `subzeroclaw` |
| `subzeroclaw_path` | Remote binary path | `subzeroclaw` |
| `api_key` / `model` / `endpoint` | LLM settings (fall back to env) | — |

Authentication: if `key_path` points to an existing file, its directory is used as the SSH `user_dir`; otherwise the backend falls back to `~/.ssh`. A `password`, if given, is added in addition. Host keys are accepted automatically (`silently_accept_hosts: true`, `user_interaction: false`), so this backend trusts whatever host it connects to — pin keys yourself if that matters.

When `nixos: true`, the agent is launched as the `remote_user` (`subzeroclaw` by default) via `sudo -u <user> env … subzeroclaw`. On non-NixOS hosts set `nixos: false`; the agent then runs as the SSH login user (the `remote_user` key is ignored), and you must install subzeroclaw and its tools yourself. If a local `skills_dir` is set, its files are copied to the remote skills directory over SFTP at start time (and again on each `deploy_skills` call). The agent is started with `SUBZEROCLAW_AGENT_NAME`, `SUBZEROCLAW_SKILLS`, and the LLM env vars set on the remote command line.

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
| `extra_env` | Extra environment variables (a map) injected into the sandbox | `%{}` |
| `memory_limit` | cgroup memory cap | `"256M"` |
| `cpu_shares` | cgroup CPU shares | `100` |
| `tasks_max` | Max tasks/processes in the cgroup | `50` |
| `subzeroclaw_path` | Explicit binary path | resolved (see below) |
| `presets` | Sandbox base layers to overlay | `[:base]` |

`sandbox_id` is `{swarm}-{agent}-{timestamp_ms}`. Resource limits are enforced by wrapping the bwrap command in a `systemd-run` cgroup scope. Inside the sandbox, the overlay's merged directory is bound as `/`, the skills directory is bind-mounted read-only at `/root/.subzeroclaw/skills`, a sibling `logs/` directory is bound writable at `/root/.subzeroclaw/logs`, the workspace is bound at `/workspace`, and the Nix store is mounted read-only so binaries resolve. `extra_ro_binds` entries are only mounted if the host path exists. The sandbox runs with `--unshare-{user,pid,uts,ipc}` as uid/gid 1000, with `PATH` defaulting to `/bin:/usr/local/bin` (your `extra_path` dirs are prepended).

> Note: `extra_rw_binds` is listed as a bwrap backend key in the project conventions (it is accepted in agent config without error), but the current backend implements only `extra_ro_binds` (read-only) for extra mounts — `extra_rw_binds` is silently ignored. Use `workspace` for the agent's writable area.

### Binary path resolution

The bwrap backend locates the `subzeroclaw` binary in this order (first existing regular file wins):

1. Explicit `subzeroclaw_path` in config, or the `:subzeroclaw_path` application env (used directly if the file exists).
2. `../subzeroclaw/subzeroclaw` relative to the current working directory (sibling checkout).
3. `../subzeroclaw/subzeroclaw` relative to the Genswarms source dir (when Genswarms is used as a dependency).
4. The `SUBZEROCLAW_PATH` environment variable.
5. The system `PATH` (via `which subzeroclaw`).

### Mock and recording inside the sandbox

If `mock_script` is set in config or `SUBZEROCLAW_MOCK_SCRIPT` is set in the environment, it is passed into the sandbox as `SUBZEROCLAW_MOCK_SCRIPT`, so bwrap agents can run without LLM calls. If the `SUBZEROCLAW_RECORD_SCRIPT` environment variable is set (any value), subzeroclaw records responses to `/workspace/.recorded_responses.json` inside the sandbox.

Requirements: NixOS with bubblewrap and fuse-overlayfs, unprivileged user namespaces enabled (`kernel.unprivileged_userns_clone = 1`), `/run/swarm` mounted as tmpfs, and pre-built sandbox base layers (`nix build .#sandboxBase-*`). Base layers are resolved from `/run/swarm/sandbox-base/<preset-name>` (plus any dirs in the `:extra_preset_dirs` app env), falling back to `base` when a preset is missing. For the NixOS setup, preset/base-layer internals, and overlay/cgroup details, see [containers.md](containers.md).

## Mock

The mock backend (`lib/genswarms/backends/mock_backend.ex`) spawns no external process at all. It is a stub: it accepts input (returning `:ok` and discarding it) and produces no output. Use it to exercise swarm orchestration — topology, routing, dynamic add/remove/scale — without any agent runtime or LLM cost.

```elixir
%{name: :worker, backend: :mock}
```

It also accepts an optional `script` (`{:mock, %{script: [...]}}`), but the backend only stores that script on its ref for introspection — it does **not** match against it or generate responses (`send_input/2` and `handle_output/2` are no-ops). The bare `:mock` form is what the test suite and examples use.

> Producing canned LLM responses (with a `match`/`response` script) is a feature of **subzeroclaw**, not of the `:mock` backend. To run *real* agents (local/docker/bwrap) without calling an LLM, point them at a subzeroclaw mock script via the `SUBZEROCLAW_MOCK_SCRIPT` environment variable, or use `mix genswarms.test --mock script.json`. See [testing.md](testing.md).

## See also

- [configuration.md](configuration.md) — the swarm config DSL and how `backend:` fits in
- [containers.md](containers.md) — NixOS containers, tool presets, and bwrap base-layer internals
- [testing.md](testing.md) — using the mock backend with `mix genswarms.test`
- [troubleshooting.md](troubleshooting.md) — diagnosing backend startup and connection failures
