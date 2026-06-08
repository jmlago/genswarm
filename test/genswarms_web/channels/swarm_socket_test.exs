defmodule GenswarmsWeb.SwarmSocketTest do
  # not async: reads global application env (:api_token)
  use ExUnit.Case, async: false

  alias GenswarmsWeb.SwarmSocket

  @token "ws-token-abcdef"
  @sock :sentinel_socket
  @loopback %{peer_data: %{address: {127, 0, 0, 1}}}
  @remote %{peer_data: %{address: {203, 0, 113, 22}}}

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

  describe "connect/3 — token configured" do
    setup do
      Application.put_env(:genswarms, :api_token, @token)
      :ok
    end

    test "accepts a correct token via the ?token= connect param" do
      assert {:ok, @sock} = SwarmSocket.connect(%{"token" => @token}, @sock, @remote)
    end

    test "accepts a correct token via the Authorization header" do
      ci = Map.put(@remote, :x_headers, [{"authorization", "Bearer #{@token}"}])
      assert {:ok, @sock} = SwarmSocket.connect(%{}, @sock, ci)
    end

    test "rejects a wrong token param" do
      assert :error = SwarmSocket.connect(%{"token" => "nope"}, @sock, @remote)
    end

    test "rejects no token, even from loopback" do
      assert :error = SwarmSocket.connect(%{}, @sock, @loopback)
    end
  end

  describe "connect/3 — no token configured" do
    setup do
      Application.delete_env(:genswarms, :api_token)
      :ok
    end

    test "accepts loopback peers" do
      assert {:ok, @sock} = SwarmSocket.connect(%{}, @sock, @loopback)
    end

    test "rejects remote peers" do
      assert :error = SwarmSocket.connect(%{}, @sock, @remote)
    end

    test "rejects when peer data is unavailable" do
      assert :error = SwarmSocket.connect(%{}, @sock, %{})
    end
  end
end
