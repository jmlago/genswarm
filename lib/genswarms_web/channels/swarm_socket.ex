defmodule GenswarmsWeb.SwarmSocket do
  @moduledoc """
  WebSocket for real-time swarm communication.

  Clients can:
  - Subscribe to swarm events
  - Send tasks to agents
  - Receive agent output in real-time
  """

  use Phoenix.Socket

  channel "swarm:*", GenswarmsWeb.SwarmChannel

  @impl true
  def connect(params, socket, connect_info) do
    case System.get_env("DASHBOARD_API_TOKEN") do
      nil -> {:ok, socket}
      "" -> {:ok, socket}
      token ->
        # Prefer the `x-dashboard-token` HEADER (keeps the secret out of the URL,
        # so it can't leak via access logs / proxy logs / the Referer header). Fall
        # back to the legacy `?token=` query param for backward compatibility with
        # an un-upgraded client. Requires `connect_info: [:x_headers]` on the socket.
        provided = header_token(connect_info) || params["token"]
        if provided == token, do: {:ok, socket}, else: :error
    end
  end

  # The `x-dashboard-token` value from the upgrade request headers, or nil. Header
  # names arrive lower-cased; `:x_headers` carries every `x-` prefixed header.
  defp header_token(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == "x-dashboard-token", do: v
    end)
  end

  defp header_token(_), do: nil

  @impl true
  def id(_socket), do: nil
end
