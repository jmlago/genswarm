defmodule GenswarmsWeb.ConfigController do
  @moduledoc """
  REST API controller for configuration validation and management.
  """

  use GenswarmsWeb, :controller

  alias Genswarms.Config.{Loader, SwarmConfig}

  @doc """
  Validates a swarm configuration.

  POST /api/config/validate
  Body: { "config": { ... } } or { "config_path": "path/to/config.exs" }

  Returns validation result with any errors found.
  """
  def validate(conn, %{"config" => config}) when is_map(config) do
    case SwarmConfig.parse(config) do
      {:ok, parsed} ->
        json(conn, %{
          valid: true,
          config: summarize_config(parsed)
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          valid: false,
          errors: format_validation_errors(reason)
        })
    end
  end

  def validate(conn, %{"config_path" => path}) do
    expanded_path = Path.expand(path)

    unless File.exists?(expanded_path) do
      conn
      |> put_status(:not_found)
      |> json(%{
        valid: false,
        errors: ["File not found: #{path}"]
      })
    else
      case Loader.load(expanded_path) do
        {:ok, parsed} ->
          json(conn, %{
            valid: true,
            config_path: expanded_path,
            config: summarize_config(parsed)
          })

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{
            valid: false,
            config_path: expanded_path,
            errors: format_validation_errors(reason)
          })
      end
    end
  end

  def validate(conn, %{"content" => content, "format" => format}) do
    # Only data formats are accepted as request content. Executable .exs is never
    # evaluated from a request body (that would be RCE); load trusted .exs via
    # config_path on the server instead.
    case normalize_content_format(format) do
      {:ok, format_atom} ->
        case Loader.load_string(content, format_atom) do
          {:ok, parsed} ->
            json(conn, %{valid: true, format: format, config: summarize_config(parsed)})

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{valid: false, format: format, errors: format_validation_errors(reason)})
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          valid: false,
          format: format,
          errors: [
            "Unsupported content format '#{format}'. Use 'json' or 'yaml'. " <>
              "Executable .exs configs are not accepted as request content; " <>
              "load a trusted .exs file via 'config_path' on the server instead."
          ]
        })
    end
  end

  def validate(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Missing 'config', 'config_path', or 'content' parameter",
      usage: %{
        config: "JSON object with swarm configuration",
        config_path: "Path to a .exs, .json, or .yaml config file",
        content: "Raw config string (requires 'format' param: exs, json, yaml)"
      }
    })
  end

  # Private helpers

  # Request content may only be data formats; .exs (executable) is rejected.
  defp normalize_content_format("json"), do: {:ok, :json}
  defp normalize_content_format("yaml"), do: {:ok, :yaml}
  defp normalize_content_format("yml"), do: {:ok, :yaml}
  defp normalize_content_format(_), do: :error

  defp summarize_config(config) do
    %{
      name: config.name,
      agent_count: length(config.agents),
      object_count: length(config.objects || []),
      topology_edges: length(config.topology),
      agents:
        Enum.map(config.agents, fn a ->
          %{
            name: a.name,
            backend: format_backend(a.backend),
            skills: Map.get(a, :skills, []),
            model: Map.get(a, :model)
          }
        end),
      objects:
        Enum.map(config.objects || [], fn o ->
          %{
            name: o.name,
            handler: inspect(Map.get(o, :handler))
          }
        end),
      topology:
        Enum.map(config.topology, fn {from, to} ->
          %{from: from, to: to}
        end)
    }
  end

  defp format_backend(:local), do: "local"
  defp format_backend({:docker, image}), do: "docker:#{image}"
  defp format_backend({:docker, image, _}), do: "docker:#{image}"
  defp format_backend({:ssh, host}), do: "ssh:#{host}"
  defp format_backend({:ssh, host, _}), do: "ssh:#{host}"
  defp format_backend(other), do: inspect(other)

  defp format_validation_errors({:missing_field, field}) do
    ["Missing required field: #{field}"]
  end

  defp format_validation_errors({:invalid_field, field, reason}) do
    ["Invalid field '#{field}': #{inspect(reason)}"]
  end

  defp format_validation_errors({:invalid_topology, errors}) when is_list(errors) do
    ["Invalid topology: #{inspect(errors)}"]
  end

  defp format_validation_errors({:eval_error, exception}) do
    ["Config evaluation error: #{Exception.message(exception)}"]
  end

  defp format_validation_errors({:file_not_found, path}) do
    ["File not found: #{path}"]
  end

  defp format_validation_errors({:unsupported_format, ext}) do
    ["Unsupported file format: #{ext}"]
  end

  defp format_validation_errors(:exs_string_not_supported) do
    ["Executable .exs configs are not accepted as request content; use json/yaml or a server-side config_path."]
  end

  defp format_validation_errors(reason) when is_binary(reason) do
    [reason]
  end

  defp format_validation_errors(reason) do
    [inspect(reason)]
  end
end
