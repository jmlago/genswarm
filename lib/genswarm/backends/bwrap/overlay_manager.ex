defmodule Genswarm.Backends.Bwrap.OverlayManager do
  @moduledoc """
  Manages overlay filesystems for bwrap sandboxes.

  Uses fuse-overlayfs (userspace overlay filesystem) to create per-agent
  writable layers on top of shared read-only Nix base layers.

  ## Directory Structure

      /run/swarm/
      ├── sandbox-base/          # Symlinks to pre-built Nix environments
      │   ├── base -> /nix/store/...
      │   ├── web -> /nix/store/...
      │   └── code -> /nix/store/...
      └── agents/{sandbox_id}/   # Per-agent (on tmpfs)
          ├── upper/             # Copy-on-write writes
          ├── work/              # Kernel workdir
          └── merged/            # Union mount point

  ## Requirements

  - fuse-overlayfs installed
  - /run/swarm mounted as tmpfs (configured via NixOS module)
  - Pre-built sandbox bases via `nix build .#sandboxBase-*`
  """

  require Logger

  @swarm_base_dir "/run/swarm"
  @sandbox_bases_dir "/run/swarm/sandbox-base"
  @agents_dir "/run/swarm/agents"

  @doc """
  Sets up an overlay filesystem for an agent sandbox.

  Creates the upper/work/merged directories and mounts fuse-overlayfs.

  Returns `{:ok, overlay_dir}` or `{:error, reason}`.
  """
  @spec setup_overlay(String.t(), [atom()]) :: {:ok, String.t()} | {:error, term()}
  def setup_overlay(sandbox_id, presets) do
    agent_dir = Path.join(@agents_dir, sandbox_id)
    upper_dir = Path.join(agent_dir, "upper")
    work_dir = Path.join(agent_dir, "work")
    merged_dir = Path.join(agent_dir, "merged")

    with :ok <- ensure_base_dirs_exist(),
         :ok <- create_agent_dirs(agent_dir, upper_dir, work_dir, merged_dir),
         {:ok, base_layer} <- resolve_base_layer(presets),
         :ok <- mount_overlay(base_layer, upper_dir, work_dir, merged_dir) do
      {:ok, agent_dir}
    end
  end

  @doc """
  Cleans up an overlay filesystem.

  Unmounts the overlay and removes all per-agent directories.
  """
  @spec cleanup_overlay(String.t()) :: :ok
  def cleanup_overlay(sandbox_id) do
    agent_dir = Path.join(@agents_dir, sandbox_id)
    merged_dir = Path.join(agent_dir, "merged")

    # Unmount fuse-overlayfs
    unmount_overlay(merged_dir)

    # Remove agent directory
    case File.rm_rf(agent_dir) do
      {:ok, _} -> :ok
      {:error, reason, _} ->
        Logger.warning("Failed to cleanup overlay for #{sandbox_id}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Gets the path to the base layer for the given presets.

  Base layers are pre-built Nix store paths containing all tools
  for a preset combination.
  """
  @spec get_base_layer([atom()]) :: String.t()
  def get_base_layer(presets) do
    preset_name = presets_to_name(presets)
    base_path = Path.join(@sandbox_bases_dir, preset_name)

    if File.exists?(base_path) do
      # Follow symlink to actual Nix store path
      case File.read_link(base_path) do
        {:ok, target} -> target
        {:error, _} -> base_path
      end
    else
      # Fallback to base preset
      Path.join(@sandbox_bases_dir, "base")
    end
  end

  @doc """
  Checks if the swarm base directories exist.
  Returns true if the bwrap infrastructure is set up.
  """
  @spec infrastructure_ready?() :: boolean()
  def infrastructure_ready? do
    File.dir?(@swarm_base_dir) &&
      File.dir?(@sandbox_bases_dir) &&
      File.exists?(Path.join(@sandbox_bases_dir, "base"))
  end

  @doc """
  Lists all active sandbox overlay directories.
  """
  @spec list_active_sandboxes() :: [String.t()]
  def list_active_sandboxes do
    case File.ls(@agents_dir) do
      {:ok, dirs} -> dirs
      {:error, _} -> []
    end
  end

  @doc """
  Gets memory usage of an overlay (size of upper directory).
  """
  @spec get_overlay_size(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_overlay_size(sandbox_id) do
    upper_dir = Path.join([@agents_dir, sandbox_id, "upper"])

    case System.cmd("du", ["-sb", upper_dir], stderr_to_stdout: true) do
      {output, 0} ->
        [size_str | _] = String.split(output)
        {:ok, String.to_integer(size_str)}
      {_, _} ->
        {:error, :not_found}
    end
  end

  # Private functions

  defp ensure_base_dirs_exist do
    cond do
      not File.dir?(@swarm_base_dir) ->
        {:error, {:missing_swarm_dir, @swarm_base_dir}}

      not File.dir?(@sandbox_bases_dir) ->
        {:error, {:missing_sandbox_bases, @sandbox_bases_dir}}

      true ->
        # Ensure agents directory exists
        File.mkdir_p(@agents_dir)
        :ok
    end
  end

  defp create_agent_dirs(agent_dir, upper_dir, work_dir, merged_dir) do
    with :ok <- File.mkdir_p(agent_dir),
         :ok <- File.mkdir_p(upper_dir),
         :ok <- File.mkdir_p(work_dir),
         :ok <- File.mkdir_p(merged_dir) do
      :ok
    else
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp resolve_base_layer(presets) when is_list(presets) do
    # Check for a custom base layer path in the presets
    # e.g., presets: [{:custom, "/path/to/my/base"}, :base]
    case Enum.find(presets, fn p -> match?({:custom, _}, p) end) do
      {:custom, custom_path} ->
        expanded = Path.expand(custom_path)
        if File.dir?(expanded) do
          Logger.info("[OverlayManager] Using custom base layer: #{expanded}")
          {:ok, expanded}
        else
          {:error, {:custom_base_not_found, expanded}}
        end

      nil ->
        resolve_named_preset(presets)
    end
  end

  defp resolve_named_preset(presets) do
    preset_name = presets_to_name(presets)

    # Search in system dir + any extra dirs registered by downstream projects
    # e.g., Application.put_env(:genswarm, :extra_preset_dirs, ["/my/presets"])
    search_dirs = [
      @sandbox_bases_dir
      | Application.get_env(:genswarm, :extra_preset_dirs, [])
    ]

    # Look for the preset in all search directories
    found =
      Enum.find_value(search_dirs, fn dir ->
        path = Path.join(dir, preset_name)
        if File.exists?(path), do: resolve_symlink(path)
      end)

    cond do
      found ->
        {:ok, found}

      preset_name != "base" ->
        # Try falling back to base in any search dir
        fallback =
          Enum.find_value(search_dirs, fn dir ->
            path = Path.join(dir, "base")
            if File.exists?(path), do: resolve_symlink(path)
          end)

        if fallback do
          Logger.warning("Preset #{preset_name} not found, falling back to base")
          {:ok, fallback}
        else
          {:error, {:base_layer_not_found, preset_name}}
        end

      true ->
        {:error, {:base_layer_not_found, preset_name}}
    end
  end

  defp resolve_symlink(path) do
    case File.read_link(path) do
      {:ok, target} ->
        if String.starts_with?(target, "/") do
          target
        else
          Path.join(Path.dirname(path), target)
        end
      {:error, :einval} ->
        # Not a symlink, return as-is
        path
      {:error, _} ->
        path
    end
  end

  defp mount_overlay(base_layer, upper_dir, work_dir, merged_dir) do
    # Use fuse-overlayfs for userspace overlay mounting
    # Format: fuse-overlayfs -o lowerdir=X,upperdir=Y,workdir=Z MOUNTPOINT
    cmd = "fuse-overlayfs"
    args = [
      "-o", "lowerdir=#{base_layer},upperdir=#{upper_dir},workdir=#{work_dir}",
      merged_dir
    ]

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok
      {output, code} ->
        Logger.error("fuse-overlayfs mount failed (exit #{code}): #{output}")
        {:error, {:mount_failed, output}}
    end
  end

  defp unmount_overlay(merged_dir) do
    # fusermount -u for userspace unmount
    case System.cmd("fusermount", ["-u", merged_dir], stderr_to_stdout: true) do
      {_, 0} ->
        :ok
      {output, _} ->
        # May already be unmounted
        Logger.debug("Unmount of #{merged_dir}: #{output}")
        :ok
    end
  end

  defp presets_to_name(presets) do
    # Sort for consistent naming, filter out custom tuples
    presets
    |> Enum.reject(&match?({:custom, _}, &1))
    |> Enum.sort()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join("-")
  end
end
