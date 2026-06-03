defmodule SubzeroclawSwarmWeb.SwarmSocket do
  @moduledoc """
  WebSocket for real-time swarm communication.

  Clients can:
  - Subscribe to swarm events
  - Send tasks to agents
  - Receive agent output in real-time
  """

  use Phoenix.Socket

  channel "swarm:*", SubzeroclawSwarmWeb.SwarmChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case System.get_env("DASHBOARD_API_TOKEN") do
      nil -> {:ok, socket}
      "" -> {:ok, socket}
      token -> if params["token"] == token, do: {:ok, socket}, else: :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
