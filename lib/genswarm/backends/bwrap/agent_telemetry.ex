defmodule Genswarm.Backends.Bwrap.AgentTelemetry do
  @moduledoc """
  ETS ring buffer for agent output at 10k+ agent scale.

  At large scale, Logger becomes a bottleneck and memory hog. This module
  provides a high-performance alternative that:

  - Uses ETS for lock-free concurrent writes
  - Implements per-agent ring buffers with automatic pruning
  - Emits Telemetry events for monitoring integration
  - Keeps memory bounded regardless of agent count

  ## Usage

      # Log agent output (replaces Logger in agent code path)
      AgentTelemetry.log_output("sandbox-123", "Hello from agent")

      # Get recent output for an agent
      AgentTelemetry.tail("sandbox-123", 50)

      # Get throughput statistics
      AgentTelemetry.throughput_stats()

  ## Memory Budget

  With default settings:
  - 200 lines/agent * 10k agents = 2M entries max
  - ~100 bytes/entry avg = ~200MB total

  ## Important

  Logger should be set to `:warning` level in production to avoid
  duplicating agent output. This module handles all agent I/O logging.
  """

  use GenServer

  @table :bwrap_agent_output
  @events_table :bwrap_agent_events
  @stats_table :bwrap_agent_stats

  @max_lines_per_agent 200
  @max_events_per_agent 100
  @prune_threshold 1.5  # Prune when exceeding threshold * max

  # Telemetry event names
  @output_event [:bwrap, :agent, :output]
  @event_event [:bwrap, :agent, :event]

  @doc """
  Starts the telemetry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs agent output to the ring buffer.

  This is the hot path - must be extremely fast.
  """
  @spec log_output(String.t(), String.t() | map()) :: :ok
  def log_output(sandbox_id, line) when is_binary(line) do
    ts = System.monotonic_time(:nanosecond)
    :ets.insert(@table, {{sandbox_id, ts}, line})

    # Emit telemetry for external monitoring
    :telemetry.execute(@output_event, %{size: byte_size(line)}, %{sandbox_id: sandbox_id})

    # Async prune check (don't block hot path)
    maybe_schedule_prune(sandbox_id)

    :ok
  end

  def log_output(sandbox_id, %{} = message) do
    log_output(sandbox_id, Jason.encode!(message))
  end

  @doc """
  Logs an agent lifecycle event (start, stop, error, etc).
  """
  @spec log_event(String.t(), atom(), map()) :: :ok
  def log_event(sandbox_id, event_type, metadata \\ %{}) do
    ts = System.monotonic_time(:nanosecond)
    wall_time = DateTime.utc_now()

    entry = %{
      type: event_type,
      metadata: metadata,
      wall_time: wall_time
    }

    :ets.insert(@events_table, {{sandbox_id, ts}, entry})

    :telemetry.execute(@event_event, %{}, %{
      sandbox_id: sandbox_id,
      event_type: event_type
    })

    :ok
  end

  @doc """
  Gets the most recent N output lines for an agent.
  """
  @spec tail(String.t(), pos_integer()) :: [String.t()]
  def tail(sandbox_id, n \\ 50) do
    # Use match spec for efficient retrieval
    match_spec = [{{{sandbox_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    :ets.select(@table, match_spec)
    |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {_, line} -> line end)
    |> Enum.reverse()
  end

  @doc """
  Gets all output for an agent (use sparingly).
  """
  @spec get_all_output(String.t()) :: [String.t()]
  def get_all_output(sandbox_id) do
    match_spec = [{{{sandbox_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    :ets.select(@table, match_spec)
    |> Enum.sort_by(fn {ts, _} -> ts end)
    |> Enum.map(fn {_, line} -> line end)
  end

  @doc """
  Gets recent events for an agent.
  """
  @spec get_events(String.t(), pos_integer()) :: [map()]
  def get_events(sandbox_id, n \\ 50) do
    match_spec = [{{{sandbox_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    :ets.select(@events_table, match_spec)
    |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {_, event} -> event end)
    |> Enum.reverse()
  end

  @doc """
  Clears all output for an agent (called on agent stop).
  """
  @spec clear(String.t()) :: :ok
  def clear(sandbox_id) do
    # Delete all entries for this sandbox
    match_spec = [{{{sandbox_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@table, match_spec)
    :ets.select_delete(@events_table, match_spec)
    :ok
  end

  @doc """
  Gets throughput and memory statistics.
  """
  @spec throughput_stats() :: map()
  def throughput_stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Gets count of active agents (those with recent output).
  """
  @spec active_agent_count() :: non_neg_integer()
  def active_agent_count do
    # Count unique sandbox_ids
    :ets.foldl(
      fn {{sandbox_id, _}, _}, acc ->
        MapSet.put(acc, sandbox_id)
      end,
      MapSet.new(),
      @table
    )
    |> MapSet.size()
  end

  @doc """
  Gets list of all sandbox IDs with output.
  """
  @spec list_sandboxes() :: [String.t()]
  def list_sandboxes do
    :ets.foldl(
      fn {{sandbox_id, _}, _}, acc ->
        MapSet.put(acc, sandbox_id)
      end,
      MapSet.new(),
      @table
    )
    |> MapSet.to_list()
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables with optimal settings for concurrent access
    :ets.new(@table, [
      :named_table,
      :public,
      :ordered_set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    :ets.new(@events_table, [
      :named_table,
      :public,
      :ordered_set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    :ets.new(@stats_table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true}
    ])

    # Initialize stats
    :ets.insert(@stats_table, {:total_lines, 0})
    :ets.insert(@stats_table, {:total_bytes, 0})
    :ets.insert(@stats_table, {:last_prune, System.monotonic_time(:second)})

    # Attach telemetry handler for stats
    :telemetry.attach(
      "bwrap-output-stats",
      @output_event,
      &handle_telemetry/4,
      nil
    )

    # Schedule periodic stats update
    schedule_stats_update()

    {:ok, %{prune_pending: MapSet.new()}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    [{:total_lines, total_lines}] = :ets.lookup(@stats_table, :total_lines)
    [{:total_bytes, total_bytes}] = :ets.lookup(@stats_table, :total_bytes)

    output_count = :ets.info(@table, :size)
    events_count = :ets.info(@events_table, :size)
    memory_bytes = :ets.info(@table, :memory) * :erlang.system_info(:wordsize)

    stats = %{
      total_lines_processed: total_lines,
      total_bytes_processed: total_bytes,
      current_output_entries: output_count,
      current_event_entries: events_count,
      memory_bytes: memory_bytes,
      memory_mb: Float.round(memory_bytes / 1_048_576, 2),
      active_sandboxes: active_agent_count()
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:prune, sandbox_id}, state) do
    prune_sandbox(sandbox_id)
    new_pending = MapSet.delete(state.prune_pending, sandbox_id)
    {:noreply, %{state | prune_pending: new_pending}}
  end

  @impl true
  def handle_info(:update_stats, state) do
    # Periodic stats snapshot
    schedule_stats_update()
    {:noreply, state}
  end

  def handle_info({:prune_check, sandbox_id}, state) do
    # Check if prune is needed and not already pending
    if not MapSet.member?(state.prune_pending, sandbox_id) do
      count = count_entries(sandbox_id)
      if count > @max_lines_per_agent * @prune_threshold do
        new_pending = MapSet.put(state.prune_pending, sandbox_id)
        GenServer.cast(__MODULE__, {:prune, sandbox_id})
        {:noreply, %{state | prune_pending: new_pending}}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Private functions

  defp handle_telemetry(_event, %{size: size}, _metadata, _config) do
    :ets.update_counter(@stats_table, :total_lines, 1)
    :ets.update_counter(@stats_table, :total_bytes, size)
  end

  defp maybe_schedule_prune(sandbox_id) do
    # Only check occasionally to avoid overhead
    if :rand.uniform(100) == 1 do
      send(__MODULE__, {:prune_check, sandbox_id})
    end
  end

  defp prune_sandbox(sandbox_id) do
    # Get all entries for this sandbox, sorted by timestamp
    match_spec = [{{{sandbox_id, :"$1"}, :_}, [], [:"$1"]}]
    timestamps = :ets.select(@table, match_spec) |> Enum.sort()

    # Delete oldest entries beyond max
    entries_to_delete = max(0, length(timestamps) - @max_lines_per_agent)

    timestamps
    |> Enum.take(entries_to_delete)
    |> Enum.each(fn ts ->
      :ets.delete(@table, {sandbox_id, ts})
    end)

    # Also prune events
    event_match = [{{{sandbox_id, :"$1"}, :_}, [], [:"$1"]}]
    event_timestamps = :ets.select(@events_table, event_match) |> Enum.sort()
    event_deletes = max(0, length(event_timestamps) - @max_events_per_agent)

    event_timestamps
    |> Enum.take(event_deletes)
    |> Enum.each(fn ts ->
      :ets.delete(@events_table, {sandbox_id, ts})
    end)
  end

  defp count_entries(sandbox_id) do
    match_spec = [{{{sandbox_id, :_}, :_}, [], [true]}]
    :ets.select_count(@table, match_spec)
  end

  defp schedule_stats_update do
    Process.send_after(self(), :update_stats, 60_000)
  end
end
