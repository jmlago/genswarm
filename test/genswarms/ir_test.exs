defmodule Genswarms.IRTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR

  defp data_ref(ref, digest), do: %{"ref" => ref, "digest" => digest, "kind" => "data"}

  defp agent_doc(name) do
    %{
      "name" => name,
      "body" => data_ref("swarmidx:jmlago/#{name}@1.0.0", "sha256:aa00"),
      "model" => %{"ref" => "openrouter:m", "attested" => true},
      "backend" => data_ref("oci:szc-agent-code", "sha256:71de00")
    }
  end

  defp seed(agents \\ ["researcher", "coder"]) do
    {:ok, s} =
      IR.state(%{
        "v" => 1,
        "kind" => "swarm.state",
        "name" => "s",
        "phase" => "desired",
        "agents" => Enum.map(agents, &agent_doc/1),
        "topology" => []
      })

    s
  end

  defp ev(seq, op, payload), do: %{"seq" => seq, "op" => op, "payload" => payload}

  defp ov(events) do
    {:ok, o} =
      IR.overlay(%{"v" => 1, "kind" => "swarm.overlay", "swarm" => "s", "events" => events})

    o
  end

  defp names(state), do: Enum.map(state.agents, & &1.name)

  describe "state/1 and overlay/1" do
    test "delegate to the validating parsers" do
      assert {:ok, %{name: "s"}} =
               IR.state(%{
                 "v" => 1,
                 "kind" => "swarm.state",
                 "name" => "s",
                 "phase" => "desired",
                 "agents" => [],
                 "topology" => []
               })

      assert {:error, {:wrong_kind, _}} =
               IR.overlay(%{"v" => 1, "kind" => "nope", "swarm" => "s", "events" => []})
    end
  end

  describe "apply_op/3 (policy + fold)" do
    test "applies a structurally + policy valid op" do
      [event] = ov([ev(1, "add_agent", agent_doc("reviewer"))]).events
      {:ok, state} = IR.apply_op(seed(), event)
      assert "reviewer" in names(state)
    end

    test "rejects on policy: agent cap (with seq)" do
      [event] = ov([ev(1, "add_agent", agent_doc("reviewer"))]).events

      assert {:error, {1, {:agent_cap_exceeded, 3, 2}}} =
               IR.apply_op(seed(), event, max_agents: 2)
    end

    test "rejects on structure: duplicate name (with seq)" do
      [event] = ov([ev(7, "add_agent", agent_doc("coder"))]).events
      assert {:error, {7, {:agent_exists, "coder"}}} = IR.apply_op(seed(), event)
    end
  end

  describe "apply_overlay/3" do
    test "threads the state through every op (policy enforced)" do
      overlay = ov([ev(1, "add_agent", agent_doc("a")), ev(2, "add_agent", agent_doc("b"))])
      {:ok, state} = IR.apply_overlay(seed(), overlay)
      assert "a" in names(state) and "b" in names(state)
    end

    test "halts at the first op that violates policy" do
      overlay = ov([ev(1, "add_agent", agent_doc("a")), ev(2, "add_agent", agent_doc("b"))])
      # seed has 2 agents, cap 3: first add ok (3), second over cap
      assert {:error, {2, {:agent_cap_exceeded, 4, 3}}} =
               IR.apply_overlay(seed(), overlay, max_agents: 3)
    end
  end

  describe "compact/3 (§5.6 checkpoint equivalence)" do
    test "folding remaining onto the checkpoint equals folding the whole overlay onto the seed" do
      overlay =
        ov([
          ev(1, "add_agent", agent_doc("a")),
          ev(2, "add_topology_edges", %{"edges" => [["researcher", "a"]]}),
          ev(3, "add_agent", agent_doc("b")),
          ev(4, "remove_agent", %{"name" => "coder"})
        ])

      {:ok, full} = IR.materialize(seed(), overlay)

      {:ok, checkpoint, remaining} = IR.compact(seed(), overlay, 2)
      assert Enum.map(remaining, & &1.seq) == [3, 4]

      {:ok, from_checkpoint} = IR.materialize(checkpoint, remaining)

      # checkpoint identity == re-folding from the seed
      assert MapSet.new(names(from_checkpoint)) == MapSet.new(names(full))
      assert MapSet.new(from_checkpoint.topology) == MapSet.new(full.topology)
    end
  end
end
