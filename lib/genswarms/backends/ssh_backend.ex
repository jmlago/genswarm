defmodule Genswarms.Backends.SSHBackend do
  @moduledoc """
  SSH backend for bare metal NixOS agents.

  Connects to remote NixOS machines that have been configured and deployed
  via Colmena with the agent module. The remote machine already has:
  - All required tools installed via NixOS configuration
  - Skills directory at /var/lib/subzeroclaw/skills
  - Subzeroclaw user and environment set up

  ## Deployment Flow

  1. Define agent in swarm config with SSH backend
  2. Generate Colmena config from swarm config
  3. Deploy NixOS config to remote machines: `colmena apply`
  4. Start orchestrator - it connects via SSH to pre-configured machines

  ## Usage

      %{
        name: :researcher,
        backend: {:ssh, "agent@192.168.1.51", %{
          key_path: "~/.ssh/id_ed25519",
          nixos: true  # Machine is NixOS, tools already installed
        }},
        presets: [:base, :web],  # Used by Colmena, not SSH backend
        skills: ["web.md"]
      }

  ## Non-NixOS Usage

  For non-NixOS machines, set `nixos: false` and ensure subzeroclaw
  and required tools are installed manually.
  """

  @behaviour Genswarms.Backends.BackendBehaviour

  require Logger
  alias Genswarms.Observability.LogStore

  defstruct [
    :connection,
    :channel,
    :host,
    :user,
    :port,
    :name,
    :remote_skills_dir,
    :subzeroclaw_path,
    :nixos,
    :buffer
  ]

  @type t :: %__MODULE__{
          connection: pid() | nil,
          channel: integer() | nil,
          host: String.t(),
          user: String.t(),
          port: non_neg_integer(),
          name: String.t(),
          remote_skills_dir: String.t(),
          subzeroclaw_path: String.t(),
          nixos: boolean(),
          buffer: binary()
        }

  @default_port 22

  # NixOS defaults (from agent-module.nix)
  @nixos_skills_dir "/var/lib/subzeroclaw/skills"
  @nixos_subzeroclaw_path "subzeroclaw"
  @nixos_user "subzeroclaw"

  # Non-NixOS defaults
  @default_skills_dir "~/.subzeroclaw/skills"
  @default_subzeroclaw_path "subzeroclaw"

  @impl true
  def backend_type, do: :ssh

  @impl true
  def start(name, config) do
    {user, host} = parse_host(Map.fetch!(config, :host))
    port = Map.get(config, :port, @default_port)
    key_path = Map.get(config, :key_path)
    nixos = Map.get(config, :nixos, true)

    # Use NixOS paths if it's a NixOS machine
    {remote_skills_dir, subzeroclaw_path, remote_user} =
      if nixos do
        {
          Map.get(config, :remote_skills_dir, @nixos_skills_dir),
          Map.get(config, :subzeroclaw_path, @nixos_subzeroclaw_path),
          Map.get(config, :remote_user, @nixos_user)
        }
      else
        {
          Map.get(config, :remote_skills_dir, @default_skills_dir),
          Map.get(config, :subzeroclaw_path, @default_subzeroclaw_path),
          user
        }
      end

    Logger.info("Connecting to #{user}@#{host}:#{port} for agent #{name} (nixos: #{nixos})")

    :ok = Application.ensure_started(:ssh)

    connect_opts = build_connect_opts(user, key_path, config)

    swarm_name = Map.get(config, :swarm_name, "default")

    case :ssh.connect(String.to_charlist(host), port, connect_opts, 30_000) do
      {:ok, connection} ->
        Logger.info("SSH connection established for agent #{name}")

        LogStore.log(
          :info,
          :backend,
          :ssh_connect,
          "SSH connection established to #{user}@#{host}:#{port}",
          swarm: swarm_name,
          agent: String.to_atom(name),
          metadata: %{host: host, user: user, port: port, nixos: nixos}
        )

        # Deploy skills if local skills_dir specified
        skills_dir = Map.get(config, :skills_dir)

        if skills_dir do
          deploy_skills_scp(connection, skills_dir, remote_skills_dir)
        end

        # Start the agent process
        case start_agent_process(
               connection,
               name,
               subzeroclaw_path,
               remote_skills_dir,
               remote_user,
               config
             ) do
          {:ok, channel} ->
            ref = %__MODULE__{
              connection: connection,
              channel: channel,
              host: host,
              user: user,
              port: port,
              name: name,
              remote_skills_dir: remote_skills_dir,
              subzeroclaw_path: subzeroclaw_path,
              nixos: nixos,
              buffer: ""
            }

            LogStore.log(
              :info,
              :backend,
              :ssh_agent_start,
              "SSH agent process started on #{host}",
              swarm: swarm_name,
              agent: String.to_atom(name),
              metadata: %{host: host, channel: channel}
            )

            {:ok, ref}

          {:error, reason} ->
            :ssh.close(connection)

            LogStore.log(
              :error,
              :backend,
              :ssh_agent_start_failed,
              "Failed to start agent process via SSH: #{inspect(reason)}",
              swarm: swarm_name,
              agent: String.to_atom(name),
              metadata: %{host: host, reason: inspect(reason)}
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to connect via SSH for agent #{name}: #{inspect(reason)}")

        LogStore.log(
          :error,
          :backend,
          :ssh_connect_failed,
          "SSH connection failed to #{user}@#{host}:#{port}",
          swarm: swarm_name,
          agent: String.to_atom(name),
          metadata: %{host: host, user: user, port: port, reason: inspect(reason)}
        )

        {:error, {:ssh_connect_failed, reason}}
    end
  end

  @impl true
  def stop(%__MODULE__{connection: connection, channel: channel, name: name}) do
    Logger.info("Stopping SSH agent #{name}")

    if channel do
      :ssh_connection.close(connection, channel)
    end

    if connection do
      :ssh.close(connection)
    end

    :ok
  end

  @impl true
  def send_input(%__MODULE__{connection: connection, channel: channel}, message)
      when is_binary(message) do
    data =
      if String.ends_with?(message, "\n") do
        message
      else
        message <> "\n"
      end

    case :ssh_connection.send(connection, channel, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  @impl true
  def deploy_skills(%__MODULE__{connection: connection} = ref, skills_dir) do
    deploy_skills_scp(connection, skills_dir, ref.remote_skills_dir)
    {:ok, ref}
  end

  @impl true
  def health_check(%__MODULE__{connection: connection}) do
    case :ssh.connection_info(connection, :client_version) do
      {:error, _} -> {:error, :connection_closed}
      _ -> :ok
    end
  end

  # Private functions

  defp parse_host(host_string) do
    case String.split(host_string, "@") do
      [user, host] -> {user, host}
      [host] -> {System.get_env("USER", "root"), host}
    end
  end

  @doc false
  # Builds the option list for :ssh.connect/4.
  #
  # Host-key verification is ON by default: an unknown or changed remote host
  # key aborts the connection (fail closed), preventing MITM. The remote key is
  # checked against the known_hosts file in the SSH user_dir. Operators who
  # genuinely need to skip verification (e.g. ephemeral dev hosts) must opt in
  # explicitly via `silently_accept_hosts: true` in the backend config; that
  # value may also be a verification fun, which is passed straight through.
  def build_connect_opts(user, key_path, config) do
    accept_hosts = Map.get(config, :silently_accept_hosts, false)

    base_opts = [
      {:user, String.to_charlist(user)},
      {:silently_accept_hosts, accept_hosts},
      {:user_interaction, false}
    ]

    key_opts =
      if key_path do
        expanded = Path.expand(key_path)

        if File.exists?(expanded) do
          [{:user_dir, String.to_charlist(Path.dirname(expanded))}]
        else
          Logger.warning("SSH key not found: #{expanded}")
          []
        end
      else
        [{:user_dir, String.to_charlist(Path.expand("~/.ssh"))}]
      end

    password_opts =
      case Map.get(config, :password) do
        nil -> []
        pass -> [{:password, String.to_charlist(pass)}]
      end

    base_opts ++ key_opts ++ password_opts
  end

  defp deploy_skills_scp(connection, local_skills_dir, remote_skills_dir) do
    expanded_local = Path.expand(local_skills_dir)

    if File.exists?(expanded_local) do
      Logger.info("Deploying skills from #{expanded_local} to #{remote_skills_dir}")

      # Create remote directory (remote_skills_dir is shell-quoted: this runs as
      # a remote shell command and the path may come from config).
      exec_command(connection, "mkdir -p #{shell_escape(remote_skills_dir)}")

      case :ssh_sftp.start_channel(connection) do
        {:ok, channel_pid} ->
          files = File.ls!(expanded_local)

          Enum.each(files, fn file ->
            local_path = Path.join(expanded_local, file)
            remote_path = "#{remote_skills_dir}/#{file}"

            case File.read(local_path) do
              {:ok, content} ->
                :ssh_sftp.write_file(channel_pid, String.to_charlist(remote_path), content)
                Logger.debug("Deployed skill: #{file}")

              {:error, reason} ->
                Logger.warning("Failed to read skill file #{file}: #{inspect(reason)}")
            end
          end)

          :ssh_sftp.stop_channel(channel_pid)
          :ok

        {:error, reason} ->
          Logger.warning("Failed to start SFTP channel: #{inspect(reason)}")
          :ok
      end
    else
      Logger.warning("Skills directory not found: #{expanded_local}")
      :ok
    end
  end

  defp start_agent_process(
         connection,
         name,
         subzeroclaw_path,
         remote_skills_dir,
         remote_user,
         config
       ) do
    cmd = build_remote_command(name, subzeroclaw_path, remote_skills_dir, remote_user, config)

    case :ssh_connection.session_channel(connection, :infinity) do
      {:ok, channel} ->
        case :ssh_connection.exec(connection, channel, String.to_charlist(cmd), :infinity) do
          :success ->
            Logger.info("Started remote agent #{name} on channel #{channel}")
            {:ok, channel}

          :failure ->
            {:error, :exec_failed}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:channel_failed, reason}}
    end
  end

  @doc false
  # Builds the remote shell command that launches subzeroclaw.
  #
  # SSH "exec" requests are interpreted by the remote login shell — there is no
  # argv channel as there is for local processes — so every value interpolated
  # into the command MUST be shell-quoted. Each untrusted value (agent name,
  # skills dir, model, api_key, endpoint, subzeroclaw path, remote user) is
  # passed through shell_escape/1, so metacharacters are treated as literal
  # data and cannot inject additional commands.
  def build_remote_command(name, subzeroclaw_path, remote_skills_dir, remote_user, config) do
    api_key = Map.get(config, :api_key) || System.get_env("SUBZEROCLAW_API_KEY")
    model = Map.get(config, :model) || System.get_env("SUBZEROCLAW_MODEL")
    endpoint = Map.get(config, :endpoint) || System.get_env("SUBZEROCLAW_ENDPOINT")

    env_vars =
      [
        {"SUBZEROCLAW_AGENT_NAME", name},
        {"SUBZEROCLAW_SKILLS", remote_skills_dir},
        {"SUBZEROCLAW_API_KEY", api_key},
        {"SUBZEROCLAW_MODEL", model},
        {"SUBZEROCLAW_ENDPOINT", endpoint}
      ]
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Enum.map(fn {k, v} -> "#{k}=#{shell_escape(v)}" end)

    env_segment = Enum.join(env_vars, " ")
    binary = shell_escape(subzeroclaw_path)

    # For NixOS, run as the subzeroclaw user via sudo if needed
    if Map.get(config, :nixos, true) and remote_user != nil do
      "sudo -u #{shell_escape(remote_user)} env #{env_segment} #{binary}"
    else
      "env #{env_segment} #{binary}"
    end
  end

  # POSIX shell single-quote escaping: wrap the value in single quotes and
  # replace every embedded single quote with the '\'' sequence. The result is a
  # single shell word that reproduces the input verbatim, with no metacharacter
  # left active.
  defp shell_escape(value) do
    escaped = value |> to_string() |> String.replace("'", "'\\''")
    "'" <> escaped <> "'"
  end

  defp exec_command(connection, cmd) do
    case :ssh_connection.session_channel(connection, :infinity) do
      {:ok, channel} ->
        :ssh_connection.exec(connection, channel, String.to_charlist(cmd), :infinity)
        :ssh_connection.close(connection, channel)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
