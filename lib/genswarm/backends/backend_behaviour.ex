defmodule Genswarm.Backends.BackendBehaviour do
  @moduledoc """
  Behaviour definition for agent backends.

  Backends are responsible for starting, stopping, and communicating with
  subzeroclaw agent processes. Implementations include:

  - `LocalBackend` - Runs subzeroclaw as a local Port process
  - `DockerBackend` - Runs subzeroclaw in a Docker container
  - `SSHBackend` - Runs subzeroclaw on a remote machine via SSH
  """

  @type ref :: any()
  @type config :: map()
  @type skills :: [String.t()]
  @type message :: String.t()

  @doc """
  Starts an agent process with the given name and configuration.

  Returns `{:ok, ref}` where `ref` is a backend-specific reference
  that can be used with other callbacks.
  """
  @callback start(name :: String.t(), config :: config()) ::
              {:ok, ref()} | {:error, term()}

  @doc """
  Stops a running agent process.
  """
  @callback stop(ref :: ref()) :: :ok | {:error, term()}

  @doc """
  Sends input to the agent's stdin.
  """
  @callback send_input(ref :: ref(), message :: message()) ::
              :ok | {:error, term()}

  @doc """
  Deploys skills to the agent.

  For local backend, this sets the SUBZEROCLAW_SKILLS env var.
  For Docker, this mounts the skills directory as a volume.
  For SSH, this SCPs the skills to the remote machine.
  """
  @callback deploy_skills(ref :: ref(), skills_dir :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Performs a health check on the agent.
  """
  @callback health_check(ref :: ref()) :: :ok | {:error, term()}

  @doc """
  Returns the backend type as an atom.
  """
  @callback backend_type() :: atom()

  @doc """
  Optional callback for handling output from the agent.
  Called by the agent server when data is received.
  """
  @callback handle_output(ref :: ref(), data :: binary()) :: {:ok, [map()]}

  @optional_callbacks [handle_output: 2]
end
