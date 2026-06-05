defmodule Genswarm.Observability.EventStoreTest do
  use ExUnit.Case, async: false

  alias Genswarm.Observability.EventStore
  alias Genswarm.CLI.SwarmRegistry

  setup do
    SwarmRegistry.init()
    :ok
  end

  describe "SQLite backend (default)" do
    test "persist then query round-trips through the facade" do
      EventStore.persist(%{
        level: :info,
        category: :agent,
        event_type: :store_roundtrip,
        message: "hi",
        swarm: "store-a",
        agent: :a1,
        metadata: %{k: "v"}
      })

      events = EventStore.query(swarm: "store-a", limit: 10)
      assert Enum.any?(events, &(&1.event_type == :store_roundtrip))
    end

    test "events_since / max_event_id are exposed via the facade" do
      base = EventStore.max_event_id()

      EventStore.persist(%{
        level: :info,
        category: :swarm,
        event_type: :s,
        message: "x",
        swarm: "store-b"
      })

      assert EventStore.max_event_id() > base
      assert Enum.any?(EventStore.events_since(base, 100), &(&1.event_type == :s))
    end

    test "the default backend is stateless (no supervised children)" do
      assert EventStore.backend() == Genswarm.Observability.EventStore.Sqlite
      assert EventStore.child_specs() == []
    end
  end

  describe "swappable backend" do
    defmodule StubBackend do
      @behaviour Genswarm.Observability.EventStore

      @impl true
      def persist(event), do: send(:event_store_test_owner, {:persisted, event}) && :ok
      @impl true
      def query(_opts), do: [:from_stub]
      @impl true
      def events_since(_since, _limit), do: []
      @impl true
      def max_event_id, do: 0
      @impl true
      def child_specs, do: [{Agent, fn -> :ok end}]
    end

    test "the facade dispatches to the configured backend, child_specs included" do
      Process.register(self(), :event_store_test_owner)
      prev = Application.get_env(:genswarm, :event_store)
      Application.put_env(:genswarm, :event_store, StubBackend)

      # The registered name is auto-released when this test process exits.
      on_exit(fn -> Application.put_env(:genswarm, :event_store, prev) end)

      assert EventStore.backend() == StubBackend
      assert EventStore.query([]) == [:from_stub]
      assert [{Agent, _}] = EventStore.child_specs()

      EventStore.persist(%{level: :info, category: :agent, event_type: :x, message: "m"})
      assert_received {:persisted, %{event_type: :x}}
    end
  end
end
