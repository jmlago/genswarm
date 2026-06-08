defmodule Genswarms.IR.ReconcileTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR.{State, Reconcile}

  defp dref(ref, digest), do: %{"ref" => ref, "digest" => digest, "kind" => "data"}

  defp agent_doc(name, config \\ %{}) do
    %{
      "name" => name,
      "body" => dref("swarmidx:jmlago/#{name}@1.0.0", "sha256:aa00"),
      "model" => %{"ref" => "openrouter:m", "attested" => true},
      "backend" => dref("oci:szc-agent-code", "sha256:71de00"),
      "config" => config
    }
  end

  defp object_doc(name) do
    %{
      "name" => name,
      "handler" => %{"ref" => "module:M", "digest" => "sha256:cc00", "kind" => "code"}
    }
  end

  defp st(agents, objects \\ [], topology \\ []) do
    {:ok, s} =
      State.parse(%{
        "v" => 1,
        "kind" => "swarm.state",
        "name" => "s",
        "phase" => "desired",
        "agents" => agents,
        "objects" => objects,
        "topology" => topology
      })

    s
  end

  test "an identical desired/observed pair has converged (empty plan)" do
    s = st([agent_doc("a"), agent_doc("b")], [], [["a", "b"]])
    assert Reconcile.plan(s, s) == []
    assert Reconcile.converged?(s, s)
  end

  test "starts agents present in desired but not observed" do
    desired = st([agent_doc("a"), agent_doc("b")])
    observed = st([agent_doc("a")])

    assert [{:start_agent, %{name: "b"}}] = Reconcile.plan(desired, observed)
  end

  test "stops agents present in observed but not desired" do
    desired = st([agent_doc("a")])
    observed = st([agent_doc("a"), agent_doc("gone")])

    assert [{:stop_agent, "gone"}] = Reconcile.plan(desired, observed)
  end

  test "restarts an agent whose spec changed" do
    desired = st([agent_doc("a", %{"k" => 1})])
    observed = st([agent_doc("a", %{"k" => 2})])

    assert [{:restart_agent, %{name: "a", config: %{"k" => 1}}}] =
             Reconcile.plan(desired, observed)
  end

  test "adds and removes topology edges" do
    desired = st([agent_doc("a"), agent_doc("b")], [], [["a", "b"]])
    observed = st([agent_doc("a"), agent_doc("b")], [], [["b", "a"]])

    plan = Reconcile.plan(desired, observed)
    assert {:add_edge, {"a", "b"}} in plan
    assert {:remove_edge, {"b", "a"}} in plan
  end

  test "handles objects (start/stop/restart) like agents" do
    desired = st([], [object_doc("ev")])
    observed = st([], [])
    assert [{:start_object, %{name: "ev"}}] = Reconcile.plan(desired, observed)

    assert [{:stop_object, "ev"}] = Reconcile.plan(st([], []), st([], [object_doc("ev")]))
  end

  test "is ordered: starts before edge adds before stops" do
    # add agent c (+edge a->c), drop agent b
    desired = st([agent_doc("a"), agent_doc("c")], [], [["a", "c"]])
    observed = st([agent_doc("a"), agent_doc("b")], [], [])

    plan = Reconcile.plan(desired, observed)
    tags = Enum.map(plan, &elem(&1, 0))

    start_idx = Enum.find_index(tags, &(&1 == :start_agent))
    edge_idx = Enum.find_index(tags, &(&1 == :add_edge))
    stop_idx = Enum.find_index(tags, &(&1 == :stop_agent))

    assert start_idx < edge_idx
    assert edge_idx < stop_idx
  end
end
