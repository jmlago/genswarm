defmodule Genswarm.Objects.ObjectSupervisor do
  @moduledoc """
  Module for managing object processes.

  Uses the same DynamicSupervisor and Registry as agents,
  allowing objects and agents to coexist in the same swarm topology.
  """

  require Logger

  alias Genswarm.Objects.ObjectServer

  @supervisor Genswarm.AgentSupervisor

  @doc """
  Starts an object under the supervisor.

  ## Options
    - `:name` - Object name (atom, required)
    - `:swarm_name` - Swarm name (string, required)
    - `:handler` - Handler module implementing ObjectHandler behaviour (required)
    - `:config` - Configuration map passed to handler's init/1 (optional)
  """
  @spec start_object(map()) :: {:ok, pid()} | {:error, term()}
  def start_object(object_config) do
    child_spec = {ObjectServer, object_config_to_opts(object_config)}

    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:ok, pid} ->
        Logger.info(
          "Started object #{object_config[:name]} (#{object_config[:handler]}) in swarm #{object_config[:swarm_name]}"
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.warning("Object #{object_config[:name]} already started")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start object #{object_config[:name]}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops an object.
  """
  @spec stop_object(String.t(), atom()) :: :ok | {:error, :not_found}
  def stop_object(swarm_name, object_name) do
    case find_object_pid(swarm_name, object_name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all objects for a swarm.
  """
  @spec list_objects(String.t()) :: [
          %{name: atom(), pid: String.t(), state: atom(), handler: module()}
        ]
  def list_objects(swarm_name) do
    Registry.select(Genswarm.AgentRegistry, [
      {{{swarm_name, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.filter(fn {name, _pid} ->
      # Check if this is an object (not an agent) by trying to get its status
      try do
        status = ObjectServer.get_status(swarm_name, name)
        Map.get(status, :type) == :object
      catch
        _, _ -> false
      end
    end)
    |> Enum.map(fn {name, pid} ->
      try do
        status = ObjectServer.get_status(swarm_name, name)

        %{
          name: name,
          pid: inspect(pid),
          state: status.state,
          handler: status.handler
        }
      catch
        _, _ ->
          %{name: name, pid: inspect(pid), state: :unknown, handler: nil}
      end
    end)
  end

  @doc """
  Stops all objects for a swarm.
  """
  @spec stop_all_objects(String.t()) :: :ok
  def stop_all_objects(swarm_name) do
    objects = list_objects(swarm_name)

    Enum.each(objects, fn %{name: name} ->
      stop_object(swarm_name, name)
    end)

    :ok
  end

  @doc """
  Gets the interface for all objects in a swarm.

  Returns a map of object names to their interface schemas.
  """
  @spec get_all_interfaces(String.t()) :: %{atom() => map()}
  def get_all_interfaces(swarm_name) do
    list_objects(swarm_name)
    |> Enum.reduce(%{}, fn %{name: name}, acc ->
      interface =
        try do
          ObjectServer.get_interface(swarm_name, name)
        catch
          _, _ -> %{}
        end

      Map.put(acc, name, interface)
    end)
  end

  # Private functions

  defp object_config_to_opts(config) do
    [
      name: config[:name],
      swarm_name: config[:swarm_name],
      handler: config[:handler],
      backend: config[:backend],
      config: config[:config] || %{}
    ]
  end

  defp find_object_pid(swarm_name, object_name) do
    case Registry.lookup(Genswarm.AgentRegistry, {swarm_name, object_name}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end
