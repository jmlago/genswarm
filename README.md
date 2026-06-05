# Genswarm

An Elixir/OTP orchestrator for managing swarms of subzeroclaw agents with pluggable backends, arbitrary directed graph topologies, per-agent skills, and fault tolerance via OTP supervision trees.

## Features

- **Pluggable backends**: Local (Port), Docker (NixOS containers), SSH, Bwrap (bubblewrap), Mock
- **NixOS-based containers**: Declarative, minimal containers with only the tools each agent needs
- **Bwrap sandboxing**: Lightweight bubblewrap isolation for 10k+ agents on a single NixOS machine
- **Per-agent tool configuration**: Specify presets (`:web`, `:code`, `:data`) or individual tools
- **Arbitrary topologies**: Define directed graphs for inter-agent communication
- **System object routing**: `:metrics`, `:tick`, and `:gateway` are always routable without explicit topology edges
- **Per-agent skills**: Markdown skill files deployed to each agent with template variable resolution
- **Skill templating**: `{{agent_name}}`, `{{workspace}}`, `{{swarm_name}}` resolved at deploy time
- **Per-agent workspaces**: `agent :name, count: N` auto-appends agent name to workspace path (e.g., `fixer_1` gets `workspace/fixer_1/`)
- **File-based messaging**: File-inbox (`.inbox/`) and file-outbox (`.outbox/`) for reliable message delivery to sandboxed agents
- **Mock backend**: `backend: :mock` with script config for testing without LLM calls
- **Fault tolerance**: OTP supervision trees for resilient operation
- **Hybrid deployments**: Mix Docker containers, bare metal, bwrap, and SSH agents
- **REST API**: Complete programmatic swarm control with CORS support
- **WebSocket**: Real-time agent output, message routing, and event streaming
- **CLI**: Full-featured command-line management
- **E2E testing**: `mix swarm.test` for automated validation and testing of swarm configurations
- **Multi-swarm isolation**: Run multiple swarms simultaneously with independent pause/resume
- **Daemon-based swarms**: Run swarms as background OS processes
- **Centralized observability**: Query events and logs via CLI or API

## Deployment Models

### 1. Docker Containers (NixOS-based)
Run many isolated agents on a single machine using minimal NixOS containers.
Each container includes only the tools specified in presets/tools.

```bash
# Build containers
nix build .#agentContainer-web
docker load < result

# Use in swarm config
%{name: :researcher, backend: {:docker, "researcher"}, presets: [:base, :web]}
```

**Multi-Swarm Isolation:** Containers are namespaced by swarm name (`szc-{swarm}-{agent}`), so multiple swarms can run simultaneously without interference. Pause/resume operations only affect containers belonging to the specified swarm.

### 2. Bare Metal (Colmena + NixOS)
Deploy agents to dedicated NixOS machines via Colmena.
The machines are fully configured with required tools before the swarm starts.

```bash
# Deploy NixOS configs to all machines
colmena apply

# Start orchestrator (connects via SSH)
mix swarm start examples/bare_metal_swarm.exs
```

### 3. Hybrid
Mix local, Docker, and SSH agents in the same swarm.

```elixir
%{
  agents: [
    %{name: :coordinator, backend: :local},
    %{name: :worker_1, backend: {:docker, "worker"}},
    %{name: :remote_1, backend: {:ssh, "root@192.168.1.51"}}
  ]
}
```

## Architecture

```
                        Application
                             │
                 ┌───────────┼───────────┐
                 │           │           │
           SwarmManager    Phoenix    Telemetry
                 │         (API)
    ┌──────┬─────┴─────┬──────┐
    │      │           │      │
 Registry Router  Skills  AgentDynSup
                              │
                    ┌─────────┼─────────┐
                    │    │    │    │    │
                  Agent Agent Agent Agent ...
                  (Port/Docker/SSH)

                             │
                      SwarmRegistry (SQLite)
                             │
                 Cross-process state & task queue
```

### API-First Architecture

The Phoenix server exposes a pure JSON REST API and WebSocket for real-time events. No HTML/frontend is included - bring your own frontend (React, Vue, etc.) or use the CLI.

```
External Frontend                   Phoenix API Server
(React, Vue, etc.)                         │
        │                                  ├── REST API (/api/*)
        ├── HTTP ─────────────────────────►├── WebSocket (/swarm)
        │                                  └── CORS enabled
        │
        │                           Daemon Process (swarm start)
        │                                  │
        └── (optional) ───────────────────►├── SwarmManager
                                           ├── Agents/Containers
                                           └── SwarmRegistry (SQLite)
```

### Daemon Architecture

Swarms run as independent OS processes (daemons), separate from the API server:

```
API Server (Phoenix)                 Daemon Process (swarm start)
        │                                      │
        ├── REST API                           ├── SwarmManager
        ├── WebSocket                          ├── Agents/Containers
        └── SwarmRegistry ◄──── SQLite ────► SwarmRegistry
              (query state)                    (write state)
              (queue tasks)                    (poll tasks @ 500ms)
```

## Installation

### With Nix (recommended)

```bash
# Enter development shell
nix develop

# Install dependencies
mix deps.get

# Build the swarm CLI
mix escript.build
sudo cp swarm /usr/local/bin/   # or ~/.local/bin/

# Start the API server
swarm up
```

### Without Nix

Requires Elixir 1.17+, Erlang 27+

```bash
mix deps.get

# Build the swarm CLI
mix escript.build
cp swarm ~/.local/bin/

# Start the API server
swarm up
```

### Building Agent Containers

```bash
# Build NixOS-based container images
nix build .#agentContainer-base
nix build .#agentContainer-web
nix build .#agentContainer-code
nix build .#agentContainer-data
nix build .#agentContainer-full

# Load into Docker
docker load < result
```

## Quick Start

### Create a new project

```bash
# Create a new swarm project with example configs
swarm init my-project
cd my-project

# Copy and configure environment
cp .env.example .env
# Edit .env with your API keys
```

### Start the API server

```bash
# Start Phoenix in background
swarm up

# Check status
swarm status
```

### Start a swarm from config

```bash
swarm start swarms/example_swarm.exs
```

### Check status

```bash
swarm status                     # Show all status (server + swarms)
swarm status example-swarm       # Specific swarm details
```

### Send a task to an agent

```bash
swarm task example-swarm researcher "find papers on transformers"
```

### Send messages between agents

```bash
swarm msg example-swarm researcher coder "Please implement this algorithm"
```

### Stream agent logs

```bash
swarm logs example-swarm              # All agents
swarm logs example-swarm researcher   # Specific agent
swarm logs example-swarm -f           # Follow mode
```

### Stop the swarm

```bash
swarm stop example-swarm
```

### Stop everything

```bash
swarm down   # Stops all swarms + Phoenix server
```

### List available skills

```bash
swarm list-skills
```

## CLI Reference

The `swarm` CLI provides a unified interface for all operations. Build and install it as an escript:

```bash
# Build the escript
mix escript.build

# Install globally (choose one)
sudo cp swarm /usr/local/bin/       # System-wide
cp swarm ~/.local/bin/              # User-local (ensure ~/.local/bin is in PATH)
mix escript.install                 # Via mix (installs to ~/.mix/escripts)
```

### Commands

| Command | Description |
|---------|-------------|
| `swarm init [dir]` | Create new project structure |
| `swarm up` | Start Phoenix API server (background) |
| `swarm down` | Stop everything (API server + all swarms) |
| `swarm start <config>` | Start a swarm from configuration |
| `swarm stop <name>` | Stop a running swarm |
| `swarm restart <name>` | Restart a swarm |
| `swarm restart <name> --delete` | Restart with clean slate (delete old data) |
| `swarm pause <name>` | Pause a swarm (freeze containers) |
| `swarm resume <name>` | Resume a paused swarm |
| `swarm delete <name>` | Delete swarm and all its data |
| `swarm clean` | Clean up stopped/crashed swarms |
| `swarm clean --all` | Also clear all events from database |
| `swarm restart-agent <swarm> <agent>` | Restart a specific agent |
| `swarm status [name]` | Show status of server and swarms |
| `swarm logs [swarm] [agent]` | Stream agent logs |
| `swarm task <swarm> <agent> <msg>` | Send task to an agent |
| `swarm msg <swarm> <from> <to> <msg>` | Send message between agents |
| `swarm env [list\|get\|set]` | Manage environment variables |
| `swarm build [image]` | Build Docker images via nix |
| `swarm config validate <file>` | Validate configuration files |
| `swarm list-skills` | List available skills |
| `swarm events` | View recent events |

Additionally, the following mix tasks are available:

| Command | Description |
|---------|-------------|
| `mix swarm.test` | Run e2e tests on example swarm configurations |
| `mix swarm.test --validate-only` | Only validate configs, don't run |
| `mix swarm.test --mock script.json` | Run with mock backend (no LLM calls) |

All commands can also be run via mix: `mix swarm <command>`.

### Daemon Swarms

Swarms run as independent OS daemon processes, separate from the API server:

```bash
# Start swarm as daemon (runs in background)
swarm start swarms/my_swarm.exs

# API server can monitor and control running daemon swarms
swarm up

# Stop daemon swarm
swarm stop my-swarm
```

Benefits:
- Swarms survive API server restarts
- Multiple swarms can run simultaneously
- API server is optional (use CLI for headless operation)
- Tasks sent via API are queued and delivered by daemon

### Event Querying

View and filter events from all swarms:

```bash
# View last 50 events
swarm events

# Filter by error level
swarm events --errors

# Filter by swarm and/or agent
swarm events -s my-swarm
swarm events -s my-swarm -a coder

# Filter by time (last N minutes)
swarm events -n 5

# Real-time streaming
swarm events --follow

# Filter by category (backend, agent, routing, swarm)
swarm events --category backend
```

Event types include: agent started/stopped, task sent, message routed, Docker container events, API errors.

### Pause and Resume

Pause freezes all Docker containers for a swarm without stopping them:

```bash
# Pause a swarm (freeze all containers)
swarm pause my-swarm

# Resume a paused swarm
swarm resume my-swarm
```

Paused swarms maintain their state and can be resumed instantly. This is useful for:
- Temporarily freeing resources
- Debugging without losing state
- Switching between swarms on limited hardware

### Environment Management

The CLI automatically loads `.env` files from the current or parent directories:

```bash
# List all variables (sensitive values masked)
swarm env list

# Get a specific variable
swarm env get ANTHROPIC_API_KEY

# Set a variable
swarm env set PORT 3000

# Use a specific file
swarm env list --file .env.production
```

### Configuration Validation

Validate swarm configs before running:

```bash
swarm config validate swarms/my_swarm.exs
swarm config validate swarms/*.exs   # Glob patterns
```

## Configuration DSL

For detailed documentation on creating swarm configurations, see [docs/swarm_dsl.md](docs/swarm_dsl.md).

### Basic Example

```elixir
%{
  name: "research-swarm",
  agents: [
    %{name: :researcher, skills: ["web.md"], backend: :local},
    %{name: :coder, skills: ["code.md"], backend: {:docker, "agent-coder"}},
    %{name: :reviewer, skills: ["review.md"], backend: {:ssh, "pi@192.168.1.50"}}
  ],
  topology: [
    {:researcher, :coder},
    {:coder, :reviewer},
    {:reviewer, :coder}
  ]
}
```

### Per-Agent Model Configuration

Each agent can specify its own LLM model using OpenRouter format (`provider/model-name`):

```elixir
%{
  name: "mixed-model-swarm",
  agents: [
    %{
      name: :researcher,
      backend: :local,
      model: "anthropic/claude-sonnet-4",    # Claude for research
      skills: ["research.md"]
    },
    %{
      name: :coder,
      backend: :local,
      model: "deepseek/deepseek-chat",       # DeepSeek for coding (cheaper)
      skills: ["code.md"]
    },
    %{
      name: :reviewer,
      backend: :local,
      model: "openai/gpt-4o",                # GPT-4o for review
      skills: ["review.md"]
    }
  ],
  topology: [
    {:researcher, :coder},
    {:coder, :reviewer},
    {:reviewer, :researcher}
  ]
}
```

Popular models available via OpenRouter (see [openrouter.ai/models](https://openrouter.ai/models) for full list):

| Model | Provider | Description |
|-------|----------|-------------|
| `anthropic/claude-sonnet-4` | Anthropic | Balanced Claude model |
| `anthropic/claude-opus-4` | Anthropic | Most capable Claude model |
| `openai/gpt-4o` | OpenAI | GPT-4o |
| `openai/gpt-4o-mini` | OpenAI | Fast and cheap |
| `deepseek/deepseek-chat` | DeepSeek | Very affordable |
| `google/gemini-2.0-flash-001` | Google | Gemini Flash |

If no model is specified for an agent, it falls back to `SUBZEROCLAW_MODEL` environment variable.

### Backend Types

| Backend | Syntax | Description |
|---------|--------|-------------|
| Local | `:local` | Run as local subprocess via Elixir Port |
| Docker | `{:docker, "container"}` | Run in Docker container |
| Docker with opts | `{:docker, "container", %{...}}` | Docker with options |
| SSH | `{:ssh, "user@host"}` | Run on remote machine via SSH |
| SSH with opts | `{:ssh, "user@host", %{...}}` | SSH with options |
| Bwrap | `:bwrap` | Lightweight bubblewrap sandbox (NixOS) |
| Bwrap with opts | `{:bwrap, %{memory_limit: "256M"}}` | Bwrap with resource limits |
| Mock | `:mock` | Mock backend for testing (no LLM) |
| Mock with script | `{:mock, %{script: [...]}}` | Mock with canned response script |

### Configuration Formats

Swarm configs can be written in multiple formats:

- `.exs` - Elixir term files (recommended)
- `.json` - JSON files
- `.yaml` / `.yml` - YAML files

## Inter-Agent Communication

Agents communicate using `@agent_name:` prefixes in their output:

```
ASST: I've analyzed the paper. @coder: Please implement the algorithm
described in section 3. Here's the pseudocode: ...
```

Broadcast to all connected agents:

```
ASST: @all: Task completed successfully.
```

The orchestrator parses these patterns and routes messages according to the topology.

### File-Based Messaging

For sandboxed (bwrap) agents that cannot use stdin/stdout reliably, two file-based channels are available:

**File-inbox** (inbound): Messages delivered to an agent are also written to `{workspace}/.inbox/{seq}_{from}.json`:

```json
{"from": "pop_gen", "content": "...", "seq": 1, "timestamp": "2024-01-01T00:00:00Z"}
```

**File-outbox** (outbound): Agents can write JSON files to `{workspace}/.outbox/` instead of using `@agent:` syntax. The LogWatcher polls the outbox and routes messages via the Router:

```json
{"to": "runner", "content": "here is the fixed simulation"}
```

Or for broadcasts:

```json
{"broadcast": true, "content": "task completed"}
```

The `swarm-msg` helper supports outbox writing from inside a sandbox:

```bash
swarm-msg outbox <target> <message>       # Write to .outbox/ for routing
swarm-msg outbox-broadcast <message>      # Broadcast via .outbox/
```

### System Object Routing

The Router always allows messages to `:metrics`, `:tick`, and `:gateway` regardless of topology edges. Objects and agents can send state reports, heartbeats, etc. to these system objects without needing explicit topology connections.

## Objects (Non-Agentic Components)

Objects are Elixir modules implementing the `ObjectHandler` behaviour. They participate in the swarm topology but execute deterministic Elixir code instead of LLM calls.

```elixir
defmodule MyApp.Objects.Evaluator do
  @behaviour Genswarm.Objects.ObjectHandler

  @impl true
  def init(config), do: {:ok, %{config: config}}

  @impl true
  def interface(), do: %{evaluate: %{input: "configs", output: "results"}}

  @impl true
  def handle_message(from, content, state) do
    # Return: {:reply, response, state} | {:send, to, msg, state}
    #       | {:broadcast, msg, state} | {:noreply, state}
    #       | {:send_many, [{target, msg}], state}
    #       | {:multi, [{:send, to, msg} | {:broadcast, msg}], state}
    {:reply, "done", state}
  end
end
```

### ObjectServer `:send_many`

Objects can return `{:send_many, [{target, msg}], state}` from `handle_message/3` or `handle_info/2` to send multiple messages at once:

```elixir
def handle_message(_from, content, state) do
  results = process(content)
  messages = Enum.map(results, fn {agent, msg} -> {agent, msg} end)
  {:send_many, messages, state}
end
```

The `:send_many` return also accepts tagged tuples: `{:send, to, msg}` and `{:broadcast, msg}`.

## REST API

The API server returns JSON for all endpoints. CORS is enabled for all origins.

### API Info

```bash
# Get API info and documentation
curl http://localhost:4000/
```

### Swarm Management

```bash
# List all swarms
curl http://localhost:4000/api/swarms

# Get detailed swarm status (agents, objects, topology, file paths)
curl http://localhost:4000/api/swarms/research-swarm

# Create swarm from config file
curl -X POST http://localhost:4000/api/swarms \
  -H "Content-Type: application/json" \
  -d '{"config_path": "examples/research_swarm.exs"}'

# Create swarm from inline config
curl -X POST http://localhost:4000/api/swarms \
  -H "Content-Type: application/json" \
  -d '{"config": {"name": "my-swarm", "agents": [...], "topology": [...]}}'

# Stop swarm
curl -X DELETE http://localhost:4000/api/swarms/research-swarm

# Stop and purge all data
curl -X DELETE "http://localhost:4000/api/swarms/research-swarm?purge=true"

# Pause swarm (freeze containers)
curl -X POST http://localhost:4000/api/swarms/research-swarm/pause

# Resume paused swarm
curl -X POST http://localhost:4000/api/swarms/research-swarm/resume

# Restart swarm
curl -X POST http://localhost:4000/api/swarms/research-swarm/restart

# Restart with clean slate
curl -X POST "http://localhost:4000/api/swarms/research-swarm/restart?delete=true"

# Route message between agents
curl -X POST http://localhost:4000/api/swarms/research-swarm/message \
  -H "Content-Type: application/json" \
  -d '{"from": "researcher", "to": "coder", "content": "Please implement this"}'

# Clean up stopped/crashed swarms
curl -X POST http://localhost:4000/api/swarms/clean

# Clean and clear all events
curl -X POST "http://localhost:4000/api/swarms/clean?all=true"
```

### Agent Operations

```bash
# List agents in swarm
curl http://localhost:4000/api/swarms/research-swarm/agents

# Get agent status
curl http://localhost:4000/api/swarms/research-swarm/agents/researcher

# Send task to agent
curl -X POST http://localhost:4000/api/swarms/research-swarm/agents/researcher/task \
  -H "Content-Type: application/json" \
  -d '{"task": "find papers on transformers"}'

# Restart agent
curl -X POST http://localhost:4000/api/swarms/research-swarm/agents/researcher/restart

# Get agent logs
curl http://localhost:4000/api/swarms/research-swarm/agents/researcher/logs

# Get agent message history
curl http://localhost:4000/api/swarms/research-swarm/agents/researcher/history

# Get agent skills
curl http://localhost:4000/api/swarms/research-swarm/agents/researcher/skills

# Update agent skill
curl -X PUT http://localhost:4000/api/swarms/research-swarm/agents/researcher/skills/web.md \
  -H "Content-Type: application/json" \
  -d '{"content": "# Updated skill content..."}'
```

### Topology and Messages

```bash
# Get topology
curl http://localhost:4000/api/swarms/research-swarm/topology

# Get message log
curl http://localhost:4000/api/swarms/research-swarm/messages?limit=50
```

### Events

```bash
# Query all events
curl http://localhost:4000/api/events

# Query with filters
curl "http://localhost:4000/api/events?level=error&category=routing&limit=100"

# Get swarm events
curl http://localhost:4000/api/swarms/research-swarm/events

# Get agent events
curl http://localhost:4000/api/swarms/research-swarm/agents/researcher/events
```

### Skills

```bash
# List available skills
curl http://localhost:4000/api/skills

# Get skill content
curl http://localhost:4000/api/skills/web.md
```

### Config Validation

```bash
# Validate config from JSON
curl -X POST http://localhost:4000/api/config/validate \
  -H "Content-Type: application/json" \
  -d '{"config": {"name": "test", "agents": [], "topology": []}}'

# Validate config file
curl -X POST http://localhost:4000/api/config/validate \
  -H "Content-Type: application/json" \
  -d '{"config_path": "swarms/my_swarm.exs"}'
```

## WebSocket API

Connect to `/swarm` socket and join swarm channels for real-time updates:

```javascript
const socket = new Phoenix.Socket("/swarm")
socket.connect()

const channel = socket.channel("swarm:research-swarm", {})

channel.join()
  .receive("ok", resp => console.log("Joined:", resp))
  .receive("error", resp => console.log("Unable to join:", resp))

// Real-time events from server
channel.on("agent_output", data => console.log("Output:", data))
channel.on("message_routed", data => console.log("Routed:", data))
channel.on("message_broadcast", data => console.log("Broadcast:", data))
channel.on("agent_status", data => console.log("Status:", data))
channel.on("swarm_stopped", () => console.log("Swarm stopped"))
channel.on("log_entry", data => console.log("Log:", data))
channel.on("event", data => console.log("Event:", data))

// Send task
channel.push("send_task", {agent: "researcher", task: "find papers"})
  .receive("ok", resp => console.log("Task sent:", resp))
  .receive("error", resp => console.log("Error:", resp))

// Get status
channel.push("get_status", {})
  .receive("ok", status => console.log("Status:", status))

// Subscribe to log stream
channel.push("subscribe_logs", {agent: "researcher"})
  .receive("ok", resp => console.log("Subscribed:", resp.recent_logs))

// Subscribe to all logs
channel.push("subscribe_logs", {})

// Unsubscribe from logs
channel.push("unsubscribe_logs", {agent: "researcher"})

// Subscribe to event stream with filters
channel.push("subscribe_events", {filters: {level: "error"}})
  .receive("ok", resp => console.log("Subscribed:", resp.recent_events))

// Unsubscribe from events
channel.push("unsubscribe_events", {})
```

### WebSocket Events Reference

| Event | Direction | Description |
|-------|-----------|-------------|
| `send_task` | client→server | Send task to agent |
| `get_status` | client→server | Get swarm status |
| `subscribe_logs` | client→server | Subscribe to log stream |
| `unsubscribe_logs` | client→server | Unsubscribe from logs |
| `subscribe_events` | client→server | Subscribe to event stream |
| `unsubscribe_events` | client→server | Unsubscribe from events |
| `agent_output` | server→client | Agent output |
| `message_routed` | server→client | Message routed between agents |
| `message_broadcast` | server→client | Broadcast message sent |
| `agent_status` | server→client | Agent status change |
| `swarm_stopped` | server→client | Swarm was stopped |
| `log_entry` | server→client | Real-time log entry |
| `event` | server→client | Real-time event |

## Docker Deployment

### Using Docker Compose

See `examples/docker-compose.yml` for a complete deployment example:

```bash
cd examples
export SUBZEROCLAW_API_KEY=your_api_key
export SECRET_KEY_BASE=$(mix phx.gen.secret)
docker-compose up -d
```

### Building the Orchestrator Image

```bash
docker build -t subzeroclaw-swarm .
docker run -p 4000:4000 \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e SUBZEROCLAW_API_KEY=$SUBZEROCLAW_API_KEY \
  subzeroclaw-swarm
```

## Skills

Skills are markdown files in `priv/skills/` that define agent behavior and capabilities. They are deployed to each agent's skills directory.

### Built-in Skills

| Skill | Description |
|-------|-------------|
| `web.md` | Web research and information gathering |
| `code.md` | Code implementation and debugging |
| `review.md` | Code review and quality assessment |

### Creating Custom Skills

Create a markdown file in `priv/skills/`:

```markdown
# My Custom Skill

You are a specialist in [domain]. Your role is to [description].

## Capabilities
- Capability 1
- Capability 2

## Guidelines
1. Guideline 1
2. Guideline 2

## Communication
When communicating with other agents, use @agent_name: prefix.
```

### Skill Templating

Skills support template variables that are resolved when deployed to each agent:

| Variable | Resolved To |
|----------|-------------|
| `{{agent_name}}` | The agent's name (e.g., `fixer_3`) |
| `{{swarm_name}}` | The swarm name |
| `{{workspace}}` | The agent's workspace path |

Example skill using templates:

```markdown
# Fixer Agent

You are {{agent_name}} in the {{swarm_name}} swarm.
Your workspace is {{workspace}}.

Write output files to your workspace directory.
```

### Per-Agent Workspaces

When using `count: N` to create multiple instances of an agent, the compiler automatically appends the agent name to the workspace path. For example:

```elixir
%{
  name: :fixer,
  count: 20,
  backend: :bwrap,
  config: %{workspace: "/tmp/phylo/workspace"}
}
```

This creates `fixer_1` through `fixer_20`, each with their own workspace:
- `fixer_1` gets `/tmp/phylo/workspace/fixer_1/`
- `fixer_2` gets `/tmp/phylo/workspace/fixer_2/`
- etc.

## Mock Backend

The mock backend (`backend: :mock`) runs agents without making LLM API calls, using canned responses instead. This is useful for testing swarm topologies and message routing.

```elixir
%{
  name: "test-swarm",
  agents: [
    %{
      name: :researcher,
      backend: {:mock, %{script: [
        %{match: "find papers", response: "@coder: implement this algorithm"},
        %{match: ".*", response: "acknowledged"}
      ]}},
      skills: ["research.md"]
    }
  ],
  topology: [{:researcher, :coder}]
}
```

The mock backend pattern-matches incoming messages against the script and returns the first matching response.

## E2E Testing

The `mix swarm.test` command provides automated end-to-end testing of swarm configurations:

```bash
mix swarm.test                           # Validate + run all examples
mix swarm.test --validate-only           # Only validate configs, don't run
mix swarm.test --example tic-tac-toe     # Test a specific example
mix swarm.test --mock script.json        # Run with mock backend (no LLM)
mix swarm.test --timeout 60000           # Custom timeout per swarm (ms)
mix swarm.test --steps 3                 # Steps for .sim examples
mix swarm.test --logs-dir /tmp/logs      # Custom logs directory
```

Test output is saved to `.test-logs/`:

```
.test-logs/
├── tic_tac_toe_swarm.log
├── party_swarm.log
└── summary.log
```

Exit code is 0 if all pass, 1 if any fail.

## Bwrap Backend

The bubblewrap (bwrap) backend provides lightweight process isolation using Linux user namespaces, enabling 10k+ agents on a single NixOS machine:

| Metric | Docker | Bwrap |
|--------|--------|-------|
| RAM per agent | ~50MB | ~500KB |
| Startup time | 2-3s | ~50ms |
| External daemon | Yes (SPOF) | No |
| 10k agents RAM | ~500GB | ~5GB |

### Bwrap Agent Configuration

```elixir
%{
  name: :worker,
  backend: :bwrap,
  config: %{
    workspace: "/tmp/my-workspace",
    memory_limit: "256M",
    extra_path: ["/opt/tools/bin"],
    extra_ro_binds: [{"/home/user/project", "/project"}]
  }
}
```

Backend-specific keys (separated from domain config):
- `workspace` - Agent workspace directory
- `extra_path` - Additional PATH directories inside the sandbox
- `extra_ro_binds` - Read-only bind mounts as `[{host_path, container_path}]`
- `memory_limit` - Memory limit (default: `"256M"`)
- `cpu_shares` - CPU shares (default: `100`)
- `tasks_max` - Max tasks/processes (default: `50`)

### Binary Path Resolution

The bwrap backend searches for the `subzeroclaw` binary in this order:
1. Explicit config (`subzeroclaw_path` in agent config)
2. `../subzeroclaw/subzeroclaw` (sibling checkout, when running from the swarm repo)
3. `../subzeroclaw/subzeroclaw` relative to the swarm source dir (when used as a dependency)
4. `SUBZEROCLAW_PATH` environment variable
5. System PATH (via `which subzeroclaw`)

## Programmatic Usage

### Starting a Swarm

```elixir
# From config file
{:ok, swarm_name} = Genswarm.start_swarm("path/to/config.exs")

# From config map
config = %{
  name: "my-swarm",
  agents: [%{name: :agent1, backend: :local}],
  topology: []
}
{:ok, swarm_name} = Genswarm.start_swarm_from_config(config)
```

### Managing Swarms

```elixir
# Get status
{:ok, status} = Genswarm.status("my-swarm")

# Send task
:ok = Genswarm.send_task("my-swarm", :agent1, "do something")

# List swarms
swarms = Genswarm.list_swarms()

# Get topology
{:ok, topology} = Genswarm.get_topology("my-swarm")

# Stop swarm
:ok = Genswarm.stop_swarm("my-swarm")
```

### Subscribing to Events

```elixir
# Subscribe to swarm events
Phoenix.PubSub.subscribe(Genswarm.PubSub, "swarm:my-swarm")
Phoenix.PubSub.subscribe(Genswarm.PubSub, "swarm:my-swarm:output")
Phoenix.PubSub.subscribe(Genswarm.PubSub, "swarm:my-swarm:routing")

# Handle events
def handle_info({:agent_output, agent, content}, state) do
  IO.puts("#{agent}: #{content}")
  {:noreply, state}
end
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SUBZEROCLAW_API_KEY` | API key for LLM provider (OpenRouter, Anthropic, etc.) | - |
| `SUBZEROCLAW_MODEL` | Default model for agents (OpenRouter format) | `anthropic/claude-sonnet-4` |
| `SUBZEROCLAW_ENDPOINT` | API endpoint URL | Auto-detected from key |
| `SUBZEROCLAW_PATH` | Path to subzeroclaw binary | `subzeroclaw` |
| `SUBZEROCLAW_SRC` | Source directory for Docker containers | `../subzeroclaw` |
| `SUBZEROCLAW_MOCK_SCRIPT` | Path to mock script JSON (skips LLM API calls) | - |
| `SWARM_DATA_DIR` | Directory for swarm data | `~/.subzeroclaw/swarms` |
| `SWARM_TOPOLOGY` | (Container only) Comma-separated targets for `swarm-msg list` | Auto-set |
| `SKILLS_DIR` | Directory for skill files | `priv/skills` |
| `SECRET_KEY_BASE` | Phoenix secret key (prod) | - |
| `PHX_HOST` | Phoenix host (prod) | `localhost` |
| `PORT` | HTTP port | `4000` |
| `LOG_LEVEL` | Log level (debug, info, warn, error) | `info` |

## Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Run tests with coverage
mix test --cover

# Start development server
mix phx.server

# Format code
mix format

# Run static analysis
mix credo
```

## Troubleshooting

### Agent not starting

1. Check that the subzeroclaw binary is in PATH or `SUBZEROCLAW_PATH` is set
2. Verify API key is configured
3. Check logs: `mix swarm status swarm-name`

### Messages not routing

1. Verify topology allows the route: source -> target
2. Check agent is using correct `@agent:` syntax
3. View message log via API: `GET /api/swarms/{name}/messages`

### SSH backend fails

1. Verify SSH key authentication works: `ssh user@host`
2. Check remote subzeroclaw path is correct
3. Ensure skills directory is writable on remote

### Docker backend fails

1. Verify Docker is running: `docker ps`
2. Check image exists: `docker images`
3. Review container logs: `docker logs container-name`

### Tasks not being delivered to daemon swarms

1. Check daemon is running: `swarm status`
2. View pending tasks in events: `swarm events --category agent`
3. Verify daemon is polling: check `.swarm/swarms.db` tasks table
4. Check for errors: `swarm events --errors`

### API returns errors

1. Check API is running: `curl http://localhost:4000/`
2. Verify CORS is working for your frontend origin
3. Check server logs for detailed error messages
