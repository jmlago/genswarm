defmodule Genswarm.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias Genswarm.Config.Loader

  describe "load_string/2" do
    test "loads configuration from Elixir string" do
      content = """
      %{
        name: "test-swarm",
        agents: [
          %{name: :agent1, backend: :local}
        ],
        topology: []
      }
      """

      {:ok, config} = Loader.load_string(content, :exs)

      assert config.name == "test-swarm"
      assert length(config.agents) == 1
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

    test "returns error for invalid Elixir syntax" do
      content = "not valid elixir {"
      assert {:error, {:eval_error, _}} = Loader.load_string(content, :exs)
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
