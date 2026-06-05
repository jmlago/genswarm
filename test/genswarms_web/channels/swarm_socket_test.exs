defmodule GenswarmsWeb.SwarmSocketTest do
  use ExUnit.Case, async: false
  alias GenswarmsWeb.SwarmSocket

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

  test "token env -> authenticates via the x-dashboard-token header (no token in url)" do
    System.put_env("DASHBOARD_API_TOKEN", "secret")
    on_exit(fn -> System.delete_env("DASHBOARD_API_TOKEN") end)
    assert {:ok, _} = SwarmSocket.connect(%{}, %Phoenix.Socket{}, %{x_headers: [{"x-dashboard-token", "secret"}]})
    assert :error = SwarmSocket.connect(%{}, %Phoenix.Socket{}, %{x_headers: [{"x-dashboard-token", "nope"}]})
  end

  test "header and legacy query param both authenticate (backward compatible)" do
    System.put_env("DASHBOARD_API_TOKEN", "secret")
    on_exit(fn -> System.delete_env("DASHBOARD_API_TOKEN") end)
    # legacy ?token= path still works for an un-upgraded client
    assert {:ok, _} = SwarmSocket.connect(%{"token" => "secret"}, %Phoenix.Socket{}, %{})
    # header path works with no token in the URL
    assert {:ok, _} = SwarmSocket.connect(%{}, %Phoenix.Socket{}, %{x_headers: [{"x-dashboard-token", "secret"}]})
  end
end
