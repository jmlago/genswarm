defmodule Genswarms.IR.ExecutorTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR.{FromConfig, ToConfig, Executor}

  # A stub orchestrator: records mutation calls (send to self/), serves the live
  # config from the process dictionary. Runs in the test process (apply is sync).
  defmodule StubSM do
    def get_full_config(_swarm),
      do: {:ok, Process.get(:sm_config, %{name: "s", agents: [], objects: [], topology: []})}

    def add_agent(_s, spec, _opts \\ []), do: send(self(), {:add_agent, spec}) && {:ok, :added}
    def remove_agent(_s, name, _opts \\ []), do: send(self(), {:remove_agent, name}) && :ok
    def add_object(_s, spec, _opts \\ []), do: send(self(), {:add_object, spec}) && {:ok, :added}
    def remove_object(_s, name, _opts \\ []), do: send(self(), {:remove_object, name}) && :ok

    def add_topology_edges(_s, edges, _opts \\ []),
      do: send(self(), {:add_edges, edges}) && :ok

    def remove_topology_edges(_s, edges, _opts \\ []),
      do: send(self(), {:remove_edges, edges}) && :ok
  end

  defp agent_cfg(name, extra \\ %{}),
    do:
      Map.merge(%{name: String.to_atom(name), backend: :bwrap, model: "anthropic/claude"}, extra)

  defp sm, do: [swarm_manager: StubSM]

  describe "ToConfig round-trips FromConfig" do
    test "agent spec recovers backend / model / skills / presets" do
      cfg = %{
        name: "s",
        agents: [
          %{
            name: :researcher,
            backend: {:docker, "web"},
            model: "anthropic/claude-sonnet-4",
            skills: ["web.md"],
            presets: [:base, :web]
          }
        ]
      }

      {:ok, state} = FromConfig.from_config(cfg)
      spec = ToConfig.agent_spec(hd(state.agents))

      assert spec.name == "researcher"
      assert spec.backend == {:docker, "web"}
      assert spec.model == "anthropic/claude-sonnet-4"
      assert spec.skills == ["web.md"]
      assert spec.presets == [:base, :web]
    end

    test "ssh / local backends and absent model round-trip" do
      {:ok, state} =
        FromConfig.from_config(%{
          name: "s",
          agents: [
            %{name: :a, backend: :local},
            %{name: :b, backend: {:ssh, "pi@192.168.1.50"}}
          ]
        })

      [a, b] = state.agents
      assert ToConfig.agent_spec(a).backend == :local
      assert ToConfig.agent_spec(a).model == nil
      assert ToConfig.agent_spec(b).backend == {:ssh, "pi@192.168.1.50"}
    end
  end

  describe "apply/3 maps a plan to orchestrator calls" do
    test "each action becomes one call, in order" do
      {:ok, st} = FromConfig.from_config(%{name: "s", agents: [agent_cfg("a")]})
      agent = hd(st.agents)

      plan = [{:start_agent, agent}, {:add_edge, {"a", "b"}}, {:stop_agent, "old"}]
      assert :ok = Executor.apply_plan("s", plan, sm())

      assert_received {:add_agent, %{name: "a"}}
      assert_received {:add_edges, [{:a, :b}]}
      assert_received {:remove_agent, "old"}
    end
  end

  describe "reconcile/3 (the full connection)" do
    test "diffs live config (observed) vs desired and applies the difference" do
      # live swarm currently runs only "a"
      Process.put(:sm_config, %{
        name: "s",
        agents: [agent_cfg("a")],
        objects: [],
        topology: []
      })

      # desired runs "a" and "b"
      {:ok, desired} =
        FromConfig.from_config(%{name: "s", agents: [agent_cfg("a"), agent_cfg("b")]})

      {:ok, plan} = Executor.reconcile("s", desired, sm())

      assert Enum.any?(plan, &match?({:start_agent, %{name: "b"}}, &1))
      assert_received {:add_agent, %{name: "b"}}
      # "a" already runs and its spec is unchanged -> no restart/add for it
      refute_received {:add_agent, %{name: "a"}}
    end

    test "stops agents the desired state dropped" do
      Process.put(:sm_config, %{
        name: "s",
        agents: [agent_cfg("a"), agent_cfg("gone")],
        objects: [],
        topology: []
      })

      {:ok, desired} = FromConfig.from_config(%{name: "s", agents: [agent_cfg("a")]})

      {:ok, _plan} = Executor.reconcile("s", desired, sm())
      assert_received {:remove_agent, "gone"}
    end
  end
end
