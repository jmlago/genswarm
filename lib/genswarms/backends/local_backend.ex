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
    workspace = Map.get(config, :workspace)

    # Each local agent gets its own workspace dir (used as cwd + WORKSPACE) so
    # swarm-msg's outbox and the LogWatcher poll the SAME per-agent .outbox.
    if workspace && workspace != "", do: File.mkdir_p!(Path.expand(workspace))

    env =
      [
        {~c"SUBZEROCLAW_AGENT_NAME", String.to_charlist(name)}
      ] ++
        maybe_add_skills_env(skills_dir) ++
        maybe_add_api_key_env(config) ++
        maybe_add_model_env(config) ++
        maybe_add_endpoint_env(config) ++
        maybe_add_workspace_env(workspace) ++
        extra_env(config)

    port_opts =
      [
        :binary,
        :exit_status,
        {:line, 16_384},
        {:env, env},
        :use_stdio,
        :stderr_to_stdout
      ] ++ maybe_cd(workspace)

    cmd = build_command(wrapper_path, subzeroclaw_path, name, skills_dir)

    try do
      port = Port.open({:spawn, cmd}, port_opts)

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

  defp build_command(wrapper_path, subzeroclaw_path, name, skills_dir) do
    skills_arg = if skills_dir, do: skills_dir, else: ""
    "#{wrapper_path} #{name} #{subzeroclaw_path} #{skills_arg}"
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

  # WORKSPACE lets swarm-msg (and the skill) resolve a per-agent .outbox instead
  # of the bwrap-only hardcoded /workspace.
  defp maybe_add_workspace_env(nil), do: []
  defp maybe_add_workspace_env(""), do: []

  defp maybe_add_workspace_env(workspace) do
    [{~c"WORKSPACE", String.to_charlist(Path.expand(workspace))}]
  end

  # Arbitrary per-agent env (e.g. WINGSTON_CONVERSATION_ID) passed via the
  # {:local, %{extra_env: %{...}}} backend opts.
  defp extra_env(config) do
    config
    |> Map.get(:extra_env, %{})
    |> Enum.map(fn {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))} end)
  end

  defp maybe_cd(nil), do: []
  defp maybe_cd(""), do: []
  defp maybe_cd(workspace), do: [{:cd, String.to_charlist(Path.expand(workspace))}]

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
