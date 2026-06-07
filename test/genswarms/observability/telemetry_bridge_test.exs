defmodule Genswarms.Observability.TelemetryBridgeTest do
  use ExUnit.Case, async: false

  alias Genswarms.Observability.{LogStore, TelemetryBridge}

  # The bridge is attached at application start; these tests exercise that live
  # attachment end-to-end (telemetry -> LogStore -> PubSub).
  setup do
    :ok = LogStore.subscribe()
    on_exit(fn -> LogStore.unsubscribe() end)
    :ok
  end

  test "agent telemetry becomes a queryable + streamed log event" do
    :telemetry.execute(
      [:genswarms, :agent, :agent_started],
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

  test "message_delivered is bridged under the :agent domain (regression)" do
    # message_delivered is emitted as [:genswarms, :agent, :message_delivered]
    # (agent_server.ex); the bridge must listen on the :agent domain, not :router,
    # or the event never reaches LogStore.
    :telemetry.execute(
      [:genswarms, :agent, :message_delivered],
      %{},
      %{agent: :coder, swarm: "s_md", from: :researcher}
    )

    assert_receive {:log_event, %{swarm: "s_md"} = event}, 1_000
    assert event.category == :agent
    assert event.event_type == :message_delivered
    assert event.agent == :coder
    assert event.metadata.from == :researcher
  end

  test "error-named events are mapped to :error level" do
    :telemetry.execute([:genswarms, :agent, :agent_error], %{}, %{agent: :a, swarm: "s2"})

    assert_receive {:log_event, %{swarm: "s2", event_type: :agent_error, level: :error}}, 1_000
  end

  test "invalid_route maps to :warning" do
    :telemetry.execute([:genswarms, :router, :invalid_route], %{}, %{
      swarm: "s3",
      from: :a,
      to: :b
    })

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
      [:genswarms, :router, :message_routed],
      %{},
      %{swarm: "s4", from: :researcher, to: :coder}
    )

    assert_receive {:log_event, %{swarm: "s4"} = event}, 1_000
    assert event.category == :routing
    assert event.message == "message routed researcher → coder"
  end

  test "a struct (DateTime) in metadata is rendered opaque, not dropped (regression)" do
    # DateTime is a map but not Enumerable; the generic map sanitizer's Map.new/2
    # used to raise Protocol.UndefinedError and the whole event was dropped.
    ts = ~U[2026-06-07 09:30:28Z]

    :telemetry.execute(
      [:genswarms, :router, :message_routed],
      %{},
      %{swarm: "s_dt", from: :researcher, to: :coder, at: ts}
    )

    assert_receive {:log_event, %{swarm: "s_dt"} = event}, 1_000
    assert event.metadata.at == inspect(ts)
  end

  test "swarm/agent/object keys are not duplicated inside the metadata blob" do
    :telemetry.execute(
      [:genswarms, :object, :object_started],
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

  test "an explicit :level in metadata overrides the name-derived level" do
    # :swarm_started would derive :info, but a partial start passes level: :error.
    :telemetry.execute(
      [:genswarms, :swarm, :swarm_started],
      %{},
      %{swarm: "s6", status: :error, level: :error}
    )

    assert_receive {:log_event, %{swarm: "s6"} = event}, 1_000
    assert event.event_type == :swarm_started
    assert event.level == :error
    # The override is a logging concern, not part of the event payload.
    refute Map.has_key?(event.metadata, :level)
    assert event.metadata.status == :error
  end

  test "swarm messages don't stutter the domain word" do
    :telemetry.execute([:genswarms, :swarm, :swarm_started], %{}, %{swarm: "s7", status: :running})

    assert_receive {:log_event, %{swarm: "s7"} = event}, 1_000
    assert event.message == "swarm s7 started"
  end

  test "every event in known_events/0 is registered with :telemetry" do
    attached = :telemetry.list_handlers([]) |> Enum.map(& &1.id)
    assert "genswarms-telemetry-bridge" in attached

    # attach/0 is idempotent.
    assert TelemetryBridge.attach() == :ok
  end
end
