defmodule GenswarmsWeb.SwarmChannelAtomTest do
  @moduledoc """
  Atom-exhaustion DoS guard for the swarm WebSocket channel. `send_task` resolves
  the agent name to an existing atom only, so an unknown name is rejected without
  minting an atom — verified by calling handle_in/3 directly with a hand-built
  socket (no join / running swarm required).
  """
  use ExUnit.Case, async: false

  alias GenswarmsWeb.SwarmChannel

  defp socket do
    %Phoenix.Socket{
      assigns: %{
        swarm_name: "s",
        log_subscriptions: MapSet.new(),
        event_subscriptions: MapSet.new()
      }
    }
  end

  defp fresh_name, do: "ghost_agent_" <> Integer.to_string(System.unique_integer([:positive]))

  test "send_task rejects an unknown agent" do
    assert {:reply, {:error, %{reason: "unknown agent"}}, _socket} =
             SwarmChannel.handle_in(
               "send_task",
               %{"agent" => fresh_name(), "task" => "x"},
               socket()
             )
  end

  test "flooding send_task with unknown agents mints no atoms" do
    # Warm up first so one-off lazy initialization (module/code loading on the
    # first calls) doesn't count against the steady-state measurement.
    for _ <- 1..20 do
      SwarmChannel.handle_in("send_task", %{"agent" => fresh_name(), "task" => "x"}, socket())
    end

    before = :erlang.system_info(:atom_count)

    for _ <- 1..300 do
      SwarmChannel.handle_in("send_task", %{"agent" => fresh_name(), "task" => "x"}, socket())
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count == before, "channel minted #{after_count - before} atoms"
  end
end
