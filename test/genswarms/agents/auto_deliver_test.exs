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

  defmodule SinkHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(config), do: {:ok, %{test_pid: Map.fetch!(config, :test_pid)}}
    @impl true
    def handle_message(from, content, state) do
      send(state.test_pid, {:sink_got, from, content})
      {:noreply, state}
    end

    @impl true
    def interface(), do: %{}
  end

  @fake_szc """
  #!/usr/bin/env bash
  # Fake subzeroclaw: same I/O contract as the real harness.
  while IFS= read -r -d '' turn; do
    printf '[1] fake-model...\\n' >&2
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

  defp wait_for_idle(swarm, agent, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> AgentServer.get_state(swarm, agent) end)
    |> Enum.reduce_while(nil, fn s, _ ->
      cond do
        s == :idle -> {:halt, :ok}
        System.monotonic_time(:millisecond) > deadline -> raise "agent never idle (#{s})"
        true -> Process.sleep(20) && {:cont, nil}
      end
    end)
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
