# Swarm configuration

The Swarm Configuration DSL is the declarative format that defines a swarm: its name, its agents and objects, and the topology that connects them. Configs can be written as Elixir (`.exs`), JSON (`.json`), or YAML (`.yaml`/`.yml`) and are validated by `Genswarms.Config.SwarmConfig` when loaded.

## Top-level structure

A configuration is a map with the following keys.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | string or atom | Yes | Unique swarm identifier. Must start with a letter and contain only alphanumerics, `_`, or `-`. Atoms are converted to strings. |
| `agents` | list of maps | Yes | One or more agent definitions. Must be non-empty. |
| `objects` | list of maps | No | Non-agentic Elixir/backend components. Defaults to `[]`. |
| `topology` | list of `{from, to}` tuples | No | Directed communication edges. Defaults to `[]`. |
| `skills_base_dir` | string | No | Base directory to resolve skill files from. Stored on the parsed struct; not otherwise validated. |
| `options` | map | No | Free-form additional settings. Defaults to `%{}`. |

```elixir
%{
  name: "example-swarm",
  agents: [
    %{name: :researcher, backend: :local, skills: ["web.md"]},
    %{name: :coder, backend: {:docker, "coder"}, skills: ["code.md"]}
  ],
  objects: [],
  topology: [
    {:researcher, :coder},
    {:coder, :researcher}
  ]
}
```

## Agent configuration

Each entry in `agents` is a map. Only the keys below are recognized by the validator and serializer; unknown keys are passed through into the agent map but are not validated.

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `name` | atom or string | Yes | — | Unique agent identifier. Strings are normalized to atoms. |
| `backend` | backend spec | No | `:bwrap` | Where/how the agent runs (see [Backend value forms](#backend-value-forms)). If omitted, the parser fills in `:bwrap`. |
| `model` | string | No | — | LLM model in OpenRouter format (`provider/model-name`). When unset, the backend passes through `SUBZEROCLAW_MODEL`; `subzeroclaw` itself falls back to `anthropic/claude-sonnet-4`. |
| `endpoint` | string | No | — | API endpoint URL. When unset, the backend passes through `SUBZEROCLAW_ENDPOINT`; otherwise `subzeroclaw` auto-detects from the API key. |
| `skills` | list of strings | No | `[]` | Skill markdown filenames to deploy. All entries must be strings. |
| `presets` | list of atoms | No | `[]` | NixOS tool presets. Must be drawn from the valid preset set below. |
| `tools` | list of atoms | No | `[]` | Individual tools. Must be drawn from the valid tool set below. |
| `config` | map | No | `%{}` | Backend-specific and domain-specific configuration (see [Bwrap config separation](#bwrap-config-separation)). |

```elixir
%{
  name: :researcher,
  backend: :local,
  model: "anthropic/claude-sonnet-4",
  endpoint: "https://openrouter.ai/api/v1/chat/completions",
  skills: ["web.md", "summarize.md"],
  presets: [:base, :web]
}
```

### Valid presets

Presets are validated against the `@valid_presets` set in `Genswarms.Config.SwarmConfig` (the corresponding NixOS package sets live in `nix/tool-presets.nix`):

`:base`, `:web`, `:code`, `:python`, `:node`, `:data`, `:docs`, `:network`, `:system`, `:security`, `:containers`, `:cloud`, `:ai`

A `presets` value that is not a list of atoms fails with `:invalid_presets_format`.

### Valid tools

Individual tools are validated against the complete `@valid_tools` set in `Genswarms.Config.SwarmConfig`:

`:git`, `:curl`, `:wget`, `:jq`, `:yq`, `:tree`, `:htop`, `:ripgrep`, `:rg`, `:fd`, `:fzf`, `:ag`, `:vim`, `:neovim`, `:nano`, `:python`, `:python3`, `:node`, `:nodejs`, `:ruby`, `:go`, `:rustc`, `:cargo`, `:make`, `:cmake`, `:gcc`, `:clang`, `:sqlite`, `:postgresql`, `:mysql`, `:redis`, `:duckdb`, `:pandoc`, `:pdftotext`, `:ssh`, `:rsync`, `:netcat`, `:httpie`, `:docker`, `:podman`, `:kubectl`, `:gh`, `:glab`, `:miller`, `:csvkit`, `:xsv`, `:ffmpeg`, `:imagemagick`, `:pytest`, `:ruff`, `:mypy`, `:black`, `:flake8`, `:pip`, `:poetry`, `:uv`.

A `tools` value that is not a list of atoms fails with `:invalid_tools_format`. Atoms outside the set above fail with `{:unknown_tools, invalid}` (where `invalid` is the list of offending atoms); likewise unknown presets fail with `{:unknown_presets, invalid}`.

## Backend value forms

The `backend` key accepts any of the following forms. See [backends.md](backends.md) for behavioral details.

| Form | Backend | Notes |
|------|---------|-------|
| `:local` | Local | Runs as an Elixir Port subprocess. |
| `{:docker, "name"}` | Docker | Container image/name; resolves to `%{image: "name"}`. |
| `{:docker, "name", %{opts}}` | Docker | Options map merged over `%{image: "name"}`. |
| `{:ssh, "user@host"}` | SSH | Resolves to `%{host: "user@host"}`. |
| `{:ssh, "user@host", %{opts}}` | SSH | Options map merged over `%{host: ...}`. |
| `:bwrap` | Bwrap | Bubblewrap sandbox; default when `backend` is omitted. |
| `{:bwrap, %{opts}}` | Bwrap | Options map (see below). |
| `:mock` | Mock | No process; a stub for testing. |
| `{:mock, %{script: [...]}}` | Mock | `script` is stored for test introspection only — the backend does not generate responses (see [backends.md](backends.md)). |

Any other value fails validation with `{:invalid_backend, backend}`.

> JSON/YAML limitation: the loader only converts a **scalar string** backend to an atom (`"local"` → `:local`, `"bwrap"` → `:bwrap`, `"mock"` → `:mock`, etc.). It does **not** turn an array like `["docker", "coder"]` into a `{:docker, "coder"}` tuple, so array-form backends reach the validator unchanged and fail. Tuple-form backends (Docker/SSH, or any form with an options map) can therefore only be expressed in `.exs` configs. JSON/YAML configs are limited to the scalar string backends.

## Bwrap config separation

For bwrap agents, the agent's `config` map is split at deploy time (in `Genswarms.Agents.AgentServer`) into backend keys and domain keys. Backend keys override the values returned by `SwarmConfig.backend_config/1` and control the execution environment; all remaining keys stay as domain config available to the agent's skills and logic.

The backend keys are:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `workspace` | string | `/tmp/szc-workspace/<sandbox_id>` | Working directory mounted read-write into the sandbox. |
| `extra_path` | list of strings | `[]` | Additional directories prepended to `PATH`. |
| `extra_ro_binds` | list of `{host, container}` | `[]` | Extra read-only bind mounts. |
| `extra_rw_binds` | list of `{host, container}` | `[]` | Split out of `config`, but **not currently applied** by the backend (only `extra_ro_binds` is mounted). Use `workspace` for writable space. |
| `extra_env` | map | `%{}` | Extra environment variables passed into the sandbox. |
| `memory_limit` | string | `"256M"` | Memory ceiling (e.g. `"512M"`). |
| `cpu_shares` | integer | `100` | Relative CPU weight. |
| `tasks_max` | integer | `50` | Max number of tasks/processes. |
| `subzeroclaw_path` | string | resolved | Explicit path to the `subzeroclaw` binary. |
| `presets` | list of atoms | `[:base]` | The same agent-level `presets` key (above), forwarded to the sandbox. The bwrap backend falls back to `[:base]` when none are given. |

Any key in `config` not listed above (for example `population_size` or `max_iterations`) is preserved as domain config and is not interpreted by the backend.

```elixir
%{
  name: :fixer,
  backend: :bwrap,
  config: %{
    # Backend keys
    workspace: "/tmp/workspace",
    extra_path: ["/opt/tools/bin"],
    extra_ro_binds: [{"/home/user/project", "/project"}],
    memory_limit: "512M",
    # Domain keys
    population_size: 10,
    max_iterations: 50
  }
}
```

## Objects

Objects are non-agentic components that participate in topology but run deterministic code instead of LLM calls. Each object must specify either a `handler` (native Elixir) or a `backend` (Docker/SSH). See [objects.md](objects.md) for the handler behaviour.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | atom or string | Yes | Unique object identifier. Normalized to an atom. |
| `handler` | module | For native objects | Module implementing `init/1` and `handle_message/3` from `Genswarms.Objects.ObjectHandler`. |
| `backend` | backend spec | For Docker/SSH objects | Same forms as agent backends. |
| `config` | map | No | Passed to the handler's `init/1` (or to the backend). |

If a `handler` module is already loaded, the validator checks it exports `init/1` and `handle_message/3` (raising `{:invalid_handler, handler, ...}` otherwise); if the module is not yet loaded (it may live in the host application), validation is deferred. An object map with neither `handler` nor `backend` fails with `:invalid_object_config`.

```elixir
objects: [
  %{
    name: :evaluator,
    handler: MyApp.Objects.Evaluator,
    config: %{parallel: true, timeout: 300_000}
  }
]
```

## Topology

`topology` is a list of directed edges, each a `{from, to}` tuple. Every endpoint must be the name of a defined agent or object. Both endpoints may be atoms or strings (strings are normalized to atoms).

```elixir
topology: [
  {:researcher, :coder},  # researcher can send to coder
  {:coder, :researcher}   # and back
]
```

An edge `{a, b}` permits messages from `a` to `b`. For two-way communication, declare both directions explicitly. The topology may be empty.

Validation collects all edge errors and returns them wrapped as `{:invalid_topology, errors}`. Each entry is either `{:unknown_agent, name}` (an endpoint that is not a defined agent or object) or `{:invalid_edge_format, idx, edge}` (an edge that is not a `{from, to}` tuple of atoms/strings).

### System objects

The router always permits messages to the system objects `:metrics`, `:tick`, and `:gateway`, even without an explicit topology edge (`@system_objects` in `lib/genswarms/routing/router.ex`). You do not need to declare edges to these targets. See [messaging.md](messaging.md) for routing details.

## Config formats

The file extension determines the parser: `.exs` (Elixir term), `.json`, or `.yaml`/`.yml`. All formats produce the same validated structure. String keys are atomized and scalar string backend values are converted to atoms during loading.

### Elixir (.exs)

The file must evaluate to a configuration map. This is the only format that supports Elixir-native values such as module atoms for object handlers, tuple-form backends, and dynamic expressions.

```elixir
%{
  name: "example-swarm",
  agents: [
    %{name: :researcher, backend: :local, skills: ["web.md"]},
    %{name: :coder, backend: {:docker, "coder"}, skills: ["code.md"]}
  ],
  topology: [
    {:researcher, :coder},
    {:coder, :researcher}
  ]
}
```

### JSON

Topology edges are two-element arrays. Backends must be scalar strings
(`"local"`, `"bwrap"`, `"mock"`) — see the JSON/YAML limitation above; use `.exs`
for Docker/SSH or option-map backends.

```json
{
  "name": "example-swarm",
  "agents": [
    { "name": "researcher", "backend": "local", "skills": ["web.md"] },
    { "name": "coder", "backend": "bwrap", "skills": ["code.md"] }
  ],
  "topology": [
    ["researcher", "coder"],
    ["coder", "researcher"]
  ]
}
```

### YAML

Same rule as JSON: backends are scalar strings.

```yaml
name: example-swarm
agents:
  - name: researcher
    backend: local
    skills:
      - web.md
  - name: coder
    backend: bwrap
    skills:
      - code.md
topology:
  - [researcher, coder]
  - [coder, researcher]
```

## Per-agent models

Each agent can run on a different model and endpoint. When omitted, the backend passes through `SUBZEROCLAW_MODEL`, and `subzeroclaw` itself falls back to `anthropic/claude-sonnet-4`; the endpoint is auto-detected from the API key. Models use OpenRouter format (`provider/model-name`); see [openrouter.ai/models](https://openrouter.ai/models) for the full list.

```elixir
agents: [
  %{name: :researcher, backend: :local, model: "anthropic/claude-sonnet-4", skills: ["web.md"]},
  %{name: :coder, backend: :local, model: "deepseek/deepseek-chat", skills: ["code.md"]}
]
```

## Skill templating

Skill files listed under an agent's `skills:` are copied into the agent at deploy
time, and three template variables are substituted per agent:

| Variable | Resolves to |
|----------|-------------|
| `{{agent_name}}` | the agent's name |
| `{{swarm_name}}` | the swarm name |
| `{{workspace}}` | the agent's `workspace` path (empty if unset) |

This lets one skill file serve many agents. See [skills.md](skills.md) for
authoring details and built-in skills.

## Full annotated example

```elixir
%{
  # Required: unique identifier (letter-led, alphanumeric/_/-)
  name: "example-swarm",

  agents: [
    # Local agent with a per-agent model and tool presets
    %{
      name: :researcher,
      backend: :local,
      model: "anthropic/claude-sonnet-4",
      skills: ["web.md", "summarize.md"],
      presets: [:base, :web]
    },

    # Sandboxed bwrap agent: backend keys + domain keys in `config`
    %{
      name: :coder,
      backend: :bwrap,
      skills: ["code.md"],
      config: %{
        # Backend keys (consumed by BwrapBackend)
        workspace: "/tmp/example-swarm/coder",
        memory_limit: "512M",
        presets: [:base, :code],
        # Domain key (available to the agent's logic)
        max_iterations: 25
      }
    }
  ],

  # Optional: deterministic, non-agentic component
  objects: [
    %{
      name: :evaluator,
      handler: MyApp.Objects.Evaluator,
      config: %{parallel: true}
    }
  ],

  # Directed edges; system objects (:metrics, :tick, :gateway)
  # are routable without explicit edges
  topology: [
    {:researcher, :coder},
    {:coder, :evaluator},
    {:evaluator, :researcher}
  ]
}
```

## See also

- [backends.md](backends.md) — backend types and their options
- [containers.md](containers.md) — building NixOS container images for Docker agents
- [objects.md](objects.md) — the `ObjectHandler` behaviour and object patterns
- [skills.md](skills.md) — authoring and deploying agent skill files
- [cli.md](cli.md) — validating and running configs from the command line
