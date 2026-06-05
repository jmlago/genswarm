defmodule Genswarm.CLI.ServerManager do
  @moduledoc """
  Manages the Phoenix server lifecycle for CLI operations.

  Handles:
  - Starting the server in background mode
  - Stopping the server
  - PID file management
  - Server status checking
  """

  @swarm_dir ".swarm"
  @pid_file "phoenix.pid"
  @default_port 4000

  @doc """
  Returns the path to the .swarm directory.
  """
  def swarm_dir(base_dir \\ File.cwd!()) do
    Path.join(base_dir, @swarm_dir)
  end

  @doc """
  Returns the path to the PID file.
  """
  def pid_file(base_dir \\ File.cwd!()) do
    Path.join(swarm_dir(base_dir), @pid_file)
  end

  @doc """
  Ensures the .swarm directory exists.
  """
  def ensure_swarm_dir(base_dir \\ File.cwd!()) do
    dir = swarm_dir(base_dir)
    File.mkdir_p(dir)
  end

  @doc """
  Starts the Phoenix server in background mode.
  Returns {:ok, pid} or {:error, reason}.
  """
  def start_server(opts \\ []) do
    port = Keyword.get(opts, :port, get_port())
    base_dir = Keyword.get(opts, :dir, File.cwd!())

    # Check if already running
    case get_server_status(base_dir) do
      {:running, pid} ->
        {:error, {:already_running, pid}}

      _ ->
        do_start_server(port, base_dir)
    end
  end

  @doc """
  Stops the Phoenix server.
  """
  def stop_server(base_dir \\ File.cwd!()) do
    case read_pid_file(base_dir) do
      {:ok, pid} ->
        # Send SIGTERM to the process
        case System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true) do
          {_, 0} ->
            # Wait for process to exit
            wait_for_exit(pid, 10)
            remove_pid_file(base_dir)
            :ok

          {output, _code} ->
            # Process might already be dead
            remove_pid_file(base_dir)
            {:error, {:kill_failed, output}}
        end

      :not_found ->
        {:error, :not_running}
    end
  end

  @doc """
  Gets the server status.
  Returns {:running, pid}, :stopped, or {:stale, pid}.
  """
  def get_server_status(base_dir \\ File.cwd!()) do
    case read_pid_file(base_dir) do
      {:ok, pid} ->
        if process_alive?(pid) do
          {:running, pid}
        else
          {:stale, pid}
        end

      :not_found ->
        :stopped
    end
  end

  @doc """
  Gets the server URL.
  """
  def server_url(port \\ get_port()) do
    host = System.get_env("PHX_HOST") || "localhost"
    "http://#{host}:#{port}"
  end

  @doc """
  Reads the PID from the pid file.
  """
  def read_pid_file(base_dir \\ File.cwd!()) do
    path = pid_file(base_dir)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Integer.parse(String.trim(content)) do
            {pid, _} -> {:ok, pid}
            :error -> :not_found
          end

        {:error, _} ->
          :not_found
      end
    else
      :not_found
    end
  end

  @doc """
  Writes a PID to the pid file.
  """
  def write_pid_file(pid, base_dir \\ File.cwd!()) do
    ensure_swarm_dir(base_dir)
    path = pid_file(base_dir)
    File.write(path, to_string(pid))
  end

  @doc """
  Removes the pid file.
  """
  def remove_pid_file(base_dir \\ File.cwd!()) do
    path = pid_file(base_dir)

    if File.exists?(path) do
      File.rm(path)
    else
      :ok
    end
  end

  # Private functions

  defp do_start_server(port, base_dir) do
    ensure_swarm_dir(base_dir)

    # Build the command to start Phoenix in background
    cmd = build_start_command(port)

    # Start the process
    port_ref =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:cd, base_dir}
      ])

    # Read the PID from stdout (the shell echoes it via `echo $!`)
    case receive_pid_from_port(port_ref, "") do
      {:ok, bg_pid} ->
        write_pid_file(bg_pid, base_dir)
        {:ok, bg_pid}

      :error ->
        # Fallback: wait and check if server started
        Process.sleep(2000)

        case get_server_status(base_dir) do
          {:running, pid} -> {:ok, pid}
          _ -> {:error, :failed_to_start}
        end
    end
  end

  defp receive_pid_from_port(port_ref, acc) do
    receive do
      {^port_ref, {:data, data}} ->
        # Accumulate data and try to parse PID
        new_acc = acc <> data

        case Integer.parse(String.trim(new_acc)) do
          {pid, _} -> {:ok, pid}
          :error -> receive_pid_from_port(port_ref, new_acc)
        end

      {^port_ref, {:exit_status, _}} ->
        # Process exited, try to parse what we have
        case Integer.parse(String.trim(acc)) do
          {pid, _} -> {:ok, pid}
          :error -> :error
        end
    after
      5000 ->
        # Timeout - try to parse what we have
        case Integer.parse(String.trim(acc)) do
          {pid, _} -> {:ok, pid}
          :error -> :error
        end
    end
  end

  defp build_start_command(port) do
    # Run our dashboard task which properly starts Phoenix via Application.start_web_server
    "sh -c 'MIX_ENV=dev PORT=#{port} nohup mix swarm.dashboard start --foreground > .swarm/phoenix.log 2>&1 & echo $!'"
  end

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp wait_for_exit(pid, 0), do: {:error, {:timeout, pid}}

  defp wait_for_exit(pid, attempts) do
    if process_alive?(pid) do
      Process.sleep(500)
      wait_for_exit(pid, attempts - 1)
    else
      :ok
    end
  end

  defp get_port do
    case System.get_env("PORT") do
      nil ->
        @default_port

      port_str ->
        case Integer.parse(port_str) do
          {port, _} -> port
          :error -> @default_port
        end
    end
  end
end
