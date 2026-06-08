defmodule Genswarms.Backends.LocalBackend do
  @moduledoc """
  Local backend implementation using Elixir Ports.

  Spawns subzeroclaw as a subprocess and communicates via stdin/stdout.
  Uses the szc-wrapper script to translate between JSON protocol and
  subzeroclaw's plain text interface.
  """

  @behaviour Genswarms.Backends.BackendBehaviour

  require Logger

  defstruct [:port, :name, :skills_dir, :session_id, :buffer]

  @type t :: %__MODULE__{
          port: port(),
          name: String.t(),
          skills_dir: String.t() | nil,
          session_id: String.t() | nil,
          buffer: binary()
        }

  @impl true
  def backend_type, do: :local

  @impl true
  def start(name, config) do
    wrapper_path = get_wrapper_path(config)
    subzeroclaw_path = get_subzeroclaw_path(config)
    skills_dir = Map.get(config, :skills_dir)

    env =
      [
        {~c"SUBZEROCLAW_AGENT_NAME", String.to_charlist(name)}
      ] ++
        maybe_add_skills_env(skills_dir) ++
        maybe_add_api_key_env(config) ++
        maybe_add_model_env(config) ++
        maybe_add_endpoint_env(config)

    port_opts = [
      :binary,
      :exit_status,
      {:line, 16_384},
      {:env, env},
      :use_stdio,
      :stderr_to_stdout
    ]

    args = build_args(name, subzeroclaw_path, skills_dir)

    try do
      # spawn_executable + :args passes argv directly (no /bin/sh), so agent
      # names / paths cannot be interpreted as shell commands. Using {:spawn, str}
      # here would run the string through "/bin/sh -c" (command injection).
      port = Port.open({:spawn_executable, wrapper_path}, [{:args, args} | port_opts])

      ref = %__MODULE__{
        port: port,
        name: name,
        skills_dir: skills_dir,
        session_id: nil,
        buffer: ""
      }

      Logger.info("Started local agent #{name} with port #{inspect(port)}")
      {:ok, ref}
    rescue
      e ->
        Logger.error("Failed to start local agent #{name}: #{inspect(e)}")
        {:error, {:start_failed, e}}
    end
  end

  @impl true
  def stop(%__MODULE__{port: port, name: name}) do
    Logger.info("Stopping local agent #{name}")

    try do
      Port.close(port)
      :ok
    rescue
      _ -> :ok
    end
  end

  @impl true
  def send_input(%__MODULE__{port: port}, message) when is_binary(message) do
    # Ensure message ends with newline for line-based protocol
    data =
      if String.ends_with?(message, "\n") do
        message
      else
        message <> "\n"
      end

    try do
      Port.command(port, data)
      :ok
    rescue
      e ->
        {:error, {:send_failed, e}}
    end
  end

  @impl true
  def deploy_skills(%__MODULE__{} = ref, skills_dir) do
    # For local backend, skills are deployed via env var at start time
    # This callback is mainly for updating skills at runtime
    {:ok, %{ref | skills_dir: skills_dir}}
  end

  @impl true
  def health_check(%__MODULE__{port: port}) do
    case Port.info(port) do
      nil -> {:error, :port_closed}
      info when is_list(info) -> :ok
    end
  end

  @impl true
  def handle_output(%__MODULE__{buffer: buffer}, data) do
    # Combine buffer with new data and parse complete JSON lines
    combined = buffer <> data
    {messages, remaining} = parse_json_lines(combined)
    {:ok, messages, remaining}
  end

  # Private functions

  defp get_wrapper_path(config) do
    Map.get(config, :wrapper_path) ||
      Application.get_env(:genswarms, :wrapper_path) ||
      Path.join(:code.priv_dir(:genswarms), "szc-wrapper-fifo.sh")
  end

  defp get_subzeroclaw_path(config) do
    Map.get(config, :subzeroclaw_path) ||
      Application.get_env(:genswarms, :subzeroclaw_path, "subzeroclaw")
  end

  # argv list passed to the wrapper: <agent_name> <subzeroclaw_path> [skills_dir].
  # Returned as a list (not a joined string) so Port spawn_executable hands them
  # to execvp directly and no shell metacharacter interpretation can occur.
  @doc false
  def build_args(name, subzeroclaw_path, skills_dir) do
    skills_arg = if skills_dir, do: skills_dir, else: ""
    [to_string(name), to_string(subzeroclaw_path), to_string(skills_arg)]
  end

  defp maybe_add_skills_env(nil), do: []

  defp maybe_add_skills_env(skills_dir) do
    [{~c"SUBZEROCLAW_SKILLS", String.to_charlist(Path.expand(skills_dir))}]
  end

  defp maybe_add_api_key_env(config) do
    case Map.get(config, :api_key) || System.get_env("SUBZEROCLAW_API_KEY") do
      nil -> []
      key -> [{~c"SUBZEROCLAW_API_KEY", String.to_charlist(key)}]
    end
  end

  defp maybe_add_model_env(config) do
    case Map.get(config, :model) || System.get_env("SUBZEROCLAW_MODEL") do
      nil -> []
      model -> [{~c"SUBZEROCLAW_MODEL", String.to_charlist(model)}]
    end
  end

  defp maybe_add_endpoint_env(config) do
    case Map.get(config, :endpoint) || System.get_env("SUBZEROCLAW_ENDPOINT") do
      nil -> []
      endpoint -> [{~c"SUBZEROCLAW_ENDPOINT", String.to_charlist(endpoint)}]
    end
  end

  defp parse_json_lines(data) do
    lines = String.split(data, "\n")

    {complete_lines, [remaining]} =
      case lines do
        [] -> {[], [""]}
        _ -> Enum.split(lines, -1)
      end

    messages =
      complete_lines
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(&parse_json_message/1)
      |> Enum.filter(&(&1 != nil))

    {messages, remaining}
  end

  defp parse_json_message(line) do
    case Jason.decode(line) do
      {:ok, message} ->
        message

      {:error, _} ->
        # Not valid JSON, treat as raw output
        %{"type" => "output", "content" => line}
    end
  end
end
