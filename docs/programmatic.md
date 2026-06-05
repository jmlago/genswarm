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
| `stop_swarm/1` | `stop_swarm(swarm_name)` | `{:ok, config_path}` \| `{:error, :not_found}` |

`start_swarm_from_config/1`, `list_swarms/0`, and `stop_swarm/1` are convenience
delegates to `SwarmManager.start_from_config/1`, `SwarmManager.list/0`, and
`SwarmManager.stop/1` respectively. Note that this in-process API talks to the
local `SwarmManager` GenServer; it is independent of the daemon/CLI lifecycle
that goes through SQLite.

> **Return shape note:** `stop_swarm/1` returns `{:ok, config_path}` (the path
> the swarm was started from, or `nil` if it was started from a config map), not
> a bare `:ok`. It returns `{:error, :not_found}` when the swarm isn't running.

## Starting a swarm from a file

`start_swarm/1` loads a configuration file (`.exs`, `.json`, or `.yaml`/`.yml`)
and starts the swarm. It returns the swarm name on success.

```elixir
{:ok, swarm_name} = Genswarms.start_swarm("examples/tic-tac-toe/tic_tac_toe_swarm.exs")
```

Failure modes worth handling:

- `{:error, reason}` — the config file failed to load or parse.
- `{:error, :already_exists}` — a swarm with that name is already running.
- `{:error, {:partial_start, errors}}` — the swarm record was created but one or
  more agents/objects failed to start. `errors` is a list of `{:error, reason}`
  tuples. The swarm is left in `:error` status; inspect it with `status/1` and
  stop it with `stop_swarm/1` if you want a clean restart.

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

# Stop a swarm (returns the config path it was started from, or nil)
{:ok, _config_path} = Genswarms.stop_swarm("example-swarm")
```

`status/1` returns a map with `:name`, `:status`, `:started_at`, `:config_path`,
`:agents`, `:objects`, `:agent_counts`, and a `:config` summary
(`:agent_count`, `:object_count`, `:topology_edges`). Each entry from
`list_swarms/0` carries `:name`, `:status`, `:started_at`, `:agent_count`, and
`:object_count`.

## Sending tasks to agents

`send_task/3` delivers a task string to a named agent. The agent name may be an
atom or a string; strings are converted to atoms internally before the task is
forwarded to the agent's `AgentServer`.

```elixir
Genswarms.send_task("example-swarm", :researcher, "find papers on transformers")

# A string agent name works too
Genswarms.send_task("example-swarm", "coder", "implement the parser")
```

## Runtime mutation (SwarmManager)

Beyond the `Genswarms` facade, `Genswarms.SwarmManager` exposes functions for
mutating a running swarm in place. These are not delegated through `Genswarms`,
so call them on `SwarmManager` directly. Most accept a `persist: true` option to
append the change to the swarm's overlay log so it survives a restart (default
is `false` — the change is in-memory only).

| Function | Purpose |
|----------|---------|
| `add_agent/3` | Add an agent at runtime. `opts`: `connections: [atom]`, `incoming: [atom]`, `persist: boolean`. Returns `{:ok, name}`. |
| `remove_agent/3` | Remove an agent (and its topology edges). Returns `:ok`. |
| `add_object/3` | Add a non-agentic object. Same opts as `add_agent/3`. |
| `remove_object/3` | Remove an object. |
| `add_topology_edges/3` | Add `[{from, to}]` edges. |
| `remove_topology_edges/3` | Remove `[{from, to}]` edges. |
| `scale_agent_group/4` | Scale a group `base`, `base_1`, `base_2`… to a target count. Returns `{:ok, %{added: [...], removed: [...], failed: [...]}}`. |
| `pause/1`, `resume/1`, `paused?/1` | Freeze/unfreeze the swarm's Docker containers. `pause`/`resume` return `{:ok, count}`. |
| `get_full_config/1` | Return the effective in-memory `SwarmConfig` (seed config merged with overlay). |

```elixir
alias Genswarms.SwarmManager

# Add an agent connected to :coder, persisted across restarts
{:ok, :reviewer} =
  SwarmManager.add_agent("example-swarm",
    %{name: :reviewer, backend: :local, skills: ["review.md"]},
    connections: [:coder], incoming: [:coder], persist: true)

# Scale a "fixer" pool up to 5 replicas (fixer_1 .. fixer_5)
{:ok, %{added: added, removed: removed, failed: failed}} =
  SwarmManager.scale_agent_group("example-swarm", :fixer, 5)
```

Each of these mutations broadcasts `{:topology_changed, swarm_name}` on the
`"swarm:<name>"` topic (see below).

## Subscribing to events via PubSub

Genswarms broadcasts live activity on `Phoenix.PubSub` under the
`Genswarms.PubSub` name. Subscribe from any process and handle the messages in
`handle_info/2` (or receive them in an IEx session). Each broadcast is a plain
Erlang tuple — there is no JSON envelope at this layer.

### Per-swarm topics

The `SwarmManager`, `AgentServer`, and `Router` broadcast on swarm-scoped
topics:

| Topic | Message | Meaning |
|-------|---------|---------|
| `"swarm:<name>"` | `{:swarm_started, swarm_name, status}` | The swarm finished starting. `status` is `:running` or `:error`. |
| `"swarm:<name>"` | `{:swarm_stopped, swarm_name}` | The swarm was stopped. |
| `"swarm:<name>"` | `{:agent_added, swarm_name, name, spec}` | An agent was added at runtime. |
| `"swarm:<name>"` | `{:agent_removed, swarm_name, name}` | An agent was removed at runtime. |
| `"swarm:<name>"` | `{:topology_changed, swarm_name}` | The topology changed (agent/object/edge mutation or scaling). |
| `"swarm:<name>:output"` | `{:agent_output, agent_name, content}` | Raw agent output. |
| `"swarm:<name>:status"` | `{:agent_status, agent_name, agent_state}` | An agent changed state (`agent_state` is a string, e.g. `"idle"`). |
| `"swarm:<name>:routing"` | `{:message_routed, log_entry}` | A point-to-point message was routed. |
| `"swarm:<name>:routing"` | `{:message_broadcast, log_entry}` | A broadcast was routed. |

The `log_entry` on the `:routing` topic is a map of the form:

```elixir
%{
  timestamp: ~U[...],
  swarm: "example-swarm",
  from: :researcher,
  to: :coder,                 # an atom for :message_routed,
                              # a list of atoms for :message_broadcast
  type: :direct,              # :direct or :broadcast
  content_preview: "first 100 chars of the message"
}
```

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

> **Note:** `LogStore.unsubscribe/0` only unsubscribes from the global
> `"log_store:events"` topic. If you subscribed to a swarm-specific stream with
> `LogStore.subscribe("example-swarm")`, unsubscribe from it directly with
> `Phoenix.PubSub.unsubscribe(Genswarms.PubSub, "log_store:events:example-swarm")`.

A subscriber process then receives:

```elixir
def handle_info({:log_event, event}, state) do
  IO.inspect(event, label: "event")
  {:noreply, state}
end
```

Each `event` is a map with `:id`, `:timestamp`, `:level`
(`:debug | :info | :warning | :error`), `:category`
(`:backend | :routing | :agent | :object | :swarm | :system`), `:swarm`,
`:agent`, `:event_type`, `:message`, and `:metadata`.

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