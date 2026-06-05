defmodule GenswarmWeb.SkillsController do
  @moduledoc """
  REST API controller for skill management.
  """

  use GenswarmWeb, :controller

  @doc """
  Lists all available skills.

  GET /api/skills
  Query params:
    - path: Optional base path to search for skills (defaults to priv/skills)
  """
  def index(conn, params) do
    base_path = params["path"] || get_default_skills_path()

    skills =
      if File.dir?(base_path) do
        list_skills_recursive(base_path, base_path)
      else
        []
      end

    json(conn, %{
      skills: skills,
      base_path: base_path,
      count: length(skills)
    })
  end

  @doc """
  Gets a specific skill by name.

  GET /api/skills/:name
  """
  def show(conn, %{"name" => name}) do
    base_path = get_default_skills_path()
    skill_path = find_skill(base_path, name)

    case skill_path do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Skill not found"})

      path ->
        case File.read(path) do
          {:ok, content} ->
            json(conn, %{
              name: name,
              path: path,
              content: content,
              size: byte_size(content)
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to read skill: #{inspect(reason)}"})
        end
    end
  end

  # Private helpers

  defp get_default_skills_path do
    Application.get_env(:genswarm, :skills_dir, "priv/skills")
    |> Path.expand()
  end

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

              [
                %{
                  name: entry,
                  path: full_path,
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
