defmodule Genswarms.Agents.LogWatcherTest do
  @moduledoc """
  LogWatcher must not retain an unbounded per-message hash set — position
  tracking already dedups (audit finding 32).
  """
  use ExUnit.Case, async: true

  alias Genswarms.Agents.LogWatcher

  setup do
    dir = Path.join(System.tmp_dir!(), "logwatcher_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "state has no unbounded processed_hashes set", %{dir: dir} do
    {:ok, pid} =
      LogWatcher.start_link(
        swarm_name: "lw-test",
        agent_name: :lw_agent,
        log_dir: dir,
        workspace: dir
      )

    state = :sys.get_state(pid)

    refute Map.has_key?(state, :processed_hashes),
           "processed_hashes (unbounded growth) should be gone"

    assert Map.has_key?(state, :last_positions)

    GenServer.stop(pid)
  end
end
