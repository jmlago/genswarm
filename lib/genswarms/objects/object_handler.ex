defmodule Genswarms.Objects.ObjectHandler do
  @moduledoc """
  Behaviour module defining callbacks for object handlers.

  Objects are non-agentic GenServers that participate in the swarm topology,
  receive/send messages, but execute Elixir code instead of LLM calls.

  ## Example Implementation

      defmodule MyApp.Objects.Evaluator do
        @behaviour Genswarms.Objects.ObjectHandler

        @impl true
        def init(config) do
          {:ok, %{config: config, results: []}}
        end

        @impl true
        def interface do
          %{
            evaluate: %{
              input: "JSON list of swarm configs",
              output: "JSON with results, top_k, pareto_front"
            }
          }
        end

        @impl true
        def handle_message(from, content, state) do
          case Jason.decode(content) do
            {:ok, %{"action" => "evaluate", "configs" => configs}} ->
              results = evaluate_configs(configs)
              {:reply, Jason.encode!(results), state}

            _ ->
              {:noreply, state}
          end
        end
      end
  """

  @doc """
  Initializes the object handler state.

  Called when the ObjectServer starts. Returns the initial state
  that will be passed to subsequent callbacks.

  ## Return Values
    - `{:ok, state}` - Initialize with state
    - `{:ok, state, {:send, to, content}}` - Initialize and send message to agent/object
    - `{:error, reason}` - Failed to initialize
  """
  @callback init(config :: map()) ::
              {:ok, state :: term()}
              | {:ok, state :: term(), {:send, to :: atom(), content :: String.t()}}
              | {:error, reason :: term()}

  @doc """
  Handles an incoming message from an agent or another object.

  ## Arguments
    - `from` - The name (atom) of the sender
    - `content` - The message content (string)
    - `state` - Current handler state

  ## Return Values
    - `{:reply, response, new_state}` - Send response back to sender
    - `{:send, to, content, new_state}` - Send message to specific agent/object
    - `{:broadcast, content, new_state}` - Send to all connected nodes in topology
    - `{:noreply, new_state}` - No response, just update state
  """
  @callback handle_message(from :: atom(), content :: String.t(), state :: term()) ::
              {:reply, response :: String.t(), new_state :: term()}
              | {:send, to :: atom(), content :: String.t(), new_state :: term()}
              | {:broadcast, content :: String.t(), new_state :: term()}
              | {:noreply, new_state :: term()}

  @doc """
  Returns the interface schema for display in swarm-msg and dashboard.

  The interface describes what actions/methods the object supports
  and their expected inputs/outputs.
  """
  @callback interface() :: map()

  @doc """
  Handles process messages (timers, etc.) for native handlers.

  Optional callback for handlers that need to receive process-level messages,
  such as timer events from `Process.send_after/3`.

  ## Return Values
    - `{:reply, response, new_state}` - Send response back to sender
    - `{:send, to, content, new_state}` - Send message to specific agent/object
    - `{:broadcast, content, new_state}` - Send to all connected nodes in topology
    - `{:noreply, new_state}` - No response, just update state
  """
  @callback handle_info(msg :: term(), state :: term()) ::
              {:reply, response :: String.t(), new_state :: term()}
              | {:send, to :: atom(), content :: String.t(), new_state :: term()}
              | {:broadcast, content :: String.t(), new_state :: term()}
              | {:noreply, new_state :: term()}

  @doc """
  Called when the object is being terminated.

  Optional callback for cleanup.
  """
  @callback terminate(reason :: term(), state :: term()) :: :ok

  @doc """
  Returns dashboard contributions for the read-only swarm dashboard.

  Optional. If implemented, return a list of contribution maps with `:kind` set to
  `:sessions` (with `:items` list + optional `:pool` map) or `:extension` (with
  `:name` string and `:data` map). The aggregator merges contributions from all
  objects into the dashboard response.

  Omitting this callback (`:no_dashboard`) is the default and is always safe.
  """
  @callback dashboard(state :: term()) :: [map()]

  @doc """
  Returns the conversation transcript for a session, or `:not_available`.

  Optional. Called by the dashboard's `session_history` endpoint. The implementation
  should look up turns by `session_id` from whatever durable store it manages, and
  return `{:ok, [turn_map()]}` or `:not_available`.

  `opts` is reserved for future pagination / filtering parameters.
  """
  @callback session_history(state :: term(), session_id :: String.t(), opts :: map()) ::
              {:ok, [map()]} | :not_available

  @optional_callbacks [terminate: 2, handle_info: 2, dashboard: 1, session_history: 3]
end
