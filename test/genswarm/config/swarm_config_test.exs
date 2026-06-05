defmodule Genswarm.Config.SwarmConfigTest do
  use ExUnit.Case, async: true

  alias Genswarm.Config.SwarmConfig

  describe "parse/1" do
    test "parses valid configuration" do
      config = %{
        name: "test-swarm",
        agents: [
          %{name: "researcher", backend: :local, skills: ["web.md"]},
          %{name: "coder", backend: {:docker, "coder-container"}}
        ],
        topology: [
          {:researcher, :coder},
          {:coder, :researcher}
        ]
      }

      assert {:ok, parsed} = SwarmConfig.parse(config)
      assert parsed.name == "test-swarm"
      assert length(parsed.agents) == 2
      assert length(parsed.topology) == 2
    end

    test "normalizes string agent names to atoms" do
      config = %{
        name: "test-swarm",
        agents: [
          %{name: "agent1", backend: :local}
        ],
        topology: []
      }

      {:ok, parsed} = SwarmConfig.parse(config)
      assert [%{name: :agent1}] = parsed.agents
    end

    test "normalizes string topology names to atoms" do
      config = %{
        name: "test-swarm",
        agents: [
          %{name: :a, backend: :local},
          %{name: :b, backend: :local}
        ],
        topology: [
          {"a", "b"}
        ]
      }

      {:ok, parsed} = SwarmConfig.parse(config)
      assert [{:a, :b}] = parsed.topology
    end

    test "rejects missing name" do
      config = %{agents: [%{name: "a", backend: :local}]}
      assert {:error, :missing_name} = SwarmConfig.parse(config)
    end

    test "rejects empty agents" do
      config = %{name: "test", agents: []}
      assert {:error, :missing_or_empty_agents} = SwarmConfig.parse(config)
    end

    test "rejects invalid backend" do
      config = %{
        name: "test",
        agents: [%{name: "a", backend: :invalid}]
      }

      assert {:error, {:invalid_backend, :invalid}} = SwarmConfig.parse(config)
    end

    test "validates topology references existing agents" do
      config = %{
        name: "test",
        agents: [%{name: :a, backend: :local}],
        topology: [{:a, :nonexistent}]
      }

      assert {:error, {:invalid_topology, _}} = SwarmConfig.parse(config)
    end

    test "accepts docker backend with container name" do
      config = %{
        name: "test",
        agents: [%{name: :a, backend: {:docker, "my-container"}}],
        topology: []
      }

      assert {:ok, _} = SwarmConfig.parse(config)
    end

    test "accepts docker backend with options" do
      config = %{
        name: "test",
        agents: [%{name: :a, backend: {:docker, "my-container", %{memory: "512m"}}}],
        topology: []
      }

      assert {:ok, _} = SwarmConfig.parse(config)
    end

    test "accepts ssh backend" do
      config = %{
        name: "test",
        agents: [%{name: :a, backend: {:ssh, "user@host"}}],
        topology: []
      }

      assert {:ok, _} = SwarmConfig.parse(config)
    end

    test "accepts ssh backend with options" do
      config = %{
        name: "test",
        agents: [%{name: :a, backend: {:ssh, "user@host", %{key_path: "~/.ssh/id_rsa"}}}],
        topology: []
      }

      assert {:ok, _} = SwarmConfig.parse(config)
    end
  end

  describe "build_adjacency_map/1" do
    test "builds correct adjacency map" do
      topology = [
        {:a, :b},
        {:a, :c},
        {:b, :a}
      ]

      adjacency = SwarmConfig.build_adjacency_map(topology)

      assert :b in adjacency[:a]
      assert :c in adjacency[:a]
      assert :a in adjacency[:b]
      refute Map.has_key?(adjacency, :c)
    end
  end

  describe "can_send?/3" do
    test "returns true for allowed routes" do
      {:ok, config} =
        SwarmConfig.parse(%{
          name: "test",
          agents: [
            %{name: :a, backend: :local},
            %{name: :b, backend: :local}
          ],
          topology: [{:a, :b}]
        })

      assert SwarmConfig.can_send?(config, :a, :b)
    end

    test "returns false for disallowed routes" do
      {:ok, config} =
        SwarmConfig.parse(%{
          name: "test",
          agents: [
            %{name: :a, backend: :local},
            %{name: :b, backend: :local}
          ],
          topology: [{:a, :b}]
        })

      refute SwarmConfig.can_send?(config, :b, :a)
    end
  end

  describe "backend_module/1" do
    test "returns correct module for local backend" do
      assert SwarmConfig.backend_module(:local) == Genswarm.Backends.LocalBackend
    end

    test "returns correct module for docker backend" do
      assert SwarmConfig.backend_module({:docker, "test"}) ==
               Genswarm.Backends.DockerBackend
    end

    test "returns correct module for ssh backend" do
      assert SwarmConfig.backend_module({:ssh, "user@host"}) ==
               Genswarm.Backends.SSHBackend
    end
  end

  describe "backend_config/1" do
    test "extracts docker image name" do
      config = SwarmConfig.backend_config({:docker, "my-container"})
      assert config.image == "my-container"
    end

    test "extracts ssh host" do
      config = SwarmConfig.backend_config({:ssh, "user@host"})
      assert config.host == "user@host"
    end

    test "merges options for docker" do
      config = SwarmConfig.backend_config({:docker, "my-container", %{memory: "512m"}})
      assert config.image == "my-container"
      assert config.memory == "512m"
    end

    test "returns empty map for bwrap" do
      config = SwarmConfig.backend_config(:bwrap)
      assert config == %{}
    end

    test "returns options for bwrap with opts" do
      config = SwarmConfig.backend_config({:bwrap, %{memory_limit: "256M"}})
      assert config.memory_limit == "256M"
    end
  end
end
