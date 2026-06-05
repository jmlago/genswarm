# Programmatic API

Genswarms is an OTP application (`:genswarms`) and can be driven directly from
Elixir. The public surface lives in the `Genswarms` module
(`lib/genswarms.ex`), which delegates to `Genswarms.SwarmManager`. This guide
covers starting and managing swarms in process, sending tasks, and subscribing
to live events over `Phoenix.PubSub`.

Add `:genswarms` as a dependency (or work inside an `iex -S mix` session in the
project) and make sure the application is started so the supervision tree,
registries, and `Genswarms.PubSub` are running.

## Public functions

| Function | Signature | Returns |
|----------|-----------|---------|
| `start_swarm/1` | `start_swarm(config_path)` | `{:ok, swarm_name}` \| `{:error, reason}` |
| `start_swarm_from_config/1` | `start_swarm_from_config(config_map)` | `{:ok, swarm_name}` \| `{:error, reason}` |
| `status/1` | `status(swarm_name)` | `{:ok, map}` \| `{:error, :not_found}` |
| `send_task/3` | `send_task(swarm_name, agent_name, task)` | `:ok` \| `{:error, reason}` |
| `list_swarms/0` | `list_swarms()` | `[map]` |
| `get_topology/1` | `get_topology(swarm_name)` | `{:ok, map}` \| `{:error, reason}` |
| `stop_swarm/1` | `stop_swarm(swarm_name)` | `:ok` \| `{:error, reason}` |

`start_swarm_from_config/1`, `list_swarms/0`, and `stop_swarm/1` are convenience
delegates to `SwarmManager.start_from_config/1`, `SwarmManager.list/0`, and
`SwarmManager.stop/1` respectively. Note that this in-process API talks to the
local `SwarmManager` GenServer; it is independent of the daemon/CLI lifecycle
that goes through SQLite.

## Starting a swarm from a file

`start_swarm/1` loads a configuration file (`.exs`, `.json`, or `.yaml`/`.yml`)
and starts the swarm. It returns the swarm name on success.

```elixir
{:ok, swarm_name} = Genswarms.start_swarm("examples/tic-tac-toe/tic_tac_toe_swarm.exs")
```

## Starting a swarm from a config map

`start_swarm_from_config/1` skips file loading and takes the configuration map
directly — useful when you build configs programmatically.

```elixir
config = %{
  name: "example-swarm",
  agents: [
    %{name: :researcher, backend: :local, skills: ["web.md"]},
    %{name: :coder, backend: {:docker, "agent-coder"}, skills: ["code.md"]}
  ],
  topology: [
    {:researcher, :coder},
    {:coder, :researcher}
  ]
}

{:ok, swarm_name} = Genswarms.start_swarm_from_config(config)
```

See [configuration.md](configuration.md) for the full set of config keys.

## Inspecting and managing swarms

```elixir
# All running swarms (list of maps)
Genswarms.list_swarms()

# Detailed status for one swarm
{:ok, status} = Genswarms.status("example-swarm")

# Topology adjacency map
{:ok, topology} = Genswarms.get_topology("example-swarm")

# Stop a swarm
:ok = Genswarms.stop_swarm("example-swarm")
```

## Sending tasks to agents

`send_task/3` delivers a task string to a named agent. The agent name may be an
atom or a string; strings are converted to atoms internally.

```elixir
Genswarms.send_task("example-swarm", :researcher, "find papers on transformers")

# A string agent name works too
Genswarms.send_task("example-swarm", "coder", "implement the parser")
```

## Subscribing to events via PubSub

Genswarms broadcasts live activity on `Phoenix.PubSub` under the
`Genswarms.PubSub` name. Subscribe from any process and handle the messages in
`handle_info/2` (or receive them in an IEx session). Each broadcast is a plain
Erlang tuple — there is no JSON envelope at this layer.

### Per-swarm topics

The `SwarmManager` and `AgentServer` broadcast on swarm-scoped topics:

| Topic | Message | Meaning |
|-------|---------|---------|
| `"swarm:<name>"` | `{:swarm_stopped, swarm_name}` | The swarm was stopped. |
| `"swarm:<name>"` | `{:agent_added, swarm_name, name, spec}` | An agent was added. |
| `"swarm:<name>"` | `{:agent_removed, swarm_name, name}` | An agent was removed. |
| `"swarm:<name>"` | `{:topology_changed, swarm_name}` | The topology changed. |
| `"swarm:<name>:output"` | `{:agent_output, agent_name, content}` | Raw agent output. |
| `"swarm:<name>:status"` | `{:agent_status, agent_name, agent_state}` | An agent changed state. |
| `"swarm:<name>:routing"` | `{:message_routed, log_entry}` | A point-to-point message was routed. |
| `"swarm:<name>:routing"` | `{:message_broadcast, log_entry}` | A broadcast was routed. |

```elixir
Phoenix.PubSub.subscribe(Genswarms.PubSub, "swarm:example-swarm:routing")

receive do
  {:message_routed, entry} -> IO.inspect(entry, label: "routed")
  {:message_broadcast, entry} -> IO.inspect(entry, label: "broadcast")
end
```

### Observability event stream

The centralized event log exposes a helper API on
`Genswarms.Observability.LogStore` so you do not have to hardcode topic strings.
Events are broadcast as `{:log_event, event}`.

```elixir
alias Genswarms.Observability.LogStore

# All events
LogStore.subscribe()

# Only events for one swarm
LogStore.subscribe("example-swarm")

# Later
LogStore.unsubscribe()
```

A subscriber process then receives:

```elixir
def handle_info({:log_event, event}, state) do
  IO.inspect(event, label: "event")
  {:noreply, state}
end
```

Under the hood, `LogStore.subscribe/0` subscribes to the `"log_store:events"`
topic and `LogStore.subscribe/1` to `"log_store:events:<swarm>"`. Prefer the
helper functions over subscribing to the raw topics. See
[observability.md](observability.md) for querying historical events.

### Worked example: a GenServer subscriber

```elixir
defmodule ExampleSwarm.Watcher do
  use GenServer
  alias Genswarms.Observability.LogStore

  def start_link(swarm), do: GenServer.start_link(__MODULE__, swarm)

  @impl true
  def init(swarm) do
    LogStore.subscribe(swarm)
    Phoenix.PubSub.subscribe(Genswarms.PubSub, "swarm:#{swarm}:output")
    {:ok, %{swarm: swarm}}
  end

  @impl true
  def handle_info({:log_event, event}, state) do
    IO.inspect(event, label: "event")
    {:noreply, state}
  end

  def handle_info({:agent_output, agent, content}, state) do
    IO.puts("#{agent}: #{content}")
    {:noreply, state}
  end
end
```

## See also

- [objects.md](objects.md) — building deterministic non-agentic components
- [rest-api.md](rest-api.md) — the HTTP equivalent of these operations
- [observability.md](observability.md) — querying and streaming events
- [configuration.md](configuration.md) — the swarm configuration DSL
