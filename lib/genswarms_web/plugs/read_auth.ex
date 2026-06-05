defmodule GenswarmsWeb.Plugs.ReadAuth do
  @moduledoc """
  Read-only bearer auth for the dashboard's read endpoints. If `DASHBOARD_API_TOKEN`
  is set, requires `Authorization: Bearer <token>`; if unset, allows (localhost dev).
  Scoped to READ routes only — it must never be attached to mutating routes.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case System.get_env("DASHBOARD_API_TOKEN") do
      nil ->
        conn

      "" ->
        conn

      token ->
        # Constant-time compare so a valid token can't be recovered by timing the
        # response (a plain `== ` / pinned-pattern match leaks length + prefix).
        case get_req_header(conn, "authorization") do
          ["Bearer " <> presented] ->
            if Plug.Crypto.secure_compare(presented, token),
              do: conn,
              else: conn |> send_resp(401, ~s({"error":"unauthorized"})) |> halt()

          _ ->
            conn |> send_resp(401, ~s({"error":"unauthorized"})) |> halt()
        end
    end
  end
end
