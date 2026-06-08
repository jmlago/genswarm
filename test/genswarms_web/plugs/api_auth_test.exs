defmodule GenswarmsWeb.Plugs.ApiAuthTest do
  # not async: toggles global application env (:api_token)
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias GenswarmsWeb.Plugs.ApiAuth

  @token "test-api-token-1234567890"

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

  defp run(conn), do: ApiAuth.call(conn, ApiAuth.init([]))
  defp base(remote_ip \\ {127, 0, 0, 1}), do: %{conn(:get, "/api/swarms") | remote_ip: remote_ip}

  defp assert_401(conn) do
    assert conn.halted
    assert conn.status == 401
    assert %{"error" => msg} = Jason.decode!(conn.resp_body)
    assert is_binary(msg) and msg != ""
  end

  defp assert_allowed(conn) do
    refute conn.halted
    assert conn.status == nil
  end

  describe "with a token configured" do
    setup do
      Application.put_env(:genswarms, :api_token, @token)
      :ok
    end

    test "allows a request with the correct bearer token" do
      base() |> put_req_header("authorization", "Bearer #{@token}") |> run() |> assert_allowed()
    end

    test "allows the correct token even from a remote IP" do
      base({203, 0, 113, 9})
      |> put_req_header("authorization", "Bearer #{@token}")
      |> run()
      |> assert_allowed()
    end

    test "rejects a wrong token" do
      base() |> put_req_header("authorization", "Bearer wrong") |> run() |> assert_401()
    end

    test "rejects a missing Authorization header" do
      base() |> run() |> assert_401()
    end

    test "rejects a non-Bearer scheme" do
      base() |> put_req_header("authorization", "Token #{@token}") |> run() |> assert_401()
    end

    test "rejects a bare token without the Bearer prefix" do
      base() |> put_req_header("authorization", @token) |> run() |> assert_401()
    end
  end

  describe "with no token configured" do
    setup do
      Application.delete_env(:genswarms, :api_token)
      :ok
    end

    test "allows loopback callers without any token" do
      base({127, 0, 0, 1}) |> run() |> assert_allowed()
      base({0, 0, 0, 0, 0, 0, 0, 1}) |> run() |> assert_allowed()
    end

    test "rejects remote callers with 401" do
      base({203, 0, 113, 10}) |> run() |> assert_401()
    end

    test "rejects remote callers even if they send some token" do
      base({203, 0, 113, 10})
      |> put_req_header("authorization", "Bearer anything")
      |> run()
      |> assert_401()
    end
  end

  describe "router pipeline integration (auth is actually wired into :api)" do
    test "a remote, tokenless caller is halted with 401 before any controller runs" do
      Application.delete_env(:genswarms, :api_token)

      conn =
        %{conn(:get, "/api/swarms") | remote_ip: {203, 0, 113, 1}}
        |> GenswarmsWeb.Router.call(GenswarmsWeb.Router.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "a remote caller with the correct token passes the auth stage" do
      Application.put_env(:genswarms, :api_token, @token)

      conn =
        %{conn(:get, "/api/swarms") | remote_ip: {203, 0, 113, 1}}
        |> put_req_header("authorization", "Bearer #{@token}")
        |> GenswarmsWeb.Router.call(GenswarmsWeb.Router.init([]))

      # Auth did not halt with 401; the request reached the controller (whatever
      # it returns, it is not the auth rejection).
      refute conn.status == 401
    end
  end
end
