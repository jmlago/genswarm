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

  test "flooding unknown agent filters mints no atoms" do
    # Warm up so one-off lazy initialization isn't counted (seed/order independent).
    for _ <- 1..10, do: build_conn() |> EventsController.index(%{"agent" => fresh_name()})

    before = :erlang.system_info(:atom_count)
    for _ <- 1..300, do: build_conn() |> EventsController.index(%{"agent" => fresh_name()})
    after_count = :erlang.system_info(:atom_count)

    assert after_count == before, "events controller minted #{after_count - before} atoms"
  end
end
