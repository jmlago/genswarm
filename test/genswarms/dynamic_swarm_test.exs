defmodule Genswarms.DynamicSwarmTest do
  @moduledoc """
  Integration tests for dynamic agent/object addition.

  Uses ObjectHandler-based objects (no external backend) for most flows
  and the :mock backend for agent-specific flows.
  """

  use ExUnit.Case

  alias Genswarms.{SwarmManager, Routing.Router}
  alias Genswarms.CLI.SwarmRegistry

  defmodule NoopHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_config), do: {:ok, %{}}
    @impl true
    def handle_message(_from, _content, state), do: {:noreply, state}
    @impl true
    def interface(), do: %{}
  end

  # Registry deregistration is eventually consistent after process death;
  # wait briefly for the entry to clear.
  defp wait_unregistered(swarm, name, attempts \\ 50) do
    case Registry.lookup(Genswarms.AgentRegistry, {swarm, name}) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_unregistered(swarm, name, attempts - 1)

      _ ->
        :timeout
    end
  end

  setup do
    swarm_name = "dyn-test-#{System.unique_integer([:positive])}"

    config = %{
      name: swarm_name,
      agents: [
        %{name: :alpha, backend: :mock}
      ],
      objects: [
        %{name: :sink, handler: NoopHandler}
      ],
      topology: [
        {:alpha, :sink}
      ]
    }

    {:ok, ^swarm_name} = SwarmManager.start_from_config(config)
    SwarmRegistry.clear_overlay(swarm_name)

    on_exit(fn ->
      SwarmManager.stop(swarm_name)
      SwarmRegistry.clear_overlay(swarm_name)
    end)

    {:ok, swarm: swarm_name}
  end

  describe "add_topology_edges/3" do
    test "adds edges to router and config", %{swarm: swarm} do
      :ok = SwarmManager.add_topology_edges(swarm, [{:sink, :alpha}])

      {:ok, conns} = Router.get_connections(swarm, :sink)
      assert :alpha in conns

      {:ok, status} = SwarmManager.status(swarm)
      assert status.config.topology_edges == 2
    end

    test "returns error for unknown swarm" do
      assert {:error, :swarm_not_found} =
               SwarmManager.add_topology_edges("nope", [{:a, :b}])
    end
  end

  describe "add_object/3" do
    test "adds an object and wires up connections", %{swarm: swarm} do
      spec = %{name: :sink2, handler: NoopHandler}

      {:ok, :sink2} =
        SwarmManager.add_object(swarm, spec, connections: [:alpha], incoming: [:alpha])

      # Object is in registry
      assert [_] = Registry.lookup(Genswarms.AgentRegistry, {swarm, :sink2})

      # Edges added
      {:ok, conns_out} = Router.get_connections(swarm, :sink2)
      assert :alpha in conns_out
      {:ok, conns_in} = Router.get_connections(swarm, :alpha)
      assert :sink2 in conns_in
    end

    test "rejects duplicate name", %{swarm: swarm} do
      assert {:error, {:already_exists, :sink}} =
               SwarmManager.add_object(swarm, %{name: :sink, handler: NoopHandler})
    end
  end

  describe "remove_object/3" do
    test "removes object and clears edges", %{swarm: swarm} do
      spec = %{name: :scratch, handler: NoopHandler}
      {:ok, :scratch} = SwarmManager.add_object(swarm, spec, incoming: [:alpha])

      :ok = SwarmManager.remove_object(swarm, :scratch)
      :ok = wait_unregistered(swarm, :scratch)

      assert [] = Registry.lookup(Genswarms.AgentRegistry, {swarm, :scratch})
      {:ok, conns} = Router.get_connections(swarm, :alpha)
      refute :scratch in conns
    end

    test "returns error for unknown object", %{swarm: swarm} do
      assert {:error, :not_found} = SwarmManager.remove_object(swarm, :nowhere)
    end
  end

  describe "add_agent/3 (with :mock backend)" do
    test "edges are registered before agent is started (no invalid_route race)", %{swarm: swarm} do
      spec = %{name: :beta, backend: :mock}

      {:ok, :beta} = SwarmManager.add_agent(swarm, spec, connections: [:sink])

      # Edge must be present
      {:ok, conns} = Router.get_connections(swarm, :beta)
      assert :sink in conns

      # And the agent is registered as an :agent (not :object)
      assert [{_pid, :agent}] =
               Registry.lookup(Genswarms.AgentRegistry, {swarm, :beta})
    end

    test "config reflects new agent", %{swarm: swarm} do
      {:ok, :gamma} = SwarmManager.add_agent(swarm, %{name: :gamma, backend: :mock})

      {:ok, status} = SwarmManager.status(swarm)
      # Original seed had 1 agent; we now have 2 in the config
      assert status.config.agent_count == 2
    end

    test "rejects an agent name with shell metacharacters (runtime path)", %{swarm: swarm} do
      # The dynamic add-agent path bypasses SwarmConfig.parse, so validation must
      # also happen here — names flow into backend spawn commands.
      for evil <- ["a; touch /tmp/pwned", "a$(id)", "a b", "../escape", "1starts_digit"] do
        assert {:error, {:invalid_agent_name, _}} =
                 SwarmManager.add_agent(swarm, %{name: evil, backend: :mock}),
               "expected #{inspect(evil)} to be rejected at the runtime add_agent path"

        # And no agent process was registered under that name.
        assert [] = Registry.lookup(Genswarms.AgentRegistry, {swarm, String.to_atom(evil)})
      end
    end

    test "accepts a valid agent name at the runtime path", %{swarm: swarm} do
      assert {:ok, :valid_one} =
               SwarmManager.add_agent(swarm, %{name: "valid_one", backend: :mock})
    end
  end

  describe "remove_agent/3" do
    test "stops agent and removes from topology", %{swarm: swarm} do
      {:ok, :delta} =
        SwarmManager.add_agent(swarm, %{name: :delta, backend: :mock}, connections: [:sink])

      :ok = SwarmManager.remove_agent(swarm, :delta)
      :ok = wait_unregistered(swarm, :delta)

      assert [] = Registry.lookup(Genswarms.AgentRegistry, {swarm, :delta})
      {:ok, conns} = Router.get_connections(swarm, :delta)
      assert conns == []
    end
  end

  describe "scale_agent_group/4" do
    test "scales up from 0 to N using existing agent as template", %{swarm: swarm} do
      # scale_agent_group normalizes the group to base_name_1..N.
      # The bare :alpha singleton (not matching :alpha_N) is replaced.
      {:ok, %{added: added, removed: removed, failed: failed}} =
        SwarmManager.scale_agent_group(swarm, :alpha, 3)

      assert added == [:alpha_1, :alpha_2, :alpha_3]
      assert removed == [:alpha]
      assert failed == []

      for i <- 1..3 do
        assert [_] = Registry.lookup(Genswarms.AgentRegistry, {swarm, :"alpha_#{i}"})
      end

      # Bare :alpha is gone
      assert [] = Registry.lookup(Genswarms.AgentRegistry, {swarm, :alpha})
    end

    test "scales down by removing extras", %{swarm: swarm} do
      {:ok, _} = SwarmManager.scale_agent_group(swarm, :alpha, 5)

      {:ok, %{added: added, removed: removed}} =
        SwarmManager.scale_agent_group(swarm, :alpha, 2)

      assert added == []
      assert Enum.sort(removed) == [:alpha_3, :alpha_4, :alpha_5]

      for name <- [:alpha_3, :alpha_4, :alpha_5] do
        assert [] = Registry.lookup(Genswarms.AgentRegistry, {swarm, name})
      end
    end

    test "returns error if no template exists", %{swarm: swarm} do
      assert {:error, {:no_template, :nonexistent}} =
               SwarmManager.scale_agent_group(swarm, :nonexistent, 3)
    end
  end

  describe "persist: true" do
    test "appends to overlay log", %{swarm: swarm} do
      {:ok, :persisted} =
        SwarmManager.add_agent(swarm, %{name: :persisted, backend: :mock}, persist: true)

      events = SwarmRegistry.load_overlay(swarm)
      assert [{:add_agent, payload} | _] = events
      assert payload[:name] == :persisted or payload["name"] == :persisted
    end

    test "persist: false does not write overlay", %{swarm: swarm} do
      SwarmRegistry.clear_overlay(swarm)

      {:ok, :transient} =
        SwarmManager.add_agent(swarm, %{name: :transient, backend: :mock}, persist: false)

      events = SwarmRegistry.load_overlay(swarm)
      assert events == []
    end
  end

  describe "rollback / atomicity" do
    test "rejecting a duplicate agent leaves topology unchanged", %{swarm: swarm} do
      {:ok, topology_before} = Router.get_topology(swarm)

      # :alpha already exists — duplicate should be rejected
      assert {:error, {:already_exists, :alpha}} =
               SwarmManager.add_agent(swarm, %{name: :alpha, backend: :mock},
                 connections: [:sink, :alpha]
               )

      {:ok, topology_after} = Router.get_topology(swarm)
      assert topology_before == topology_after
    end

    test "rejecting a duplicate object leaves topology unchanged", %{swarm: swarm} do
      {:ok, topology_before} = Router.get_topology(swarm)

      assert {:error, {:already_exists, :sink}} =
               SwarmManager.add_object(swarm, %{name: :sink, handler: NoopHandler},
                 connections: [:alpha]
               )

      {:ok, topology_after} = Router.get_topology(swarm)
      assert topology_before == topology_after
    end
  end

  describe "ExsWriter snapshot" do
    test "round-trips through Loader", %{swarm: swarm} do
      {:ok, :tau} =
        SwarmManager.add_agent(swarm, %{name: :tau, backend: :mock}, connections: [:sink])

      {:ok, config} = SwarmManager.get_full_config(swarm)
      source = Genswarms.Config.ExsWriter.to_exs_source(config)

      # Write to temp file and reload via Loader
      tmp = Path.join(System.tmp_dir!(), "snapshot_#{System.unique_integer([:positive])}.exs")
      File.write!(tmp, source)

      assert {:ok, reloaded} = Genswarms.Config.Loader.load(tmp)
      assert reloaded.name == config.name
      assert length(reloaded.agents) == length(config.agents)
      assert Enum.sort(reloaded.topology) == Enum.sort(config.topology)

      File.rm(tmp)
    end
  end

  describe "overlay replay on swarm restart" do
    test "persisted agents are restored after stop+start" do
      swarm_name = "replay-test-#{System.unique_integer([:positive])}"
      SwarmRegistry.clear_overlay(swarm_name)

      config = %{
        name: swarm_name,
        agents: [%{name: :seed, backend: :mock}],
        objects: [],
        topology: []
      }

      {:ok, ^swarm_name} = SwarmManager.start_from_config(config)

      {:ok, :extra} =
        SwarmManager.add_agent(swarm_name, %{name: :extra, backend: :mock}, persist: true)

      # Stop without clearing overlay (preserve semantics)
      {:ok, _} = SwarmManager.stop(swarm_name)

      # Restart
      {:ok, ^swarm_name} = SwarmManager.start_from_config(config)

      # :extra should be back via replay
      assert [_] = Registry.lookup(Genswarms.AgentRegistry, {swarm_name, :extra})

      SwarmManager.stop(swarm_name)
      SwarmRegistry.clear_overlay(swarm_name)
    end

    test "scale events replay deterministically" do
      swarm_name = "replay-scale-#{System.unique_integer([:positive])}"
      SwarmRegistry.clear_overlay(swarm_name)

      config = %{
        name: swarm_name,
        agents: [%{name: :worker_1, backend: :mock}],
        objects: [],
        topology: []
      }

      {:ok, ^swarm_name} = SwarmManager.start_from_config(config)

      {:ok, _} =
        SwarmManager.scale_agent_group(swarm_name, :worker, 4, persist: true)

      {:ok, _} = SwarmManager.stop(swarm_name)
      {:ok, ^swarm_name} = SwarmManager.start_from_config(config)

      for i <- 1..4 do
        assert [_] = Registry.lookup(Genswarms.AgentRegistry, {swarm_name, :"worker_#{i}"})
      end

      SwarmManager.stop(swarm_name)
      SwarmRegistry.clear_overlay(swarm_name)
    end
  end
end
