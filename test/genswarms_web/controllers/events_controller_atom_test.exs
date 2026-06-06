defmodule GenswarmsWeb.EventsControllerAtomTest do
  @moduledoc """
  Atom-exhaustion DoS guard for the events controller's `agent` filter.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias GenswarmsWeb.EventsController

  defp fresh_name, do: "ghost_agent_" <> Integer.to_string(System.unique_integer([:positive]))

  test "an unknown agent filter returns an empty, well-formed result (no 500)" do
    conn = build_conn() |> EventsController.index(%{"agent" => fresh_name()})

    assert conn.status == 200
    decoded = Jason.decode!(conn.resp_body)
    assert decoded["events"] == []
    assert decoded["count"] == 0
  end

  test "unknown level/category/event_type filters return empty, not 500" do
    for filter <- ["level", "category", "event_type"] do
      conn = build_conn() |> EventsController.index(%{filter => fresh_name()})
      assert conn.status == 200, "expected 200 for unknown #{filter}, got #{conn.status}"
      assert Jason.decode!(conn.resp_body)["count"] == 0
    end
  end

  test "flooding unknown agent/level/category/event_type filters mints no atoms" do
    flood = fn ->
      build_conn() |> EventsController.index(%{"agent" => fresh_name()})
      build_conn() |> EventsController.index(%{"level" => fresh_name()})
      build_conn() |> EventsController.index(%{"category" => fresh_name()})
      build_conn() |> EventsController.index(%{"event_type" => fresh_name()})
    end

    # Warm up so one-off lazy initialization isn't counted (seed/order independent).
    for _ <- 1..10, do: flood.()
    before = :erlang.system_info(:atom_count)
    for _ <- 1..300, do: flood.()
    after_count = :erlang.system_info(:atom_count)

    assert after_count == before, "events controller minted #{after_count - before} atoms"
  end
end
