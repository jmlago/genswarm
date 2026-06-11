defmodule Genswarms.Agents.TurnBoundsTest do
  @moduledoc """
  Tests for turn bounds (genswarms#53 G3): the per-turn wall clock (engine) and
  the per-agent step budget written into the harness config (backends).

  The wall-clock tests run through the REAL local backend + wrapper with a
  stalling fake harness (same approach as AutoDeliverTest); the budget tests
  exercise the pure backend builders directly.

  async: false — shares the global AgentRegistry/Router.
  """
  use ExUnit.Case, async: false

  alias Genswarms.{SwarmManager, Agents.AgentServer}
  alias Genswarms.Backends.{BwrapBackend, DockerBackend}
  alias Genswarms.CLI.SwarmRegistry

  alias Genswarms.Test.SinkHandler

  import Genswarms.Test.SyncTurnHelpers

  # Stalls 1200ms before answering — long past the test's 200ms wall clock,
  # so the turn expires first and the late answer must NOT be delivered.
  @stalling_szc """
  #!/usr/bin/env bash
  while IFS= read -r -d '' turn; do
    sleep 1.2
    printf 'LATE ANSWER to: %s\\n' "$turn"
    printf '\\n<<TURN_COMPLETE>>\\n> '
  done
  """

  describe "per-turn wall clock" do
    setup do
      if System.find_executable("bash") == nil or System.find_executable("jq") == nil do
        raise "bash/jq required by the szc wrapper are not available"
      end

      base = Path.join(System.tmp_dir!(), "turnbounds_#{System.unique_integer([:positive])}")
      workspace = Path.join(base, "ws")
      File.mkdir_p!(workspace)

      fixture = Path.join(base, "stalling_szc.sh")
      File.write!(fixture, @stalling_szc)
      File.chmod!(fixture, 0o755)

      on_exit(fn -> File.rm_rf(base) end)
      {:ok, workspace: workspace, fixture: fixture}
    end

    test "an over-budget turn emits turn_timeout and its late text is not delivered",
         %{workspace: ws, fixture: fixture} do
      handler_id = "turn-timeout-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:genswarms, :agent, :turn_timeout],
          [:genswarms, :agent, :auto_deliver_skipped]
        ],
        fn [:genswarms, :agent, event], _meas, meta, pid -> send(pid, {event, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      swarm = "bounds-#{System.unique_integer([:positive])}"

      config = %{
        name: swarm,
        agents: [
          %{
            name: :writer,
            backend: :local,
            config: %{
              workspace: ws,
              subzeroclaw_path: fixture,
              reply_to: :sink,
              reply_grace_ms: 100,
              turn_timeout_ms: 200
            }
          }
        ],
        objects: [%{name: :sink, handler: SinkHandler, config: %{test_pid: self()}}],
        topology: [{:writer, :sink}]
      }

      {:ok, ^swarm} = SwarmManager.start_from_config(config)
      SwarmRegistry.clear_overlay(swarm)

      on_exit(fn ->
        SwarmManager.stop(swarm)
        SwarmRegistry.clear_overlay(swarm)
      end)

      wait_for_idle(swarm, :writer, 5_000)

      :ok = AgentServer.send_task(swarm, :writer, "will stall")

      # 200ms wall clock fires while the harness sleeps 1.2s...
      assert_receive {:turn_timeout, %{agent: :writer, timeout_ms: 200}}, 5_000
      # ...the late TURN_COMPLETE arrives, is visibly skipped...
      assert_receive {:auto_deliver_skipped, %{reason: :turn_expired}}, 5_000
      # ...and the stale answer never reaches the sink.
      refute_receive {:sink_got, _, _}, 800
    end
  end

  describe "step budget → harness config" do
    test "bwrap writes max_turns into the overlay upper layer" do
      overlay = Path.join(System.tmp_dir!(), "bw_overlay_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(overlay) end)

      :ok = BwrapBackend.setup_harness_config(overlay, %{max_turns: 16})

      assert File.read!(Path.join([overlay, "upper", "root", ".subzeroclaw", "config"])) ==
               "max_turns = 16\n"
    end

    test "bwrap writes nothing without max_turns (harness defaults preserved)" do
      overlay = Path.join(System.tmp_dir!(), "bw_overlay_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(overlay) end)

      :ok = BwrapBackend.setup_harness_config(overlay, %{})
      :ok = BwrapBackend.setup_harness_config(overlay, %{max_turns: "16; rm -rf /"})

      refute File.exists?(Path.join([overlay, "upper", "root", ".subzeroclaw", "config"]))
    end

    test "docker default bootstrap appends max_turns to the in-container config" do
      args =
        DockerBackend.build_docker_args("c1", "img", nil, nil, nil, nil, "a1", %{max_turns: 16})

      script = List.last(args)

      assert script =~ ~s(echo "max_turns = 16" >> /root/.subzeroclaw/config)
    end

    test "docker bootstrap is unchanged without max_turns (and rejects non-integers)" do
      for config <- [%{}, %{max_turns: "16; evil"}, %{max_turns: 0}] do
        args = DockerBackend.build_docker_args("c1", "img", nil, nil, nil, nil, "a1", config)
        script = List.last(args)
        refute script =~ "max_turns"
      end
    end
  end

end
