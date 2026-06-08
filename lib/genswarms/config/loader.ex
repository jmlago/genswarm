defmodule Genswarms.Config.Loader do
  @moduledoc """
  Configuration loader supporting multiple file formats.

  Supports:
  - `.exs` - Elixir term files
  - `.json` - JSON files
  - `.yaml` / `.yml` - YAML files
  """

  alias Genswarms.Config.SwarmConfig

  @doc """
  Loads and parses a swarm configuration from a file.

  The format is determined by the file extension.
  """
  @spec load(String.t()) :: {:ok, SwarmConfig.t()} | {:error, term()}
  def load(path) do
    expanded_path = Path.expand(path)

    # Load .env from the config file's directory
    config_dir = Path.dirname(expanded_path)
    Genswarms.CLI.EnvManager.auto_load(config_dir)

    with {:ok, _} <- check_file_exists(expanded_path),
         {:ok, config} <- load_file(expanded_path) do
      SwarmConfig.parse(config)
    end
  end

  @doc """
  Loads configuration from a string with explicit format.
  """
  @spec load_string(String.t(), :exs | :json | :yaml) ::
          {:ok, SwarmConfig.t()} | {:error, term()}
  def load_string(content, format) do
    with {:ok, config} <- parse_string(content, format) do
      SwarmConfig.parse(config)
    end
  end

  # Private functions

  defp check_file_exists(path) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:file_not_found, path}}
    end
  end

  defp load_file(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ".exs" -> load_exs(path)
      ".json" -> load_json(path)
      ".yaml" -> load_yaml(path)
      ".yml" -> load_yaml(path)
      _ -> {:error, {:unsupported_format, ext}}
    end
  end

  defp load_exs(path) do
    try do
      {config, _bindings} = Code.eval_file(path)
      normalize_config(config)
    rescue
      e -> {:error, {:eval_error, e}}
    end
  end

  defp load_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content, keys: :atoms) do
      normalize_config(data)
    end
  end

  defp load_yaml(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- YamlElixir.read_from_string(content) do
      normalize_config(atomize_keys(data))
    end
  end

  defp parse_string(_content, :exs) do
    # `.exs` is executable Elixir. The only source of *string* configs is the
    # network API, which is untrusted, so evaluating it would be arbitrary code
    # execution (RCE). String configs must be data-only (json/yaml). Trusted
    # `.exs` *files* are still supported via `load/1` (the local CLI workflow).
    {:error, :exs_string_not_supported}
  end

  defp parse_string(content, :json) do
    with {:ok, data} <- Jason.decode(content, keys: :atoms) do
      normalize_config(data)
    end
  end

  defp parse_string(content, :yaml) do
    with {:ok, data} <- YamlElixir.read_from_string(content) do
      normalize_config(atomize_keys(data))
    end
  end

  defp normalize_config(config) when is_map(config) do
    # Convert string keys to atoms and handle nested structures
    config = deep_atomize_keys(config)
    # Normalize agent backends from strings to atoms
    config = normalize_agent_backends(config)
    {:ok, config}
  end

  defp normalize_config(config), do: {:ok, config}

  # Convert string backend values to atoms (e.g., "local" -> :local, "bwrap" -> :bwrap)
  defp normalize_agent_backends(%{agents: agents} = config) when is_list(agents) do
    normalized_agents = Enum.map(agents, &normalize_agent_backend/1)
    %{config | agents: normalized_agents}
  end

  defp normalize_agent_backends(config), do: config

  defp normalize_agent_backend(%{backend: backend} = agent) when is_binary(backend) do
    %{agent | backend: String.to_atom(backend)}
  end

  defp normalize_agent_backend(agent), do: agent

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value

  defp deep_atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), deep_atomize_keys(v)}
      {k, v} when is_atom(k) -> {k, deep_atomize_keys(v)}
      {k, v} -> {k, deep_atomize_keys(v)}
    end)
  end

  defp deep_atomize_keys(list) when is_list(list) do
    Enum.map(list, &deep_atomize_keys/1)
  end

  defp deep_atomize_keys({a, b}), do: {deep_atomize_keys(a), deep_atomize_keys(b)}
  defp deep_atomize_keys(value), do: value
end
