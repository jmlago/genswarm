defmodule GenswarmsWeb.DashboardController do
  use GenswarmsWeb, :controller
  alias Genswarms.Observability.Dashboard

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

  def session_logs(conn, %{"name" => name, "session_id" => sid}) do
    case Dashboard.session_logs(name, sid) do
      {:ok, entries} ->
        json(conn, %{session_id: sid, logs: Enum.map(entries, &rename_log_file/1), source: "slot"})

      {:not_found} ->
        json(conn, %{session_id: sid, logs: [], source: "unavailable"})
    end
  end

  # The per-entry `session_id` from AgentServer logs is the log filename, not a
  # session id — rename it so it isn't confused with the URL's session_id.
  defp rename_log_file(%{"session_id" => f} = e), do: e |> Map.delete("session_id") |> Map.put("log_file", f)
  defp rename_log_file(e), do: e
end
