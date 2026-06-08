defmodule GenswarmsWeb.CreateSwarmPathTest do
  @moduledoc """
  POST /api/swarms must reject a config_path that escapes the allowed config
  directory, before any file is loaded or evaluated.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias GenswarmsWeb.SwarmController

  setup do
    original = Application.get_env(:genswarms, :swarm_config_dir)
    # Constrain to a directory that definitely does not contain /etc, ~, etc.
    Application.put_env(:genswarms, :swarm_config_dir, "/srv/genswarms-allowed")
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:genswarms, :swarm_config_dir)
  defp restore(val), do: Application.put_env(:genswarms, :swarm_config_dir, val)

  defp create(path) do
    build_conn() |> SwarmController.create(%{"config_path" => path})
  end

  test "absolute path outside the allowed dir is rejected with 400" do
    conn = create("/etc/passwd")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "Invalid config_path"
  end

  test "parent traversal escaping the allowed dir is rejected with 400" do
    conn = create("../../../../etc/cron.d/evil.exs")
    assert conn.status == 400
  end

  test "sibling-prefix directory is rejected with 400" do
    conn = create("/srv/genswarms-allowed-evil/x.exs")
    assert conn.status == 400
  end

  test "empty config_path is rejected with 400" do
    conn = create("")
    assert conn.status == 400
  end
end
