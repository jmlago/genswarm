defmodule GenswarmsWeb.FormatErrorTest do
  @moduledoc """
  API error responses must not leak internal details / host paths (finding 31).
  """
  use ExUnit.Case, async: true

  alias GenswarmsWeb.SwarmController

  test "atoms render as their name (safe)" do
    assert SwarmController.format_error(:swarm_not_found) == "swarm_not_found"
  end

  test "our own {tag, message} strings are surfaced verbatim" do
    assert SwarmController.format_error({:invalid_agent_name, "Agent name must…"}) ==
             "Agent name must…"
  end

  test "validation-feedback tuples are kept" do
    assert SwarmController.format_error({:invalid_topology, [{:a, :b}]}) =~ "Invalid topology"
  end

  test "arbitrary internal reasons are replaced with a generic message" do
    # An exception / struct / host-path-bearing reason must NOT be echoed.
    leaky = %RuntimeError{message: "/home/op/secret/path boom"}
    assert SwarmController.format_error({:start_failed, leaky}) == "Internal error"

    assert SwarmController.format_error({:enoent, "/etc/shadow"}) == "Internal error"
    refute SwarmController.format_error({:enoent, "/etc/shadow"}) =~ "/etc/shadow"
  end

  test "bare non-atom reasons are generic" do
    assert SwarmController.format_error(%{internal: "state"}) == "Internal error"
  end
end
