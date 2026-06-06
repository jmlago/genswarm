defmodule GenswarmsWeb.SkillsController do
  @moduledoc """
  REST API controller for skill management.
  """

  use GenswarmsWeb, :controller

  @doc """
  Lists all available skills.

  GET /api/skills
  Query params:
    - path: Optional base path to search for skills (defaults to priv/skills)
  """
  def index(conn, params) do
    root = get_default_skills_path()

    # The optional `path` is attacker-controlled. Resolve it strictly inside the
    # skills root so it can't enumerate the host filesystem (e.g. ?path=/ or
    # ?path=../../etc), and never echo absolute host paths back.
    case resolve_within(root, params["path"]) do
      {:ok, dir} ->
        skills = if File.dir?(dir), do: list_skills_recursive(root, dir), else: []

        json(conn, %{
          skills: skills,
          base_path: relative_within(dir, root),
          count: length(skills)
        })

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid path"})
    end
  end

  @doc """
  Gets a specific skill by name.

  GET /api/skills/:name
  """
  def show(conn, %{"name" => name}) do
    # `name` is a URL segment and can contain "/" (via %2F); find_skill joins it
    # onto base_path and reads the result, so an unguarded name is an arbitrary
    # host file read (e.g. ..%2F..%2F..%2Fetc%2Fpasswd). Require a single plain
    # filename, and don't echo the absolute host path.
    if safe_skill_name?(name) do
      case find_skill(get_default_skills_path(), name) do
        nil ->
          conn |> put_status(:not_found) |> json(%{error: "Skill not found"})

        skill_path ->
          case File.read(skill_path) do
            {:ok, content} ->
              json(conn, %{name: name, content: content, size: byte_size(content)})

            {:error, reason} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{error: "Failed to read skill: #{inspect(reason)}"})
          end
      end
    else
      conn |> put_status(:bad_request) |> json(%{error: "Invalid skill name"})
    end
  end

  # A skill name from the API must be a single plain filename — no directory
  # components, traversal, or null bytes — so it cannot escape the skills root.
  defp safe_skill_name?(name) when is_binary(name) do
    name != "" and
      name not in [".", ".."] and
      not String.contains?(name, ["/", "\\", "\0"]) and
      Path.basename(name) == name
  end

  defp safe_skill_name?(_), do: false

  # Private helpers

  defp get_default_skills_path do
    Application.get_env(:genswarms, :skills_dir, "priv/skills")
    |> Path.expand()
  end

  # Resolves a client-supplied subpath strictly within `root`. nil/blank → root.
  # Absolute paths and `..` traversal that escape `root` are rejected. Lexical
  # (prefix-safe) containment, like the config_path guard.
  defp resolve_within(root, nil), do: {:ok, root}
  defp resolve_within(root, ""), do: {:ok, root}

  defp resolve_within(root, sub) when is_binary(sub) do
    candidate = Path.expand(sub, root)

    if candidate == root or String.starts_with?(candidate, root <> "/") do
      {:ok, candidate}
    else
      :error
    end
  end

  defp resolve_within(_root, _), do: :error

  # The directory relative to the skills root, for echoing back without leaking
  # the absolute host path. The root itself reports as ".".
  defp relative_within(root, root), do: "."
  defp relative_within(dir, root), do: Path.relative_to(dir, root)

  defp list_skills_recursive(base_path, current_path) do
    case File.ls(current_path) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          full_path = Path.join(current_path, entry)

          cond do
            File.dir?(full_path) ->
              list_skills_recursive(base_path, full_path)

            String.ends_with?(entry, ".md") ->
              relative_path = Path.relative_to(full_path, base_path)

              # Note: no absolute `full_path` is exposed — only the skill name and
              # its path relative to the skills root.
              [
                %{
                  name: entry,
                  relative_path: relative_path,
                  category: get_category(relative_path)
                }
              ]

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp get_category(relative_path) do
    case Path.dirname(relative_path) do
      "." -> "default"
      dir -> dir
    end
  end

  defp find_skill(base_path, name) do
    # Try exact path first
    exact_path = Path.join(base_path, name)

    cond do
      File.exists?(exact_path) ->
        exact_path

      File.exists?(exact_path <> ".md") ->
        exact_path <> ".md"

      true ->
        # Search recursively
        find_skill_recursive(base_path, name)
    end
  end

  defp find_skill_recursive(current_path, name) do
    case File.ls(current_path) do
      {:ok, entries} ->
        Enum.find_value(entries, fn entry ->
          full_path = Path.join(current_path, entry)

          cond do
            File.dir?(full_path) ->
              find_skill_recursive(full_path, name)

            entry == name or entry == name <> ".md" ->
              full_path

            true ->
              nil
          end
        end)

      {:error, _} ->
        nil
    end
  end
end
