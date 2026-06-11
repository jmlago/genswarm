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

  @fake_szc """
  #!/usr/bin/env bash
  # Fake subzeroclaw: same I/O contract as the real harness.
  # SILENT → no stdout answer; SLOW → 600ms of "thinking" before answering.
  while IFS= read -r -d '' turn; do
    printf '[1] fake-model...\\n' >&2
    case "$turn" in
      *SLOW*) sleep 0.6 ;;
    esac
    case "$turn" in
      *SILENT*) : ;;
      *) printf 'ANSWER to: %s\\n' "$turn" ;;
    esac
    printf '\\n<<TURN_COMPLETE>>\\n> '
  done
  """

  setup do
    if System.find_executable("bash") == nil or System.find_executable("jq") == nil do
      raise "bash/jq required by the szc wrapper are not available"
    end

    base = Path.join(System.tmp_dir!(), "autodeliver_#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "ws")
    File.mkdir_p!(workspace)

    fixture = Path.join(base, "fake_szc.sh")
    File.write!(fixture, @fake_szc)
    File.chmod!(fixture, 0o755)

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, workspace: workspace, fixture: fixture}
  end

  defp start_swarm(workspace, fixture, test_pid, grace_ms) do
    swarm = "autodel-#{System.unique_integer([:positive])}"

    config = %{
      name: swarm,
      agents: [
        %{
          name: :writer,
          backend: :local,
          config: %{
            workspace: workspace,
            subzeroclaw_path: fixture,
            reply_to: :sink,
            reply_grace_ms: grace_ms
          }
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

  test "BLOCKER regression: explicit send during turn N + queued follow-up — N is suppressed, N+1 still delivers",
       %{workspace: ws, fixture: fixture} do
    # The adversarial review's headline finding: with seq-at-noting-time
    # attribution, the explicit send written late in turn N got stamped with
    # N+1 (the follow-up had already begun a new turn), suppressing the
    # FOLLOW-UP's legitimate answer. Exact stamping via the synchronous sweep
    # fixes the attribution; serial turns fix the dispatch accounting.
    swarm = start_swarm(ws, fixture, self(), 300)

    :ok = AgentServer.send_task(swarm, :writer, "SLOW first")
    # While turn 1 is still thinking: the agent explicitly replies via outbox,
    # and the user sends a follow-up (which must QUEUE, not pipeline).
    Process.sleep(150)
    outbox = Path.join(ws, ".outbox")
    File.mkdir_p!(outbox)

    File.write!(
      Path.join(outbox, "0001_sink_explicit.json"),
      Jason.encode!(%{to: "sink", content: "EXPLICIT REPLY"})
    )

    :ok = AgentServer.send_task(swarm, :writer, "second")

    # The explicit reply arrives, turn 1's auto-delivery is suppressed in its
    # favor — and turn 2's answer is NOT collateral damage.
    assert_receive {:sink_got, :writer, "EXPLICIT REPLY"}, 8_000
    assert_receive {:sink_got, :writer, "ANSWER to: [From orchestrator] second"}, 8_000
    refute_receive {:sink_got, _, "ANSWER to: [From orchestrator] SLOW first"}, 600
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

  test "an explicit outbox send to the sink suppresses the automatic delivery",
       %{workspace: ws, fixture: fixture} do
    # Long grace: the LogWatcher polls .outbox every 500ms, and the explicit
    # send must be noted before the grace elapses.
    swarm = start_swarm(ws, fixture, self(), 1_500)

    :ok = AgentServer.send_task(swarm, :writer, "with explicit send")

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
end
