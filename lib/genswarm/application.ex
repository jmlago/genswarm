defmodule Genswarm.Application do
  @moduledoc """
  The Genswarm OTP Application.

  Supervises the swarm orchestrator including:
  - Agent Registry for process lookup
  - Router for inter-agent messaging
  - Skills Manager for managing agent skills
  - Dynamic Supervisor for agent processes
  - Phoenix web interface
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Load .env file if present
    case Genswarm.CLI.EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[Genswarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end

    children = [
      # Telemetry supervisor
      Genswarm.Telemetry,
      # PubSub for broadcasting messages
      {Phoenix.PubSub, name: Genswarm.PubSub},
      # Centralized event logging (before other components so they can log)
      Genswarm.Observability.LogStore,
      # Bwrap agent telemetry (ETS ring buffer for 10k+ scale)
      Genswarm.Backends.Bwrap.AgentTelemetry,
      # Registry for agent process lookup
      {Registry, keys: :unique, name: Genswarm.AgentRegistry},
      # ETS-backed skills manager
      Genswarm.Skills.SkillsManager,
      # Router for inter-agent message routing
      Genswarm.Routing.Router,
      # Dynamic supervisor for agent processes
      {DynamicSupervisor, name: Genswarm.AgentSupervisor, strategy: :one_for_one},
      # Swarm manager for orchestrating swarms
      Genswarm.SwarmManager
      # Note: Phoenix endpoint is optional, started via `swarm dashboard`
    ]

    opts = [strategy: :one_for_one, name: Genswarm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    if web_server_running?() do
      GenswarmWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end

  @doc """
  Starts the Phoenix web server dynamically.

  ## Options

    * `:port` - Port to run the server on (default: 4000 or $PORT)

  """
  @spec start_web_server(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_web_server(opts \\ []) do
    if web_server_running?() do
      {:error, :already_running}
    else
      port = Keyword.get(opts, :port, get_port())

      # Update endpoint config with port
      endpoint_config = Application.get_env(:genswarm, GenswarmWeb.Endpoint, [])

      updated_config =
        Keyword.merge(endpoint_config,
          http: [port: port],
          server: true
        )

      Application.put_env(:genswarm, GenswarmWeb.Endpoint, updated_config)

      # Start endpoint under the supervisor
      Supervisor.start_child(Genswarm.Supervisor, GenswarmWeb.Endpoint)
    end
  end

  @doc """
  Stops the Phoenix web server if running.
  """
  @spec stop_web_server() :: :ok | {:error, term()}
  def stop_web_server do
    if web_server_running?() do
      case Supervisor.terminate_child(Genswarm.Supervisor, GenswarmWeb.Endpoint) do
        :ok ->
          Supervisor.delete_child(Genswarm.Supervisor, GenswarmWeb.Endpoint)
          :ok

        error ->
          error
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Checks if the Phoenix web server is running.
  """
  @spec web_server_running?() :: boolean()
  def web_server_running? do
    case Process.whereis(GenswarmWeb.Endpoint) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Gets the port the web server is configured to run on.
  """
  @spec get_port() :: non_neg_integer()
  def get_port do
    case System.get_env("PORT") do
      nil ->
        4000

      port_str ->
        case Integer.parse(port_str) do
          {port, _} -> port
          :error -> 4000
        end
    end
  end
end
