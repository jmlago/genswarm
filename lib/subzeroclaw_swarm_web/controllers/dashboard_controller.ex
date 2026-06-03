defmodule SubzeroclawSwarmWeb.DashboardController do
  use SubzeroclawSwarmWeb, :controller
  alias SubzeroclawSwarm.Observability.Dashboard

  def show(conn, %{"name" => name}) do
    case Dashboard.build(name) do
      {:ok, data} -> json(conn, data)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "swarm_not_found"})
    end
  end

  def session_history(conn, %{"name" => name, "session_id" => sid}) do
    case Dashboard.session_history(name, sid) do
      {:ok, turns} -> json(conn, %{session_id: sid, turns: turns, source: "store"})
      {:not_found} -> json(conn, %{session_id: sid, turns: [], source: "unavailable"})
    end
  end
end
