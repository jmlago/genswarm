defmodule Genswarm do
  @moduledoc """
  Genswarm - An Elixir/OTP orchestrator for managing swarms of subzeroclaw agents.

  ## Features

  - **Pluggable backends**: Local (Port), Docker, SSH
  - **Arbitrary directed graph topologies** for inter-agent communication
  - **Per-agent skills** (markdown files)
  - **Fault tolerance** via OTP supervision trees
  - **Hybrid deployments**: Docker Compose + bare metal + mixed

  ## Quick Start

      # Start a swarm from config
      {:ok, swarm_id} = Genswarm.start_swarm("path/to/config.exs")

      # Send a task to an agent
      Genswarm.send_task(swarm_id, "researcher", "find papers on transformers")

      # Get swarm status
      Genswarm.status(swarm_id)

      # Stop the swarm
      Genswarm.stop_swarm(swarm_id)

  ## Configuration Example

      %{
        name: "research-swarm",
        agents: [
          %{name: "researcher", skills: ["web.md"], backend: :local},
          %{name: "coder", skills: ["code.md"], backend: {:docker, "agent-coder"}},
          %{name: "reviewer", skills: ["review.md"], backend: {:ssh, "pi@192.168.1.50"}}
        ],
        topology: [
          {:researcher, :coder},
          {:coder, :reviewer},
          {:reviewer, :coder}
        ]
      }
  """

  alias Genswarm.SwarmManager

  @doc """
  Starts a swarm from a configuration file.

  Supported formats: .exs, .json, .yaml/.yml
  """
  defdelegate start_swarm(config_path), to: SwarmManager

  @doc """
  Starts a swarm from a configuration map.
  """
  defdelegate start_swarm_from_config(config), to: SwarmManager, as: :start_from_config

  @doc """
  Stops a running swarm.
  """
  defdelegate stop_swarm(swarm_name), to: SwarmManager, as: :stop

  @doc """
  Gets the status of a swarm.
  """
  defdelegate status(swarm_name), to: SwarmManager

  @doc """
  Sends a task to a specific agent in a swarm.
  """
  defdelegate send_task(swarm_name, agent_name, task), to: SwarmManager

  @doc """
  Lists all running swarms.
  """
  defdelegate list_swarms(), to: SwarmManager, as: :list

  @doc """
  Gets the topology of a swarm.
  """
  defdelegate get_topology(swarm_name), to: SwarmManager
end
