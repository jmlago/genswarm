defmodule Mix.Tasks.Swarm.RestartAgent do
  @moduledoc """
  Restarts a specific agent in a running swarm.

  ## Usage

      mix swarm restart-agent <swarm-name> <agent-name>

  This stops the agent and starts it again with its current configuration.
  Useful after modifying skills or when an agent is in an error state.
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, APIClient}

  @shortdoc "Restart a specific agent"

  @impl Mix.Task
  def run([swarm_name, agent_name]) do
    Application.ensure_all_started(:req)

    if APIClient.server_running?() do
      restart_via_api(swarm_name, agent_name)
    else
      Output.error("Server not running. Start it with: mix swarm up")
    end
  end

  def run(_) do
    Output.error("Usage: mix swarm restart-agent <swarm-name> <agent-name>")
  end

  defp restart_via_api(swarm_name, agent_name) do
    Output.info("Restarting agent #{agent_name} in swarm #{swarm_name}...")

    case APIClient.post("/api/swarms/#{swarm_name}/agents/#{agent_name}/restart", %{}) do
      {:ok, %{"status" => "restarted"}} ->
        Output.success("Agent #{agent_name} restarted")

      {:ok, %{"error" => error}} ->
        Output.error("Failed: #{error}")

      {:error, reason} ->
        Output.error("Failed to restart agent: #{inspect(reason)}")
    end
  end
end
