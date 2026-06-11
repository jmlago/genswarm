defmodule Genswarms.Agents.AutoDeliverTest do
  @moduledoc """
  End-to-end tests for reply auto-delivery (genswarms#53 G2), through the REAL
  local backend + szc wrapper: a fake harness binary mimics subzeroclaw's I/O
  contract (NUL-delimited turns in; stderr banners; stdout answer;
  `<<TURN_COMPLETE>>`), and the engine must derive the turn's reply text
  (banners and prompts excluded) and deliver it to the configured `reply_to`
  sink — or emit `no_final_text` when the turn produced none.

  Requires bash + jq (the wrapper's dependencies); skipped when absent.

  async: false — shares the global AgentRegistry/Router.
  """
  use ExUnit.Case, async: false

  alias Genswarms.{SwarmManager, Agents.AgentServer}
  alias Genswarms.CLI.SwarmRegistry

  alias Genswarms.Test.SinkHandler

  import Genswarms.Test.SyncTurnHelpers

  # Fake subzeroclaw: same I/O contract as the real harness. The workspace is
  # interpolated so SENDLATE/SENDSILENT can write a real .outbox file from
  # INSIDE the (fake) agent process, exactly like swarm-msg send does.
  #   SILENT     → no stdout answer
  #   SLOW       → 600ms of "thinking" before answering
  #   SENDLATE   → write an explicit outbox send IMMEDIATELY before the turn
  #                marker, so only the synchronous TURN_COMPLETE sweep can
  #                attribute it (the 500ms poll cannot win that race) — the
  #                sweep path of review round 3 finding 1
  #   SENDSILENT → the same late outbox write, but no stdout answer at all
  #                (the no_final_text path)
  defp fake_szc(ws) do
    """
    #!/usr/bin/env bash
    while IFS= read -r -d '' turn; do
      printf '[1] fake-model...\\n' >&2
      case "$turn" in
        *SLOW*) sleep 0.6 ;;
      esac
      case "$turn" in
        *SENDLATE*|*SENDSILENT*)
          sleep 0.4
          mkdir -p "#{ws}/.outbox"
          printf '{"to":"sink","content":"EXPLICIT REPLY"}' > "#{ws}/.outbox/.tmp1"
          mv "#{ws}/.outbox/.tmp1" "#{ws}/.outbox/0001_sink_explicit.json"
          ;;
      esac
      case "$turn" in
        *SILENT*) : ;;
        *) printf 'ANSWER to: %s\\n' "$turn" ;;
      esac
      printf '\\n<<TURN_COMPLETE>>\\n> '
    done
    """
  end

  setup do
    if System.find_executable("bash") == nil or System.find_executable("jq") == nil do
      raise "bash/jq required by the szc wrapper are not available"
    end

    base = Path.join(System.tmp_dir!(), "autodeliver_#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "ws")
    File.mkdir_p!(workspace)

    fixture = Path.join(base, "fake_szc.sh")
    File.write!(fixture, fake_szc(workspace))
    File.chmod!(fixture, 0o755)

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, workspace: workspace, fixture: fixture}
  end

  defp start_swarm(workspace, fixture, test_pid, grace_ms, opts \\ []) do
    swarm = "autodel-#{System.unique_integer([:positive])}"

    agent_config = %{
      workspace: workspace,
      subzeroclaw_path: fixture,
      reply_grace_ms: grace_ms
    }

    agent_config =
      case Keyword.get(opts, :reply_to, :sink) do
        nil -> agent_config
        sink -> Map.put(agent_config, :reply_to, sink)
      end

    config = %{
      name: swarm,
      agents: [
        %{
          name: :writer,
          backend: :local,
          config: agent_config
        }
      ],
      objects: [
        %{name: :sink, handler: SinkHandler, config: %{test_pid: test_pid}}
      ],
      topology: [
        {:writer, :sink}
      ]
    }

    {:ok, ^swarm} = SwarmManager.start_from_config(config)
    SwarmRegistry.clear_overlay(swarm)

    on_exit(fn ->
      SwarmManager.stop(swarm)
      SwarmRegistry.clear_overlay(swarm)
    end)

    # Local backend starts asynchronously (:start_backend); wait for :idle.
    wait_for_idle(swarm, :writer, 5_000)
    swarm
  end

  test "the turn's answer is auto-delivered to reply_to; banners and prompts are not",
       %{workspace: ws, fixture: fixture} do
    swarm = start_swarm(ws, fixture, self(), 100)

    :ok = AgentServer.send_task(swarm, :writer, "hello docs")

    assert_receive {:sink_got, :writer, text}, 8_000
    assert text == "ANSWER to: [From orchestrator] hello docs"
    refute text =~ "fake-model"
    refute text =~ "TURN_COMPLETE"

    # one delivery, not two
    refute_receive {:sink_got, _, _}, 500
  end

  test "consecutive turns each deliver exactly once (prompt glue handled)",
       %{workspace: ws, fixture: fixture} do
    swarm = start_swarm(ws, fixture, self(), 100)

    :ok = AgentServer.send_task(swarm, :writer, "first")
    assert_receive {:sink_got, :writer, first}, 8_000
    assert first == "ANSWER to: [From orchestrator] first"

    :ok = AgentServer.send_task(swarm, :writer, "second")
    assert_receive {:sink_got, :writer, second}, 8_000
    # the second turn's stdout arrives glued to the pending "> " prompt;
    # derivation must strip exactly that one prompt.
    assert second == "ANSWER to: [From orchestrator] second"
  end

  test "a completed turn's reply still delivers when the NEXT message arrives within the grace window",
       %{workspace: ws, fixture: fixture} do
    # Regression: the first cut invalidated a pending delivery whenever a new
    # turn began (turn_seq bump), silently dropping the completed turn's
    # answer on rapid consecutive messages — the exact failure class this
    # feature exists to fix.
    swarm = start_swarm(ws, fixture, self(), 800)

    :ok = AgentServer.send_task(swarm, :writer, "first")
    # let the first turn complete (fixture answers in ms) but stay inside its
    # 800ms grace, then start the next turn
    Process.sleep(300)
    :ok = AgentServer.send_task(swarm, :writer, "second")

    assert_receive {:sink_got, :writer, "ANSWER to: [From orchestrator] first"}, 8_000
    assert_receive {:sink_got, :writer, "ANSWER to: [From orchestrator] second"}, 8_000
  end

  test "a turn with no stdout answer emits no_final_text and delivers nothing",
       %{workspace: ws, fixture: fixture} do
    handler_id = "no-final-text-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:genswarms, :agent, :no_final_text],
      fn _event, _meas, meta, pid -> send(pid, {:no_final_text, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    swarm = start_swarm(ws, fixture, self(), 100)
    :ok = AgentServer.send_task(swarm, :writer, "SILENT please")

    assert_receive {:no_final_text, %{agent: :writer}}, 8_000
    refute_receive {:sink_got, _, _}, 500
  end

  test "an explicit send written immediately before TURN_COMPLETE (sweep path) suppresses turn N",
       %{workspace: ws, fixture: fixture} do
    # The outbox file lands milliseconds before the turn marker, so the 500ms
    # poll cannot drain it first — the synchronous TURN_COMPLETE sweep must be
    # what routes AND attributes it. (The old version of this test wrote the
    # file ~450ms before turn end, so the poll usually won and the sweep path
    # went untested — review round 3 finding 8.)
    swarm = start_swarm(ws, fixture, self(), 300)

    :ok = AgentServer.send_task(swarm, :writer, "SENDLATE first")

    # The explicit reply arrives (routed by the sweep)...
    assert_receive {:sink_got, :writer, "EXPLICIT REPLY"}, 8_000
    # ...and turn 1's auto-delivery is suppressed in its favor.
    refute_receive {:sink_got, _, _}, 800
  end

  test "BLOCKER regression (review round 3 finding 1): sweep-routed send during turn N + queued follow-up — N suppressed, N+1 still delivers",
       %{workspace: ws, fixture: fixture} do
    # Turn N explicit-sends to the sink JUST BEFORE <<TURN_COMPLETE>>, with a
    # follow-up already queued (serial turns). The TURN_COMPLETE handler runs
    # the sweep AND dispatches the queued task in the same handle_info. With
    # the old async note_agent_send cast, the note was processed AFTER the
    # turn_seq bump for N+1, stamping a FALSE {sink, N+1} mark — turn N+1's
    # legitimate answer was silently swallowed as :explicit_send. The sweep
    # return value (plus the poll-path accumulator) is now the ONLY mark
    # source, stamped synchronously with the completing turn's seq.
    swarm = start_swarm(ws, fixture, self(), 300)

    :ok = AgentServer.send_task(swarm, :writer, "SENDLATE first")
    # Queue the follow-up while turn 1 is still thinking (it must QUEUE, not
    # pipeline) — it is dispatched in turn 1's TURN_COMPLETE handler.
    Process.sleep(120)
    :ok = AgentServer.send_task(swarm, :writer, "second")

    # The explicit reply arrives, turn 1's auto-delivery is suppressed in its
    # favor — and turn 2's answer is NOT collateral damage.
    assert_receive {:sink_got, :writer, "EXPLICIT REPLY"}, 8_000
    assert_receive {:sink_got, :writer, "ANSWER to: [From orchestrator] second"}, 8_000
    refute_receive {:sink_got, _, "ANSWER to: [From orchestrator] SENDLATE first"}, 600
  end

  test "a broadcast during the turn also counts as an explicit send (no double delivery)",
       %{workspace: ws, fixture: fixture} do
    swarm = start_swarm(ws, fixture, self(), 300)

    :ok = AgentServer.send_task(swarm, :writer, "SLOW bb")
    Process.sleep(150)
    outbox = Path.join(ws, ".outbox")
    File.mkdir_p!(outbox)

    File.write!(
      Path.join(outbox, "0001_broadcast.json"),
      Jason.encode!(%{broadcast: true, content: "NOTICE TO ALL"})
    )

    # the broadcast reaches the sink (it's in the topology)...
    assert_receive {:sink_got, :writer, "NOTICE TO ALL"}, 8_000
    # ...and the turn's text is not delivered on top of it.
    refute_receive {:sink_got, _, "ANSWER to: [From orchestrator] SLOW bb"}, 600
  end

  test "an explicit outbox send drained by the 500ms poll mid-turn suppresses the automatic delivery",
       %{workspace: ws, fixture: fixture} do
    # The file is written ~450ms before the SLOW turn ends, so the watcher's
    # poll (not the sweep) usually routes it — it must be accumulated and
    # handed back by the TURN_COMPLETE sweep for exact attribution. (A real
    # agent can only write .outbox files DURING its turn — its process is
    # blocked at the prompt afterwards — so the file goes in mid-turn here.)
    swarm = start_swarm(ws, fixture, self(), 1_500)

    :ok = AgentServer.send_task(swarm, :writer, "SLOW with explicit send")
    Process.sleep(150)

    # Simulate the agent's own `swarm-msg send sink` during the turn.
    outbox = Path.join(ws, ".outbox")
    File.mkdir_p!(outbox)

    File.write!(
      Path.join(outbox, "0001_sink_explicit.json"),
      Jason.encode!(%{to: "sink", content: "EXPLICIT REPLY"})
    )

    # The explicit send arrives (via LogWatcher → Router)...
    assert_receive {:sink_got, :writer, "EXPLICIT REPLY"}, 8_000
    # ...and the automatic delivery is suppressed (grace expires silently).
    refute_receive {:sink_got, _, _}, 2_500
  end

  # ── turn_sends bookkeeping bounds (review round 3 finding 2) ───────────────

  defp turn_sends(swarm) do
    :sys.get_state(AgentServer.via_tuple(swarm, :writer)).turn_sends
  end

  test "no reply_to ⇒ no turn_sends marks are ever recorded (default deployments don't leak)",
       %{workspace: ws, fixture: fixture} do
    # With reply_to nil there is no auto-delivery to suppress, so any mark
    # recorded is pure leak: nothing ever consumed them (the only prune site
    # was the {:auto_deliver, ...} handler, which never runs).
    swarm = start_swarm(ws, fixture, self(), 100, reply_to: nil)

    for i <- 1..3 do
      :ok = AgentServer.send_task(swarm, :writer, "SLOW task #{i}")
      Process.sleep(150)

      File.mkdir_p!(Path.join(ws, ".outbox"))

      File.write!(
        Path.join(ws, ".outbox/000#{i}_sink.json"),
        Jason.encode!(%{to: "sink", content: "send #{i}"})
      )

      # the explicit send still routes normally
      assert_receive {:sink_got, :writer, "send " <> _}, 8_000
      wait_for_idle(swarm, :writer, 5_000)
    end

    assert turn_sends(swarm) == MapSet.new()

    # ...and the watcher's poll-path accumulator (never swept when reply_to is
    # off) must not be quietly growing in the AgentServer's stead.
    watcher = :sys.get_state(AgentServer.via_tuple(swarm, :writer)).log_watcher
    assert :sys.get_state(watcher).routed_since_sweep == []
  end

  test "a no_final_text turn prunes its own marks (explicit send + silent turn does not leak)",
       %{workspace: ws, fixture: fixture} do
    # SENDSILENT: the turn explicit-sends but produces no stdout answer, so no
    # {:auto_deliver, ...} is ever scheduled — the previous prune site. The
    # skip path itself must discard the turn's marks.
    swarm = start_swarm(ws, fixture, self(), 100)

    :ok = AgentServer.send_task(swarm, :writer, "SENDSILENT one")
    assert_receive {:sink_got, :writer, "EXPLICIT REPLY"}, 8_000
    wait_for_idle(swarm, :writer, 5_000)

    assert turn_sends(swarm) == MapSet.new()
    refute_receive {:sink_got, _, _}, 500
  end
end
