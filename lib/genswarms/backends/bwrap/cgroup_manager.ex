defmodule Genswarms.Backends.Bwrap.CgroupManager do
  @moduledoc """
  Manages cgroup resource limits for bwrap sandboxes using systemd scopes.

  Uses `systemd-run --user --scope` to place each agent process in its own
  cgroup with configurable resource limits. This provides:

  - Memory limits (hard cap with OOM killer)
  - CPU shares (relative priority)
  - Task limits (max processes/threads)
  - Easy monitoring via cgroup filesystem

  ## Systemd Slice

  All agent scopes are placed under the `subzeroclaw.slice` for:
  - Aggregate resource accounting
  - Bulk operations (stop all agents)
  - Monitoring via `systemd-cgtop`

  ## Example Usage

      {exe, args, scope_name} = CgroupManager.create_scope("my-agent", ["bwrap", "..."], %{
        memory_max: "256M",
        cpu_shares: 100,
        tasks_max: 50
      })
      # exe is the systemd-run path, args is its full argv list:
      # ["--user", "--slice=...", ..., "--", "bwrap", "..."]
  """

  require Logger

  @systemd_slice "subzeroclaw"
  @cgroup_base_path "/sys/fs/cgroup/user.slice"

  @doc """
  Creates a systemd scope command wrapper for the given command.

  Accepts `command_args` as a list of discrete argv entries (the sandbox
  executable followed by its arguments) and returns
  `{executable, args, scope_name}`:

  - `executable` - absolute path to `systemd-run`
  - `args` - the full argv list for `systemd-run`, ending with `--` followed by
    the original `command_args`
  - `scope_name` - the transient unit name

  The caller spawns the result with `Port.open({:spawn_executable, executable},
  [{:args, args} | _])`, i.e. execvp with no shell. Because nothing is ever
  joined into a shell string, untrusted values inside `command_args` cannot be
  interpreted as shell commands.

  ## Options

  - `:memory_max` - Maximum memory (e.g., "256M", "1G")
  - `:cpu_shares` - CPU weight (1-10000, default 100)
  - `:tasks_max` - Maximum number of tasks/threads
  - `:timeout_sec` - Scope timeout (default: infinity)
  """
  @spec create_scope(String.t(), [String.t()], map()) ::
          {String.t(), [String.t()], String.t()}
  def create_scope(sandbox_id, command_args, opts \\ %{}) when is_list(command_args) do
    scope_name = "szc-#{sanitize_name(sandbox_id)}"

    # Absolute path for systemd-run (required by spawn_executable, which does
    # not resolve bare names against PATH).
    systemd_run = find_executable("systemd-run")

    args =
      [
        "--user",
        # Use transient service instead of scope for I/O forwarding
        # --scope doesn't support --pipe
        "--slice=#{@systemd_slice}",
        "--unit=#{scope_name}",
        # Pass stdin/stdout/stderr through to the service
        "--pipe",
        # Quiet mode to not pollute stdout
        "--quiet"
      ] ++ build_property_args(opts) ++ ["--"] ++ command_args

    {systemd_run, args, scope_name}
  end

  @doc """
  Gets the cgroup filesystem path for a scope.
  """
  @spec get_cgroup_path(String.t()) :: String.t()
  def get_cgroup_path(scope_name) do
    uid = System.get_env("UID") || get_current_uid()

    Path.join([
      @cgroup_base_path,
      "user-#{uid}.slice",
      "user@#{uid}.service",
      "#{@systemd_slice}.slice",
      "#{scope_name}.scope"
    ])
  end

  @doc """
  Checks if a scope is still active.
  """
  @spec scope_active?(String.t()) :: boolean()
  def scope_active?(scope_name) do
    # Check both service and scope (we use transient services with --pipe)
    case System.cmd("systemctl", ["--user", "is-active", "#{scope_name}.service"],
           stderr_to_stdout: true
         ) do
      {"active\n", 0} ->
        true

      _ ->
        # Fall back to scope check for backwards compatibility
        case System.cmd("systemctl", ["--user", "is-active", "#{scope_name}.scope"],
               stderr_to_stdout: true
             ) do
          {"active\n", 0} -> true
          _ -> false
        end
    end
  end

  @doc """
  Kills a systemd scope, terminating all processes within it.
  """
  @spec kill_scope(String.t()) :: :ok
  def kill_scope(nil), do: :ok

  def kill_scope(scope_name) do
    # Try stopping as service first (we use transient services with --pipe)
    System.cmd("systemctl", ["--user", "stop", "#{scope_name}.service"], stderr_to_stdout: true)

    # Also try scope for backwards compatibility
    System.cmd("systemctl", ["--user", "stop", "#{scope_name}.scope"], stderr_to_stdout: true)

    # Reset failed state if any
    System.cmd("systemctl", ["--user", "reset-failed", "#{scope_name}.service"],
      stderr_to_stdout: true
    )

    System.cmd("systemctl", ["--user", "reset-failed", "#{scope_name}.scope"],
      stderr_to_stdout: true
    )

    :ok
  end

  @doc """
  Gets memory usage for a scope in bytes.
  """
  @spec get_memory_usage(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_memory_usage(scope_name) do
    cgroup_path = get_cgroup_path(scope_name)
    memory_file = Path.join(cgroup_path, "memory.current")

    case File.read(memory_file) do
      {:ok, content} ->
        {:ok, content |> String.trim() |> String.to_integer()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets CPU usage statistics for a scope.
  """
  @spec get_cpu_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_cpu_stats(scope_name) do
    cgroup_path = get_cgroup_path(scope_name)
    cpu_file = Path.join(cgroup_path, "cpu.stat")

    case File.read(cpu_file) do
      {:ok, content} ->
        stats =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, " ") do
              [key, value] -> {String.to_atom(key), String.to_integer(value)}
              _ -> nil
            end
          end)
          |> Enum.filter(&(&1 != nil))
          |> Map.new()

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets number of tasks/processes in a scope.
  """
  @spec get_task_count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_task_count(scope_name) do
    cgroup_path = get_cgroup_path(scope_name)
    pids_file = Path.join(cgroup_path, "pids.current")

    case File.read(pids_file) do
      {:ok, content} ->
        {:ok, content |> String.trim() |> String.to_integer()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all active subzeroclaw scopes.
  """
  @spec list_active_scopes() :: [String.t()]
  def list_active_scopes do
    case System.cmd(
           "systemctl",
           ["--user", "list-units", "--type=scope", "--state=running", "--plain", "--no-legend"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, " ", parts: 2))
        |> Enum.map(&List.first/1)
        |> Enum.filter(&String.starts_with?(&1, "szc-"))
        |> Enum.map(&String.trim_trailing(&1, ".scope"))

      _ ->
        []
    end
  end

  @doc """
  Gets aggregate resource usage for all subzeroclaw scopes.
  """
  @spec get_aggregate_stats() :: map()
  def get_aggregate_stats do
    scopes = list_active_scopes()

    memory_total =
      scopes
      |> Enum.map(&get_memory_usage/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, bytes} -> bytes end)
      |> Enum.sum()

    tasks_total =
      scopes
      |> Enum.map(&get_task_count/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, count} -> count end)
      |> Enum.sum()

    %{
      scope_count: length(scopes),
      total_memory_bytes: memory_total,
      total_memory_mb: Float.round(memory_total / 1_048_576, 2),
      total_tasks: tasks_total
    }
  end

  # Private functions

  defp build_property_args(opts) do
    args = []

    # Memory limit
    args =
      case Map.get(opts, :memory_max) do
        nil -> args
        limit -> args ++ ["--property=MemoryMax=#{limit}"]
      end

    # CPU shares (weight)
    args =
      case Map.get(opts, :cpu_shares) do
        nil -> args
        shares -> args ++ ["--property=CPUWeight=#{shares}"]
      end

    # Task limit
    args =
      case Map.get(opts, :tasks_max) do
        nil -> args
        max -> args ++ ["--property=TasksMax=#{max}"]
      end

    args
  end

  defp sanitize_name(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9\-_]/, "-")
    |> String.slice(0, 64)
  end

  defp get_current_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {uid, 0} -> String.trim(uid)
      _ -> "1000"
    end
  end

  defp find_executable(name) do
    # Check common NixOS paths first, then fall back to a PATH lookup. An
    # absolute path is required because the scope is spawned via
    # spawn_executable (execvp on a path), not through a shell.
    paths = [
      "/run/current-system/sw/bin/#{name}",
      "/usr/bin/#{name}",
      "/bin/#{name}"
    ]

    Enum.find(paths, &File.exists?/1) || System.find_executable(name) || name
  end
end
