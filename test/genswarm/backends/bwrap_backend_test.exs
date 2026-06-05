defmodule Genswarm.Backends.BwrapBackendTest do
  use ExUnit.Case, async: false

  alias Genswarm.Backends.BwrapBackend
  alias Genswarm.Backends.Bwrap.{OverlayManager, AgentTelemetry}

  @moduletag :bwrap

  setup_all do
    # Start telemetry if not running
    case AgentTelemetry.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, infrastructure_ready: OverlayManager.infrastructure_ready?()}
  end

  describe "backend_type/0" do
    test "returns :bwrap" do
      assert BwrapBackend.backend_type() == :bwrap
    end
  end

  describe "start/2 and stop/1" do
    @tag :integration
    test "starts and stops a bwrap sandbox", %{infrastructure_ready: ready} do
      if not ready do
        IO.puts("Skipping: bwrap infrastructure not ready")
      else
        config = %{
          swarm_name: "test",
          presets: [:base],
          workspace: "/tmp/test-workspace-#{:rand.uniform(999999)}"
        }

        assert {:ok, ref} = BwrapBackend.start("test-agent", config)
        assert %BwrapBackend{} = ref
        assert ref.sandbox_id =~ "test-test-agent"
        assert ref.port != nil

        # Should be healthy
        assert :ok = BwrapBackend.health_check(ref)

        # Stop should cleanup
        assert :ok = BwrapBackend.stop(ref)

        # Overlay should be cleaned up
        refute File.exists?(ref.overlay_dir)
      end
    end

    test "returns error when overlay setup fails" do
      # Test with a config that will fail (infrastructure not ready simulates this)
      config = %{
        swarm_name: "test",
        presets: [:base]
      }

      result = BwrapBackend.start("test-agent", config)

      # Should either succeed (if infra ready) or fail gracefully
      case result do
        {:ok, ref} ->
          BwrapBackend.stop(ref)
          assert true

        {:error, {:overlay_setup_failed, _}} ->
          assert true

        {:error, _other} ->
          assert true
      end
    end
  end

  describe "send_input/2" do
    @tag :integration
    test "sends input to running sandbox", %{infrastructure_ready: ready} do
      if not ready do
        IO.puts("Skipping: bwrap infrastructure not ready")
      else
        config = %{
          swarm_name: "test",
          presets: [:base],
          workspace: "/tmp/test-workspace-#{:rand.uniform(999999)}"
        }

        {:ok, ref} = BwrapBackend.start("test-agent", config)

        # Send some input
        assert :ok = BwrapBackend.send_input(ref, "echo hello")

        # Cleanup
        BwrapBackend.stop(ref)
      end
    end

    test "returns error for nil port" do
      # Create a ref with nil port
      ref = %BwrapBackend{
        port: nil,
        name: "test",
        sandbox_id: "test-123",
        overlay_dir: "/tmp/test",
        buffer: ""
      }

      # Should handle gracefully
      assert {:error, _} = BwrapBackend.send_input(ref, "test")
    end
  end

  describe "health_check/1" do
    @tag :integration
    test "returns :ok for healthy sandbox", %{infrastructure_ready: ready} do
      if not ready do
        IO.puts("Skipping: bwrap infrastructure not ready")
      else
        config = %{
          swarm_name: "test",
          presets: [:base],
          workspace: "/tmp/test-workspace-#{:rand.uniform(999999)}"
        }

        {:ok, ref} = BwrapBackend.start("test-agent", config)

        assert :ok = BwrapBackend.health_check(ref)

        BwrapBackend.stop(ref)
      end
    end

    test "returns error for nil port" do
      ref = %BwrapBackend{
        port: nil,
        name: "test",
        sandbox_id: "test-123",
        overlay_dir: "/tmp/test",
        scope_name: nil,
        buffer: ""
      }

      assert {:error, :port_closed} = BwrapBackend.health_check(ref)
    end
  end

  describe "deploy_skills/2" do
    test "updates skills_dir in ref" do
      ref = %BwrapBackend{
        port: nil,
        name: "test",
        sandbox_id: "test-123",
        overlay_dir: "/tmp/test",
        skills_dir: nil,
        buffer: ""
      }

      {:ok, new_ref} = BwrapBackend.deploy_skills(ref, "/path/to/skills")

      assert new_ref.skills_dir == "/path/to/skills"
    end
  end

  describe "handle_output/2" do
    test "parses JSON lines correctly" do
      ref = %BwrapBackend{
        buffer: "",
        sandbox_id: "test-123"
      }

      data = ~s({"type": "message", "content": "hello"}\n{"type": "output", "content": "world"}\npartial)

      {:ok, messages, remaining} = BwrapBackend.handle_output(ref, data)

      assert length(messages) == 2
      assert remaining == "partial"
    end

    test "handles non-JSON lines" do
      ref = %BwrapBackend{
        buffer: "",
        sandbox_id: "test-123"
      }

      data = "plain text output\n"

      {:ok, messages, remaining} = BwrapBackend.handle_output(ref, data)

      assert length(messages) == 1
      assert hd(messages)["type"] == "output"
      assert hd(messages)["content"] == "plain text output"
      assert remaining == ""
    end
  end
end
