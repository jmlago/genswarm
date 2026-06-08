defmodule Genswarms.IR.GateTest do
  # not async: the cap tests mutate the global :max_agents_per_swarm app env.
  use ExUnit.Case, async: false

  alias Genswarms.IR.Gate

  defp swarm_config(agents), do: %{name: "s", agents: agents, objects: [], topology: []}

  describe "validate_start/1" do
    test "accepts a valid config" do
      assert Gate.validate_start(swarm_config([%{name: :a, backend: :bwrap}])) == :ok
    end

    test "rejects a config that fails the §6 invariants (duplicate names)" do
      config = swarm_config([%{name: :a, backend: :bwrap}, %{name: :a, backend: :bwrap}])

      assert {:error, {:ir_validation_failed, {:duplicate_name, "a"}}} =
               Gate.validate_start(config)
    end

    test "rejects a config the IR cannot translate (object without handler)" do
      config = %{
        name: "s",
        agents: [],
        objects: [%{name: :o, backend: {:docker, "x"}}],
        topology: []
      }

      assert {:error, {:ir_validation_failed, :object_without_handler}} =
               Gate.validate_start(config)
    end
  end

  describe "validate_add_agent/2" do
    test "allows a safe spec" do
      cfg = swarm_config([%{name: :a, backend: :bwrap}])
      assert Gate.validate_add_agent(cfg, %{name: :b, backend: :bwrap, config: %{x: 1}}) == :ok
    end

    test "rejects a host-escape backend config key (#24)" do
      cfg = swarm_config([%{name: :a, backend: :bwrap}])
      spec = %{name: :b, backend: :bwrap, config: %{extra_ro_binds: [{"/etc", "/etc"}]}}

      assert {:error, {:forbidden_config_keys, ["extra_ro_binds"]}} =
               Gate.validate_add_agent(cfg, spec)
    end

    test "rejects when the swarm is at the agent cap (#28)" do
      Application.put_env(:genswarms, :max_agents_per_swarm, 1)
      on_exit(fn -> Application.delete_env(:genswarms, :max_agents_per_swarm) end)

      cfg = swarm_config([%{name: :a, backend: :bwrap}])

      assert {:error, {:agent_cap_exceeded, 2, 1}} =
               Gate.validate_add_agent(cfg, %{name: :b, backend: :bwrap})
    end
  end

  describe "validate_scale/3" do
    test "allows a target within the cap" do
      Application.put_env(:genswarms, :max_agents_per_swarm, 10)
      on_exit(fn -> Application.delete_env(:genswarms, :max_agents_per_swarm) end)

      assert Gate.validate_scale(swarm_config([%{name: :a, backend: :bwrap}]), "a", 5) == :ok
    end

    test "rejects a target over the cap" do
      Application.put_env(:genswarms, :max_agents_per_swarm, 3)
      on_exit(fn -> Application.delete_env(:genswarms, :max_agents_per_swarm) end)

      assert {:error, {:agent_cap_exceeded, 100, 3}} =
               Gate.validate_scale(swarm_config([%{name: :a, backend: :bwrap}]), "a", 100)
    end
  end
end
