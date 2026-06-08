defmodule Genswarms.Observability.LogStore do
  @moduledoc """
  Centralized event logging for swarm observability.

  Provides:
  - ETS-backed storage with ordered timestamps
  - Ring buffer (configurable max events)
  - Real-time subscriptions via PubSub
  - Query interface for filtering/searching events

  ## Event Structure

      %{
        id: integer(),
        timestamp: DateTime.t(),
        level: :debug | :info | :warning | :error,
        category: :backend | :routing | :agent | :object | :swarm | :system,
        swarm: String.t() | nil,
        agent: atom() | nil,
        event_type: atom(),
        message: String.t(),
        metadata: map()
      }

  ## Usage

      # Log an event
      LogStore.log(:error, :backend, :docker_start_failed,
        "Failed to start container",
        swarm: "my-swarm", agent: :coder,
        metadata: %{image: "szc-agent-base", error: "image not found"})

      # Query events
      LogStore.query(level: :error, limit: 50)
      LogStore.query(swarm: "my-swarm", category: :backend)
      LogStore.query(minutes: 5, level: :error)

      # Subscribe to real-time events
      LogStore.subscribe()
  """

  use GenServer
  require Logger

  @table :subzeroclaw_logs
  @default_max_events 10_000
  @pubsub_topic "log_store:events"

  defp max_events do
    Application.get_env(:genswarms, :max_log_events, @default_max_events)
  end

  defstruct [:counter, :oldest_id]

  @type level :: :debug | :info | :warning | :error
  @type category :: :backend | :routing | :agent | :swarm | :system
  @type event_type :: atom()

  @type event :: %{
          id: non_neg_integer(),
          timestamp: DateTime.t(),
          level: level(),
          category: category(),
          swarm: String.t() | nil,
          agent: atom() | nil,
          event_type: event_type(),
          message: String.t(),
          metadata: map()
        }

  @type query_opts :: [
          level: level() | [level()],
          category: category() | [category()],
          swarm: String.t(),
          agent: atom(),
          event_type: event_type() | [event_type()],
          minutes: non_neg_integer(),
          since: DateTime.t(),
          limit: non_neg_integer(),
          offset: non_neg_integer()
        ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs an event to the store.

  ## Examples

      LogStore.log(:error, :backend, :docker_start_failed,
        "Container failed to start",
        swarm: "my-swarm",
        agent: :coder,
        metadata: %{image: "szc-agent-base"})
  """
  @spec log(level(), category(), event_type(), String.t(), keyword()) :: :ok
  def log(level, category, event_type, message, opts \\ []) do
    GenServer.cast(__MODULE__, {:log, level, category, event_type, message, opts})
  end

  @doc """
  Queries events from the store.

  ## Options

    * `:level` - Filter by level(s): :debug, :info, :warning, :error
    * `:category` - Filter by category: :backend, :routing, :agent, :swarm, :system
    * `:swarm` - Filter by swarm name
    * `:agent` - Filter by agent name
    * `:event_type` - Filter by event type(s)
    * `:minutes` - Events from the last N minutes
    * `:since` - Events since DateTime
    * `:limit` - Maximum events to return (default: 100)
    * `:offset` - Skip first N events

  ## Examples

      LogStore.query(level: :error, limit: 50)
      LogStore.query(swarm: "my-swarm", minutes: 5)
      LogStore.query(category: :backend, event_type: [:docker_start_failed, :docker_exit])
  """
  @spec query(query_opts()) :: [event()]
  def query(opts \\ []) do
    GenServer.call(__MODULE__, {:query, opts})
  end

  @doc """
  Gets the last N events (convenience function).
  """
  @spec recent(non_neg_integer()) :: [event()]
  def recent(n \\ 50) do
    query(limit: n)
  end

  @doc """
  Gets error events from the last N minutes.
  """
  @spec errors(non_neg_integer()) :: [event()]
  def errors(minutes \\ 60) do
    query(level: :error, minutes: minutes)
  end

  @doc """
  Gets event statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Subscribes to real-time events.

  Events are broadcast as `{:log_event, event}` messages.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Genswarms.PubSub, @pubsub_topic)
  end

  @doc """
  Subscribes to events for a specific swarm.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(swarm_name) do
    Phoenix.PubSub.subscribe(Genswarms.PubSub, "#{@pubsub_topic}:#{swarm_name}")
  end

  @doc """
  Unsubscribes from real-time events.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(Genswarms.PubSub, @pubsub_topic)
  end

  @doc """
  Clears all events from the store.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table: ordered_set for efficient range queries by id
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])

    state = %__MODULE__{
      counter: 0,
      oldest_id: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:log, level, category, event_type, message, opts}, state) do
    id = state.counter + 1
    timestamp = DateTime.utc_now()

    swarm = Keyword.get(opts, :swarm)
    agent = Keyword.get(opts, :agent)
    metadata = Keyword.get(opts, :metadata, %{})

    event = %{
      id: id,
      timestamp: timestamp,
      level: level,
      category: category,
      swarm: swarm,
      agent: agent,
      event_type: event_type,
      message: message,
      metadata: metadata
    }

    # Insert into ETS (in-memory for fast queries)
    :ets.insert(@table, {id, event})

    # Persist to the durable, cross-process store (SQLite by default)
    persist_durably(event)

    # Broadcast to subscribers
    broadcast_event(event)

    # Enforce ring buffer size
    new_state = maybe_prune(%{state | counter: id})

    {:noreply, new_state}
  end

  # Persist event to the durable cross-process store (SQLite by default).
  # Observability must never take down the logging GenServer if the store fails.
  defp persist_durably(event) do
    Genswarms.Observability.EventStore.persist(event)
  rescue
    _ -> :ok
  end

  @impl true
  def handle_call({:query, opts}, _from, state) do
    events = do_query(opts)
    {:reply, events, state}
  end

  def handle_call(:stats, _from, state) do
    stats = compute_stats()
    {:reply, stats, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | counter: 0, oldest_id: nil}}
  end

  # Private functions

  defp do_query(opts) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    # Get all events from ETS (reverse order for newest first)
    all_events =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, event} -> event end)
      |> Enum.sort_by(& &1.id, :desc)

    # Apply filters
    filtered =
      all_events
      |> filter_by_level(Keyword.get(opts, :level))
      |> filter_by_category(Keyword.get(opts, :category))
      |> filter_by_swarm(Keyword.get(opts, :swarm))
      |> filter_by_agent(Keyword.get(opts, :agent))
      |> filter_by_event_type(Keyword.get(opts, :event_type))
      |> filter_by_time(opts)

    # Apply offset and limit
    filtered
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  defp filter_by_level(events, nil), do: events

  defp filter_by_level(events, levels) when is_list(levels) do
    Enum.filter(events, &(&1.level in levels))
  end

  defp filter_by_level(events, level) do
    Enum.filter(events, &(&1.level == level))
  end

  defp filter_by_category(events, nil), do: events

  defp filter_by_category(events, categories) when is_list(categories) do
    Enum.filter(events, &(&1.category in categories))
  end

  defp filter_by_category(events, category) do
    Enum.filter(events, &(&1.category == category))
  end

  defp filter_by_swarm(events, nil), do: events

  defp filter_by_swarm(events, swarm) do
    Enum.filter(events, &(&1.swarm == swarm))
  end

  defp filter_by_agent(events, nil), do: events

  defp filter_by_agent(events, agent) do
    agent_atom = if is_binary(agent), do: String.to_atom(agent), else: agent
    Enum.filter(events, &(&1.agent == agent_atom))
  end

  defp filter_by_event_type(events, nil), do: events

  defp filter_by_event_type(events, types) when is_list(types) do
    Enum.filter(events, &(&1.event_type in types))
  end

  defp filter_by_event_type(events, event_type) do
    Enum.filter(events, &(&1.event_type == event_type))
  end

  defp filter_by_time(events, opts) do
    cond do
      minutes = Keyword.get(opts, :minutes) ->
        cutoff = DateTime.add(DateTime.utc_now(), -minutes, :minute)
        Enum.filter(events, &(DateTime.compare(&1.timestamp, cutoff) != :lt))

      since = Keyword.get(opts, :since) ->
        Enum.filter(events, &(DateTime.compare(&1.timestamp, since) != :lt))

      true ->
        events
    end
  end

  defp compute_stats do
    all_events =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, event} -> event end)

    total = length(all_events)

    by_level =
      Enum.group_by(all_events, & &1.level)
      |> Enum.map(fn {level, events} -> {level, length(events)} end)
      |> Map.new()

    by_category =
      Enum.group_by(all_events, & &1.category)
      |> Enum.map(fn {cat, events} -> {cat, length(events)} end)
      |> Map.new()

    by_swarm =
      all_events
      |> Enum.filter(& &1.swarm)
      |> Enum.group_by(& &1.swarm)
      |> Enum.map(fn {swarm, events} -> {swarm, length(events)} end)
      |> Map.new()

    # Recent errors (last hour)
    hour_ago = DateTime.add(DateTime.utc_now(), -1, :hour)

    recent_errors =
      all_events
      |> Enum.filter(&(&1.level == :error and DateTime.compare(&1.timestamp, hour_ago) != :lt))
      |> length()

    %{
      total: total,
      by_level: by_level,
      by_category: by_category,
      by_swarm: by_swarm,
      recent_errors: recent_errors,
      max_events: max_events()
    }
  end

  defp broadcast_event(event) do
    # Broadcast to general topic
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      @pubsub_topic,
      {:log_event, event}
    )

    # Broadcast to swarm-specific topic if applicable
    if event.swarm do
      Phoenix.PubSub.broadcast(
        Genswarms.PubSub,
        "#{@pubsub_topic}:#{event.swarm}",
        {:log_event, event}
      )
    end
  end

  defp maybe_prune(state) do
    size = :ets.info(@table, :size)
    max = max_events()

    if size > max do
      # Delete the oldest rows using the ordered_set's natural ordering
      # (:ets.first is the smallest/oldest id). O(to_delete · log n) instead of
      # a full :ets.tab2list + Enum.sort on every insert (audit finding 33);
      # to_delete is normally 1, so this is ~O(log n) per logged event.
      delete_oldest(size - max)

      case :ets.first(@table) do
        :"$end_of_table" -> %{state | oldest_id: nil}
        id -> %{state | oldest_id: id}
      end
    else
      state
    end
  end

  defp delete_oldest(n) when n <= 0, do: :ok

  defp delete_oldest(n) do
    case :ets.first(@table) do
      :"$end_of_table" ->
        :ok

      id ->
        :ets.delete(@table, id)
        delete_oldest(n - 1)
    end
  end
end
