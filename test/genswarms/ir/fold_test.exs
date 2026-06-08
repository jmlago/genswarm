defmodule Genswarms.IR.FoldTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR.{State, Overlay, Fold}

  defp data_ref(ref, digest), do: %{"ref" => ref, "digest" => digest, "kind" => "data"}
  defp oci, do: data_ref("oci:szc-agent-code", "sha256:71de00")

  defp agent_doc(name, body_digest \\ "sha256:aa00") do
    %{
      "name" => name,
      "body" => data_ref("swarmidx:jmlago/#{name}@1.0.0", body_digest),
      "model" => %{"ref" => "openrouter:m", "attested" => true},
      "backend" => oci()
    }
  end

  defp seed do
    {:ok, state} =
      State.parse(%{
        "v" => 1,
        "kind" => "swarm.state",
        "name" => "research-swarm",
        "phase" => "desired",
        "agents" => [
          agent_doc("researcher"),
          agent_doc("coder"),
          agent_doc("reviewer", "sha256:c50e00")
        ],
        "topology" => [["researcher", "coder"], ["coder", "reviewer"]]
      })

    state
  end

  defp overlay(events) do
    {:ok, ov} =
      Overlay.parse(%{
        "v" => 1,
        "kind" => "swarm.overlay",
        "swarm" => "research-swarm",
        "events" => events
      })

    ov
  end

  defp ev(seq, op, payload), do: %{"seq" => seq, "op" => op, "payload" => payload}

  defp names(state), do: Enum.map(state.agents, & &1.name)

  describe "fold/2 is pure (no effects) and ordered" do
    test "applies events in seq order and returns the new state" do
      ov = overlay([ev(1, "add_agent", agent_doc("fact_checker"))])
      {:ok, state} = Fold.fold(seed(), ov)
      assert "fact_checker" in names(state)
    end
  end

  describe "add/remove agent" do
    test "add_agent rejects a name that already exists" do
      ov = overlay([ev(1, "add_agent", agent_doc("coder"))])
      assert {:error, {1, {:agent_exists, "coder"}}} = Fold.fold(seed(), ov)
    end

    test "remove_agent drops the node and its incident edges" do
      ov = overlay([ev(1, "remove_agent", %{"name" => "coder", "on_inflight" => "drain"})])
      {:ok, state} = Fold.fold(seed(), ov)
      refute "coder" in names(state)
      # both edges touched coder
      assert state.topology == []
    end

    test "remove_agent on an absent node fails at its seq" do
      ov = overlay([ev(1, "remove_agent", %{"name" => "ghost"})])
      assert {:error, {1, {:agent_not_found, "ghost"}}} = Fold.fold(seed(), ov)
    end
  end

  describe "topology edges" do
    test "add_topology_edges requires existing endpoints" do
      ov = overlay([ev(1, "add_topology_edges", %{"edges" => [["coder", "ghost"]]})])
      assert {:error, {1, {:unknown_edge_endpoint, "ghost"}}} = Fold.fold(seed(), ov)
    end

    test "adds new edges (deduped) and removes edges" do
      ov =
        overlay([
          ev(1, "add_topology_edges", %{
            "edges" => [["reviewer", "researcher"], ["researcher", "coder"]]
          }),
          ev(2, "remove_topology_edges", %{"edges" => [["coder", "reviewer"]]})
        ])

      {:ok, state} = Fold.fold(seed(), ov)
      assert {"reviewer", "researcher"} in state.topology
      # the dup ["researcher","coder"] was not added twice
      assert Enum.count(state.topology, &(&1 == {"researcher", "coder"})) == 1
      refute {"coder", "reviewer"} in state.topology
    end
  end

  describe "bump_package (§4.5)" do
    test "swaps a slot digest when `from` matches" do
      ov =
        overlay([
          ev(1, "bump_package", %{
            "target" => "reviewer",
            "field" => "body",
            "from" => "sha256:c50e00",
            "to" => "sha256:f7aa00"
          })
        ])

      {:ok, state} = Fold.fold(seed(), ov)
      reviewer = Enum.find(state.agents, &(&1.name == "reviewer"))
      assert reviewer.body.digest == "sha256:f7aa00"
    end

    test "fails when `from` does not match the current digest (concurrency guard)" do
      ov =
        overlay([
          ev(1, "bump_package", %{
            "target" => "reviewer",
            "field" => "body",
            "from" => "sha256:0000",
            "to" => "sha256:f7aa00"
          })
        ])

      assert {:error, {1, {:bump_digest_mismatch, expected: "sha256:0000", got: "sha256:c50e00"}}} =
               Fold.fold(seed(), ov)
    end
  end

  describe "scale_agent_group (§4.4)" do
    test "expands the template into base#1..base#N and fans out incident edges" do
      ov = overlay([ev(1, "scale_agent_group", %{"base_name" => "coder", "target_count" => 3})])
      {:ok, state} = Fold.fold(seed(), ov)

      refute "coder" in names(state)
      assert "coder#1" in names(state)
      assert "coder#2" in names(state)
      assert "coder#3" in names(state)

      # edge researcher->coder fans out to each instance
      assert {"researcher", "coder#1"} in state.topology
      assert {"researcher", "coder#3"} in state.topology
      # edge coder->reviewer fans out from each instance
      assert {"coder#2", "reviewer"} in state.topology
    end

    test "scaling an unknown base fails" do
      ov = overlay([ev(1, "scale_agent_group", %{"base_name" => "ghost", "target_count" => 2})])
      assert {:error, {1, {:scale_base_not_found, "ghost"}}} = Fold.fold(seed(), ov)
    end
  end

  describe "set_options / update_config" do
    test "set_options merges, update_config merges into a node" do
      ov =
        overlay([
          ev(1, "set_options", %{"options" => %{"log_level" => "debug"}}),
          ev(2, "update_config", %{"target" => "coder", "config" => %{"max_iterations" => 5}})
        ])

      {:ok, state} = Fold.fold(seed(), ov)
      assert state.options["log_level"] == "debug"
      assert Enum.find(state.agents, &(&1.name == "coder")).config["max_iterations"] == 5
    end
  end

  describe "the §4.6 overlay end-to-end" do
    test "applies all five events onto a matching seed" do
      ov =
        overlay([
          ev(1, "add_agent", agent_doc("fact_checker")),
          ev(2, "add_topology_edges", %{
            "edges" => [["reviewer", "fact_checker"], ["fact_checker", "reviewer"]]
          }),
          ev(3, "scale_agent_group", %{
            "base_name" => "coder",
            "target_count" => 3,
            "on_inflight" => "drain"
          }),
          ev(4, "bump_package", %{
            "target" => "reviewer",
            "field" => "body",
            "from" => "sha256:c50e00",
            "to" => "sha256:f7aa00",
            "migration" => "state_migrate",
            "on_inflight" => "drain"
          }),
          ev(5, "remove_agent", %{"name" => "researcher", "on_inflight" => "drain"})
        ])

      {:ok, state} = Fold.fold(seed(), ov)

      assert "fact_checker" in names(state)
      refute "researcher" in names(state)
      assert "coder#1" in names(state) and "coder#3" in names(state)
      assert Enum.find(state.agents, &(&1.name == "reviewer")).body.digest == "sha256:f7aa00"
      # the materialized desired state is structurally valid (§6)
      assert State.validate(state) == :ok
    end
  end
end
