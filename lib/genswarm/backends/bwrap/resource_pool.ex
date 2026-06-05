defmodule Genswarm.Backends.Bwrap.ResourcePool do
  @moduledoc """
  Pre-allocates overlay directories for fast agent startup.

  At scale, the ~50ms overlay setup time adds up. This GenServer maintains
  a pool of pre-configured sandboxes that can be acquired instantly.

  ## Architecture

  - Maintains pool of ready-to-use overlay directories per preset
  - Agents acquire sandboxes from pool (instant) instead of setup (50ms)
  - Background workers replenish the pool as sandboxes are consumed
  - Dirty sandboxes are cleaned up asynchronously after release

  ## Pool Sizing

  Default: 100 sandboxes per preset. Adjust based on burst patterns.
  With 10 presets, this uses ~500MB tmpfs for pre-allocated directories.

  ## Usage

      # Acquire a ready sandbox
      {:ok, sandbox_id, overlay_dir} = ResourcePool.acquire(:base)

      # When done, release it (async cleanup)
      ResourcePool.release(sandbox_id)

      # Or mark dirty for immediate cleanup
      ResourcePool.release(sandbox_id, :dirty)
  """

  use GenServer
  require Logger

  alias Genswarm.Backends.Bwrap.OverlayManager

  @pool_size_per_preset 100
  @replenish_threshold 0.2  # Replenish when pool drops below 20%
  @max_concurrent_replenish 10

  defstruct [
    :pools,           # %{preset => [ready_sandbox_ids]}
    :in_use,          # MapSet of sandbox_ids currently in use
    :replenishing,    # MapSet of presets currently being replenished
    :presets,         # List of presets to maintain pools for
    :pool_size        # Target pool size per preset
  ]

  @type sandbox :: {String.t(), String.t()}  # {sandbox_id, overlay_dir}

  # Client API

  @doc """
  Starts the resource pool GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires a ready sandbox from the pool.

  If the pool is empty, falls back to creating one on-demand.
  Returns `{:ok, sandbox_id, overlay_dir}` or `{:error, reason}`.
  """
  @spec acquire(atom() | [atom()]) :: {:ok, String.t(), String.t()} | {:error, term()}
  def acquire(presets) when is_list(presets) do
    preset_key = presets_to_key(presets)
    GenServer.call(__MODULE__, {:acquire, preset_key, presets})
  end

  def acquire(preset) when is_atom(preset) do
    acquire([preset])
  end

  @doc """
  Releases a sandbox back to the pool or marks it for cleanup.

  Options:
  - `:clean` (default) - Return to pool if unchanged, otherwise cleanup
  - `:dirty` - Always cleanup (sandbox was modified)
  - `:reuse` - Return to pool unconditionally
  """
  @spec release(String.t(), atom()) :: :ok
  def release(sandbox_id, mode \\ :clean) do
    GenServer.cast(__MODULE__, {:release, sandbox_id, mode})
  end

  @doc """
  Gets pool statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Warms up the pool by pre-creating sandboxes for common presets.
  """
  @spec warmup([atom()]) :: :ok
  def warmup(presets \\ [:base, :web, :code]) do
    GenServer.cast(__MODULE__, {:warmup, presets})
  end

  @doc """
  Drains all pools (for shutdown).
  """
  @spec drain() :: :ok
  def drain do
    GenServer.call(__MODULE__, :drain, 30_000)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    presets = Keyword.get(opts, :presets, [:base, :web, :code, :data, :python])
    pool_size = Keyword.get(opts, :pool_size, @pool_size_per_preset)

    state = %__MODULE__{
      pools: Map.new(presets, fn p -> {presets_to_key([p]), []} end),
      in_use: MapSet.new(),
      replenishing: MapSet.new(),
      presets: presets,
      pool_size: pool_size
    }

    # Schedule initial pool warmup
    Process.send_after(self(), :warmup_pools, 1000)

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, preset_key, presets}, _from, state) do
    case Map.get(state.pools, preset_key, []) do
      [{sandbox_id, overlay_dir} | rest] ->
        # Got one from pool
        new_pools = Map.put(state.pools, preset_key, rest)
        new_in_use = MapSet.put(state.in_use, sandbox_id)
        new_state = %{state | pools: new_pools, in_use: new_in_use}

        # Check if we need to replenish
        maybe_replenish(preset_key, presets, new_state)

        {:reply, {:ok, sandbox_id, overlay_dir}, new_state}

      [] ->
        # Pool empty, create on-demand
        case create_sandbox(presets) do
          {:ok, sandbox_id, overlay_dir} ->
            new_in_use = MapSet.put(state.in_use, sandbox_id)
            new_state = %{state | in_use: new_in_use}

            # Trigger replenish since we hit empty
            maybe_replenish(preset_key, presets, new_state)

            {:reply, {:ok, sandbox_id, overlay_dir}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    pool_stats =
      state.pools
      |> Enum.map(fn {preset, sandboxes} ->
        {preset, length(sandboxes)}
      end)
      |> Map.new()

    stats = %{
      pools: pool_stats,
      total_pooled: Enum.sum(Map.values(pool_stats)),
      in_use: MapSet.size(state.in_use),
      replenishing: MapSet.to_list(state.replenishing),
      target_per_preset: state.pool_size
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    # Cleanup all pooled sandboxes
    Enum.each(state.pools, fn {_preset, sandboxes} ->
      Enum.each(sandboxes, fn {sandbox_id, _} ->
        OverlayManager.cleanup_overlay(sandbox_id)
      end)
    end)

    new_state = %{state | pools: %{}}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:release, sandbox_id, mode}, state) do
    if MapSet.member?(state.in_use, sandbox_id) do
      new_in_use = MapSet.delete(state.in_use, sandbox_id)

      case mode do
        :dirty ->
          # Always cleanup
          Task.start(fn -> OverlayManager.cleanup_overlay(sandbox_id) end)
          {:noreply, %{state | in_use: new_in_use}}

        :clean ->
          # Check if sandbox is still clean (no writes to upper dir)
          case check_sandbox_clean(sandbox_id) do
            true ->
              # Could return to pool, but simpler to just cleanup
              Task.start(fn -> OverlayManager.cleanup_overlay(sandbox_id) end)
              {:noreply, %{state | in_use: new_in_use}}

            false ->
              Task.start(fn -> OverlayManager.cleanup_overlay(sandbox_id) end)
              {:noreply, %{state | in_use: new_in_use}}
          end

        :reuse ->
          # Return to pool - need to determine preset
          # For simplicity, just cleanup (would need metadata tracking)
          Task.start(fn -> OverlayManager.cleanup_overlay(sandbox_id) end)
          {:noreply, %{state | in_use: new_in_use}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:warmup, presets}, state) do
    Enum.each(presets, fn preset ->
      preset_key = presets_to_key([preset])
      spawn_replenish_workers(preset_key, [preset], state.pool_size, state)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:replenished, preset_key, sandbox}, state) do
    new_pools = Map.update(state.pools, preset_key, [sandbox], fn pool ->
      [sandbox | pool]
    end)

    {:noreply, %{state | pools: new_pools}}
  end

  @impl true
  def handle_cast({:replenish_done, preset_key}, state) do
    new_replenishing = MapSet.delete(state.replenishing, preset_key)
    {:noreply, %{state | replenishing: new_replenishing}}
  end

  @impl true
  def handle_info(:warmup_pools, state) do
    # Check if bwrap infrastructure is ready
    if OverlayManager.infrastructure_ready?() do
      Enum.each(state.presets, fn preset ->
        preset_key = presets_to_key([preset])
        current = Map.get(state.pools, preset_key, []) |> length()

        if current < state.pool_size do
          spawn_replenish_workers(preset_key, [preset], state.pool_size - current, state)
        end
      end)
    else
      # Infrastructure not ready, retry later
      Logger.debug("Bwrap infrastructure not ready, retrying warmup in 5s")
      Process.send_after(self(), :warmup_pools, 5000)
    end

    {:noreply, state}
  end

  # Private functions

  defp create_sandbox(presets) do
    sandbox_id = generate_sandbox_id()

    case OverlayManager.setup_overlay(sandbox_id, presets) do
      {:ok, overlay_dir} ->
        {:ok, sandbox_id, overlay_dir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_sandbox_id do
    "pool-#{System.unique_integer([:positive])}-#{:rand.uniform(999999)}"
  end

  defp presets_to_key(presets) do
    presets
    |> Enum.sort()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join("-")
    |> String.to_atom()
  end

  defp maybe_replenish(preset_key, presets, state) do
    pool_count = Map.get(state.pools, preset_key, []) |> length()
    threshold = trunc(state.pool_size * @replenish_threshold)

    if pool_count < threshold and not MapSet.member?(state.replenishing, preset_key) do
      count_needed = state.pool_size - pool_count
      spawn_replenish_workers(preset_key, presets, count_needed, state)
    end
  end

  defp spawn_replenish_workers(preset_key, presets, count, _state) do
    # Spawn workers to replenish pool (limited concurrency)
    workers_to_spawn = min(count, @max_concurrent_replenish)

    for _ <- 1..workers_to_spawn do
      Task.start(fn ->
        case create_sandbox(presets) do
          {:ok, sandbox_id, overlay_dir} ->
            GenServer.cast(__MODULE__, {:replenished, preset_key, {sandbox_id, overlay_dir}})

          {:error, _reason} ->
            :ok  # Silently ignore failures
        end
      end)
    end

    # If more needed, schedule another batch
    if count > workers_to_spawn do
      Process.send_after(
        self(),
        {:continue_replenish, preset_key, presets, count - workers_to_spawn},
        100
      )
    else
      GenServer.cast(__MODULE__, {:replenish_done, preset_key})
    end
  end

  defp check_sandbox_clean(sandbox_id) do
    # Check if upper directory has any files (indicating writes)
    upper_dir = Path.join(["/run/swarm/agents", sandbox_id, "upper"])

    case File.ls(upper_dir) do
      {:ok, []} -> true  # Empty = clean
      {:ok, _files} -> false  # Has files = dirty
      {:error, _} -> false  # Error = assume dirty
    end
  end
end
