# Swarm Configuration DSL

This document describes the Domain-Specific Language (DSL) for defining Genswarm configurations. Use this guide to create swarm configurations that define agent networks with custom topologies and deployment strategies.

For CLI usage and commands, see the [CLI Reference](../README.md#cli-reference) in the main README.

## Overview

A swarm configuration is a map with three required keys:
- `name` - Unique identifier for the swarm
- `agents` - List of agent definitions
- `topology` - List of directed edges defining communication paths

## Configuration Schema

```elixir
%{
  # Required: Unique swarm identifier
  name: String.t(),

  # Required: List of agent definitions
  agents: [
    %{
      name: atom() | String.t(),           # Required: Agent identifier
      backend: backend_spec(),              # Required: How to run the agent
      model: String.t(),                    # Optional: LLM model (OpenRouter format)
      endpoint: String.t(),                 # Optional: API endpoint URL
      skills: [String.t()],                 # Optional: Skill files to deploy
      presets: [atom()],                    # Optional: NixOS tool presets
      tools: [atom()],                      # Optional: Individual tools
      config: map()                         # Optional: Backend-specific config
    }
  ],

  # Optional: List of object definitions (non-agentic Elixir components)
  objects: [
    %{
      name: atom() | String.t(),           # Required: Object identifier
      handler: module(),                    # Required: Elixir module implementing ObjectHandler
      config: map()                         # Optional: Configuration passed to handler init/1
    }
  ],

  # Required: Communication topology (can be empty list)
  # Can include both agents and objects as sources/targets
  topology: [{source :: atom(), target :: atom()}],

  # Optional: Base directory for skills
  skills_base_dir: String.t(),

  # Optional: Additional settings
  options: map()
}
```

## Per-Agent Models and Endpoints

Each agent can specify its own LLM model and API endpoint:

```elixir
%{
  name: :researcher,
  backend: :local,
  model: "anthropic/claude-sonnet-4",   # OpenRouter format
  endpoint: "https://openrouter.ai/api/v1/chat/completions",  # Optional
  skills: ["research.md"]
}
```

The model uses OpenRouter format (`provider/model-name`). The endpoint is optional and auto-detected based on the API key format.

### Available Models

Popular models via OpenRouter (600+ available at [openrouter.ai/models](https://openrouter.ai/models)):

| Model | Provider | Use Case |
|-------|----------|----------|
| `anthropic/claude-sonnet-4` | Anthropic | Balanced, general purpose |
| `anthropic/claude-opus-4` | Anthropic | Most capable |
| `openai/gpt-4o` | OpenAI | Strong general model |
| `openai/gpt-4o-mini` | OpenAI | Fast and affordable |
| `deepseek/deepseek-chat` | DeepSeek | Very cheap, good for coding |
| `google/gemini-2.0-flash-001` | Google | Fast responses |
| `meta-llama/llama-3.1-405b-instruct` | Meta | Open weights |

### Fallback Behavior

If no model is specified for an agent, it falls back to:
1. `SUBZEROCLAW_MODEL` environment variable
2. Default: `anthropic/claude-sonnet-4`

If no endpoint is specified, it falls back to:
1. `SUBZEROCLAW_ENDPOINT` environment variable
2. Auto-detected based on API key format

## NixOS Tool System

Agents can specify which tools are available in their environment using **presets** (groups of related tools) and individual **tools**. These are defined in `nix/tool-presets.nix` and used to build minimal NixOS containers.

### Tool Presets

Presets group related tools together:

| Preset | Description | Key Tools |
|--------|-------------|-----------|
| `:base` | Core utilities | coreutils, bash, grep, sed, awk, find |
| `:web` | HTTP/API tools | curl, wget, httpie, jq, yq, w3m |
| `:code` | Development | git, gcc, make, ripgrep, fd, bat |
| `:python` | Python env | python3, pip, requests, pandas, numpy |
| `:node` | Node.js env | nodejs, npm, yarn, pnpm |
| `:data` | Data processing | jq, csvkit, miller, sqlite, duckdb, xsv |
| `:docs` | Documents | pandoc, texlive, poppler, imagemagick |
| `:network` | Networking | curl, ssh, rsync, netcat, aria2 |
| `:system` | Debugging | htop, btop, lsof, strace, procps |
| `:security` | Crypto | openssl, gnupg, age, sops |
| `:containers` | Containers | docker, podman, skopeo, dive |
| `:cloud` | Cloud CLIs | aws, gcloud, kubectl, terraform |
| `:ai` | AI/ML | openai, anthropic, tiktoken |

### Individual Tools

For fine-grained control, specify individual tools:

```elixir
%{
  name: :agent,
  backend: :local,
  presets: [:base],          # Start with base tools
  tools: [:git, :python, :jq, :curl]  # Add specific tools
}
```

Common tools: `:git`, `:curl`, `:wget`, `:jq`, `:yq`, `:ripgrep`, `:fd`, `:fzf`,
`:python`, `:node`, `:go`, `:rustc`, `:docker`, `:kubectl`, `:gh`, `:glab`

### Building Container Images

Docker containers are built using Nix:

```bash
# Build specific preset container
nix build .#agentContainer-web
nix build .#agentContainer-code

# Load into Docker
docker load < result

# List available containers
nix flake show | grep agentContainer
```

## Naming Rules

### Swarm Names
- Must start with a letter (a-z, A-Z)
- Can contain alphanumeric characters, underscores, and hyphens
- Examples: `"research-swarm"`, `"dev_team_1"`, `"ProductionSwarm"`

### Agent Names
- Can be atoms or strings (strings are converted to atoms)
- Should be descriptive of the agent's role
- Examples: `:researcher`, `:coder`, `"data_analyst"`, `:reviewer`

## Backend Specifications

### Local Backend

Runs the agent as a local subprocess using Elixir Ports.

```elixir
# Simple local backend
%{name: :agent1, backend: :local}

# With skills
%{name: :researcher, backend: :local, skills: ["web.md", "search.md"]}
```

### Docker Backend

Runs the agent in a Docker container. Containers are automatically namespaced by swarm: `szc-{swarm_name}-{agent_name}`.

```elixir
# Simple Docker backend
%{name: :coder, backend: {:docker, "coder-container"}}

# With options
%{
  name: :coder,
  backend: {:docker, "coder-container", %{
    image: "subzeroclaw:latest",      # Docker image to use
    memory_limit: "512m",              # Memory limit
    cpu_limit: 1.0,                    # CPU limit
    network: "swarm-network",          # Docker network
    env: %{                            # Additional env vars
      "DEBUG" => "true"
    },
    volumes: [                         # Additional volume mounts
      {"/host/path", "/container/path"}
    ]
  }}
}
```

**Docker Backend Options:**

| Option | Type | Description |
|--------|------|-------------|
| `image` | String | Docker image (default: `subzeroclaw:latest`) |
| `memory_limit` | String | Memory limit (e.g., `"512m"`, `"2g"`) |
| `cpu_limit` | Float | CPU limit (e.g., `1.0`, `0.5`) |
| `network` | String | Docker network name |
| `env` | Map | Additional environment variables |
| `volumes` | List | Additional volume mounts as `{host, container}` tuples |

### SSH Backend

Runs the agent on a remote machine via SSH.

```elixir
# Simple SSH backend
%{name: :remote_agent, backend: {:ssh, "user@192.168.1.100"}}

# With options
%{
  name: :pi_agent,
  backend: {:ssh, "pi@raspberry.local", %{
    port: 22,                                    # SSH port
    key_path: "~/.ssh/id_ed25519",              # Path to SSH key
    subzeroclaw_path: "/home/pi/bin/subzeroclaw", # Remote binary path
    remote_skills_dir: "~/.subzeroclaw/skills"   # Remote skills directory
  }}
}
```

**SSH Backend Options:**

| Option | Type | Description |
|--------|------|-------------|
| `port` | Integer | SSH port (default: 22) |
| `key_path` | String | Path to SSH private key |
| `subzeroclaw_path` | String | Path to binary on remote (default: `subzeroclaw`) |
| `remote_skills_dir` | String | Remote skills directory |
| `password` | String | SSH password (not recommended) |

## Topology Definition

The topology defines which agents can send messages to which other agents. It's a list of directed edges.

### Basic Topology

```elixir
topology: [
  {:agent_a, :agent_b},  # a can send to b
  {:agent_b, :agent_c},  # b can send to c
]
```

### Bidirectional Communication

```elixir
topology: [
  {:agent_a, :agent_b},  # a -> b
  {:agent_b, :agent_a},  # b -> a (explicit reverse)
]
```

### Hub-and-Spoke (Coordinator Pattern)

```elixir
topology: [
  {:coordinator, :worker_1},
  {:coordinator, :worker_2},
  {:coordinator, :worker_3},
  {:worker_1, :coordinator},
  {:worker_2, :coordinator},
  {:worker_3, :coordinator},
]
```

### Pipeline

```elixir
topology: [
  {:input, :processor},
  {:processor, :validator},
  {:validator, :output},
]
```

### Mesh (Fully Connected)

```elixir
# All agents can communicate with all others
topology: [
  {:a, :b}, {:a, :c},
  {:b, :a}, {:b, :c},
  {:c, :a}, {:c, :b},
]
```

### Ring

```elixir
topology: [
  {:agent_1, :agent_2},
  {:agent_2, :agent_3},
  {:agent_3, :agent_1},
]
```

## Skills

Skills are markdown files that define agent behavior. Reference them by filename.

```elixir
%{
  name: :researcher,
  backend: :local,
  skills: ["web.md", "academic.md", "summarize.md"]
}
```

Skills are loaded from:
1. `priv/skills/` directory (default)
2. Custom directory via `skills_base_dir` option

## Objects

Objects are non-agentic components that execute Elixir code instead of LLM calls. They participate in the swarm topology but provide deterministic, fast computation for tasks that don't require AI reasoning.

For comprehensive documentation, see [Objects Guide](./objects.md).

### When to Use Objects

| Use Case | Solution |
|----------|----------|
| Single agent needs CLI tool | Use NixOS presets (`:code`, `:python`, etc.) |
| Agents need external service | Use internet APIs from agents |
| Multiple agents need shared custom computation | **Use Objects** |
| Deterministic, high-throughput processing | **Use Objects** |

### Object Definition

**Native Object (Elixir handler):**
```elixir
objects: [
  %{
    name: :evaluator,
    handler: MyApp.Objects.Evaluator,
    config: %{parallel: true, timeout: 300_000}
  }
]
```

**Docker Object (JSON protocol):**
```elixir
objects: [
  %{
    name: :gpu_processor,
    backend: {:docker, "cuda-processor:latest", %{gpus: "all"}},
    config: %{batch_size: 64}
  }
]
```

**SSH Object (remote execution):**
```elixir
objects: [
  %{
    name: :remote_eval,
    backend: {:ssh, "user@gpu-server.local"},
    config: %{}
  }
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | atom/string | Yes | Unique identifier in swarm |
| `handler` | module | For native | Elixir module implementing `ObjectHandler` |
| `backend` | backend_spec | For Docker/SSH | Same backend types as agents |
| `config` | map | No | Configuration passed to handler or backend |

Objects require either `handler` (native Elixir) or `backend` (Docker/SSH).

### Object Handler Behaviour

Objects implement the `Genswarm.Objects.ObjectHandler` behaviour:

```elixir
defmodule MyApp.Objects.Evaluator do
  @behaviour Genswarm.Objects.ObjectHandler

  @impl true
  def init(config) do
    {:ok, %{config: config}}
  end

  @impl true
  def handle_message(from, content, state) do
    # Process message and return one of:
    # {:reply, response, new_state}     - Reply to sender
    # {:send, to, message, new_state}   - Send to specific target
    # {:broadcast, message, new_state}  - Send to all connected
    # {:noreply, new_state}             - No response
  end

  @impl true
  def interface() do
    %{action_name: %{input: "description", output: "description"}}
  end
end
```

### Objects in Topology

Objects participate in topology alongside agents:

```elixir
%{
  agents: [
    %{name: :worker_1, backend: :local, skills: ["work.md"]},
    %{name: :worker_2, backend: :local, skills: ["work.md"]}
  ],

  objects: [
    %{name: :coordinator, handler: MyApp.Objects.Coordinator}
  ],

  topology: [
    {:worker_1, :coordinator},  # Agent → Object
    {:worker_2, :coordinator},
    {:coordinator, :worker_1},  # Object → Agent
    {:coordinator, :worker_2}
  ]
}
```

### Dashboard Visualization

In the topology graph:
- **Agents** are displayed as **circles**
- **Objects** are displayed as **squares**
- Both use the same color coding for state (teal=idle, amber=working, red=error)

## Complete Examples

### Research Team

A three-agent team for research tasks, each with its own model:

```elixir
%{
  name: "research-team",

  agents: [
    %{
      name: :researcher,
      backend: :local,
      model: "anthropic/claude-sonnet-4",      # Claude for research
      skills: ["web.md"]
    },
    %{
      name: :analyst,
      backend: :local,
      model: "openai/gpt-4o",                  # GPT-4o for analysis
      skills: ["analysis.md", "statistics.md"]
    },
    %{
      name: :writer,
      backend: :local,
      model: "deepseek/deepseek-chat",         # Cheaper model for writing
      skills: ["writing.md", "formatting.md"]
    }
  ],

  topology: [
    # Researcher sends findings to analyst
    {:researcher, :analyst},
    # Analyst sends insights to writer
    {:analyst, :writer},
    # Writer can ask researcher for more info
    {:writer, :researcher},
    # Analyst can ask researcher for clarification
    {:analyst, :researcher}
  ]
}
```

### Development Pipeline

Code review pipeline with multiple stages:

```elixir
%{
  name: "dev-pipeline",

  agents: [
    %{name: :planner, backend: :local, skills: ["planning.md"]},
    %{name: :coder, backend: :local, skills: ["code.md"]},
    %{name: :tester, backend: :local, skills: ["testing.md"]},
    %{name: :reviewer, backend: :local, skills: ["review.md"]}
  ],

  topology: [
    {:planner, :coder},
    {:coder, :tester},
    {:tester, :reviewer},
    {:reviewer, :coder},      # Send back for fixes
    {:reviewer, :planner}     # Escalate issues
  ]
}
```

### Hybrid Deployment

Mixed local, Docker, and SSH agents:

```elixir
%{
  name: "hybrid-swarm",

  agents: [
    # Local coordinator
    %{
      name: :coordinator,
      backend: :local,
      skills: ["orchestration.md"]
    },

    # Docker workers for heavy processing
    %{
      name: :processor_1,
      backend: {:docker, "proc-1", %{
        image: "subzeroclaw:gpu",
        memory_limit: "4g"
      }},
      skills: ["processing.md"]
    },
    %{
      name: :processor_2,
      backend: {:docker, "proc-2", %{
        image: "subzeroclaw:gpu",
        memory_limit: "4g"
      }},
      skills: ["processing.md"]
    },

    # Remote sensor on Raspberry Pi
    %{
      name: :sensor,
      backend: {:ssh, "pi@sensor.local", %{
        key_path: "~/.ssh/id_ed25519"
      }},
      skills: ["sensor.md", "gpio.md"]
    }
  ],

  topology: [
    {:coordinator, :processor_1},
    {:coordinator, :processor_2},
    {:coordinator, :sensor},
    {:processor_1, :coordinator},
    {:processor_2, :coordinator},
    {:sensor, :coordinator}
  ]
}
```

### Genetic Algorithm with Object Evaluator

A GA swarm using an object for deterministic evaluation:

```elixir
%{
  name: "genetic-algorithm",

  agents: [
    %{
      name: :pop_gen,
      backend: {:docker, "ga-agent:latest"},
      skills: ["population.md"],
      presets: [:base, :code]
    },
    %{
      name: :fixer,
      backend: {:docker, "ga-agent:latest"},
      skills: ["fixer.md"],
      presets: [:base, :code]
    },
    %{
      name: :crossover,
      backend: {:docker, "ga-agent:latest"},
      skills: ["crossover.md"],
      presets: [:base, :code]
    },
    %{
      name: :mutator,
      backend: {:docker, "ga-agent:latest"},
      skills: ["mutator.md"],
      presets: [:base, :code]
    }
  ],

  # Object handles evaluation - fast, deterministic, no LLM costs
  objects: [
    %{
      name: :eval,
      handler: MyApp.Objects.Evaluator,
      config: %{
        parallel: true,
        timeout: 300_000,
        benchmarks: ["test_1", "test_2", "test_3"]
      }
    }
  ],

  topology: [
    # Population generation feeds into evaluation
    {:pop_gen, :eval},

    # Evaluation broadcasts results to analysis agents
    {:eval, :fixer},
    {:eval, :crossover},

    # Fixer sends improvements to crossover
    {:fixer, :crossover},

    # Crossover produces offspring for mutation
    {:crossover, :mutator},

    # Mutated population goes back to evaluation (the loop)
    {:mutator, :eval}
  ]
}
```

The `eval` object processes thousands of configurations per minute without LLM API calls, computing fitness scores, Pareto fronts, and other metrics deterministically.

### Hierarchical Team

Multi-level organization:

```elixir
%{
  name: "hierarchical-team",

  agents: [
    # Top level
    %{name: :director, backend: :local, skills: ["leadership.md"]},

    # Middle level
    %{name: :tech_lead, backend: :local, skills: ["tech_lead.md"]},
    %{name: :research_lead, backend: :local, skills: ["research_lead.md"]},

    # Team level
    %{name: :dev_1, backend: :local, skills: ["code.md"]},
    %{name: :dev_2, backend: :local, skills: ["code.md"]},
    %{name: :researcher_1, backend: :local, skills: ["research.md"]},
    %{name: :researcher_2, backend: :local, skills: ["research.md"]}
  ],

  topology: [
    # Director to leads
    {:director, :tech_lead},
    {:director, :research_lead},

    # Leads to team
    {:tech_lead, :dev_1},
    {:tech_lead, :dev_2},
    {:research_lead, :researcher_1},
    {:research_lead, :researcher_2},

    # Team to leads (reporting)
    {:dev_1, :tech_lead},
    {:dev_2, :tech_lead},
    {:researcher_1, :research_lead},
    {:researcher_2, :research_lead},

    # Leads to director (reporting)
    {:tech_lead, :director},
    {:research_lead, :director},

    # Cross-team collaboration
    {:tech_lead, :research_lead},
    {:research_lead, :tech_lead}
  ]
}
```

## JSON Format

Configurations can also be written in JSON:

```json
{
  "name": "json-swarm",
  "agents": [
    {
      "name": "researcher",
      "backend": "local",
      "skills": ["web.md"]
    },
    {
      "name": "coder",
      "backend": ["docker", "coder-container"],
      "skills": ["code.md"]
    }
  ],
  "topology": [
    ["researcher", "coder"],
    ["coder", "researcher"]
  ]
}
```

## YAML Format

```yaml
name: yaml-swarm

agents:
  - name: researcher
    backend: local
    skills:
      - web.md

  - name: coder
    backend:
      - docker
      - coder-container
    skills:
      - code.md

topology:
  - [researcher, coder]
  - [coder, researcher]
```

## Validation Rules

The configuration is validated when loaded:

1. **Name validation**
   - Must be present and non-empty
   - Must start with a letter
   - Can only contain alphanumeric, underscore, hyphen

2. **Agents validation**
   - Must have at least one agent
   - Each agent must have `name` and `backend`
   - Backend must be valid type (`:local`, `{:docker, _}`, `{:ssh, _}`)
   - Skills must be list of strings

3. **Objects validation**
   - Each object must have `name` and `handler`
   - Handler must be a module atom
   - Config (if provided) must be a map

4. **Topology validation**
   - Each edge must reference existing agents or objects
   - Both source and target must be defined in agents or objects list

## Common Patterns

### Pattern: Coordinator with Workers

```elixir
%{
  name: "coordinator-pattern",
  agents: [
    %{name: :coordinator, backend: :local, skills: ["coordinate.md"]},
    %{name: :worker_1, backend: :local, skills: ["work.md"]},
    %{name: :worker_2, backend: :local, skills: ["work.md"]},
    %{name: :worker_3, backend: :local, skills: ["work.md"]}
  ],
  topology: [
    {:coordinator, :worker_1}, {:coordinator, :worker_2}, {:coordinator, :worker_3},
    {:worker_1, :coordinator}, {:worker_2, :coordinator}, {:worker_3, :coordinator}
  ]
}
```

### Pattern: Expert Panel

```elixir
%{
  name: "expert-panel",
  agents: [
    %{name: :moderator, backend: :local, skills: ["moderate.md"]},
    %{name: :expert_a, backend: :local, skills: ["domain_a.md"]},
    %{name: :expert_b, backend: :local, skills: ["domain_b.md"]},
    %{name: :expert_c, backend: :local, skills: ["domain_c.md"]}
  ],
  topology: [
    # Moderator controls discussion
    {:moderator, :expert_a}, {:moderator, :expert_b}, {:moderator, :expert_c},
    # Experts respond to moderator
    {:expert_a, :moderator}, {:expert_b, :moderator}, {:expert_c, :moderator},
    # Experts can discuss with each other
    {:expert_a, :expert_b}, {:expert_a, :expert_c},
    {:expert_b, :expert_a}, {:expert_b, :expert_c},
    {:expert_c, :expert_a}, {:expert_c, :expert_b}
  ]
}
```

### Pattern: Supervisor Chain

```elixir
%{
  name: "supervisor-chain",
  agents: [
    %{name: :supervisor, backend: :local, skills: ["supervise.md"]},
    %{name: :senior, backend: :local, skills: ["senior.md"]},
    %{name: :junior, backend: :local, skills: ["junior.md"]}
  ],
  topology: [
    {:supervisor, :senior},
    {:senior, :junior},
    {:junior, :senior},
    {:senior, :supervisor}
  ]
}
```

## Tips for Designing Topologies

1. **Start simple** - Begin with a basic pipeline or hub-and-spoke pattern
2. **Consider information flow** - Who needs to communicate with whom?
3. **Avoid cycles for approval flows** - Use linear chains for review/approval
4. **Add bidirectional edges for collaboration** - Agents that need to discuss should have edges both ways
5. **Use coordinators for complex swarms** - A central agent can manage workflow
6. **Test with local first** - Start with `:local` backend, then move to Docker/SSH

## CLI Usage

Once you've created a configuration file, use the `swarm` CLI to manage it:

### Validate Configuration

Before starting, validate your config:

```bash
swarm config validate path/to/config.exs
```

### Start a Swarm

```bash
swarm start path/to/config.exs
```

### Interact with Agents

```bash
# Send a task to an agent
swarm task my-swarm researcher "Find papers on transformers"

# Send a message between agents
swarm msg my-swarm researcher coder "Please implement this algorithm"

# Stream logs
swarm logs my-swarm researcher -f
```

### Check Status

```bash
# Show all swarms
swarm status

# Show specific swarm with topology
swarm status my-swarm
```

### Pause and Resume

Pause freezes all containers without stopping them (preserves state):

```bash
# Pause all containers in the swarm
swarm pause my-swarm

# Resume paused containers
swarm resume my-swarm
```

### Restart Agent

Restart a specific agent (useful after editing skills):

```bash
swarm restart-agent my-swarm researcher
```

### Stop Swarm

```bash
swarm stop my-swarm
```

## Multi-Swarm Isolation

Each swarm's containers are namespaced: `szc-{swarm_name}-{agent_name}`

This means:
- Multiple swarms can run simultaneously
- `swarm pause swarm-a` only affects `szc-swarm-a-*` containers
- `swarm pause swarm-b` only affects `szc-swarm-b-*` containers

Example with two swarms running:
```
szc-research-team-researcher    # Research team swarm
szc-research-team-analyst
szc-dev-pipeline-planner        # Dev pipeline swarm
szc-dev-pipeline-coder
```

For the complete CLI reference, see [CLI Reference](../README.md#cli-reference) in the main README.
