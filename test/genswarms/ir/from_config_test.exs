defmodule Genswarms.IR.FromConfigTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR.FromConfig

  defp config do
    %{
      name: "research-swarm",
      agents: [
        %{
          name: :researcher,
          backend: :bwrap,
          model: "anthropic/claude-sonnet-4",
          skills: ["web.md"],
          presets: [:base, :web]
        },
        %{name: :coder, backend: {:docker, "coder"}, skills: ["code.md"]},
        %{name: :reviewer, backend: {:ssh, "pi@192.168.1.50"}, model: "openai/gpt-4o"}
      ],
      objects: [
        %{name: :evaluator, handler: MyApp.Objects.Evaluator, config: %{max_items: 5}}
      ],
      topology: [{:researcher, :coder}, {:coder, :reviewer}, {:reviewer, :evaluator}]
    }
  end

  defp agent(state, name), do: Enum.find(state.agents, &(&1.name == name))

  test "translates a config into a validated swarm.state (desired)" do
    {:ok, state} = FromConfig.from_config(config())
    assert state.name == "research-swarm"
    assert state.phase == :desired
    assert length(state.agents) == 3
    assert length(state.objects) == 1
  end

  test "agent persona becomes an inline body; skills/presets ride in overrides" do
    {:ok, state} = FromConfig.from_config(config())
    r = agent(state, "researcher")

    assert r.body.ref == "inline:researcher"
    assert r.body.kind == :data
    assert r.overrides["skills"] == ["web.md"]
    assert r.overrides["presets"] == ["base", "web"]
  end

  test "model string becomes an openrouter service ref (default when absent)" do
    {:ok, state} = FromConfig.from_config(config())

    assert {:service, %{ref: "openrouter:anthropic/claude-sonnet-4"}} =
             agent(state, "researcher").model

    # coder has no model -> default
    assert {:service, %{ref: "openrouter:default"}} = agent(state, "coder").model
  end

  test "backends map to local / oci / ssh refs" do
    {:ok, state} = FromConfig.from_config(config())

    assert agent(state, "researcher").backend.ref == "bwrap"
    assert agent(state, "coder").backend.ref == "oci:coder"
    assert agent(state, "reviewer").backend.ref == "ssh"
    assert agent(state, "reviewer").backend.host == "pi@192.168.1.50"
  end

  test "object handler module becomes a module: ref of kind code" do
    {:ok, state} = FromConfig.from_config(config())
    obj = hd(state.objects)

    assert obj.name == "evaluator"
    assert obj.handler.ref == "module:MyApp.Objects.Evaluator"
    assert obj.handler.kind == :code
    assert obj.config["max_items"] == 5
  end

  test "topology atoms are stringified into edges" do
    {:ok, state} = FromConfig.from_config(config())

    assert {"researcher", "coder"} in state.topology
    assert {"reviewer", "evaluator"} in state.topology
  end

  describe "errors" do
    test "an unsupported backend is reported" do
      cfg = %{name: "s", agents: [%{name: :a, backend: :weird}]}
      assert {:error, {:unsupported_backend, :weird}} = FromConfig.from_config(cfg)
    end

    test "an object without a handler is rejected (no IR §3.4 equivalent yet)" do
      cfg = %{name: "s", agents: [], objects: [%{name: :o, backend: {:docker, "x"}}]}
      assert {:error, :object_without_handler} = FromConfig.from_config(cfg)
    end

    test "a topology edge to an unknown node is caught by §6 validation" do
      cfg = %{name: "s", agents: [%{name: :a, backend: :local}], topology: [{:a, :ghost}]}
      assert {:error, {:unknown_edge_endpoint, "ghost"}} = FromConfig.from_config(cfg)
    end
  end
end
