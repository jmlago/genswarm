defmodule Genswarms.Agents.UpdateSkillPathTest do
  @moduledoc """
  Path-traversal guard for the skill-write handler. `skill_name` is an
  attacker-controlled URL segment, so update_skill must only ever write a plain
  filename inside skills_dir — never traverse out of it.

  These call AgentServer.handle_call/3 directly (the write site) with a minimal
  state map, so no GenServer/agent process is required.
  """
  use ExUnit.Case, async: true

  alias Genswarms.Agents.AgentServer

  defp update(skills_dir, skill_name, content \\ "hello") do
    from = {self(), make_ref()}
    AgentServer.handle_call({:update_skill, skill_name, content}, from, %{skills_dir: skills_dir})
  end

  describe "valid skill names" do
    @tag :tmp_dir
    test "writes a plain filename inside skills_dir", %{tmp_dir: dir} do
      assert {:reply, :ok, _state} = update(dir, "web.md", "content here")
      assert File.read!(Path.join(dir, "web.md")) == "content here"
    end

    @tag :tmp_dir
    test "accepts names with dots, dashes, underscores", %{tmp_dir: dir} do
      for name <- ["a.md", "my-skill.md", "my_skill.v2.md", "noext"] do
        assert {:reply, :ok, _} = update(dir, name)
        assert File.exists?(Path.join(dir, name))
      end
    end
  end

  describe "rejects traversal / non-plain names with :invalid_skill_name" do
    @tag :tmp_dir
    test "parent-directory traversal", %{tmp_dir: dir} do
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "../escape.md")
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "../../../../etc/cron.d/x")
    end

    @tag :tmp_dir
    test "absolute path", %{tmp_dir: dir} do
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "/etc/passwd")
    end

    @tag :tmp_dir
    test "subdirectory components", %{tmp_dir: dir} do
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "sub/skill.md")
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "a/b/c.md")
    end

    @tag :tmp_dir
    test "backslash separators and null bytes", %{tmp_dir: dir} do
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "..\\win.md")
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "evil\0.md")
    end

    @tag :tmp_dir
    test "bare dot and dot-dot and empty", %{tmp_dir: dir} do
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, ".")
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "..")
      assert {:reply, {:error, :invalid_skill_name}, _} = update(dir, "")
    end

    test "non-binary skill name" do
      assert {:reply, {:error, :invalid_skill_name}, _} = update("/tmp", :not_a_string)
    end
  end

  describe "no write escapes skills_dir (end-to-end proof)" do
    @tag :tmp_dir
    test "a traversal payload never creates a file outside skills_dir", %{tmp_dir: dir} do
      # skills_dir is a nested subdir; the payload tries to write into its parent.
      skills_dir = Path.join(dir, "skills")
      File.mkdir_p!(skills_dir)
      target = Path.join(dir, "pwned")
      refute File.exists?(target)

      assert {:reply, {:error, :invalid_skill_name}, _} = update(skills_dir, "../pwned", "x")

      refute File.exists?(target), "traversal wrote outside skills_dir"
      refute File.exists?(Path.join(skills_dir, "../pwned") |> Path.expand())
    end
  end

  describe "no skills_dir configured" do
    test "returns :no_skills_dir" do
      assert {:reply, {:error, :no_skills_dir}, _} = update(nil, "web.md")
    end
  end
end
