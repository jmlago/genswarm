defmodule Genswarms.Agents.InboxGuardTest do
  @moduledoc """
  Serial turns (genswarms#54) queue mid-turn tasks in the Inbox — these tests
  pin the two visibility guarantees around that queue (review round 3
  finding 3):

    * a task that would overflow the Inbox is REFUSED (`{:error, :inbox_full}`),
      not silently accepted-and-dropped;
    * a backend that dies with tasks still queued says so — Logger.warning +
      [:genswarms, :agent, :inbox_dropped] telemetry — instead of the tasks
      silently never running.

  async: false — shares the global AgentRegistry.
  """
  use ExUnit.Case, async: false

  alias Genswarms.Agents.AgentServer

  defp wait_for_state(swarm, agent, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> AgentServer.get_state(swarm, agent) end)
    |> Enum.reduce_while(nil, fn s, _ ->
      cond do
        s == expected -> {:halt, :ok}
        System.monotonic_time(:millisecond) > deadline -> raise "never #{expected} (#{s})"
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  test "send_task returns {:error, :inbox_full} when the queue is at capacity" do
    swarm = "inbox-full-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AgentServer, [name: :stuffed, swarm_name: swarm, backend: :mock, skills: []]}
    )

    wait_for_state(swarm, :stuffed, :idle, 1_000)

    # Gate the inbox (same effect as a turn in progress) so every task queues.
    AgentServer.set_awaiting(swarm, :stuffed)
    :sys.get_state(AgentServer.via_tuple(swarm, :stuffed))

    # Fill to the Inbox's max_size (1000)...
    for i <- 1..1_000 do
      assert :ok = AgentServer.send_task(swarm, :stuffed, "task #{i}")
    end

    # ...the next one must be refused, not silently dropped: the caller is the
    # only party that can react (retry, shed load, surface the error).
    assert {:error, :inbox_full} = AgentServer.send_task(swarm, :stuffed, "one too many")
  end

  test "a backend that exits with queued tasks warns and emits :inbox_dropped telemetry" do
    if System.find_executable("bash") == nil or System.find_executable("jq") == nil do
      raise "bash/jq required by the szc wrapper are not available"
    end

    base = Path.join(System.tmp_dir!(), "inboxguard_#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(ws)

    fixture = Path.join(base, "fake_szc.sh")

    File.write!(fixture, """
    #!/usr/bin/env bash
    # Never answers: the turn stays in flight until the test kills the port.
    while IFS= read -r -d '' turn; do
      sleep 60
    done
    """)

    File.chmod!(fixture, 0o755)
    on_exit(fn -> File.rm_rf(base) end)

    handler_id = "inbox-dropped-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:genswarms, :agent, :inbox_dropped],
      fn _event, _meas, meta, pid -> send(pid, {:inbox_dropped, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    swarm = "inbox-drop-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AgentServer,
       [
         name: :doomed,
         swarm_name: swarm,
         backend: :local,
         skills: [],
         config: %{workspace: ws, subzeroclaw_path: fixture}
       ]}
    )

    wait_for_state(swarm, :doomed, :idle, 5_000)

    # Turn 1 starts (and will never complete) — the follow-ups queue.
    :ok = AgentServer.send_task(swarm, :doomed, "first (in flight)")
    :ok = AgentServer.send_task(swarm, :doomed, "queued A")
    :ok = AgentServer.send_task(swarm, :doomed, "queued B")

    state = :sys.get_state(AgentServer.via_tuple(swarm, :doomed))
    assert Genswarms.Agents.Inbox.size(state.inbox) == 2

    # The backend dies mid-turn (synthetic exit_status from the agent's own
    # port — deterministic, no racing a real process death).
    send(AgentServer.via_tuple(swarm, :doomed) |> GenServer.whereis(), {
      state.backend_ref.port,
      {:exit_status, 137}
    })

    assert_receive {:inbox_dropped, %{agent: :doomed, count: 2, exit_status: 137}}, 2_000
  end
end
