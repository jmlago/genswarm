defmodule GenswarmsWeb.SwarmControllerAtomTest do
  @moduledoc """
  Atom-exhaustion DoS guard for the swarm REST controller. Unknown agent/edge
  names in request params must resolve to a 404 / no-op without ever interning a
  new atom.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias GenswarmsWeb.SwarmController

  # A name guaranteed never to have been interned as an atom.
  defp fresh_name, do: "ghost_agent_" <> Integer.to_string(System.unique_integer([:positive]))

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "handlers reject unknown agent names with 404 (no atom minted)" do
    test "show_agent" do
      conn =
        build_conn()
        |> SwarmController.show_agent(%{"swarm_name" => "s", "agent_name" => fresh_name()})

      assert conn.status == 404
      assert body(conn)["error"] == "Agent not found"
    end

    test "agent_logs" do
      conn =
        build_conn()
        |> SwarmController.agent_logs(%{"swarm_name" => "s", "agent_name" => fresh_name()})

      assert conn.status == 404
      assert body(conn)["error"] == "Agent not found"
    end

    test "agent_history" do
      conn =
        build_conn()
        |> SwarmController.agent_history(%{"swarm_name" => "s", "agent_name" => fresh_name()})

      assert conn.status == 404
    end

    test "agent_skills" do
      conn =
        build_conn()
        |> SwarmController.agent_skills(%{"swarm_name" => "s", "agent_name" => fresh_name()})

      assert conn.status == 404
    end

    test "restart_agent" do
      conn =
        build_conn()
        |> SwarmController.restart_agent(%{"swarm_name" => "s", "agent_name" => fresh_name()})

      assert conn.status == 404
      assert body(conn)["error"] == "Agent not found"
    end

    test "send_task" do
      conn =
        build_conn()
        |> SwarmController.send_task(%{
          "swarm_name" => "s",
          "agent_name" => fresh_name(),
          "task" => "do it"
        })

      assert conn.status == 404
      assert body(conn)["error"] == "Agent not found"
    end

    test "update_skill" do
      conn =
        build_conn()
        |> SwarmController.update_skill(%{
          "swarm_name" => "s",
          "agent_name" => fresh_name(),
          "skill_name" => "web.md",
          "content" => "hi"
        })

      assert conn.status == 404
      assert body(conn)["error"] == "Agent not found"
    end

    test "route_message rejects unknown from/to" do
      conn =
        build_conn()
        |> SwarmController.route_message(%{
          "name" => "s",
          "from" => fresh_name(),
          "to" => fresh_name(),
          "content" => "hi"
        })

      assert conn.status == 404
    end
  end

  describe "atom-table invariant under request flooding" do
    test "flooding unknown agent names through the controller mints no atoms" do
      flood = fn ->
        name = fresh_name()
        build_conn() |> SwarmController.show_agent(%{"swarm_name" => "s", "agent_name" => name})
        build_conn() |> SwarmController.agent_logs(%{"swarm_name" => "s", "agent_name" => name})

        build_conn()
        |> SwarmController.send_task(%{"swarm_name" => "s", "agent_name" => name, "task" => "x"})

        build_conn()
        |> SwarmController.route_message(%{
          "name" => "s",
          "from" => name,
          "to" => name,
          "content" => "x"
        })
      end

      # Warm up so one-off lazy initialization isn't counted (keeps the
      # assertion seed/order independent).
      for _ <- 1..10, do: flood.()

      before = :erlang.system_info(:atom_count)
      for _ <- 1..300, do: flood.()
      after_count = :erlang.system_info(:atom_count)

      assert after_count == before, "controller minted #{after_count - before} atoms"
    end
  end
end
