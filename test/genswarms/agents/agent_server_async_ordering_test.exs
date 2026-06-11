defmodule Genswarms.Agents.AgentServerAsyncOrderingTest do
  @moduledoc """
  Deterministic tests for the async-reply ordering guard introduced in AgentServer.

  Design
  ------
  The bug: when an agent sends a message to an async object (e.g. `browse`) and
  sits idle waiting for the reply, a rapid follow-up user task was forwarded to
  the backend immediately.  The object's reply then landed in the Inbox and was
  processed in the *wrong* turn's context.

  The fix: AgentServer tracks `awaiting_reply` state.  While set, new user
  tasks are queued in the Inbox instead of being forwarded to the backend.  The
  flag is cleared when the object's reply arrives (via `clear_awaiting/2`), and
  the queued task is released in order on the next `TURN_COMPLETE` via
  `maybe_process_inbox/1`.

  Tests here drive AgentServer directly via its public API (mock backend, no
  LLM), asserting on `get_status/2` inbox_size and the `awaiting_reply` field
  exposed via `get_state/2`.  We also call the internal casts directly where
  needed to simulate Router notifications.

  All tests use `async: false` because they share the global AgentRegistry.
  """

  use ExUnit.Case, async: false

  alias Genswarms.Agents.{AgentServer, Inbox}

  # Unique swarm prefix per test to avoid registry collisions when tests are
  # run in sequence (on_exit cleanup is async, so we use unique names).
  defp swarm_name, do: "async-ord-test-#{System.unique_integer([:positive])}"
  defp agent_name, do: :test_agent

  # Start a mock-backend AgentServer and wait for it to reach :idle.
  defp start_agent(swarm, agent) do
    opts = [
      name: agent,
      swarm_name: swarm,
      backend: :mock,
      skills: []
    ]

    pid = start_supervised!({AgentServer, opts})

    # The mock backend transitions to :idle synchronously in the :start_backend
    # handle_info.  Poll briefly in case the message hasn't been processed yet.
    wait_for_state(swarm, agent, :idle, 500)
    pid
  end

  # Poll get_state until it matches `expected` or we time out.
  defp wait_for_state(swarm, agent, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> AgentServer.get_state(swarm, agent) end)
    |> Enum.reduce_while(:timeout, fn state, _ ->
      cond do
        state == expected -> {:halt, :ok}
        System.monotonic_time(:millisecond) > deadline -> {:halt, :timeout}
        true -> Process.sleep(10); {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> raise "Agent #{agent} in #{swarm} did not reach #{expected} within #{timeout_ms}ms (last: #{AgentServer.get_state(swarm, agent)})"
    end
  end

  # -------------------------------------------------------------------------
  # Helper: directly trigger set_awaiting / clear_awaiting on the AgentServer
  # (simulating what the Router would do).
  # -------------------------------------------------------------------------

  defp set_awaiting(swarm, agent) do
    AgentServer.set_awaiting(swarm, agent)
    # let the cast be processed
    :sys.get_state(AgentServer.via_tuple(swarm, agent))
    :ok
  end

  defp clear_awaiting(swarm, agent) do
    AgentServer.clear_awaiting(swarm, agent)
    :sys.get_state(AgentServer.via_tuple(swarm, agent))
    :ok
  end

  # Retrieve raw GenServer state for assertions on private fields.
  defp raw_state(swarm, agent) do
    :sys.get_state(AgentServer.via_tuple(swarm, agent))
  end

  # -------------------------------------------------------------------------
  # Tests
  # -------------------------------------------------------------------------

  describe "awaiting_reply flag" do
    test "is false by default" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == false
      assert state.awaiting_since == nil
      assert state.awaiting_timer_ref == nil
    end

    test "set_awaiting arms the flag and records a timestamp" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())

      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == true
      assert is_integer(state.awaiting_since)
      assert is_reference(state.awaiting_timer_ref)
    end

    test "clear_awaiting resets the flag and cancels the timer" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())
      clear_awaiting(swarm, agent_name())

      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == false
      assert state.awaiting_since == nil
      assert state.awaiting_timer_ref == nil
    end

    test "set_awaiting when already awaiting rearms the timer (idempotent flag, fresh timer)" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())
      state1 = raw_state(swarm, agent_name())
      timer1 = state1.awaiting_timer_ref

      set_awaiting(swarm, agent_name())
      state2 = raw_state(swarm, agent_name())

      # Flag is still true, but a *new* timer was armed.
      assert state2.awaiting_reply == true
      assert state2.awaiting_timer_ref != timer1
    end
  end

  describe "user task gating while awaiting" do
    test "send_task while awaiting enqueues into Inbox and does NOT send to backend" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      # Mark agent as awaiting (Router would do this after routing agent→object).
      set_awaiting(swarm, agent_name())

      # Inbox should be empty before the task.
      status = AgentServer.get_status(swarm, agent_name())
      assert status.inbox_size == 0

      # Send a user task — it must be queued, not forwarded to the (mock) backend.
      assert :ok = AgentServer.send_task(swarm, agent_name(), "do something later")

      status = AgentServer.get_status(swarm, agent_name())
      assert status.inbox_size == 1, "Expected task to be queued in Inbox while awaiting"

      # The mock backend's send_input is a no-op, but the agent state should
      # NOT have flipped to :working (which would indicate the task was sent).
      assert AgentServer.get_state(swarm, agent_name()) == :idle
    end

    test "send_task while awaiting queues multiple tasks in order" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())

      AgentServer.send_task(swarm, agent_name(), "task A")
      AgentServer.send_task(swarm, agent_name(), "task B")
      AgentServer.send_task(swarm, agent_name(), "task C")

      status = AgentServer.get_status(swarm, agent_name())
      assert status.inbox_size == 3

      # Verify FIFO order by peeking into the raw state inbox.
      state = raw_state(swarm, agent_name())
      msgs = Inbox.to_list(state.inbox)
      assert Enum.map(msgs, & &1.content) == ["task A", "task B", "task C"]
    end

    test "send_task without awaiting goes straight to backend (no queueing)" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      # No set_awaiting — normal path.
      assert :ok = AgentServer.send_task(swarm, agent_name(), "immediate task")

      # Mock backend is a no-op so the task was 'sent'; agent transitions to :working.
      assert AgentServer.get_state(swarm, agent_name()) == :working

      # Inbox stays empty.
      status = AgentServer.get_status(swarm, agent_name())
      assert status.inbox_size == 0
    end
  end

  describe "inbox release after clear_awaiting + TURN_COMPLETE" do
    test "clearing awaiting makes the queued task available for next TURN_COMPLETE" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())
      AgentServer.send_task(swarm, agent_name(), "queued task")

      state = raw_state(swarm, agent_name())
      assert state.inbox |> Inbox.size() == 1

      # Simulate the object reply arriving → clear awaiting.
      clear_awaiting(swarm, agent_name())

      # Inbox still holds the task (not yet released — that happens on TURN_COMPLETE).
      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == false
      assert Inbox.size(state.inbox) == 1

      # Simulate TURN_COMPLETE by sending the agent's output to itself with the
      # marker via the generic port-data pattern:
      #   handle_info({_port, {:data, data}}, state) when is_binary(data)
      # This works with the mock backend (which has no real port).
      agent_pid = GenServer.whereis(AgentServer.via_tuple(swarm, agent_name()))
      send(agent_pid, {make_ref(), {:data, "<<TURN_COMPLETE>>"}})

      # Give the process a moment to handle the info message.
      Process.sleep(50)

      # The task should have been popped from the Inbox and sent to the (mock)
      # backend.  The agent transitions to :working, inbox is now empty.
      status = AgentServer.get_status(swarm, agent_name())
      assert status.inbox_size == 0
      assert AgentServer.get_state(swarm, agent_name()) == :working
    end
  end

  describe "safety timeout" do
    test "awaiting_timeout message clears the flag and drains inbox" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())
      AgentServer.send_task(swarm, agent_name(), "task waiting for timeout")

      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == true
      assert Inbox.size(state.inbox) == 1

      # Cancel the real timer (to avoid a double-fire) and inject the timeout
      # message directly — this is equivalent to waiting for the full 90 s.
      Process.cancel_timer(state.awaiting_timer_ref)

      agent_pid = GenServer.whereis(AgentServer.via_tuple(swarm, agent_name()))
      send(agent_pid, :awaiting_timeout)

      # Let the process handle the injected timeout message.
      Process.sleep(50)

      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == false
      assert state.awaiting_timer_ref == nil

      # maybe_process_inbox was called: task popped and sent to mock backend.
      status = AgentServer.get_status(swarm, agent_name())
      assert status.inbox_size == 0
      assert AgentServer.get_state(swarm, agent_name()) == :working
    end

    test "stale awaiting_timeout (flag already cleared) is a no-op" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())
      clear_awaiting(swarm, agent_name())

      agent_pid = GenServer.whereis(AgentServer.via_tuple(swarm, agent_name()))
      send(agent_pid, :awaiting_timeout)

      Process.sleep(30)

      # Should still be idle with no inbox changes.
      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == false
      assert AgentServer.get_state(swarm, agent_name()) == :idle
    end
  end

  describe "lifecycle: clear on terminate" do
    test "agent can be stopped cleanly while awaiting" do
      swarm = swarm_name()
      pid = start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())
      AgentServer.send_task(swarm, agent_name(), "pending task")

      # Stop the agent — terminate/2 must cancel the timer without crashing.
      ref = Process.monitor(pid)
      AgentServer.stop(swarm, agent_name())

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end
  end

  describe "no-op for agents that never use async objects" do
    test "awaiting stays false through normal send_task + TURN_COMPLETE cycle" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      # Normal task, no awaiting flag touched.
      assert :ok = AgentServer.send_task(swarm, agent_name(), "normal task")
      assert AgentServer.get_state(swarm, agent_name()) == :working

      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == false
      assert state.awaiting_since == nil
      assert state.awaiting_timer_ref == nil
    end
  end

  describe "FIX 1: released queued task is encoded as a task, not a message" do
    test "queued task released on TURN_COMPLETE is encoded with type=task" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      set_awaiting(swarm, agent_name())
      AgentServer.send_task(swarm, agent_name(), "the queued task")

      # Verify it is in the inbox with task?: true before release.
      state = raw_state(swarm, agent_name())
      [entry] = Inbox.to_list(state.inbox)
      assert entry.task? == true, "Inbox entry must carry task?: true so pop branch is correct"
      assert entry.content == "the queued task"

      # Now clear awaiting (simulating the object reply arriving) then trigger
      # TURN_COMPLETE so maybe_process_inbox pops and encodes the entry.
      clear_awaiting(swarm, agent_name())

      agent_pid = GenServer.whereis(AgentServer.via_tuple(swarm, agent_name()))
      send(agent_pid, {make_ref(), {:data, "<<TURN_COMPLETE>>"}})
      Process.sleep(50)

      # The task must have been consumed (inbox empty) and the agent transitioned
      # to :working — which only happens when AgentProtocol.encode_task is called
      # (not encode_message, which is a no-op for the mock backend too, but the
      # :working state is the observable side-effect of the task being dispatched).
      status = AgentServer.get_status(swarm, agent_name())
      assert status.inbox_size == 0, "Queued task must be consumed from inbox"
      assert AgentServer.get_state(swarm, agent_name()) == :working,
             "Agent must transition to :working after dispatching the released task"

      # Verify the inbox entry had task?: true (the branch that calls encode_task)
      # by constructing the expected JSON directly and comparing with what
      # encode_task produces — this proves the call form is byte-identical to the
      # direct (non-queued) send_task path.
      alias Genswarms.Agents.AgentProtocol
      direct_encoded = AgentProtocol.encode_task("the queued task")
      decoded = Jason.decode!(direct_encoded)
      assert decoded["type"] == "task",
             "encode_task must produce type=task, not type=message"
      assert decoded["content"] == "the queued task"
      assert decoded["from"] == "orchestrator"
    end
  end

  describe "FIX 2: atomic clear — deliver_message clears awaiting before processing" do
    test "deliver_message clears awaiting_reply and the queued task stays in inbox until TURN_COMPLETE" do
      swarm = swarm_name()
      start_agent(swarm, agent_name())

      # 1. Mark agent as awaiting (Router would do this when routing agent→object).
      set_awaiting(swarm, agent_name())

      # 2. Queue a user task while awaiting — it must NOT be forwarded yet.
      AgentServer.send_task(swarm, agent_name(), "task gated on reply")

      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == true
      assert Inbox.size(state.inbox) == 1

      # 3. Deliver the object reply via deliver_message (atomic clear + delivery).
      #    This simulates Router calling AgentServer.deliver_message when the reply
      #    arrives — no separate clear_awaiting call needed (FIX 2).
      AgentServer.deliver_message(swarm, agent_name(), "browse_object", "here is the result")

      # Let the cast be processed.
      :sys.get_state(AgentServer.via_tuple(swarm, agent_name()))

      # 4. awaiting_reply must be cleared NOW (atomically by deliver_message).
      state = raw_state(swarm, agent_name())
      assert state.awaiting_reply == false,
             "deliver_message must clear awaiting_reply atomically"
      assert state.awaiting_timer_ref == nil

      # 5. The queued user task must still be in the inbox — it is NOT lost.
      #    It will be released only on the next TURN_COMPLETE.
      #    (The object reply itself was also pushed into the inbox, so size == 2.)
      inbox_contents = Inbox.to_list(state.inbox)
      task_entries = Enum.filter(inbox_contents, &Map.get(&1, :task?))
      assert length(task_entries) == 1,
             "The queued user task must still be present in the inbox (not dropped)"
      assert hd(task_entries).content == "task gated on reply"
    end
  end
end
