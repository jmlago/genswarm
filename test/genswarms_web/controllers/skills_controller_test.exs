defmodule GenswarmsWeb.SkillsControllerTest do
  @moduledoc """
  The skills listing must not enumerate the host filesystem via the `path` query
  param, and must not leak absolute host paths in its response.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias GenswarmsWeb.SkillsController

  setup do
    original = Application.get_env(:genswarms, :skills_dir)
    root = Path.join(System.tmp_dir!(), "skills_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "web"))
    File.write!(Path.join(root, "a.md"), "a")
    File.write!(Path.join([root, "web", "b.md"]), "b")
    Application.put_env(:genswarms, :skills_dir, root)

    on_exit(fn ->
      if original,
        do: Application.put_env(:genswarms, :skills_dir, original),
        else: Application.delete_env(:genswarms, :skills_dir)

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp index(params), do: build_conn() |> SkillsController.index(params)
  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "lists skills under the root with no path param" do
    conn = index(%{})
    assert conn.status in [200, nil]
    decoded = body(conn)
    assert decoded["base_path"] == "."
    names = Enum.map(decoded["skills"], & &1["name"]) |> Enum.sort()
    assert names == ["a.md", "b.md"]
  end

  test "never returns absolute host paths in skill entries" do
    decoded = body(index(%{}))

    for skill <- decoded["skills"] do
      refute Map.has_key?(skill, "path"), "skill entry leaked an absolute path: #{inspect(skill)}"
      refute String.starts_with?(skill["relative_path"], "/")
    end

    refute String.starts_with?(decoded["base_path"], "/")
  end

  test "a valid subdirectory within the root is allowed" do
    decoded = body(index(%{"path" => "web"}))
    assert decoded["base_path"] == "web"
    assert [%{"name" => "b.md"}] = decoded["skills"]
  end

  test "an absolute path outside the root is rejected with 400" do
    conn = index(%{"path" => "/etc"})
    assert conn.status == 400
    assert body(conn)["error"] == "Invalid path"
  end

  test "parent traversal escaping the root is rejected with 400" do
    conn = index(%{"path" => "../../../../etc"})
    assert conn.status == 400
  end

  test "a sibling-prefix dir is rejected", %{root: root} do
    File.mkdir_p!(root <> "_evil")
    on_exit(fn -> File.rm_rf(root <> "_evil") end)
    # ../<root_basename>_evil resolves next to the root, not inside it
    conn = index(%{"path" => "../" <> Path.basename(root) <> "_evil"})
    assert conn.status == 400
  end
end
