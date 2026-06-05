defmodule Genswarm.Backends.MockBackend do
  @moduledoc """
  Mock backend for testing — does not spawn any external process.

  Stores received messages in the ref so tests can introspect what was
  sent to the agent. Supports an optional `:script` for canned responses.
  """

  @behaviour Genswarm.Backends.BackendBehaviour

  defstruct name: nil, messages: [], script: [], alive?: true

  @impl true
  def backend_type, do: :mock

  @impl true
  def start(name, config) do
    {:ok,
     %__MODULE__{
       name: name,
       script: Map.get(config, :script, [])
     }}
  end

  @impl true
  def stop(%__MODULE__{} = ref), do: %{ref | alive?: false} && :ok

  @impl true
  def send_input(%__MODULE__{} = _ref, _message), do: :ok

  @impl true
  def deploy_skills(%__MODULE__{} = _ref, _skills_dir), do: :ok

  @impl true
  def health_check(%__MODULE__{alive?: true}), do: :ok
  def health_check(%__MODULE__{alive?: false}), do: {:error, :dead}

  @impl true
  def handle_output(%__MODULE__{} = _ref, _data), do: {:ok, [], ""}
end
