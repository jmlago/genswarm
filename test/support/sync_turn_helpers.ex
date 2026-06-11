defmodule Genswarms.Test.SinkHandler do
  @moduledoc """
  A reply_to sink for sync-turn tests: forwards every delivered message to the
  test process as `{:sink_got, from, content}`. Shared by the auto-delivery
  and turn-bounds suites (mix.exs already compiles `test/support` in :test).
  """
  @behaviour Genswarms.Objects.ObjectHandler
  @impl true
  def init(config), do: {:ok, %{test_pid: Map.fetch!(config, :test_pid)}}
  @impl true
  def handle_message(from, content, state) do
    send(state.test_pid, {:sink_got, from, content})
    {:noreply, state}
  end

  @impl true
  def interface(), do: %{}
end

defmodule Genswarms.Test.SyncTurnHelpers do
  @moduledoc false

  alias Genswarms.Agents.AgentServer

  def wait_for_idle(swarm, agent, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> AgentServer.get_state(swarm, agent) end)
    |> Enum.reduce_while(nil, fn s, _ ->
      cond do
        s == :idle -> {:halt, :ok}
        System.monotonic_time(:millisecond) > deadline -> raise "agent never idle (#{s})"
        true -> Process.sleep(20) && {:cont, nil}
      end
    end)
  end
end
