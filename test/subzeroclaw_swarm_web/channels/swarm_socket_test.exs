defmodule SubzeroclawSwarmWeb.SwarmSocketTest do
  use ExUnit.Case, async: false
  alias SubzeroclawSwarmWeb.SwarmSocket

  test "no token env -> open" do
    System.delete_env("DASHBOARD_API_TOKEN")
    assert {:ok, _} = SwarmSocket.connect(%{}, %Phoenix.Socket{}, %{})
  end

  test "token env -> requires matching param" do
    System.put_env("DASHBOARD_API_TOKEN", "secret")
    on_exit(fn -> System.delete_env("DASHBOARD_API_TOKEN") end)
    assert :error = SwarmSocket.connect(%{"token" => "nope"}, %Phoenix.Socket{}, %{})
    assert {:ok, _} = SwarmSocket.connect(%{"token" => "secret"}, %Phoenix.Socket{}, %{})
  end
end
