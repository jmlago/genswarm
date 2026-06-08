defmodule Genswarms.CLI.APIClient do
  @moduledoc """
  HTTP client for communicating with the running Phoenix server.

  When the server is running in background (`swarm up`), CLI commands
  use this client to interact with the server via its REST API.
  """

  @default_base_url "http://localhost:4000"

  @doc """
  Returns the base URL for the API.
  """
  def base_url do
    System.get_env("SWARM_API_URL") || @default_base_url
  end

  @doc """
  Checks if the server is running.
  """
  def server_running? do
    case request(:get, "/api/swarms") do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Lists all swarms.
  """
  def list_swarms do
    case request(:get, "/api/swarms") do
      {:ok, %{"swarms" => swarms}} -> {:ok, swarms}
      {:ok, swarms} when is_list(swarms) -> {:ok, swarms}
      error -> error
    end
  end

  @doc """
  Gets status of a specific swarm.
  """
  def get_swarm(name) do
    request(:get, "/api/swarms/#{name}")
  end

  @doc """
  Starts a swarm from a config file.
  """
  def start_swarm(config_path) do
    body = Jason.encode!(%{config_path: config_path})
    request(:post, "/api/swarms", body)
  end

  @doc """
  Stops a swarm.
  """
  def stop_swarm(name) do
    request(:delete, "/api/swarms/#{name}")
  end

  @doc """
  Sends a task to an agent.
  """
  def send_task(swarm_name, agent_name, task) do
    body = Jason.encode!(%{task: task})
    request(:post, "/api/swarms/#{swarm_name}/agents/#{agent_name}/task", body)
  end

  @doc """
  Sends a message between agents.
  """
  def send_message(swarm_name, from, to, content) do
    body = Jason.encode!(%{from: from, to: to, content: content})
    request(:post, "/api/swarms/#{swarm_name}/messages", body)
  end

  @doc """
  Gets the topology of a swarm.
  """
  def get_topology(swarm_name) do
    request(:get, "/api/swarms/#{swarm_name}/topology")
  end

  @doc """
  Gets events from the LogStore.
  """
  def get_events(opts \\ []) do
    query_string = build_query_string(opts)
    request(:get, "/api/events#{query_string}")
  end

  @doc """
  Gets events for a specific swarm.
  """
  def get_swarm_events(swarm_name, opts \\ []) do
    query_string = build_query_string(opts)
    request(:get, "/api/swarms/#{swarm_name}/events#{query_string}")
  end

  @doc """
  Gets events for a specific agent.
  """
  def get_agent_events(swarm_name, agent_name, opts \\ []) do
    query_string = build_query_string(opts)
    request(:get, "/api/swarms/#{swarm_name}/agents/#{agent_name}/events#{query_string}")
  end

  @doc """
  Makes a POST request to the given path with the given body.
  """
  def post(path, body) do
    encoded = if is_binary(body), do: body, else: Jason.encode!(body)
    request(:post, path, encoded)
  end

  defp build_query_string(opts) do
    params =
      opts
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
      |> Enum.join("&")

    if params == "", do: "", else: "?" <> params
  end

  # Private

  # Sends the API token (if configured) so the CLI works against an
  # authenticated server. Reads GENSWARMS_API_TOKEN — the same variable the
  # server reads — so local use without a token keeps working unchanged.
  defp auth_header do
    case System.get_env("GENSWARMS_API_TOKEN") do
      token when is_binary(token) and token != "" -> "Authorization: Bearer #{token}\r\n"
      _ -> ""
    end
  end

  # Simple socket-based HTTP client to avoid :httpc/:http_util issues
  defp request(method, path, body \\ nil) do
    uri = URI.parse(base_url() <> path)
    host = uri.host || "localhost"
    port = uri.port || 4000

    method_str = method |> to_string() |> String.upcase()
    body_str = body || ""

    request_line =
      "#{method_str} #{uri.path || "/"}#{if uri.query, do: "?#{uri.query}", else: ""} HTTP/1.1\r\n"

    headers =
      "Host: #{host}:#{port}\r\n" <>
        auth_header() <>
        "Content-Type: application/json\r\n" <>
        "Accept: application/json\r\n" <>
        "Content-Length: #{byte_size(body_str)}\r\n" <>
        "Connection: close\r\n" <>
        "\r\n"

    request_bytes = request_line <> headers <> body_str

    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, active: false, packet: :raw],
           10_000
         ) do
      {:ok, socket} ->
        :gen_tcp.send(socket, request_bytes)
        result = receive_response(socket, <<>>)
        :gen_tcp.close(socket)
        parse_http_response(result)

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp receive_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, data} ->
        receive_response(socket, acc <> data)

      {:error, :closed} ->
        acc

      {:error, :timeout} ->
        acc

      {:error, _reason} ->
        acc
    end
  end

  defp parse_http_response(response) do
    case String.split(response, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        status = parse_status_code(headers)

        if status in 200..299 do
          if body == "" do
            {:ok, %{}}
          else
            case Jason.decode(body) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, _} -> {:ok, body}
            end
          end
        else
          {:error, {:http_error, status, body}}
        end

      _ ->
        {:error, {:parse_error, "Invalid HTTP response"}}
    end
  end

  defp parse_status_code(headers) do
    case Regex.run(~r/HTTP\/[\d.]+\s+(\d+)/, headers) do
      [_, status_str] -> String.to_integer(status_str)
      _ -> 0
    end
  end
end
