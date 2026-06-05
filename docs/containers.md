# Container Images & Configuration

This guide covers building NixOS-based container images for Genswarm agents, configuring presets, managing volumes, and setting up environments.

## Overview

Genswarm uses NixOS-based Docker containers built with Nix flakes. This provides:
- Reproducible builds with pinned dependencies
- Minimal images containing only required tools
- Easy customization via presets and tool lists
- Consistent environments across development and production

## Building Container Images

### Quick Start

```bash
# Build a pre-defined container
nix build .#agentContainer-code
docker load --input result

# The image is now available as szc-agent-code:latest
docker run --rm szc-agent-code:latest swarm-msg help
```

### Available Pre-built Images

| Image | Presets | Use Case |
|-------|---------|----------|
| `agentContainer-base` | base | Minimal agent with core tools |
| `agentContainer-web` | base, web | Web research, HTTP APIs |
| `agentContainer-code` | base, code | Software development |
| `agentContainer-data` | base, data | Data processing, CSV/JSON |
| `agentContainer-python` | base, python, data | Python development |
| `agentContainer-node` | base, node, web | Node.js development |
| `agentContainer-devops` | base, code, containers, cloud | DevOps/Cloud operations |
| `agentContainer-full` | base, web, code, data, python, node | Full-featured agent |

Build any of these with:
```bash
nix build .#agentContainer-<name>
```

### Custom Images

Create custom images by calling `mkAgentContainer` in your flake:

```nix
# In your flake.nix
{
  inputs.genswarm.url = "github:genlayer/genswarm";

  outputs = { self, nixpkgs, genswarm, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      szsLib = genswarm.packages.x86_64-linux.lib;
    in {
      packages.x86_64-linux.my-agent = szsLib.mkAgentContainer {
        name = "my-agent";
        presets = [ "base" "code" "python" ];
        extraPackages = with pkgs; [
          postgresql
          redis
        ];
      };
    };
}
```

Build with:
```bash
nix build .#my-agent
docker load --input result
# Image: szc-agent-my-agent:latest
```

## Tool Presets

Presets are named groups of related tools. They're defined in `nix/tool-presets.nix`.

### Available Presets

#### `base` - Always included
Core utilities every agent needs:
- `coreutils`, `bash`, `grep`, `sed`, `awk`, `find`, `which`, `less`, `file`
- `curl` (required by subzeroclaw for API calls)

#### `web` - HTTP and web tools
- `curl`, `wget`, `httpie`
- `jq`, `yq` (JSON/YAML processing)
- `htmlq` (HTML processing)
- `w3m`, `lynx` (text browsers)

#### `code` - Development tools
- `git`, `git-lfs`
- `make`, `gcc`
- `ripgrep`, `fd`, `tree`
- `bat`, `delta` (better cat/diff)
- `tokei` (code statistics)

#### `python` - Python environment
- `python312`, `pip`, `virtualenv`
- `requests`, `beautifulsoup4`
- `pandas`, `numpy`

#### `node` - Node.js environment
- `nodejs_20`
- `npm`, `yarn`, `pnpm`

#### `data` - Data processing
- `jq`, `yq`
- `csvkit`, `miller`, `xsv`
- `sqlite`, `duckdb`

#### `docs` - Document processing
- `pandoc`
- `texlive` (basic)
- `poppler_utils` (PDF tools)
- `imagemagick`

#### `network` - Network tools
- `curl`, `wget`, `httpie`
- `netcat`, `socat`
- `ssh`, `rsync`

#### `containers` - Container tools
- `docker-client`, `podman`
- `skopeo`, `dive`

#### `cloud` - Cloud CLI tools
- `awscli2`, `google-cloud-sdk`, `azure-cli`
- `kubectl`, `k9s`, `terraform`

### Creating Custom Presets

Add presets to `nix/tool-presets.nix`:

```nix
{ pkgs }:

{
  # ... existing presets ...

  # Your custom preset
  ml = with pkgs; [
    python312Packages.torch-bin
    python312Packages.transformers
    python312Packages.datasets
    python312Packages.accelerate
  ];

  # Individual tools mapping
  tools = with pkgs; {
    # ... existing tools ...

    # Add custom tool mappings
    pytorch = python312Packages.torch-bin;
    huggingface = python312Packages.transformers;
  };
}
```

Then use in your container:
```nix
mkAgentContainer {
  name = "ml-agent";
  presets = [ "base" "python" "ml" ];
}
```

### Adding Individual Tools

Reference tools directly without creating a preset:

```nix
mkAgentContainer {
  name = "custom";
  presets = [ "base" ];
  tools = [ "ripgrep" "fd" "jq" ];  # From tools mapping
  extraPackages = with pkgs; [
    duckdb      # Direct nixpkgs reference
    htop
  ];
}
```

## Volume Configuration

Volumes allow agents to share files and persist data. Configure them in your swarm config.

### Syntax

```elixir
%{
  name: :my_agent,
  backend: {:docker, "szc-agent-code:latest", %{
    volumes: [
      {"~/local/path", "/container/path"},
      {"~/.data/shared", "/shared"},
      {"/absolute/path", "/data", "ro"}  # Read-only
    ]
  }},
  # ...
}
```

### Common Volume Patterns

#### Shared Workspace
All agents share a workspace for passing files:

```elixir
# In each agent config
volumes: [
  {"~/.myswarm/workspace", "/workspace"}
]
```

Agents can then:
- Write results to `/workspace/output.json`
- Read inputs from `/workspace/input.json`
- Use `swarm-msg` to notify other agents about file locations

#### Skills Directory
Share generated skills between agents:

```elixir
volumes: [
  {"~/.myswarm/skills", "/skills"}
]
```

#### Logs Directory
Centralized logs for analysis:

```elixir
volumes: [
  {"~/.myswarm/logs", "/logs"}
]
```

#### Read-Only Documentation
Mount docs without modification risk:

```elixir
volumes: [
  {"./docs", "/docs", "ro"}
]
```

### Volume Sharing Between Agents

Example: Pop-gen creates configs, Eval runs them, Breeder analyzes logs

```elixir
%{
  name: "evolution-swarm",

  agents: [
    %{
      name: :pop_gen,
      backend: {:docker, "szc-agent-code:latest", %{
        volumes: [
          {"~/.evolution/workspace", "/workspace"},    # Write configs here
          {"~/.evolution/skills", "/skills/generated"} # Write skills here
        ]
      }}
    },

    %{
      name: :breeder,
      backend: {:docker, "szc-agent-code:latest", %{
        volumes: [
          {"~/.evolution/workspace", "/workspace"},  # Read configs
          {"~/.evolution/logs", "/logs"},            # Read execution logs
          {"~/.evolution/skills", "/skills/generated"}
        ]
      }}
    }
  ],

  objects: [
    %{
      name: :eval,
      handler: MyApp.Evaluator,
      config: %{
        workspace_dir: "~/.evolution/workspace",
        logs_dir: "~/.evolution/logs"
      }
    }
  ],

  topology: [
    {:pop_gen, :eval},
    {:eval, :breeder}
  ]
}
```

### Objects and Volumes

Objects (Elixir GenServers) access the filesystem directly. Ensure paths match agent mounts:

```elixir
# Object config
%{
  name: :evaluator,
  handler: MyApp.Evaluator,
  config: %{
    # Use expanded paths matching agent volumes
    workspace: Path.expand("~/.evolution/workspace"),
    logs: Path.expand("~/.evolution/logs")
  }
}
```

In your handler:
```elixir
defmodule MyApp.Evaluator do
  use GenServer

  def init(config) do
    {:ok, %{
      workspace: config.workspace,
      logs: config.logs
    }}
  end

  def handle_cast({:message, from, content}, state) do
    # Read configs from shared workspace
    configs = Path.wildcard(Path.join(state.workspace, "*.exs"))

    # Process and write results
    results = evaluate_configs(configs)
    File.write!(Path.join(state.workspace, "results.json"), Jason.encode!(results))

    # Write logs
    File.write!(Path.join(state.logs, "eval.log"), format_log(results))

    {:noreply, state}
  end
end
```

## Environment Variables

### Setting Environment Variables

In swarm config:

```elixir
%{
  name: :agent,
  backend: {:docker, "szc-agent-code:latest", %{
    env: %{
      "API_KEY" => "${API_KEY}",              # From shell environment
      "MODEL" => "anthropic/claude-sonnet-4", # Static value
      "DEBUG" => "true"
    }
  }}
}
```

### Required Environment Variables

#### For subzeroclaw agent:
- `SUBZEROCLAW_API_KEY` - API key for LLM provider (OpenRouter, Anthropic, etc.)
- `SUBZEROCLAW_MODEL` - Model to use (e.g., `anthropic/claude-sonnet-4-20250514`)

#### For orouter:
- `OPENROUTER_API_KEY` - OpenRouter API key for model queries

### Loading from .env Files

Genswarm automatically loads `.env` files from:
1. Current working directory
2. `~/.subzeroclaw/.env`

Format:
```bash
# .env
SUBZEROCLAW_API_KEY=sk-or-...
OPENROUTER_API_KEY=sk-or-...
SUBZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
```

### Environment in Containers

The container includes these environment variables by default:
- `PATH` - Includes all tool binaries
- `SSL_CERT_FILE` - CA certificates for HTTPS
- `AGENT_NAME` - Set to the container name
- `TMPDIR` - Writable temp directory

Additional variables are passed via the `env` config option.

## Included Tools in Containers

All containers include:

### swarm-msg
Inter-agent messaging:
```bash
swarm-msg send <agent> "message"
swarm-msg send <agent> -f /path/to/file
swarm-msg broadcast "message to all"
swarm-msg list  # Show available agents
```

### swarm (CLI)
Swarm management:
```bash
swarm check config.exs      # Validate configuration
swarm help                  # Show all commands
swarm init my-project       # Create new project
```

### nix-shell (in full containers)
Install additional tools at runtime:
```bash
nix-shell -p postgresql --run "psql ..."
```

## Example: Complete Custom Setup

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    genswarm.url = "github:genlayer/genswarm";
  };

  outputs = { self, nixpkgs, genswarm, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Import container builder
      toolPresets = import "${genswarm}/nix/tool-presets.nix" { inherit pkgs; };
      containerLib = import "${genswarm}/nix/container.nix" {
        inherit pkgs toolPresets;
      };

      # Custom tool script
      myTool = pkgs.writeShellScriptBin "mytool" ''
        #!/bin/sh
        echo "Custom tool: $@"
      '';

    in {
      packages.${system} = {
        # Custom agent container
        agent-custom = containerLib.mkAgentContainer {
          name = "custom";
          presets = [ "base" "code" "python" ];
          extraPackages = [ myTool pkgs.htop ];
        };
      };
    };
}
```

Build and use:
```bash
nix build .#agent-custom
docker load --input result

# Use in swarm config
# backend: {:docker, "szc-agent-custom:latest", %{...}}
```

## Troubleshooting

### Container won't start
Check Docker logs:
```bash
docker logs <container_id>
```

Common issues:
- Volume paths don't exist on host
- Environment variables not set
- Port conflicts

### swarm command fails
Ensure Erlang is in PATH. The wrapper should handle this, but verify:
```bash
docker run --rm szc-agent-code:latest which escript
```

### Tools missing
Verify the preset includes required tools:
```bash
docker run --rm szc-agent-code:latest which <tool>
```

If missing, add to `extraPackages` or create a custom preset.

### Permission denied on volumes
Ensure host directories exist and are writable:
```bash
mkdir -p ~/.myswarm/{workspace,logs,skills}
chmod 755 ~/.myswarm/*
```

### Locale warnings
Add locale env vars if you see UTF-8 warnings:
```elixir
env: %{
  "LANG" => "C.UTF-8",
  "LC_ALL" => "C.UTF-8"
}
```
