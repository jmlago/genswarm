defmodule GenswarmsWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates REST API requests using `Genswarms.Auth`.

  Expects `Authorization: Bearer <token>` when `GENSWARMS_API_TOKEN` is set;
  otherwise allows loopback callers only. Responds `401` (JSON) and halts on
  failure.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Genswarms.Auth.authorize(
           Genswarms.Auth.configured_token(),
           bearer_token(conn),
           conn.remote_ip
         ) do
      :ok ->
        conn

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: message(reason)}))
        |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> nil
    end
  end

  defp message(:unauthorized), do: "Invalid or missing API token"

  defp message(:token_required),
    do:
      "API token required for non-local requests. Set GENSWARMS_API_TOKEN on the " <>
        "server and send 'Authorization: Bearer <token>'."
end
