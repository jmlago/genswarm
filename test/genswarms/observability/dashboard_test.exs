defmodule Genswarms.Observability.DashboardTest do
  use ExUnit.Case, async: true
  alias Genswarms.Observability.Dashboard

  @now ~U[2026-06-03 15:22:01Z]

  defp status do
    %{
      name: "wingston",
      status: :running,
      started_at: ~U[2026-06-03 13:45:00Z],
      agents: [%{name: :wingston_agent_0, state: :active}],
      objects: [
        %{name: :ingress, handler: Wingston.Objects.Ingress, state: :idle},
        %{name: :roster, handler: Wingston.Objects.Roster, state: :idle}
      ]
    }
  end

  defp topology, do: [%{from: :ingress, targets: [:policy, :roster]}, %{from: :wingston_agent_0, targets: [:sender]}]

  test "classifies nodes, normalizes edges, stamps metadata" do
    contributions = %{
      ingress: [
        %{kind: :sessions,
          items: [%{session_id: "tg:1:0", transport: "telegram", agent: "wingston_agent_0", state: :active}],
          pool: %{size: 2048, leased: 1, idle: 2047}}
      ],
      roster: [%{kind: :extension, name: "consumers", data: %{count: 1, items: []}}]
    }

    d = Dashboard.assemble(status(), topology(), contributions, @now)

    assert d.swarm == "wingston"
    assert d.data_source == "in_process"
    assert d.generated_at == @now
    assert d.uptime_s == 5821
    assert d.summary.pool == %{size: 2048, leased: 1, idle: 2047}
    assert d.summary.agents == 1 and d.summary.objects == 2
    assert %{name: "ingress", type: "object", subtype: "ingress"} in d.nodes
    assert %{name: "wingston_agent_0", type: "agent", state: "active", session_id: "tg:1:0"} in d.nodes
    assert %{from: "ingress", to: "policy"} in d.edges
    assert %{from: "ingress", to: "roster"} in d.edges
    assert [%{session_id: "tg:1:0", transport: "telegram"}] = Enum.map(d.sessions, &Map.take(&1, [:session_id, :transport]))
    assert d.extensions["consumers"] == %{count: 1, items: []}
    assert d.warnings == []
  end

  test "degrades when no sessions contribution: 200-shaped, pool null, warning" do
    contributions = %{ingress: :no_dashboard, roster: :no_dashboard}
    d = Dashboard.assemble(status(), topology(), contributions, @now)
    assert d.summary.pool == nil
    assert Enum.any?(d.warnings, &(&1.code == "missing_sessions_source"))
    assert d.sessions == []
  end

  test "empty-but-present sessions contribution: no missing_sessions_source, pool set" do
    contributions = %{
      ingress: [%{kind: :sessions, items: [], pool: %{size: 2048, leased: 0, idle: 2048}}],
      roster: :no_dashboard
    }

    d = Dashboard.assemble(status(), topology(), contributions, @now)
    assert d.sessions == []
    assert d.summary.pool == %{size: 2048, leased: 0, idle: 2048}
    refute Enum.any?(d.warnings, &(&1.code == "missing_sessions_source"))
  end

  test "normalizes get_topology adjacency into flat edges" do
    contributions = %{ingress: [%{kind: :sessions, items: []}]}
    d = Dashboard.assemble(status(), topology(), contributions, @now)
    assert %{from: "ingress", to: "policy"} in d.edges
    assert %{from: "wingston_agent_0", to: "sender"} in d.edges
  end

  test "invalid contributions become warnings, valid ones still pass" do
    contributions = %{
      ingress: [%{kind: :sessions, items: "not a list"}],
      roster: [%{kind: :extension, name: "consumers", data: %{count: 1}}]
    }
    d = Dashboard.assemble(status(), topology(), contributions, @now)
    assert Enum.any?(d.warnings, &(&1.code == "invalid_sessions_payload" and &1.object == "ingress"))
    assert d.extensions["consumers"] == %{count: 1}
  end

  test "object timeout/crash sentinel becomes a warning, not fatal" do
    contributions = %{ingress: {:error, :timeout}, roster: [%{kind: :sessions, items: []}]}
    d = Dashboard.assemble(status(), topology(), contributions, @now)
    assert Enum.any?(d.warnings, &(&1.code == "object_timeout" and &1.object == "ingress"))
  end
end
