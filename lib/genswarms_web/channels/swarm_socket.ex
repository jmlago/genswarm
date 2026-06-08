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
    case Genswarms.Auth.authorize(
           Genswarms.Auth.configured_token(),
           socket_token(params, connect_info),
           peer_ip(connect_info)
         ) do
      :ok -> {:ok, socket}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def id(_socket), do: nil

  # Token may be supplied as a `?token=` connect param (browsers can't set WS
  # headers) or as an `Authorization: Bearer` header.
  defp socket_token(params, connect_info) do
    case params do
      %{"token" => token} when is_binary(token) and token != "" -> token
      _ -> bearer_from_headers(connect_info)
    end
  end

  defp bearer_from_headers(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, "Bearer " <> token} -> if String.downcase(key) == "authorization", do: token
      _ -> nil
    end)
  end

  defp bearer_from_headers(_), do: nil

  defp peer_ip(%{peer_data: %{address: address}}), do: address
  defp peer_ip(_), do: nil
end
