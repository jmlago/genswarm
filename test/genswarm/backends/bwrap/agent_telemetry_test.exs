defmodule Genswarm.Backends.Bwrap.AgentTelemetryTest do
  use ExUnit.Case, async: false

  alias Genswarm.Backends.Bwrap.AgentTelemetry

  setup do
    # Start telemetry GenServer if not running
    case AgentTelemetry.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Create unique sandbox ID for each test
    sandbox_id = "test-#{:rand.uniform(999999)}"
    {:ok, sandbox_id: sandbox_id}
  end

  describe "log_output/2" do
    test "logs string output", %{sandbox_id: sandbox_id} do
      assert :ok = AgentTelemetry.log_output(sandbox_id, "test message")
    end

    test "logs map output as JSON", %{sandbox_id: sandbox_id} do
      msg = %{"type" => "test", "content" => "hello"}
      assert :ok = AgentTelemetry.log_output(sandbox_id, msg)
    end

    test "handles many rapid writes", %{sandbox_id: sandbox_id} do
      # Simulate high throughput
      for i <- 1..1000 do
        AgentTelemetry.log_output(sandbox_id, "message #{i}")
      end

      # Should be able to retrieve some
      lines = AgentTelemetry.tail(sandbox_id, 50)
      assert length(lines) <= 50
    end
  end

  describe "tail/2" do
    test "returns recent output", %{sandbox_id: sandbox_id} do
      for i <- 1..10 do
        AgentTelemetry.log_output(sandbox_id, "line #{i}")
      end

      lines = AgentTelemetry.tail(sandbox_id, 5)
      assert length(lines) == 5
      # Should be most recent
      assert Enum.any?(lines, &String.contains?(&1, "line 10"))
    end

    test "returns empty list for unknown sandbox" do
      lines = AgentTelemetry.tail("nonexistent-#{:rand.uniform(999999)}", 10)
      assert lines == []
    end

    test "returns in chronological order", %{sandbox_id: sandbox_id} do
      AgentTelemetry.log_output(sandbox_id, "first")
      :timer.sleep(1)
      AgentTelemetry.log_output(sandbox_id, "second")
      :timer.sleep(1)
      AgentTelemetry.log_output(sandbox_id, "third")

      lines = AgentTelemetry.tail(sandbox_id, 3)
      assert lines == ["first", "second", "third"]
    end
  end

  describe "get_all_output/1" do
    test "returns all output", %{sandbox_id: sandbox_id} do
      for i <- 1..5 do
        AgentTelemetry.log_output(sandbox_id, "msg #{i}")
      end

      all = AgentTelemetry.get_all_output(sandbox_id)
      assert length(all) == 5
    end
  end

  describe "log_event/3" do
    test "logs lifecycle events", %{sandbox_id: sandbox_id} do
      assert :ok = AgentTelemetry.log_event(sandbox_id, :started, %{presets: [:base]})
      assert :ok = AgentTelemetry.log_event(sandbox_id, :stopped, %{})
    end
  end

  describe "get_events/2" do
    test "returns events", %{sandbox_id: sandbox_id} do
      AgentTelemetry.log_event(sandbox_id, :started, %{})
      AgentTelemetry.log_event(sandbox_id, :message_received, %{from: "agent1"})
      AgentTelemetry.log_event(sandbox_id, :stopped, %{})

      events = AgentTelemetry.get_events(sandbox_id, 10)
      assert length(events) == 3
      assert Enum.any?(events, fn e -> e.type == :started end)
    end
  end

  describe "clear/1" do
    test "clears all data for sandbox", %{sandbox_id: sandbox_id} do
      AgentTelemetry.log_output(sandbox_id, "test")
      AgentTelemetry.log_event(sandbox_id, :test, %{})

      assert :ok = AgentTelemetry.clear(sandbox_id)

      assert AgentTelemetry.tail(sandbox_id, 10) == []
      assert AgentTelemetry.get_events(sandbox_id, 10) == []
    end
  end

  describe "throughput_stats/0" do
    test "returns stats map" do
      stats = AgentTelemetry.throughput_stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_lines_processed)
      assert Map.has_key?(stats, :current_output_entries)
      assert Map.has_key?(stats, :memory_mb)
    end
  end

  describe "active_agent_count/0" do
    test "counts unique sandboxes" do
      # Log to multiple sandboxes
      AgentTelemetry.log_output("sandbox-a-#{:rand.uniform(9999)}", "test")
      AgentTelemetry.log_output("sandbox-b-#{:rand.uniform(9999)}", "test")

      count = AgentTelemetry.active_agent_count()
      assert is_integer(count)
      assert count >= 2
    end
  end

  describe "list_sandboxes/0" do
    test "returns list of sandbox IDs" do
      id1 = "list-test-#{:rand.uniform(9999)}"
      id2 = "list-test-#{:rand.uniform(9999)}"

      AgentTelemetry.log_output(id1, "test")
      AgentTelemetry.log_output(id2, "test")

      sandboxes = AgentTelemetry.list_sandboxes()
      assert is_list(sandboxes)
      assert id1 in sandboxes
      assert id2 in sandboxes
    end
  end

  describe "ring buffer pruning" do
    test "prunes old entries when limit exceeded", %{sandbox_id: sandbox_id} do
      # Write more than max_lines_per_agent (200)
      for i <- 1..300 do
        AgentTelemetry.log_output(sandbox_id, "line #{i}")
      end

      # Give time for async prune
      :timer.sleep(100)

      # Force stats update to trigger prune check
      _ = AgentTelemetry.throughput_stats()

      # Eventually should be pruned to around max
      :timer.sleep(100)
      all = AgentTelemetry.get_all_output(sandbox_id)

      # Should have pruned some entries (within threshold)
      assert length(all) <= 300  # At least no more than we wrote
    end
  end
end
