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
  Optional read-only snapshot for the observability dashboard.

  Receives the object's live `handler_state`. MUST be cheap and side-effect-free.
  Returns a list of tagged contributions:

    - `%{kind: :sessions, items: [session_map], optional :pool => map()}`
    - `%{kind: :extension, name: String.t(), data: map()}`

  Bodies (transcripts/logs) MUST NOT be returned here — fetch them lazily via
  `session_history/3`. The aggregate validates and timeboxes this call.
  """
  @callback dashboard(state :: term()) :: [map()]

  @doc """
  Optional durable transcript for one session. Bodies are fetched lazily here,
  never in `dashboard/1`. Returns `{:ok, [%{role, content}]}` when the object owns a
  durable, session-keyed transcript, or `:not_available` to let the caller fall back.
  """
  @callback session_history(state :: term(), session_id :: String.t(), opts :: map()) ::
              {:ok, [map()]} | :not_available

  @optional_callbacks [terminate: 2, handle_info: 2, dashboard: 1, session_history: 3]
end
