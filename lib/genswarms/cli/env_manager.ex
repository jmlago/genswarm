defmodule Genswarms.CLI.EnvManager do
  @moduledoc """
  Manages .env files for environment variable configuration.

  Supports:
  - Parsing .env files (KEY=VALUE format)
  - Loading .env files into system environment
  - Listing, getting, and setting variables
  - Automatic .env discovery and loading
  """

  require Logger

  @default_env_file ".env"
  @example_env_file ".env.example"

  # Files that mark a project root; auto-discovery never searches above the
  # first ancestor containing one of these, so it can't pick up an unrelated
  # parent/home .env (audit finding 35).
  @project_root_markers ["mix.exs", ".genswarms"]

  @doc """
  Loads environment variables from a .env file.
  Returns {:ok, count} or {:error, reason}.
  """
  @spec load(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load(path \\ @default_env_file) do
    expanded_path = Path.expand(path)

    if File.exists?(expanded_path) do
      case parse_file(expanded_path) do
        {:ok, vars} ->
          # Do not overwrite variables already present in the environment — an
          # explicit shell export / process env wins over the .env file
          # (standard dotenv behavior; avoids a stray .env shadowing real config).
          applied =
            Enum.count(vars, fn {key, value} ->
              if System.get_env(key) == nil do
                System.put_env(key, value)
                true
              else
                false
              end
            end)

          {:ok, applied}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Loads .env from the current directory or parent directories.
  Searches up to 5 levels up from the given directory.
  """
  @spec auto_load(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def auto_load(start_dir \\ File.cwd!()) do
    case find_env_file(start_dir, 5) do
      {:ok, path} ->
        case load(path) do
          {:ok, count} ->
            # Log which .env was loaded so an unintended path is visible.
            Logger.info("Loaded #{count} env var(s) from #{path}")
            {:ok, path}

          {:error, _reason} ->
            {:error, :not_found}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Finds a .env file starting from dir and searching up.
  """
  @spec find_env_file(String.t(), non_neg_integer()) :: {:ok, String.t()} | :not_found
  def find_env_file(_dir, 0), do: :not_found

  def find_env_file(dir, levels_remaining) do
    env_path = Path.join(dir, @default_env_file)

    cond do
      File.exists?(env_path) ->
        {:ok, env_path}

      # Stop at the project root — never load a .env from above it.
      project_root?(dir) ->
        :not_found

      true ->
        parent = Path.dirname(dir)

        if parent == dir do
          # Reached filesystem root
          :not_found
        else
          find_env_file(parent, levels_remaining - 1)
        end
    end
  end

  defp project_root?(dir) do
    Enum.any?(@project_root_markers, fn marker -> File.exists?(Path.join(dir, marker)) end)
  end

  @doc """
  Parses a .env file and returns a map of key-value pairs.
  """
  @spec parse_file(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} ->
        vars = parse_content(content)
        {:ok, vars}

      {:error, reason} ->
        {:error, {:read_error, reason}}
    end
  end

  @doc """
  Parses .env content string into a map.
  """
  @spec parse_content(String.t()) :: map()
  def parse_content(content) do
    content
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_line(line) do
        {:ok, key, value} -> Map.put(acc, key, value)
        :skip -> acc
      end
    end)
  end

  @doc """
  Parses a single line from a .env file.
  """
  @spec parse_line(String.t()) :: {:ok, String.t(), String.t()} | :skip
  def parse_line(line) do
    trimmed = String.trim(line)

    cond do
      # Empty line
      trimmed == "" ->
        :skip

      # Comment
      String.starts_with?(trimmed, "#") ->
        :skip

      # Key=Value (with optional 'export ' prefix)
      String.contains?(trimmed, "=") ->
        # Remove 'export ' prefix if present
        trimmed = String.replace_prefix(trimmed, "export ", "")

        [key | rest] = String.split(trimmed, "=", parts: 2)
        value = Enum.join(rest, "=")

        key = String.trim(key)
        value = value |> String.trim() |> unquote_value()

        if valid_key?(key) do
          {:ok, key, value}
        else
          :skip
        end

      true ->
        :skip
    end
  end

  @doc """
  Lists all variables from a .env file.
  Returns a list of {key, value} tuples.
  """
  @spec list(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def list(path \\ @default_env_file) do
    expanded_path = Path.expand(path)

    case parse_file(expanded_path) do
      {:ok, vars} ->
        sorted = vars |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))
        {:ok, sorted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a variable from a .env file.
  """
  @spec get(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def get(key, path \\ @default_env_file) do
    case parse_file(Path.expand(path)) do
      {:ok, vars} ->
        case Map.get(vars, key) do
          nil -> {:error, :not_found}
          value -> {:ok, value}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sets a variable in a .env file.
  Creates the file if it doesn't exist.
  """
  @spec set(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set(key, value, path \\ @default_env_file) do
    expanded_path = Path.expand(path)

    unless valid_key?(key) do
      {:error, :invalid_key}
    else
      # Read existing content
      existing =
        if File.exists?(expanded_path) do
          case File.read(expanded_path) do
            {:ok, content} -> content
            {:error, _} -> ""
          end
        else
          ""
        end

      # Update or append
      new_content = update_or_append(existing, key, value)

      case File.write(expanded_path, new_content) do
        :ok ->
          # Also set in current environment
          System.put_env(key, value)
          :ok

        {:error, reason} ->
          {:error, {:write_error, reason}}
      end
    end
  end

  @doc """
  Removes a variable from a .env file.
  """
  @spec unset(String.t(), String.t()) :: :ok | {:error, term()}
  def unset(key, path \\ @default_env_file) do
    expanded_path = Path.expand(path)

    if File.exists?(expanded_path) do
      case File.read(expanded_path) do
        {:ok, content} ->
          new_content = remove_key(content, key)
          File.write(expanded_path, new_content)

        {:error, reason} ->
          {:error, {:read_error, reason}}
      end
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Creates a .env file from .env.example if it doesn't exist.
  """
  @spec init_from_example(String.t()) :: :ok | {:error, term()}
  def init_from_example(dir \\ ".") do
    env_path = Path.join(dir, @default_env_file)
    example_path = Path.join(dir, @example_env_file)

    cond do
      File.exists?(env_path) ->
        {:error, :already_exists}

      not File.exists?(example_path) ->
        {:error, :no_example}

      true ->
        File.cp(example_path, env_path)
    end
  end

  # Private functions

  defp valid_key?(key) do
    # Keys must start with a letter or underscore, contain only alphanumeric and underscore
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key)
  end

  defp unquote_value(value) do
    cond do
      # Double-quoted string
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value
        |> String.slice(1..-2//1)
        |> String.replace("\\n", "\n")
        |> String.replace("\\\"", "\"")

      # Single-quoted string (no escape processing)
      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        String.slice(value, 1..-2//1)

      # Unquoted value - strip inline comments
      true ->
        value
        |> String.split("#", parts: 2)
        |> List.first()
        |> String.trim()
    end
  end

  defp update_or_append(content, key, value) do
    lines = String.split(content, "\n")
    key_pattern = ~r/^#{Regex.escape(key)}\s*=/

    # Check if key exists
    key_exists? = Enum.any?(lines, &Regex.match?(key_pattern, &1))

    new_line = format_value(key, value)

    if key_exists? do
      # Replace existing line
      lines
      |> Enum.map(fn line ->
        if Regex.match?(key_pattern, line) do
          new_line
        else
          line
        end
      end)
      |> Enum.join("\n")
    else
      # Append new line
      content = String.trim_trailing(content)

      if content == "" do
        new_line <> "\n"
      else
        content <> "\n" <> new_line <> "\n"
      end
    end
  end

  defp remove_key(content, key) do
    key_pattern = ~r/^#{Regex.escape(key)}\s*=/

    content
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(key_pattern, &1))
    |> Enum.join("\n")
  end

  defp format_value(key, value) do
    # Quote values that contain special characters
    if needs_quoting?(value) do
      escaped = value |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")
      "#{key}=\"#{escaped}\""
    else
      "#{key}=#{value}"
    end
  end

  defp needs_quoting?(value) do
    String.contains?(value, [" ", "\t", "\n", "\"", "'", "#", "$", "\\"])
  end
end
