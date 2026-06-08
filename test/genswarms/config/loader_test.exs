defmodule Genswarms.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias Genswarms.Config.Loader

  describe "load_string/2" do
    test "refuses to evaluate .exs string content (RCE hardening)" do
      content = """
      %{
        name: "test-swarm",
        agents: [
          %{name: :agent1, backend: :local}
        ],
        topology: []
      }
      """

      assert {:error, :exs_string_not_supported} = Loader.load_string(content, :exs)
    end

    test "does not execute code embedded in .exs string content (no RCE side effect)" do
      marker = Path.join(System.tmp_dir!(), "loader_rce_#{System.unique_integer([:positive])}")
      File.rm(marker)

      content = ~s|File.write!(#{inspect(marker)}, "pwned"); %{name: "x", agents: []}|

      assert {:error, :exs_string_not_supported} = Loader.load_string(content, :exs)
      refute File.exists?(marker), "RCE: embedded code in .exs string content was executed"
    end

    test "loads configuration from JSON string" do
      content = """
      {
        "name": "test-swarm",
        "agents": [
          {"name": "agent1", "backend": "local"}
        ],
        "topology": []
      }
      """

      {:ok, config} = Loader.load_string(content, :json)

      assert config.name == "test-swarm"
    end

    test "loads configuration from YAML string" do
      content = """
      name: test-swarm
      agents:
        - name: agent1
          backend: local
      topology: []
      """

      {:ok, config} = Loader.load_string(content, :yaml)

      assert config.name == "test-swarm"
    end

    test "returns error for invalid JSON" do
      content = "not valid json"
      assert {:error, _} = Loader.load_string(content, :json)
    end
  end

  describe "load/1" do
    test "returns error for non-existent file" do
      assert {:error, {:file_not_found, _}} = Loader.load("/nonexistent/path.exs")
    end
  end
end
