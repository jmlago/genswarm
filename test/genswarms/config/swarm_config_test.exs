defmodule Genswarms.Config.SwarmConfigTest do
  use ExUnit.Case, async: true

  alias Genswarms.Config.SwarmConfig

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

    test "rejects agent names containing shell metacharacters (command-injection hardening)" do
      for evil <- [
            "a; touch /tmp/pwned",
            "a$(id)",
            "a`id`",
            "a|cat",
            "a name",
            "a&&b",
            "../escape",
            "a\nb",
            # trailing newline must be rejected too — ^...$ would have allowed
            # it, \A...\z does not
            "valid\n",
            "\nvalid"
          ] do
        config = %{name: "test", agents: [%{name: evil, backend: :local}]}

        assert {:error, {:invalid_agent_name, _}} = SwarmConfig.parse(config),
               "expected #{inspect(evil)} to be rejected"
      end
    end

    test "valid_identifier?/1 anchors the whole string (no trailing-newline bypass)" do
      assert SwarmConfig.valid_identifier?("researcher")
      assert SwarmConfig.valid_identifier?("coder_2")
      assert SwarmConfig.valid_identifier?("eval-bot")
      assert SwarmConfig.valid_identifier?(:atom_name)

      refute SwarmConfig.valid_identifier?("valid\n")
      refute SwarmConfig.valid_identifier?("\nvalid")
      refute SwarmConfig.valid_identifier?("a b")
      refute SwarmConfig.valid_identifier?("1leading")
      refute SwarmConfig.valid_identifier?("a;b")
      refute SwarmConfig.valid_identifier?("")
      refute SwarmConfig.valid_identifier?(123)
    end

    test "rejects agent names that do not start with a letter" do
      config = %{name: "test", agents: [%{name: "1agent", backend: :local}]}
      assert {:error, {:invalid_agent_name, _}} = SwarmConfig.parse(config)
    end

    test "accepts valid agent names (letters, digits, underscore, hyphen)" do
      config = %{
        name: "test",
        agents: [
          %{name: "researcher", backend: :local},
          %{name: "coder_2", backend: :local},
          %{name: "eval-bot", backend: :local}
        ],
        topology: []
      }

      assert {:ok, parsed} = SwarmConfig.parse(config)
      assert length(parsed.agents) == 3
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
      assert SwarmConfig.backend_module(:local) == Genswarms.Backends.LocalBackend
    end

    test "returns correct module for docker backend" do
      assert SwarmConfig.backend_module({:docker, "test"}) ==
               Genswarms.Backends.DockerBackend
    end

    test "returns correct module for ssh backend" do
      assert SwarmConfig.backend_module({:ssh, "user@host"}) ==
               Genswarms.Backends.SSHBackend
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
