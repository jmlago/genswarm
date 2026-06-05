# Messaging

Genswarms agents coordinate by sending messages to one another. Messages flow through a central `Genswarms.Routing.Router`, which validates every hop against the swarm topology before delivering it. This page covers the message syntax agents emit, how topology gates routing, the always-routable system objects, the file-based inbox and outbox channels, and the `swarm-msg` helper available inside agent sandboxes.

## The `@agent_name:` syntax

In their natural-language output, agents address another agent by prefixing a line with `@target:`. The orchestrator parses these prefixes and routes the rest of the message to the named agent.

```
ASST: I've analyzed the paper. @coder: Please implement the algorithm
described in section 3. Here's the pseudocode: ...
```

To reach every agent the sender is connected to, use `@all:`:

```
ASST: @all: Task completed successfully.
```

Under the hood, agent output is translated into structured `SWARM_MSG` markers that `Genswarms.Agents.AgentProtocol` and `Genswarms.Agents.LogWatcher` recognize:

```
<<SWARM_MSG:TO=coder:START>>
Please implement the algorithm.
<<SWARM_MSG:END>>
```

```
<<SWARM_MSG:BROADCAST:START>>
Task completed successfully.
<<SWARM_MSG:END>>
```

A target name must match `[a-zA-Z_][a-zA-Z0-9_]*`. The newline after `:START>>` is optional. `LogWatcher` polls each agent's log files every 500 ms, extracts these blocks, and forwards them to the Router as `:send` or `:broadcast` messages.

## How topology gates routing

The Router keeps each swarm's topology as an adjacency map: for every source agent it stores the list of targets that source is allowed to reach. The topology is built from the `topology:` edges in your swarm config.

```elixir
topology: [
  {:researcher, :coder},
  {:coder, :reviewer}
]
```

When a message is routed, the Router checks whether the target is in the source's adjacency list:

- If allowed, the message is delivered to the target (agent or object), logged, and emitted as a `:message_routed` telemetry event and PubSub broadcast.
- If not allowed, the message is dropped, a warning is logged, and an `:invalid_route` telemetry event is emitted listing the allowed targets.

A broadcast (`@all:`) is delivered to every target in the source's adjacency list. An agent with no outgoing edges can broadcast, but the message reaches no one.

Edges are directed. `{:researcher, :coder}` lets `researcher` message `coder`, but not the reverse — add `{:coder, :researcher}` for a reply path.

## System object routing

Three targets are always routable regardless of topology edges, defined as `@system_objects` in the Router:

| Target | Purpose |
|--------|---------|
| `:metrics` | Collect state reports and counters |
| `:tick` | Clock / heartbeat coordination |
| `:gateway` | External ingress/egress |

Any agent or object may send to `:metrics`, `:tick`, or `:gateway` without an explicit topology edge. This lets objects emit state reports, heartbeats, and similar signals without wiring them into every node of the graph. See [objects.md](objects.md) for handlers that typically consume these.

## File-based messaging

Sandboxed (bwrap) agents cannot always rely on stdin/stdout. For them, two file-based channels mirror the in-band protocol. Both live under the agent's `workspace`.

### File-inbox (inbound)

Every message delivered to an agent is also written to `{workspace}/.inbox/{seq}_{from}.json`, giving sandboxed agents a reliable place to read incoming messages. The sequence number is zero-padded to four digits (for example `0001_researcher.json`).

```json
{"from": "researcher", "content": "Please implement the algorithm.", "seq": 1, "timestamp": "2024-01-01T00:00:00Z"}
```

The file-inbox is a delivery convenience; it is written in addition to the agent's normal in-process delivery, not instead of it.

### File-outbox (outbound)

Instead of emitting `@agent:` syntax, an agent can drop a JSON file into `{workspace}/.outbox/`. `LogWatcher` polls the outbox every 500 ms, processes files in sorted order, routes each one through the Router, and deletes it afterward.

A directed send:

```json
{"to": "coder", "content": "here is the fixed simulation"}
```

A broadcast:

```json
{"broadcast": true, "content": "task completed"}
```

Files that match neither shape are logged as invalid and removed.

## The `swarm-msg` helper

`swarm-msg` is the agent-side messaging CLI available inside agent sandboxes. It writes outbox files for you, so skills can call it instead of formatting JSON by hand. (The name `swarm-msg` is intentional — it belongs to the agent side and is not renamed.)

| Command | Description |
|---------|-------------|
| `swarm-msg send <agent> <message>` | Send a message to an agent via the outbox |
| `swarm-msg send <agent> -f <file>` | Send a file's contents to an agent |
| `swarm-msg broadcast <message>` | Broadcast to all connected agents |
| `swarm-msg list` | List agents you can message (from topology) |
| `swarm-msg send-stdout <agent> <msg>` | Legacy: send via the stdout `SWARM_MSG` protocol |
| `swarm-msg help` | Show usage |

Examples:

```bash
# Send a JSON payload to another agent
swarm-msg send coder '{"action":"fix_result","status":"fixed"}'

# Send a state report to the metrics system object
swarm-msg send metrics '{"action":"state_report","data":{"state":{"count":42}}}'

# Broadcast to everyone you are connected to
swarm-msg broadcast "Phase complete, ready for next"

# Send the contents of a file
swarm-msg send reviewer -f /workspace/fix.patch
```

`send` and `broadcast` write zero-padded JSON files (for example `0001_coder.json`) into `/workspace/.outbox/`, which the router picks up automatically. The legacy `send-stdout` and `broadcast-stdout` subcommands instead print `SWARM_MSG` markers to stdout for log-based routing.

### `SWARM_TOPOLOGY` for `swarm-msg list`

Inside a container, `swarm-msg list` reads the `SWARM_TOPOLOGY` environment variable — a comma-separated list of the targets the agent is connected to — and prints them. If `SWARM_TOPOLOGY` is unset, it reports that the topology is not available.

```bash
$ swarm-msg list
Agents you can message:
  - coder
  - reviewer
```

## See also

- [configuration.md](configuration.md) — defining agents, objects, and the `topology:` edges that gate routing
- [objects.md](objects.md) — non-agentic handlers that send and receive routed messages, including system objects
- [skills.md](skills.md) — skill files that drive what agents say and how they call `swarm-msg`
