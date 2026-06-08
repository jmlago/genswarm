defmodule Genswarms.Backends.BwrapBackend do
  @moduledoc """
  Bubblewrap (bwrap) backend for lightweight agent sandboxing.

  Enables scaling to 10k+ agents on a single NixOS machine by using
  bubblewrap for process isolation instead of Docker containers.

  ## Resource Comparison

  | Metric | Docker | Bwrap |
  |--------|--------|-------|
  | RAM per agent | ~50MB | ~500KB |
  | Startup time | 2-3s | ~50ms |
  | External daemon | Yes (SPOF) | No |
  | 10k agents RAM | ~500GB | ~5GB |

  ## Usage in Swarm Config

      %{
        name: :researcher,
        backend: :bwrap,  # Use defaults
        skills: ["web.md"]
      }

      %{
        name: :coder,
        backend: {:bwrap, %{memory_limit: "256M", presets: [:base, :code]}},
        skills: ["code.md"]
      }

  ## Requirements

  - NixOS with bubblewrap and fuse-overlayfs installed
  - User namespaces enabled (kernel.unprivileged_userns_clone = 1)
  - Pre-built sandbox base layers (via nix build .#sandboxBase-*)
  """

  @behaviour Genswarms.Backends.BackendBehaviour

  alias Genswarms.Backends.Bwrap.{OverlayManager, CgroupManager, AgentTelemetry}
  alias Genswarms.Backends.EgressGuard
  alias Genswarms.Observability.LogStore

  defstruct [
    :port,
    :name,
    :sandbox_id,
    :overlay_dir,
    :cgroup_path,
    :skills_dir,
    :scope_name,
    :egress,
    :buffer
  ]

  @type t :: %__MODULE__{
          port: port() | nil,
          name: String.t(),
          sandbox_id: String.t(),
          overlay_dir: String.t(),
          cgroup_path: String.t() | nil,
          skills_dir: String.t() | nil,
          scope_name: String.t() | nil,
          egress: Genswarms.Backends.EgressGuard.t() | nil,
          buffer: binary()
        }

  # Default resource limits
  @default_memory_limit "256M"
  @default_cpu_shares 100
  @default_tasks_max 50

  @impl true
  def backend_type, do: :bwrap

  @impl true
  def start(name, config) do
    swarm_name = Map.get(config, :swarm_name, "default")
    sandbox_id = generate_sandbox_id(swarm_name, name)
    skills_dir = Map.get(config, :skills_dir)
    presets = Map.get(config, :presets, [:base])

    workspace =
      Map.get(config, :workspace, "/tmp/szc-workspace/#{sandbox_id}")
      |> Path.expand()

    # Ensure workspace exists
    File.mkdir_p!(workspace)

    # Setup overlay filesystem
    case OverlayManager.setup_overlay(sandbox_id, presets) do
      {:ok, overlay_dir} ->
        # Copy DNS config to overlay's upper layer (required for network access)
        setup_dns_config(overlay_dir)

        # Create cgroup scope for resource limits
        memory_limit = Map.get(config, :memory_limit, @default_memory_limit)
        cpu_shares = Map.get(config, :cpu_shares, @default_cpu_shares)
        tasks_max = Map.get(config, :tasks_max, @default_tasks_max)

        cgroup_opts = %{
          memory_max: memory_limit,
          cpu_shares: cpu_shares,
          tasks_max: tasks_max
        }

        # Build bwrap command
        bwrap_cmd =
          build_bwrap_command(
            sandbox_id,
            overlay_dir,
            skills_dir,
            workspace,
            presets,
            config
          )

        # Wrap with systemd-run for cgroup isolation
        {full_cmd, scope_name} = CgroupManager.create_scope(sandbox_id, bwrap_cmd, cgroup_opts)

        port_opts = [
          :binary,
          :exit_status,
          {:line, 16_384},
          {:env, build_env(name, config)},
          :use_stdio,
          :stderr_to_stdout
        ]

        # Network isolation: start the egress forwarder (and write the sandbox
        # .curlrc) before the sandbox so the LLM socket is ready on first call.
        egress_result =
          if EgressGuard.isolated?(config) do
            EgressGuard.start_forwarder(workspace, config)
          else
            {:ok, nil}
          end

        with {:ok, egress} <- egress_result do
          try do
            port = Port.open({:spawn, full_cmd}, port_opts)

            ref = %__MODULE__{
              port: port,
              name: name,
              sandbox_id: sandbox_id,
              overlay_dir: overlay_dir,
              cgroup_path: CgroupManager.get_cgroup_path(scope_name),
              skills_dir: skills_dir,
              scope_name: scope_name,
              egress: egress,
              buffer: ""
            }

            # Log to telemetry instead of Logger at scale
            AgentTelemetry.log_event(sandbox_id, :started, %{
              presets: presets,
              memory_limit: memory_limit
            })

            LogStore.log(:info, :backend, :bwrap_start, "Started bwrap sandbox #{sandbox_id}",
              swarm: swarm_name,
              agent: String.to_atom(name),
              metadata: %{sandbox_id: sandbox_id, presets: presets}
            )

            {:ok, ref}
          rescue
            e ->
              # Cleanup on failure
              EgressGuard.stop_forwarder(egress)
              OverlayManager.cleanup_overlay(sandbox_id)
              CgroupManager.kill_scope(scope_name)

              LogStore.log(
                :error,
                :backend,
                :bwrap_start_failed,
                "Failed to start bwrap: #{inspect(e)}",
                swarm: swarm_name,
                agent: String.to_atom(name),
                metadata: %{sandbox_id: sandbox_id, error: inspect(e)}
              )

              {:error, {:start_failed, e}}
          end
        else
          {:error, reason} ->
            # Egress forwarder failed to start; tear down the overlay/scope so we
            # never run an "isolated" agent that actually has no network at all.
            OverlayManager.cleanup_overlay(sandbox_id)
            CgroupManager.kill_scope(scope_name)

            LogStore.log(
              :error,
              :backend,
              :bwrap_egress_failed,
              "Failed to start egress forwarder: #{inspect(reason)}",
              swarm: swarm_name,
              agent: String.to_atom(name),
              metadata: %{sandbox_id: sandbox_id, reason: inspect(reason)}
            )

            {:error, {:egress_failed, reason}}
        end

      {:error, reason} ->
        LogStore.log(
          :error,
          :backend,
          :overlay_setup_failed,
          "Failed to setup overlay: #{inspect(reason)}",
          swarm: swarm_name,
          agent: String.to_atom(name),
          metadata: %{sandbox_id: sandbox_id, reason: inspect(reason)}
        )

        {:error, {:overlay_setup_failed, reason}}
    end
  end

  @impl true
  def stop(%__MODULE__{
        port: port,
        sandbox_id: sandbox_id,
        scope_name: scope_name,
        egress: egress,
        name: name
      }) do
    AgentTelemetry.log_event(sandbox_id, :stopping, %{})

    # Close the port
    if port do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    # Stop the egress forwarder (isolated agents) and remove its socket
    EgressGuard.stop_forwarder(egress)

    # Kill the cgroup scope (terminates all processes)
    if scope_name do
      CgroupManager.kill_scope(scope_name)
    end

    # Cleanup overlay filesystem
    OverlayManager.cleanup_overlay(sandbox_id)

    AgentTelemetry.log_event(sandbox_id, :stopped, %{})

    LogStore.log(:info, :backend, :bwrap_stop, "Stopped bwrap sandbox #{sandbox_id}",
      agent: String.to_atom(name),
      metadata: %{sandbox_id: sandbox_id}
    )

    :ok
  end

  @impl true
  def send_input(%__MODULE__{port: port}, message) when is_binary(message) do
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
    # Skills are bind-mounted read-only, updating requires restart
    # or re-mounting (not implemented for simplicity)
    {:ok, %{ref | skills_dir: skills_dir}}
  end

  @impl true
  def health_check(%__MODULE__{port: port, scope_name: scope_name}) do
    port_alive =
      case Port.info(port) do
        nil -> false
        info when is_list(info) -> true
      end

    scope_alive = scope_name && CgroupManager.scope_active?(scope_name)

    cond do
      not port_alive -> {:error, :port_closed}
      scope_name && not scope_alive -> {:error, :scope_dead}
      true -> :ok
    end
  end

  @impl true
  def handle_output(%__MODULE__{buffer: buffer, sandbox_id: sandbox_id}, data) do
    combined = buffer <> data
    {messages, remaining} = parse_json_lines(combined)

    # Log to telemetry ring buffer instead of Logger
    Enum.each(messages, fn msg ->
      AgentTelemetry.log_output(sandbox_id, msg)
    end)

    {:ok, messages, remaining}
  end

  # Private functions

  defp generate_sandbox_id(swarm_name, agent_name) do
    timestamp = System.system_time(:millisecond)
    "#{swarm_name}-#{agent_name}-#{timestamp}"
  end

  defp setup_dns_config(overlay_dir) do
    # Copy DNS configuration files to the overlay's upper layer
    # This is required because the sandbox base /etc is read-only
    upper_etc = Path.join([overlay_dir, "upper", "etc"])
    File.mkdir_p!(upper_etc)

    # Copy resolv.conf for DNS resolution
    if File.exists?("/etc/resolv.conf") do
      File.cp!("/etc/resolv.conf", Path.join(upper_etc, "resolv.conf"))
    end

    # Copy hosts file for local hostname resolution
    if File.exists?("/etc/hosts") do
      File.cp!("/etc/hosts", Path.join(upper_etc, "hosts"))
    end

    :ok
  end

  defp build_bwrap_command(sandbox_id, overlay_dir, skills_dir, workspace, _presets, config) do
    subzeroclaw_binary = find_subzeroclaw_binary(config)
    wrapper_path = find_wrapper_path()
    name = Map.get(config, :name, sandbox_id)

    # Use full path for bwrap (required for Port.open which uses /bin/sh)
    bwrap_path = find_executable("bwrap")

    # Get environment variables to pass to sandbox
    api_key = Map.get(config, :api_key) || System.get_env("SUBZEROCLAW_API_KEY")
    model = Map.get(config, :model) || System.get_env("SUBZEROCLAW_MODEL")
    endpoint = Map.get(config, :endpoint) || System.get_env("SUBZEROCLAW_ENDPOINT")
    mock_script = Map.get(config, :mock_script) || System.get_env("SUBZEROCLAW_MOCK_SCRIPT")
    # If recording enabled, always write to workspace inside bwrap
    record_script =
      case System.get_env("SUBZEROCLAW_RECORD_SCRIPT") do
        nil -> nil
        _ -> "/workspace/.recorded_responses.json"
      end

    # Derive logs directory from skills directory (sibling directory)
    logs_dir =
      if skills_dir do
        logs_path = skills_dir |> Path.dirname() |> Path.join("logs")
        File.mkdir_p!(logs_path)
        logs_path
      else
        nil
      end

    # Core bwrap arguments
    # ORDER MATTERS: overlay as root first, then other mounts on top
    args =
      [
        bwrap_path,
        # User namespace isolation
        "--unshare-user",
        "--unshare-pid",
        "--unshare-uts",
        "--unshare-ipc",
        "--uid",
        "1000",
        "--gid",
        "1000",

        # Overlay merged directory as root (MUST be first)
        "--bind",
        Path.join(overlay_dir, "merged"),
        "/",

        # Nix store read-only (required for symlinks in /bin to resolve)
        "--ro-bind",
        "/nix/store",
        "/nix/store",

        # Skills directory (if provided) - read-only
        # Subzeroclaw reads from $HOME/.subzeroclaw/skills
        skills_dir && "--ro-bind",
        skills_dir && skills_dir,
        skills_dir && "/root/.subzeroclaw/skills",

        # Logs directory - writable for subzeroclaw to write conversation logs
        # Subzeroclaw writes to $HOME/.subzeroclaw/logs/ so we bind mount there
        logs_dir && "--bind",
        logs_dir && logs_dir,
        logs_dir && "/root/.subzeroclaw/logs",

        # Workspace for agent to write files
        "--bind",
        workspace,
        "/workspace",

        # Mount subzeroclaw binary into sandbox at /usr/local/bin
        subzeroclaw_binary && "--ro-bind",
        subzeroclaw_binary && subzeroclaw_binary,
        subzeroclaw_binary && "/usr/local/bin/subzeroclaw",

        # Mount the real szc-wrapper script (with JSON protocol translation)
        wrapper_path && "--ro-bind",
        wrapper_path && wrapper_path,
        wrapper_path && "/usr/local/bin/szc-wrapper"
      ]
      |> Enum.filter(&(&1 != nil))

    # Extra read-only bind mounts from config (e.g., project dirs, tool installations)
    extra_ro_binds = Map.get(config, :extra_ro_binds, [])

    extra_bind_args =
      Enum.flat_map(extra_ro_binds, fn {host_path, container_path} ->
        if File.exists?(host_path) do
          ["--ro-bind", Path.expand(host_path), container_path]
        else
          []
        end
      end)

    # Build PATH with optional extra directories
    extra_path = Map.get(config, :extra_path, [])
    base_path = "/bin:/usr/local/bin"

    path_value =
      case extra_path do
        [] -> base_path
        dirs -> Enum.join(dirs, ":") <> ":" <> base_path
      end

    rest_args =
      [
        # Essential virtual filesystems
        "--tmpfs",
        "/tmp",
        "--dev",
        "/dev",
        "--proc",
        "/proc",

        # Provide /usr/bin/env so shebangs like `#!/usr/bin/env bash` work.
        # The base layer ships env at /bin/env; this symlink makes the standard
        # POSIX path resolve to it.
        "--symlink",
        "/bin/env",
        "/usr/bin/env",

        # Hostname
        "--hostname",
        sandbox_id,

        # Die when parent dies (prevents orphan processes)
        "--die-with-parent",

        # Set working directory
        "--chdir",
        "/workspace",

        # Set environment inside sandbox
        "--setenv",
        "PATH",
        path_value,
        "--setenv",
        "HOME",
        "/root",
        "--setenv",
        "TERM",
        "xterm-256color",
        "--setenv",
        "SSL_CERT_FILE",
        "/etc/ssl/certs/ca-bundle.crt",
        "--setenv",
        "SUBZEROCLAW_AGENT_NAME",
        to_string(name),

        # Logs directory env var for subzeroclaw
        logs_dir && "--setenv",
        logs_dir && "SUBZEROCLAW_LOGS",
        logs_dir && "/logs",

        # Mock script (if set, subzeroclaw skips API calls)
        mock_script && "--setenv",
        mock_script && "SUBZEROCLAW_MOCK_SCRIPT",
        mock_script && mock_script,

        # Record script (if set, subzeroclaw saves API responses for later replay)
        record_script && "--setenv",
        record_script && "SUBZEROCLAW_RECORD_SCRIPT",
        record_script && "/workspace/.recorded_responses.json",

        # API key (required for subzeroclaw unless mock mode)
        api_key && "--setenv",
        api_key && "SUBZEROCLAW_API_KEY",
        api_key && api_key,

        # Model (optional)
        model && "--setenv",
        model && "SUBZEROCLAW_MODEL",
        model && model,

        # Endpoint (optional)
        endpoint && "--setenv",
        endpoint && "SUBZEROCLAW_ENDPOINT",
        endpoint && endpoint
      ]
      |> Enum.filter(&(&1 != nil))

    # Extra environment variables from config (e.g., TARGET_DESCRIPTION)
    extra_env = Map.get(config, :extra_env, %{})

    extra_env_args =
      Enum.flat_map(extra_env, fn {key, value} ->
        if value do
          ["--setenv", to_string(key), to_string(value)]
        else
          []
        end
      end)

    cmd_args =
      [
        # Command to run - use bind-mounted szc-wrapper (with JSON protocol translation)
        # szc-wrapper is at /usr/local/bin/szc-wrapper (bind-mounted from priv/)
        # subzeroclaw is at /usr/local/bin/subzeroclaw (bind-mounted)
        "--",
        "/usr/local/bin/szc-wrapper",
        sandbox_id,
        "/usr/local/bin/subzeroclaw",
        # Skills are mounted to $HOME/.subzeroclaw/skills, pass that path
        if(skills_dir, do: "/root/.subzeroclaw/skills", else: "")
      ]
      |> Enum.filter(&(&1 != nil))

    # Network isolation (network: :isolated): drop the network namespace and
    # point the agent's curl at the bind-mounted egress socket via CURL_HOME.
    net_args = EgressGuard.bwrap_net_args(config)

    curl_env_args =
      if EgressGuard.isolated?(config) do
        ["--setenv", "CURL_HOME", "/workspace"]
      else
        []
      end

    (args ++
       net_args ++ extra_bind_args ++ rest_args ++ curl_env_args ++ extra_env_args ++ cmd_args)
    |> Enum.join(" ")
  end

  defp build_env(name, config) do
    base_env = [
      {~c"SUBZEROCLAW_AGENT_NAME", String.to_charlist(name)},
      {~c"HOME", ~c"/root"},
      {~c"PATH", ~c"/nix/base/bin:/usr/bin:/bin"},
      {~c"SSL_CERT_FILE", ~c"/nix/store/cacert/etc/ssl/certs/ca-bundle.crt"}
    ]

    api_key_env =
      case Map.get(config, :api_key) || System.get_env("SUBZEROCLAW_API_KEY") do
        nil -> []
        key -> [{~c"SUBZEROCLAW_API_KEY", String.to_charlist(key)}]
      end

    model_env =
      case Map.get(config, :model) || System.get_env("SUBZEROCLAW_MODEL") do
        nil -> []
        model -> [{~c"SUBZEROCLAW_MODEL", String.to_charlist(model)}]
      end

    endpoint_env =
      case Map.get(config, :endpoint) || System.get_env("SUBZEROCLAW_ENDPOINT") do
        nil -> []
        endpoint -> [{~c"SUBZEROCLAW_ENDPOINT", String.to_charlist(endpoint)}]
      end

    topology_env =
      case Map.get(config, :connections, []) do
        [] ->
          []

        connections ->
          topology_str = connections |> Enum.map(&to_string/1) |> Enum.join(",")
          [{~c"SWARM_TOPOLOGY", String.to_charlist(topology_str)}]
      end

    base_env ++ api_key_env ++ model_env ++ endpoint_env ++ topology_env
  end

  defp find_subzeroclaw_binary(config) do
    # Check explicit config first
    explicit_path =
      Map.get(config, :subzeroclaw_path) ||
        Application.get_env(:genswarms, :subzeroclaw_path)

    if explicit_path && File.exists?(explicit_path) do
      explicit_path
    else
      # Search common locations — check both CWD siblings and source repo siblings
      swarm_src = Path.expand("../..", :code.priv_dir(:genswarms) |> to_string())

      search_paths =
        [
          # Sibling to CWD (when running from the swarm repo directly)
          Path.expand("../subzeroclaw/subzeroclaw", File.cwd!()),
          # Sibling to genswarms source (when running from a dependency)
          Path.expand("../subzeroclaw/subzeroclaw", swarm_src),
          # Environment variable
          System.get_env("SUBZEROCLAW_PATH"),
          # In PATH
          find_in_path("subzeroclaw")
        ]
        |> Enum.filter(&(&1 != nil))

      Enum.find(search_paths, fn path ->
        File.exists?(path) && File.stat!(path).type == :regular
      end)
    end
  end

  defp find_in_path(binary_name) do
    case System.cmd("which", [binary_name], stderr_to_stdout: true) do
      {path, 0} -> String.trim(path)
      _ -> nil
    end
  end

  defp find_wrapper_path do
    # Find the szc-wrapper script — use :code.priv_dir which resolves correctly
    # even when genswarms is a transitive dependency
    search_paths = [
      Path.join(:code.priv_dir(:genswarms), "szc-wrapper-fifo.sh"),
      Path.join(:code.priv_dir(:genswarms), "szc-wrapper.sh")
    ]

    Enum.find(search_paths, &File.exists?/1)
  end

  defp find_executable(name) do
    # Check common NixOS paths first, then fall back to name
    paths = [
      "/run/current-system/sw/bin/#{name}",
      "/usr/bin/#{name}",
      "/bin/#{name}"
    ]

    Enum.find(paths, name, &File.exists?/1)
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
