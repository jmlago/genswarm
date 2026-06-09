defmodule GenswarmsWeb.DashboardControllerTest do
  # not async: toggles global :api_token and dispatches through the router
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  # Restore :api_token env to its original value after each test.
  setup do
    prev = Application.get_env(:genswarms, :api_token)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:genswarms, :api_token)
        v -> Application.put_env(:genswarms, :api_token, v)
      end
    end)

    :ok
  end

  # Route through the full router using a loopback remote_ip so ApiAuth allows
  # the request when no token is configured.
  defp call(method, path, headers \\ []) do
    Application.delete_env(:genswarms, :api_token)

    conn =
      method
      |> conn(path)
      |> Map.put(:remote_ip, {127, 0, 0, 1})

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    GenswarmsWeb.Router.call(conn, GenswarmsWeb.Router.init([]))
  end

  defp call_with_token(method, path, token, headers \\ []) do
    Application.put_env(:genswarms, :api_token, token)

    conn =
      method
      |> conn(path)
      |> Map.put(:remote_ip, {203, 0, 113, 1})

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    GenswarmsWeb.Router.call(conn, GenswarmsWeb.Router.init([]))
  end

  test "GET /dashboard returns 404 for unknown swarm" do
    conn = call(:get, "/api/swarms/does-not-exist/dashboard")
    assert conn.status == 404
    assert %{"error" => "swarm_not_found"} = Jason.decode!(conn.resp_body)
  end

  test "401 when GENSWARMS_API_TOKEN set and no bearer" do
    conn = call_with_token(:get, "/api/swarms/x/dashboard", "secret")
    assert conn.status == 401
  end

  test "passes auth with the correct bearer (then 404 unknown swarm)" do
    conn = call_with_token(:get, "/api/swarms/x/dashboard", "secret", [{"authorization", "Bearer secret"}])
    assert conn.status == 404
    assert %{"error" => "swarm_not_found"} = Jason.decode!(conn.resp_body)
  end

  test "session history returns unavailable for unknown swarm" do
    conn = call(:get, "/api/swarms/nope/sessions/tg:1:0/history")
    assert conn.status == 200
    assert %{"source" => "unavailable", "turns" => []} = Jason.decode!(conn.resp_body)
  end

  test "session logs returns unavailable for unknown swarm" do
    conn = call(:get, "/api/swarms/nope/sessions/tg:1:0/logs")
    assert conn.status == 200
    assert %{"source" => "unavailable", "logs" => []} = Jason.decode!(conn.resp_body)
  end
end
