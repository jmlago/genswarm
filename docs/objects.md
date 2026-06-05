# Objects Guide

Objects are non-agentic components that participate in swarm topology. They execute Elixir code (or run their own Docker containers) instead of LLM calls, providing deterministic, fast, and cost-effective computation for tasks that don't require AI reasoning.

## When to Use Objects

### Use Objects When:

1. **Multiple agents need shared, custom computation**
   - A fitness evaluator that all GA agents send candidates to
   - A coordinator that tracks state across all agents
   - A validator that checks outputs from multiple sources

2. **Deterministic, repeatable results are required**
   - Test runners, compilers, linters
   - Mathematical computations, simulations
   - Data transformations, aggregations

3. **High-throughput or low-latency is needed**
   - Objects respond in milliseconds, not seconds
   - No token costs, no API rate limits
   - Can process thousands of messages per second

4. **Custom business logic needs to run locally**
   - Proprietary algorithms you can't expose to APIs
   - Integration with local databases or file systems
   - Real-time sensor data processing

### Don't Use Objects When:

| Scenario | Better Alternative |
|----------|-------------------|
| Single agent needs a CLI tool | Use NixOS presets/tools (`:base`, `:code`, etc.) |
| Need external service (email, blockchain) | Use internet APIs directly from agent |
| Need AI reasoning or creativity | Use an agent |
| One-off computation | Have agent run the code directly |

### Decision Flowchart

```
                    Does it need AI reasoning?
                           /          \
                         Yes           No
                          |             |
                       Agent      Is it shared between agents?
                                       /          \
                                     Yes           No
                                      |             |
                              Is it custom code?   Agent with CLI tools
                                 /          \
                               Yes           No
                                |             |
                             Object      Internet API
```

## Creating an Object Handler

Objects are implemented as Elixir modules that implement the `Genswarm.Objects.ObjectHandler` behaviour.

### Required Callbacks

```elixir
defmodule MyApp.Objects.MyHandler do
  @behaviour Genswarm.Objects.ObjectHandler

  @impl true
  def init(config) do
    # Initialize state from config
    # Called when the object starts
    {:ok, %{config: config, my_state: []}}
    # Or return {:error, reason} to fail startup
  end

  @impl true
  def handle_message(from, content, state) do
    # Process incoming message from agent/object `from`
    # `content` is always a string (typically JSON)
    # Return one of:
    #   {:reply, response, new_state}     - Send response back to sender
    #   {:send, to, message, new_state}   - Send to specific target
    #   {:broadcast, message, new_state}  - Send to all connected in topology
    #   {:noreply, new_state}             - No response, just update state
  end

  @impl true
  def interface() do
    # Return schema describing what this object does
    # Used by swarm-msg list and dashboard
    %{
      process: %{
        input: "JSON with data field",
        output: "JSON with result field"
      },
      status: %{
        input: "none",
        output: "JSON with state info"
      }
    }
  end
end
```

### Optional Callbacks

```elixir
@impl true
def terminate(reason, state) do
  # Cleanup when object is stopping
  # Close file handles, connections, etc.
  :ok
end
```

### Complete Example: Evaluator

```elixir
defmodule Phylogenesis.Objects.Evaluator do
  @behaviour Genswarm.Objects.ObjectHandler
  require Logger

  @impl true
  def init(config) do
    Logger.info("Starting Evaluator with config: #{inspect(config)}")
    {:ok, %{
      config: config,
      results: [],
      parallel: Map.get(config, :parallel, true),
      timeout: Map.get(config, :timeout, 300_000)
    }}
  end

  @impl true
  def interface do
    %{
      evaluate: %{
        input: "JSON: {action: 'evaluate', configs: [...]}",
        output: "JSON: {results: [...], top_k: [...], pareto_front: [...]}"
      },
      status: %{
        input: "JSON: {action: 'status'}",
        output: "JSON: {state: atom, running: int, completed: int}"
      }
    }
  end

  @impl true
  def handle_message(from, content, state) do
    case Jason.decode(content) do
      {:ok, %{"action" => "evaluate", "configs" => configs}} ->
        results = run_evaluations(configs, state)
        response = Jason.encode!(%{
          results: results,
          top_k: Enum.take(results, 3),
          pareto_front: compute_pareto(results)
        })
        # Broadcast to all connected agents (fixer, crossover, etc.)
        {:broadcast, response, %{state | results: results}}

      {:ok, %{"action" => "status"}} ->
        response = Jason.encode!(%{
          state: :idle,
          completed: length(state.results)
        })
        {:reply, response, state}

      _ ->
        Logger.warning("Unknown message from #{from}")
        {:noreply, state}
    end
  end

  defp run_evaluations(configs, state) do
    if state.parallel do
      configs
      |> Task.async_stream(&evaluate_one/1, timeout: state.timeout)
      |> Enum.map(fn {:ok, r} -> r end)
    else
      Enum.map(configs, &evaluate_one/1)
    end
  end

  defp evaluate_one(config) do
    # Your evaluation logic here
    %{id: config["id"], fitness: :rand.uniform() * 100}
  end

  defp compute_pareto(results), do: results  # Simplified
end
```

## Configuring Objects in Swarm DSL

### Basic Object Definition

```elixir
%{
  name: "my-swarm",

  agents: [
    %{name: :worker_1, backend: :local, skills: ["work.md"]},
    %{name: :worker_2, backend: :local, skills: ["work.md"]}
  ],

  objects: [
    %{
      name: :coordinator,
      handler: MyApp.Objects.Coordinator,
      config: %{
        max_queue_size: 100,
        timeout: 30_000
      }
    }
  ],

  topology: [
    {:worker_1, :coordinator},
    {:worker_2, :coordinator},
    {:coordinator, :worker_1},
    {:coordinator, :worker_2}
  ]
}
```

### Object Configuration Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | atom/string | Yes | Unique identifier in swarm |
| `handler` | module | For native | Elixir module implementing `ObjectHandler` |
| `backend` | backend_spec | For Docker/SSH | Backend specification (like agents) |
| `config` | map | No | Configuration passed to handler or backend |

**Note:** Objects require either `handler` (for native Elixir) OR `backend` (for Docker/SSH).

### Objects in Topology

Objects participate in topology just like agents:

```elixir
topology: [
  # Agents send to object
  {:pop_gen, :eval},
  {:mutator, :eval},

  # Object sends to agents
  {:eval, :fixer},
  {:eval, :crossover},

  # Objects can send to other objects
  {:eval, :logger}
]
```

## Message Protocol

### Sending Messages to Objects

Agents use `swarm-msg` to send to objects (same as sending to agents):

```bash
# From inside an agent
swarm-msg send eval '{"action": "evaluate", "configs": [...]}'
swarm-msg send coordinator '{"action": "status"}'
```

### Object Response Patterns

**Reply to Sender:**
```elixir
def handle_message(from, content, state) do
  result = process(content)
  {:reply, Jason.encode!(result), state}
end
```

**Send to Specific Target:**
```elixir
def handle_message(from, content, state) do
  result = process(content)
  {:send, :fixer, Jason.encode!(result), state}
end
```

**Broadcast to All Connected:**
```elixir
def handle_message(from, content, state) do
  results = process(content)
  # Sends to all targets in topology from this object
  {:broadcast, Jason.encode!(results), state}
end
```

**No Response:**
```elixir
def handle_message(from, content, state) do
  new_state = record(content, state)
  {:noreply, new_state}
end
```

## Backend Modes

Objects support the same backends as agents: native (local), Docker, and SSH.

### Native Objects (Default)

Native objects use an Elixir handler module and run in the same BEAM VM. Fast and simple.

```elixir
objects: [
  %{
    name: :coordinator,
    handler: MyApp.Objects.Coordinator,  # Elixir module
    config: %{max_queue: 100}
  }
]
```

### Docker Objects

Docker objects run in containers and communicate via JSON over stdin/stdout. No Elixir handler needed - the container implements the JSON protocol.

```elixir
objects: [
  %{
    name: :gpu_evaluator,
    backend: {:docker, "cuda-evaluator:latest", %{
      gpus: "all",
      memory_limit: "16g",
      volumes: [
        {"/data/models", "/models"}
      ]
    }},
    config: %{
      model_path: "/models/evaluator.pt"
    }
  }
]
```

**JSON Protocol for Docker/SSH Objects:**

The object receives messages as JSON on stdin:
```json
{"from": "agent_name", "content": "message content here"}
```

The object responds with JSON on stdout:
```json
{"action": "reply", "to": "agent_name", "content": "response here"}
{"action": "send", "to": "other_agent", "content": "message"}
{"action": "broadcast", "content": "message to all connected"}
{"action": "noreply"}
```

### SSH Objects

SSH objects run on remote machines, using the same JSON protocol:

```elixir
objects: [
  %{
    name: :remote_processor,
    backend: {:ssh, "user@gpu-server.local", %{
      key_path: "~/.ssh/id_ed25519"
    }},
    config: %{
      batch_size: 64
    }
  }
]
```

### Hybrid: Handler + Backend

You can specify both `handler` and `backend` - the backend runs the process, and the handler is passed as config (for containers that embed Elixir):

```elixir
objects: [
  %{
    name: :evaluator,
    handler: MyApp.Objects.Evaluator,  # Passed to container
    backend: {:docker, "elixir-runner:latest"},
    config: %{parallel: true}
  }
]
```

## Viewing Objects

### Dashboard

Objects appear in the topology graph as **squares** (agents are circles). The color indicates state:

| Color | State |
|-------|-------|
| Teal | Idle |
| Amber/Orange | Working |
| Red | Error |
| Gray | Unknown |

### swarm-msg list

```bash
$ swarm-msg list

Agents you can message:
  - pop_gen
  - fixer
  - crossover

Objects:
  - eval (object: Phylogenesis.Objects.Evaluator)
    Interface:
      evaluate(configs: list) -> {results, top_k, pareto_front}
      status() -> {state, running, completed}
```

### CLI Status

```bash
$ swarm status my-swarm

Swarm: my-swarm
Status: running
Started: 2024-01-15 10:30:00

Agents (4):
  - pop_gen     idle
  - fixer       idle
  - crossover   working
  - mutator     idle

Objects (1):
  - eval (Phylogenesis.Objects.Evaluator) idle
    Messages processed: 47

Topology:
  pop_gen → eval
  eval → fixer, crossover
  ...
```

## Programmatic API

### Starting Objects

Objects are automatically started when the swarm starts. To start manually:

```elixir
# Start an object
Genswarm.Objects.ObjectSupervisor.start_object(%{
  name: :my_object,
  swarm_name: "my-swarm",
  handler: MyApp.Objects.MyHandler,
  config: %{option: "value"}
})
```

### Stopping Objects

```elixir
Genswarm.Objects.ObjectSupervisor.stop_object("my-swarm", :my_object)
```

### Listing Objects

```elixir
Genswarm.Objects.ObjectSupervisor.list_objects("my-swarm")
# => [%{name: :eval, pid: "#PID<0.123.0>", state: :idle, handler: Evaluator}]
```

### Getting Object Status

```elixir
Genswarm.Objects.ObjectServer.get_status("my-swarm", :eval)
# => %{name: :eval, state: :idle, message_count: 47, handler: Evaluator, ...}
```

### Delivering Messages Programmatically

```elixir
Genswarm.Objects.ObjectServer.deliver_message(
  "my-swarm",
  :eval,
  :pop_gen,  # from
  ~s({"action": "evaluate", "configs": [...]})
)
```

## Common Object Patterns

### Accumulator Pattern

Collect results from multiple agents, process when complete:

```elixir
def handle_message(from, content, state) do
  {:ok, data} = Jason.decode(content)
  results = [data | state.results]

  if length(results) >= state.expected_count do
    aggregated = aggregate(results)
    {:broadcast, Jason.encode!(aggregated), %{state | results: []}}
  else
    {:noreply, %{state | results: results}}
  end
end
```

### Rate Limiter Pattern

Throttle requests to an external service:

```elixir
def init(config) do
  {:ok, %{
    rate_limit: Map.get(config, :rate_limit, 10),
    window_ms: Map.get(config, :window_ms, 1000),
    requests: []
  }}
end

def handle_message(from, content, state) do
  now = System.monotonic_time(:millisecond)
  recent = Enum.filter(state.requests, fn t -> now - t < state.window_ms end)

  if length(recent) < state.rate_limit do
    result = call_external_api(content)
    {:reply, result, %{state | requests: [now | recent]}}
  else
    {:reply, Jason.encode!(%{error: "rate_limited"}), state}
  end
end
```

### Cache Pattern

Cache expensive computations:

```elixir
def init(_config) do
  {:ok, %{cache: %{}, ttl_ms: 60_000}}
end

def handle_message(_from, content, state) do
  {:ok, %{"key" => key}} = Jason.decode(content)
  now = System.monotonic_time(:millisecond)

  case Map.get(state.cache, key) do
    {value, expires} when expires > now ->
      {:reply, value, state}

    _ ->
      value = expensive_computation(key)
      expires = now + state.ttl_ms
      cache = Map.put(state.cache, key, {value, expires})
      {:reply, value, %{state | cache: cache}}
  end
end
```

### State Machine Pattern

Track workflow state:

```elixir
def handle_message(from, content, state) do
  {:ok, %{"event" => event}} = Jason.decode(content)

  case {state.current_state, event} do
    {:idle, "start"} ->
      {:send, :worker, "begin", %{state | current_state: :running}}

    {:running, "complete"} ->
      {:broadcast, "done", %{state | current_state: :idle}}

    {:running, "error"} ->
      {:send, :fixer, "help needed", %{state | current_state: :error}}

    _ ->
      {:noreply, state}
  end
end
```

## Testing Objects

```elixir
defmodule MyApp.Objects.EvaluatorTest do
  use ExUnit.Case

  alias MyApp.Objects.Evaluator

  test "initializes with config" do
    assert {:ok, state} = Evaluator.init(%{parallel: false})
    assert state.parallel == false
  end

  test "handles evaluate action" do
    {:ok, state} = Evaluator.init(%{})
    content = Jason.encode!(%{action: "evaluate", configs: [%{id: "test"}]})

    assert {:broadcast, response, _new_state} =
      Evaluator.handle_message(:pop_gen, content, state)

    assert {:ok, %{"results" => [%{"id" => "test"}]}} = Jason.decode(response)
  end

  test "handles status action" do
    {:ok, state} = Evaluator.init(%{})
    content = Jason.encode!(%{action: "status"})

    assert {:reply, response, ^state} =
      Evaluator.handle_message(:anyone, content, state)

    assert {:ok, %{"state" => "idle"}} = Jason.decode(response)
  end
end
```

## Best Practices

1. **Keep handlers focused** - One object, one responsibility
2. **Use JSON for messages** - Consistent, parseable, loggable
3. **Handle errors gracefully** - Return error responses, don't crash
4. **Log important events** - Use `Logger` for debugging
5. **Document the interface** - Implement `interface/0` clearly
6. **Test handlers in isolation** - Unit test before integrating
7. **Consider state size** - Objects persist in memory
8. **Use timeouts** - Don't let async work hang forever

## Troubleshooting

### Object not receiving messages

1. Check topology includes edge from sender to object
2. Verify object name matches in topology and config
3. Check object state isn't `:error`

### Object crashes on message

1. Check `handle_message/3` handles all message formats
2. Add catch-all clause for unexpected messages
3. Wrap JSON parsing in error handling

### Object responses not routing

1. Verify return type is correct (`{:reply, ...}`, etc.)
2. Check target exists in topology for `{:send, to, ...}`
3. Ensure response content is a string (use `Jason.encode!`)
