defmodule Genswarms.Config.PathGuardTest do
  # async: false — mutates the :genswarms/:swarm_config_dir application env.
  use ExUnit.Case, async: false

  alias Genswarms.Config.PathGuard

  setup do
    original = Application.get_env(:genswarms, :swarm_config_dir)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:genswarms, :swarm_config_dir)
  defp restore(val), do: Application.put_env(:genswarms, :swarm_config_dir, val)

  describe "allowed_dir/0" do
    test "uses the configured directory (expanded)" do
      Application.put_env(:genswarms, :swarm_config_dir, "/srv/swarms/")
      assert PathGuard.allowed_dir() == "/srv/swarms"
    end

    test "defaults to the working directory when unset" do
      Application.delete_env(:genswarms, :swarm_config_dir)
      assert PathGuard.allowed_dir() == File.cwd!()
    end

    test "defaults to cwd when blank" do
      Application.put_env(:genswarms, :swarm_config_dir, "")
      assert PathGuard.allowed_dir() == File.cwd!()
    end
  end

  describe "safe_config_path/1" do
    @base "/srv/allowed"

    setup do
      Application.put_env(:genswarms, :swarm_config_dir, @base)
      :ok
    end

    test "accepts a relative path that stays inside the base" do
      assert {:ok, @base <> "/swarms/x.exs"} = PathGuard.safe_config_path("swarms/x.exs")
    end

    test "accepts a nested relative path" do
      assert {:ok, @base <> "/a/b/c.json"} = PathGuard.safe_config_path("a/b/c.json")
    end

    test "accepts an absolute path inside the base" do
      assert {:ok, @base <> "/swarms/x.exs"} =
               PathGuard.safe_config_path(@base <> "/swarms/x.exs")
    end

    test "accepts traversal that resolves back inside the base" do
      assert {:ok, @base <> "/swarms/x.exs"} =
               PathGuard.safe_config_path("swarms/sub/../x.exs")
    end

    test "accepts the base directory itself" do
      assert {:ok, @base} = PathGuard.safe_config_path(@base)
    end

    test "rejects an absolute path outside the base" do
      assert {:error, :outside_allowed_dir} = PathGuard.safe_config_path("/etc/passwd")
      assert {:error, :outside_allowed_dir} = PathGuard.safe_config_path("/root/.ssh/id_rsa")
    end

    test "rejects parent traversal that escapes the base" do
      assert {:error, :outside_allowed_dir} =
               PathGuard.safe_config_path("../../../../etc/passwd")

      assert {:error, :outside_allowed_dir} = PathGuard.safe_config_path("../allowed-sibling/x")
    end

    test "rejects a sibling directory sharing the base as a string prefix" do
      # /srv/allowed_evil must NOT be treated as inside /srv/allowed.
      assert {:error, :outside_allowed_dir} =
               PathGuard.safe_config_path("/srv/allowed_evil/x.exs")

      assert {:error, :outside_allowed_dir} = PathGuard.safe_config_path("../allowed_evil/x.exs")
    end

    test "rejects empty and non-binary input" do
      assert {:error, :invalid_path} = PathGuard.safe_config_path("")
      assert {:error, :invalid_path} = PathGuard.safe_config_path(nil)
      assert {:error, :invalid_path} = PathGuard.safe_config_path(123)
    end
  end
end
