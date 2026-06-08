defmodule Genswarms.Observability.LogStorePruneTest do
  @moduledoc """
  LogStore prunes to its cap on overflow using the ordered_set's natural order
  (oldest first), keeping the table bounded without a full tab2list+sort per
  insert (audit finding 33).
  """
  use ExUnit.Case, async: false

  alias Genswarms.Observability.LogStore

  @table :subzeroclaw_logs
  @max 20

  setup do
    original = Application.get_env(:genswarms, :max_log_events)
    Application.put_env(:genswarms, :max_log_events, @max)

    on_exit(fn ->
      if original,
        do: Application.put_env(:genswarms, :max_log_events, original),
        else: Application.delete_env(:genswarms, :max_log_events)

      LogStore.clear()
    end)

    :ok
  end

  test "table stays bounded at the cap after overflow, dropping oldest first" do
    LogStore.clear()

    for i <- 1..60 do
      LogStore.log(:info, :system, :prune_test, "e#{i}", swarm: "prune-test")
    end

    # stats/0 is a GenServer call — flushes all prior log casts.
    _ = LogStore.stats()

    # Prune keeps the table at the cap regardless of how many were inserted.
    assert :ets.info(@table, :size) == @max

    # Oldest dropped, newest retained.
    messages =
      LogStore.query(swarm: "prune-test", limit: 1000)
      |> Enum.map(& &1.message)

    assert "e60" in messages
    refute "e1" in messages
  end
end
