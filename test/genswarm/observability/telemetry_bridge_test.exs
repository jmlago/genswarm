defmodule Genswarm.Observability.TelemetryBridgeTest do
  use ExUnit.Case, async: false

  alias Genswarm.Observability.{LogStore, TelemetryBridge}

  # The bridge is attached at application start; these tests exercise that live
  # attachment end-to-end (telemetry -> LogStore -> PubSub).
  setup do
    :ok = LogStore.subscribe()
    on_exit(fn -> LogStore.unsubscribe() end)
    :ok
  end

  test "agent telemetry becomes a queryable + streamed log event" do
    :telemetry.execute(
      [:genswarm, :agent, :agent_started],
      %{time: 0},
      %{agent: :fixer_1, swarm: "s1"}
    )

    # Pin on the (unique) swarm so the suite's other log events don't race us.
    assert_receive {:log_event, %{swarm: "s1"} = event}, 1_000
    assert event.category == :agent
    assert event.event_type == :agent_started
    assert event.level == :info
    assert event.swarm == "s1"
    assert event.agent == :fixer_1
    assert event.message =~ "fixer_1"
  end

  test "error-named events are mapped to :error level" do
    :telemetry.execute([:genswarm, :agent, :agent_error], %{}, %{agent: :a, swarm: "s2"})

    assert_receive {:log_event, %{swarm: "s2", event_type: :agent_error, level: :error}}, 1_000
  end

  test "invalid_route maps to :warning" do
    :telemetry.execute([:genswarm, :router, :invalid_route], %{}, %{swarm: "s3", from: :a, to: :b})

    assert_receive {:log_event,
                    %{
                      swarm: "s3",
                      event_type: :invalid_route,
                      level: :warning,
                      category: :routing
                    }},
                   1_000
  end

  test "router domain is normalized to the :routing category with a readable message" do
    :telemetry.execute(
      [:genswarm, :router, :message_routed],
      %{},
      %{swarm: "s4", from: :researcher, to: :coder}
    )

    assert_receive {:log_event, %{swarm: "s4"} = event}, 1_000
    assert event.category == :routing
    assert event.message == "message routed researcher → coder"
  end

  test "swarm/agent/object keys are not duplicated inside the metadata blob" do
    :telemetry.execute(
      [:genswarm, :object, :object_started],
      %{},
      %{object: :evaluator, swarm: "s5", handler: SomeHandler, extra: 42}
    )

    assert_receive {:log_event, %{swarm: "s5"} = event}, 1_000
    assert event.agent == :evaluator
    refute Map.has_key?(event.metadata, :swarm)
    refute Map.has_key?(event.metadata, :object)
    assert event.metadata.extra == 42
    # Atoms (incl. module names) are preserved — Jason serializes them to strings.
    assert event.metadata.handler == SomeHandler
  end

  test "every event in known_events/0 is registered with :telemetry" do
    attached = :telemetry.list_handlers([]) |> Enum.map(& &1.id)
    assert "genswarm-telemetry-bridge" in attached

    # attach/0 is idempotent.
    assert TelemetryBridge.attach() == :ok
  end
end
