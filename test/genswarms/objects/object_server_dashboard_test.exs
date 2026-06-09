defmodule Genswarms.Objects.ObjectServerDashboardTest do
  use ExUnit.Case, async: false
  alias Genswarms.Objects.ObjectServer

  defmodule FakeHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(cfg), do: {:ok, %{n: Map.get(cfg, :n, 0)}}
    @impl true
    def interface, do: %{}
    @impl true
    def handle_message(_from, _content, state), do: {:noreply, state}
    @impl true
    def dashboard(state), do: [%{kind: :extension, name: "fake", data: %{n: state.n}}]
    @impl true
    def session_history(_state, "s1", _opts), do: {:ok, [%{role: "user", content: "hi"}]}
    def session_history(_state, _sid, _opts), do: :not_available
  end

  defmodule NoDashHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_cfg), do: {:ok, %{}}
    @impl true
    def interface, do: %{}
    @impl true
    def handle_message(_f, _c, s), do: {:noreply, s}
  end

  # NOTE: `mix test` boots the app, so Genswarms.AgentRegistry is already
  # running — we do NOT start it here.

  test "get_dashboard returns the handler's contributions" do
    start_supervised!({ObjectServer, name: :fake, swarm_name: "t", handler: FakeHandler, config: %{n: 7}})
    assert ObjectServer.get_dashboard("t", :fake) == [%{kind: :extension, name: "fake", data: %{n: 7}}]
  end

  test "get_dashboard returns :no_dashboard when the callback is absent" do
    start_supervised!({ObjectServer, name: :nodash, swarm_name: "t", handler: NoDashHandler, config: %{}})
    assert ObjectServer.get_dashboard("t", :nodash) == :no_dashboard
  end

  test "get_session_history proxies to the handler, with :not_available fallback" do
    start_supervised!({ObjectServer, name: :fake2, swarm_name: "t", handler: FakeHandler, config: %{}})
    assert ObjectServer.get_session_history("t", :fake2, "s1", %{}) == {:ok, [%{role: "user", content: "hi"}]}
    assert ObjectServer.get_session_history("t", :fake2, "nope", %{}) == :not_available
  end
end
