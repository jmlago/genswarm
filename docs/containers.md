# Containers and sandboxes

Genswarms runs agents inside isolated execution environments built with Nix. Two
families of environment share the same tool presets: NixOS-based Docker images
(for the `{:docker, "name"}` backend) and Bubblewrap sandboxes (for the `:bwrap`
backend, designed for 10k+ agents on a single host). This page covers the build
targets, the preset catalogue, and the internals that assemble each environment.

Everything here is reproducible: images and sandbox bases are pinned by Nix
flake inputs (`nixpkgs` nixos-24.11), so the same tools resolve identically
across machines.

## Build targets

Container images are exposed as flake packages in `flake.nix`. Build one, then
load the result tarball into Docker. Each image is named `szc-agent-<name>:latest`.

```bash
nix build .#agentContainer-code
docker load < result
docker run --rm szc-agent-code:latest swarm-msg list
```

| Build target | Presets included | Use case |
|--------------|------------------|----------|
| `agentContainer-base` | `base` | Minimal agent with core utilities |
| `agentContainer-web` | `base`, `web` | Web research, HTTP APIs |
| `agentContainer-code` | `base`, `code` | Software development |
| `agentContainer-data` | `base`, `data` | Data processing, CSV/JSON |
| `agentContainer-full` | `base`, `web`, `code`, `data`, `python`, `node` | Full-featured agent |
| `agentContainer-python` | `base`, `python`, `data` | Python development |
| `agentContainer-node` | `base`, `node`, `web` | Node.js development |
| `agentContainer-devops` | `base`, `code`, `containers`, `cloud` | DevOps / cloud operations |

The preset-to-image mapping is defined in `nix/container.nix` (the `images`
attribute set) and wired to flake packages in `flake.nix`.

Each image also bundles, regardless of preset: `bashInteractive`, `coreutils`,
`cacert` (SSL certificates), the Nix package manager (so agents can run
`nix-shell -p ...` at runtime), the `szc-wrapper` protocol script, and the
`swarm-msg` messaging CLI. Working directory is `/workspace`; `/workspace`,
`/skills`, and `/tmp` are declared as volumes. The image also sets
`SSL_CERT_FILE`/`NIX_SSL_CERT_FILE`, `NIX_PATH`, and `TMPDIR` so HTTPS and
runtime `nix-shell` both work out of the box (see the `config.Env` block in
`nix/container.nix`).

### Building on demand

You don't have to pre-build images. When a Docker agent starts, the backend
(`lib/genswarms/backends/docker_backend.ex`) maps the agent's `presets` to a
pre-built image name and, if the image is missing locally, runs
`nix build .#agentContainer-<name>` and `docker load` automatically before
launching. Only the eight preset combinations in the table above have a direct
mapping; any other combination falls back to the `full` image at build time and
the `szc-agent-base:latest` image at run time.

### Custom images

Call `mkAgentContainer` from your own flake to add domain packages. The builder
lives in `nix/container.nix` and is re-exported via
`genswarms.lib.<system>.mkAgentContainer`.

```nix
{
  inputs.genswarms.url = "github:genlayer/genswarms";

  outputs = { self, nixpkgs, genswarms, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.my-agent =
        genswarms.lib.x86_64-linux.mkAgentContainer {
          name = "my-agent";
          presets = [ "base" "code" "python" ];
          tools = [ "ripgrep" "fd" "jq" ];      # names from the tools map
          extraPackages = with pkgs; [ postgresql redis ];
        };
    };
}
```

`mkAgentContainer` accepts `name`, `presets` (default `[ "base" ]`), `tools`
(individual names resolved against the tools map, then nixpkgs), `extraPackages`
(direct nixpkgs derivations), and `subzeroclawBinary` (optional path to a
subzeroclaw binary to bake in). Build with
`nix build .#my-agent && docker load < result`. The resulting image is named
`szc-agent-<name>:latest`.

### Orchestrator release

The agent container targets above are for *agents*. The Phoenix orchestrator
itself is packaged as a Nix mix release (not a Docker image — there is no
`Dockerfile` in the repo):

```bash
nix build .#orchestrator    # builds a prod mix release of the orchestrator
```

There is also a `genswarms-cli` package that builds the CLI escript as a
standalone derivation. For day-to-day use you usually run the orchestrator
directly from the dev shell (`genswarms up` / `mix phx.server`) rather than from
a built release — see [getting-started.md](getting-started.md).

## Tool presets

Presets are named groups of packages defined in `nix/tool-presets.nix`. They are
the single source of truth shared by Docker images, bwrap sandboxes, and the
NixOS agent module. Agents reference presets by name in their config.

| Preset | Tools |
|--------|-------|
| `base` | coreutils, bash, gnugrep, gnused, gawk, findutils, which, less, file, curl, jq |
| `web` | curl, wget, httpie, jq, yq, htmlq, w3m, lynx |
| `code` | git, git-lfs, gnumake, gcc, ripgrep, fd, tree, diff-so-fancy, delta, bat, tokei |
| `python` | python312, pip, virtualenv, requests, beautifulsoup4, pandas, numpy |
| `node` | nodejs_20, npm, yarn, pnpm |
| `data` | jq, yq, csvkit, miller, sqlite, duckdb, xsv |

`base` is the safe default and is included by every pre-built image. `curl` and
`jq` are in `base` because subzeroclaw needs `curl` for API calls and the
`szc-wrapper` needs `jq` for JSON protocol translation.

Additional presets also exist in `nix/tool-presets.nix` for specialized agents:
`docs` (pandoc, texlive scheme-small, poppler_utils, ghostscript, imagemagick),
`network` (curl, wget, httpie, netcat, socat, openssh, rsync, aria2), `system`
(htop, btop, lsof, strace, procps, psmisc, pciutils, usbutils), `security`
(openssl, gnupg, age, sops, pass), `containers` (docker-client, podman, skopeo,
dive), `cloud` (awscli2, google-cloud-sdk, azure-cli, kubectl, k9s, terraform),
and `ai` (openai, anthropic, tiktoken Python packages). These are not bundled
into any pre-built image except where the table above lists them; reach them via
a custom image or a custom sandbox base.

### Individual tools

For fine-grained control, `nix/tool-presets.nix` also exposes a `tools` map that
aliases friendly names to packages (for example `rg` and `ripgrep` both resolve
to ripgrep, `python3` to python312, `gh` to the GitHub CLI). Names listed in an
agent's `tools` are looked up in this map first, then fall back to a direct
nixpkgs attribute.

### Using presets in agent config

Reference presets and tools directly in the agent config. For Docker agents the
preset selection is baked into the image you build; for bwrap agents presets are
resolved at deploy time against pre-built sandbox bases (see below).

```elixir
%{
  name: :coder,
  backend: {:docker, "code"},
  presets: [:base, :code],
  skills: ["code.md"]
}
```

See [configuration.md](configuration.md) for the full agent schema and how
`presets`/`tools` are applied, and [backends.md](backends.md) for backend tuple
forms and options.

## Multi-swarm namespacing

Docker containers are namespaced by swarm name: each agent runs as a container
named `szc-{swarm}-{agent}` (set in `lib/genswarms/backends/docker_backend.ex`,
overridable per agent with the `container` config key). This lets multiple
swarms run on one host without collision.

Pause and resume operate per swarm by acting on that swarm's containers only:

```bash
docker pause szc-{swarm}-{agent}
docker unpause szc-{swarm}-{agent}
```

The orchestrator issues these for every agent in the named swarm, so pausing one
swarm never freezes another.

## Bwrap sandbox internals

The bwrap backend trades container isolation for far lower overhead, targeting
10k+ agents on a single NixOS machine. It reuses the exact same tool presets as
the Docker images but assembles them as overlay filesystems rather than images.

### Sandbox bases

`nix/bwrap-sandbox.nix` builds a read-only Nix environment per preset
combination using `pkgs.buildEnv`. Each base contains the resolved preset
packages plus the same core set as containers (`bashInteractive`, `coreutils`,
`cacert`, `nix`, the `szc-wrapper` script, and `swarm-msg`), linking `/bin`,
`/lib`, `/share`, and `/etc`. Build a base with:

```bash
nix build .#sandboxBase-code
```

The sandbox bases actually defined in `nix/bwrap-sandbox.nix` (and therefore
buildable) are:

| Flake target | Presets |
|--------------|---------|
| `sandboxBase-base` | `base` |
| `sandboxBase-web` | `base`, `web` |
| `sandboxBase-code` | `base`, `code` |
| `sandboxBase-data` | `base`, `data` |
| `sandboxBase-python` | `base`, `python`, `data` |
| `sandboxBase-node` | `base`, `node`, `web` |
| `sandboxBase-full` | `base`, `web`, `code`, `data`, `python`, `node` |
| `sandboxBase-devops` | `base`, `code`, `containers`, `cloud` |

> **Note:** `flake.nix` also declares `sandboxBase-web-code`,
> `sandboxBase-code-python`, and `sandboxBase-data-python`, but no matching
> `sandboxLib.web-code` / `code-python` / `data-python` attributes exist in
> `nix/bwrap-sandbox.nix`, so those three targets fail to evaluate. To get a
> mixed-preset base (for example `code` + `python`), build a custom base with
> `mkSandboxBase` (see *Preset resolution and custom presets* below) rather than
> relying on those declarations.

At runtime the bases are resolved by *directory name* under
`/run/swarm/sandbox-base/`, not by flake target name. The
`services.subzeroclaw-bwrap` NixOS module (`nix/bwrap-module.nix`) symlinks the
bases listed in its `sandboxPresets` option into that directory; the directory
name for a multi-preset agent is the sorted, `-`-joined preset list (see below).

### Overlay assembly

Per-agent isolation comes from `fuse-overlayfs` (userspace overlay, no root
required). For each agent, `lib/genswarms/backends/bwrap/overlay_manager.ex`
creates a directory tree and mounts the union:

```
/run/swarm/
  sandbox-base/<preset>   # symlink to the pre-built Nix environment (lowerdir)
  agents/<sandbox-id>/
    upper/                # per-agent writable layer (copy-on-write)
    work/                 # overlayfs workdir
    merged/               # union mount the agent actually runs in
```

```bash
fuse-overlayfs -o lowerdir=<base>,upperdir=<upper>,workdir=<work> <merged>
```

The shared sandbox base is the read-only lower layer; each agent gets a private
writable upper layer, so thousands of agents share one copy of the tools. Before
the agent starts, `/etc/resolv.conf` and `/etc/hosts` are copied into the upper
layer's `etc/` so DNS and hostname resolution work (the base `/etc` is
read-only). The agent then runs inside `merged/` via Bubblewrap, with the
`szc-wrapper` script bind-mounted at `/usr/local/bin/szc-wrapper` and the
subzeroclaw binary at `/usr/local/bin/subzeroclaw`. On shutdown the overlay is
unmounted (`fusermount -u`) and the per-agent directory tree is removed
(`File.rm_rf`).

### Resource isolation

Each agent is placed in its own systemd cgroup so a runaway agent can't starve
its neighbors. `lib/genswarms/backends/bwrap/cgroup_manager.ex` wraps the bwrap
command in a transient `systemd-run --user` unit under the `subzeroclaw.slice`,
named `szc-<sandbox-id>`. The backend config keys map to systemd properties:

| Config key | Default | systemd property |
|------------|---------|------------------|
| `memory_limit` | `"256M"` | `MemoryMax` |
| `cpu_shares` | `100` | `CPUWeight` |
| `tasks_max` | `50` | `TasksMax` |

Because every scope lives under one slice, you can monitor aggregate usage with
`systemd-cgtop` or via `CgroupManager.get_aggregate_stats/0`, and stop a single
agent by terminating its scope. Per-agent memory, CPU, and task counts are read
directly from the cgroup filesystem (`memory.current`, `cpu.stat`,
`pids.current`).

### Preset resolution and custom presets

Presets in the agent config map to a base directory name by sorting the preset
atoms and joining with `-` (so `[:code, :base]` resolves to the `base-code`
base). Resolution searches `/run/swarm/sandbox-base` plus any directories
registered by a downstream project:

```elixir
Application.put_env(:genswarms, :extra_preset_dirs, ["/my/presets"])
```

If a named preset directory is not found in any search dir, resolution falls
back to the `base` layer (logging a warning). You can also point an agent at a
fully custom base layer directly with a `{:custom, "/path/to/base"}` entry in
its `presets` list — this path is expanded and used verbatim as the overlay
lowerdir, and `{:custom, _}` entries are excluded from the sorted directory-name
computation.

To build a domain-specific base, copy `nix/preset-template.nix` into your
project as `preset.nix`, set `name`, choose `presets`, add `extraPackages`,
build it, and symlink the result into a preset search directory:

```bash
nix-build preset.nix
ln -sf $(readlink result) ./presets/solidity
```

The template uses `sandboxLib.mkSandboxBase` (also re-exported as
`genswarms.lib.<system>.mkSandboxBase`), so a custom base is byte-for-byte
compatible with the built-in ones.

### Backend config keys

The bwrap config separates backend keys from domain keys. Backend keys
recognized by the sandbox: `workspace`, `presets`, `memory_limit` (default
`"256M"`), `cpu_shares` (default `100`), `tasks_max` (default `50`),
`extra_ro_binds` (`[{host_path, container_path}]`, mounted read-only and skipped
silently if the host path is missing), `extra_path` (directories prepended to
the in-sandbox PATH, ahead of `/bin:/usr/local/bin`), `extra_env`
(`%{KEY => value}` extra environment variables), and `subzeroclaw_path` (path to
the subzeroclaw binary).

```elixir
%{
  name: :worker,
  backend: :bwrap,
  config: %{
    workspace: "/tmp/my-workspace",
    presets: [:base, :code],
    memory_limit: "256M",
    extra_path: ["/opt/tools/bin"],
    extra_ro_binds: [{"/home/user/project", "/project"}]
  }
}
```

See [backends.md](backends.md) for the complete bwrap key reference, binary path
resolution, and host requirements (the `services.subzeroclaw-bwrap` NixOS module
in `nix/bwrap-module.nix` provisions kernel limits, the `/run/swarm` tmpfs, the
`subzeroclaw.slice`, and symlinks the sandbox bases).

## See also

- [backends.md](backends.md) — backend tuple forms, bwrap config keys, binary resolution
- [configuration.md](configuration.md) — agent schema, presets and tools in config
- [architecture.md](architecture.md) — how backends fit into the supervision tree
