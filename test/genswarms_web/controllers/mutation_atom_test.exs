defmodule GenswarmsWeb.MutationAtomTest do
  @moduledoc """
  The mutation endpoints (add_agent/add_object) must not mint atoms for invalid
  request names. A new entity name is only interned after passing a strict
  identifier + length check; junk/oversized names are rejected with 400 first.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias GenswarmsWeb.SwarmController

  defp fresh, do: "ghost_" <> Integer.to_string(System.unique_integer([:positive]))
  defp error(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp add_agent(name),
    do: build_conn() |> SwarmController.add_agent(%{"swarm_name" => "s", "name" => name})

  defp add_object(name),
    do: build_conn() |> SwarmController.add_object(%{"swarm_name" => "s", "name" => name})

  describe "add_agent name validation" do
    test "rejects shell-metacharacter / leading-digit / spaced names with 400" do
      for bad <- ["a; touch /tmp/x", "a$(id)", "a b", "../escape", "1leading", "valid\n"] do
        conn = add_agent(bad)
        assert conn.status == 400
        assert error(conn) == "Invalid or missing agent name"
      end
    end

    test "rejects an over-long name (length cap)" do
      conn = add_agent(String.duplicate("a", 65))
      assert conn.status == 400
      assert error(conn) == "Invalid or missing agent name"
    end

    test "a valid name passes the name check (only the missing swarm fails)" do
      conn = add_agent("valid_name")
      assert conn.status == 400
      assert error(conn) != "Invalid or missing agent name"
      assert error(conn) =~ "swarm_not_found"
    end
  end

  describe "add_object name validation" do
    test "rejects an invalid object name with 400" do
      conn = add_object("a; rm -rf /")
      assert conn.status == 400
      assert error(conn) == "Invalid or missing object name"
    end
  end

  describe "atom-table invariant on mutation endpoints" do
    test "flooding add_agent/add_object with invalid names mints no atoms" do
      flood = fn ->
        add_agent("a; " <> fresh())
        add_agent(String.duplicate("z", 70) <> fresh())
        add_object("../" <> fresh())
      end

      # Generous warmup: these paths lazily load a fair amount of code on first
      # use; after warmup, steady-state minting is exactly zero.
      for _ <- 1..50, do: flood.()
      before = :erlang.system_info(:atom_count)
      for _ <- 1..300, do: flood.()
      after_count = :erlang.system_info(:atom_count)

      assert after_count == before, "mutation endpoints minted #{after_count - before} atoms"
    end

    test "invalid presets/connections do not mint atoms either" do
      # invalid name so the request is rejected, but presets/connections are
      # parsed first and must use existing-atom resolution (no minting)
      probe = fn ->
        build_conn()
        |> SwarmController.add_agent(%{
          "swarm_name" => "s",
          "name" => "bad name",
          "presets" => ["nope_" <> fresh()],
          "connections" => ["ghost_" <> fresh()]
        })
      end

      for _ <- 1..50, do: probe.()
      before = :erlang.system_info(:atom_count)
      for _ <- 1..300, do: probe.()
      after_count = :erlang.system_info(:atom_count)

      assert after_count == before, "presets/connections minted #{after_count - before} atoms"
    end
  end
end
