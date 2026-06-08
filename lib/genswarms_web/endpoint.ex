defmodule GenswarmsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :genswarms

  # WebSocket for real-time swarm communication.
  # connect_info exposes the peer IP and request headers so SwarmSocket can apply
  # the same authentication policy as the REST API.
  socket "/swarm", GenswarmsWeb.SwarmSocket,
    websocket: [connect_info: [:peer_data, :x_headers]],
    longpoll: false

  # Code reloading in development
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  # Telemetry
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Request parsing
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  # Router
  plug GenswarmsWeb.Router
end
