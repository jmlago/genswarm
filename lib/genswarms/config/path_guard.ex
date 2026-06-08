defmodule Genswarms.Config.PathGuard do
  @moduledoc """
  Containment guard for request-supplied swarm config paths.

  `POST /api/swarms` accepts a `config_path` that the server then loads — and for
  `.exs` configs, evaluates as code. Without restriction an API caller could make
  the server read/evaluate any file on the host (`/etc/...`, `~/.ssh/...`, any
  stray `.exs`). The CLI is operator-run and trusted, so this guard is applied
  only at the HTTP boundary.

  A request path is accepted only if it resolves to a location **inside** the
  allowed directory (default: the server's working directory, i.e. the project
  root; override with `GENSWARMS_SWARM_CONFIG_DIR`). Absolute paths and `..`
  traversal that escape the directory are rejected. The check is lexical (it does
  not chase symlinks out of the directory).
  """

  @type result :: {:ok, String.t()} | {:error, :invalid_path | :outside_allowed_dir}

  @doc """
  Resolves `path` against the allowed directory and returns the absolute path if
  it stays within it, otherwise an error.
  """
  @spec safe_config_path(term()) :: result()
  def safe_config_path(path) when is_binary(path) and path != "" do
    base = allowed_dir()
    candidate = Path.expand(path, base)

    if contained?(candidate, base) do
      {:ok, candidate}
    else
      {:error, :outside_allowed_dir}
    end
  end

  def safe_config_path(_), do: {:error, :invalid_path}

  @doc """
  The directory request-supplied config paths must stay within.
  """
  @spec allowed_dir() :: String.t()
  def allowed_dir do
    case Application.get_env(:genswarms, :swarm_config_dir) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> File.cwd!()
    end
  end

  # Lexical containment: candidate is the base itself or sits beneath it.
  defp contained?(candidate, base) do
    candidate == base or String.starts_with?(candidate, base <> "/")
  end
end
