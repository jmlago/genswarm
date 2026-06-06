defmodule Genswarms.Objects.ObjectServer do
  @moduledoc """
  GenServer that wraps an object handler or backend process.

  Manages the lifecycle of a non-agentic object in the swarm:
  - Receives messages via `deliver_message/4`
  - For native objects: calls handler's `handle_message/3`
  - For Docker/SSH objects: sends JSON via stdin, parses stdout
  - Routes outbound messages via Router

  ## Backend Modes

  **Native (`:local` or no backend):**
  Uses an Elixir module implementing `ObjectHandler` behaviour.
  Fast, runs in the same BEAM VM.

  **Docker (`{:docker, image}` or `{:docker, image, opts}`):**
  Runs a container that communicates via JSON over stdin/stdout.
  Container receives: `{"from": "agent_name", "content": "..."}`
  Container responds: `{"action": "reply|send|broadcast", "to": "target", "content": "..."}`

  **SSH (`{:ssh, host}` or `{:ssh, host, opts}`):**
  Runs on remote machine via SSH, same JSON protocol as Docker.
  """

  use GenServer
  require Logger

  alias Genswarms.Config.SwarmConfig
  alias Genswarms.Routing.Router
  alias Genswarms.Observability.LogStore
  alias Genswarms.SafeAtom

  defstruct [
    :name,
    :swarm_name,
    :handler,
    :handler_state,
    :config,
    :backend_module,
    :backend_ref,
    :backend_config,
    # :native | :process
    mode: :native,
    state: :initializing,
    buffer: "",
    message_count: 0,
    started_at: nil,
    last_activity: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          swarm_name: String.t(),
          handler: module() | nil,
          handler_state: term(),
          config: map(),
          backend_module: module() | nil,
          backend_ref: term(),
          backend_config: map(),
          mode: :native | :process,
          state: :initializing | :idle | :working | :error,
          buffer: String.t(),
          message_count: non_neg_integer(),
          started_at: DateTime.t() | nil,
          last_activity: DateTime.t() | nil
        }

  # Client API

  @doc """
  Starts an object server.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    swarm_name = Keyword.fetch!(opts, :swarm_name)
    registry_name = via_tuple(swarm_name, name)
    GenServer.start_link(__MODULE__, opts, name: registry_name)
  end

  @doc """
  Returns the via tuple for Registry lookup.
  """
  def via_tuple(swarm_name, object_name) do
    {:via, Registry, {Genswarms.AgentRegistry, {swarm_name, object_name}, :object}}
  end

  @doc """
  Delivers a message from an agent or another object.
  """
  def deliver_message(swarm_name, object_name, from, content) do
    GenServer.cast(via_tuple(swarm_name, object_name), {:deliver_message, from, content})
  end

  @doc """
  Gets the current state of the object.
  """
  def get_state(swarm_name, object_name) do
    GenServer.call(via_tuple(swarm_name, object_name), :get_state)
  end

  @doc """
  Gets object status info.
  """
  def get_status(swarm_name, object_name) do
    GenServer.call(via_tuple(swarm_name, object_name), :get_status)
  end

  @doc """
  Gets the object's interface schema.
  """
  def get_interface(swarm_name, object_name) do
    GenServer.call(via_tuple(swarm_name, object_name), :get_interface)
  end

  @doc """
  Stops the object.
  """
  def stop(swarm_name, object_name) do
    GenServer.stop(via_tuple(swarm_name, object_name))
  end

  @doc """
  Log a message from an object to the centralized LogStore.

  This can be called by ObjectHandler implementations to log custom messages.

  ## Examples

      ObjectServer.log(:info, swarm_name, object_name, "Game started", %{players: 2})
      ObjectServer.log(:warning, swarm_name, object_name, "Invalid move attempted")
      ObjectServer.log(:error, swarm_name, object_name, "Game error", %{reason: reason})
  """
  def log(level, swarm_name, object_name, message, metadata \\ %{}) do
    LogStore.log(level, :object, :custom, message,
      swarm: swarm_name,
      agent: object_name,
      metadata: metadata
    )
  end

  # Server callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    swarm_name = Keyword.fetch!(opts, :swarm_name)
    handler = Keyword.get(opts, :handler)
    backend = Keyword.get(opts, :backend)
    config = Keyword.get(opts, :config, %{})

    # Determine mode based on backend
    {mode, backend_module, backend_config} = determine_mode(backend, handler)

    state = %__MODULE__{
      name: name,
      swarm_name: swarm_name,
      handler: handler,
      config: config,
      mode: mode,
      backend_module: backend_module,
      backend_config: backend_config,
      started_at: DateTime.utc_now()
    }

    # Initialize based on mode
    send(self(), :init_object)

    {:ok, state}
  end

  defp determine_mode(nil, handler) when not is_nil(handler) do
    # No backend specified, use native handler
    {:native, nil, %{}}
  end

  defp determine_mode(:local, handler) when not is_nil(handler) do
    # Explicit local backend, use native handler
    {:native, nil, %{}}
  end

  defp determine_mode({:docker, _} = backend, _handler) do
    {:process, SwarmConfig.backend_module(backend), SwarmConfig.backend_config(backend)}
  end

  defp determine_mode({:docker, _, _} = backend, _handler) do
    {:process, SwarmConfig.backend_module(backend), SwarmConfig.backend_config(backend)}
  end

  defp determine_mode({:ssh, _} = backend, _handler) do
    {:process, SwarmConfig.backend_module(backend), SwarmConfig.backend_config(backend)}
  end

  defp determine_mode({:ssh, _, _} = backend, _handler) do
    {:process, SwarmConfig.backend_module(backend), SwarmConfig.backend_config(backend)}
  end

  defp determine_mode(_backend, handler) when not is_nil(handler) do
    # Fallback to native if handler is provided
    {:native, nil, %{}}
  end

  defp determine_mode(_backend, _handler) do
    # No handler and no recognized backend - error state
    {:native, nil, %{}}
  end

  @impl true
  def handle_info(:init_object, %{mode: :native} = state) do
    Logger.info(
      "[#{state.swarm_name}/#{state.name}] Initializing native object handler #{state.handler}"
    )

    if state.handler do
      case state.handler.init(state.config) do
        {:ok, handler_state} ->
          Logger.info("[#{state.swarm_name}/#{state.name}] Object handler initialized")

          emit_telemetry(:object_started, state, %{mode: :native})

          {:noreply,
           %{
             state
             | handler_state: handler_state,
               state: :idle,
               last_activity: DateTime.utc_now()
           }}

        {:ok, handler_state, {:send, to, content}} ->
          Logger.info(
            "[#{state.swarm_name}/#{state.name}] Object handler initialized, sending initial message to #{to}"
          )

          emit_telemetry(:object_started, state, %{mode: :native})
          # Send the initial message
          Router.route(state.swarm_name, state.name, to, content)

          {:noreply,
           %{
             state
             | handler_state: handler_state,
               state: :idle,
               last_activity: DateTime.utc_now()
           }}

        {:ok, handler_state, {:multi, messages}} ->
          Logger.info(
            "[#{state.swarm_name}/#{state.name}] Object handler initialized, sending #{length(messages)} initial messages"
          )

          emit_telemetry(:object_started, state, %{mode: :native})

          # Send all initial messages
          Enum.each(messages, fn
            {:send, to, content} ->
              Router.route(state.swarm_name, state.name, to, content)

            {:broadcast, content} ->
              Router.broadcast(state.swarm_name, state.name, content)
          end)

          {:noreply,
           %{
             state
             | handler_state: handler_state,
               state: :idle,
               last_activity: DateTime.utc_now()
           }}

        {:error, reason} ->
          Logger.error(
            "[#{state.swarm_name}/#{state.name}] Failed to initialize handler: #{inspect(reason)}"
          )

          emit_telemetry(:object_error, state, %{reason: inspect(reason), phase: :init})
          {:noreply, %{state | state: :error}}
      end
    else
      Logger.error("[#{state.swarm_name}/#{state.name}] No handler specified for native object")

      LogStore.log(:error, :object, :no_handler, "Object #{state.name} has no handler specified",
        swarm: state.swarm_name,
        agent: state.name
      )

      {:noreply, %{state | state: :error}}
    end
  end

  def handle_info(:init_object, %{mode: :process} = state) do
    Logger.info(
      "[#{state.swarm_name}/#{state.name}] Starting object backend #{inspect(state.backend_module)}"
    )

    config =
      state.backend_config
      |> Map.put(:swarm_name, state.swarm_name)
      # Signal to backend that this is an object
      |> Map.put(:object_mode, true)

    case state.backend_module.start(to_string(state.name), config) do
      {:ok, ref} ->
        Logger.info("[#{state.swarm_name}/#{state.name}] Object backend started")

        emit_telemetry(:object_started, state, %{mode: :process, backend: state.backend_module})
        {:noreply, %{state | backend_ref: ref, state: :idle, last_activity: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.error(
          "[#{state.swarm_name}/#{state.name}] Failed to start backend: #{inspect(reason)}"
        )

        emit_telemetry(:object_error, state, %{
          reason: inspect(reason),
          backend: state.backend_module,
          phase: :start
        })

        {:noreply, %{state | state: :error}}
    end
  end

  # Handle Port messages for process-mode objects
  def handle_info(
        {port, {:data, {:eol, line}}},
        %{mode: :process, backend_ref: %{port: port}} = state
      ) do
    handle_process_output(line, state)
  end

  def handle_info(
        {port, {:data, {:noeol, chunk}}},
        %{mode: :process, backend_ref: %{port: port}} = state
      ) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info(
        {port, {:exit_status, status}},
        %{mode: :process, backend_ref: %{port: port}} = state
      ) do
    Logger.warning(
      "[#{state.swarm_name}/#{state.name}] Object backend exited with status #{status}"
    )

    emit_telemetry(:object_stopped, state, %{exit_status: status})
    {:noreply, %{state | state: :error}}
  end

  def handle_info({_port, {:data, data}}, %{mode: :process} = state) when is_binary(data) do
    handle_process_output(data, state)
  end

  def handle_info(msg, %{mode: :native, handler: handler} = state)
      when not is_nil(handler) do
    # Check if handler implements handle_info/2
    if function_exported?(handler, :handle_info, 2) do
      case handler.handle_info(msg, state.handler_state) do
        {:reply, _response, handler_state} ->
          # Reply doesn't make sense for handle_info, but handle it anyway
          Logger.debug("[#{state.swarm_name}/#{state.name}] handle_info returned reply")
          {:noreply, %{state | handler_state: handler_state}}

        {:send, to, message, handler_state} ->
          route_message(state.swarm_name, state.name, to, message)
          {:noreply, %{state | handler_state: handler_state, last_activity: DateTime.utc_now()}}

        {:broadcast, message, handler_state} ->
          Router.broadcast(state.swarm_name, state.name, message)
          {:noreply, %{state | handler_state: handler_state, last_activity: DateTime.utc_now()}}

        {:noreply, handler_state} ->
          {:noreply, %{state | handler_state: handler_state}}

        {:multi, messages, handler_state} ->
          Enum.each(messages, fn
            {:send, to, msg} -> route_message(state.swarm_name, state.name, to, msg)
            {:broadcast, msg} -> Router.broadcast(state.swarm_name, state.name, msg)
          end)

          {:noreply, %{state | handler_state: handler_state, last_activity: DateTime.utc_now()}}

        {:send_many, messages, handler_state} ->
          Enum.each(messages, fn
            {:send, to, msg} -> route_message(state.swarm_name, state.name, to, msg)
            {:broadcast, msg} -> Router.broadcast(state.swarm_name, state.name, msg)
            {to, msg} -> route_message(state.swarm_name, state.name, to, msg)
          end)

          {:noreply, %{state | handler_state: handler_state, last_activity: DateTime.utc_now()}}
      end
    else
      Logger.debug("[#{state.swarm_name}/#{state.name}] Unhandled message: #{inspect(msg)}")
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[#{state.swarm_name}/#{state.name}] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      name: state.name,
      swarm_name: state.swarm_name,
      type: :object,
      handler: state.handler,
      backend: if(state.mode == :process, do: state.backend_module, else: :native),
      mode: state.mode,
      state: state.state,
      message_count: state.message_count,
      started_at: state.started_at,
      last_activity: state.last_activity
    }

    {:reply, status, state}
  end

  def handle_call(:get_interface, _from, %{mode: :native} = state) do
    interface =
      if state.handler && function_exported?(state.handler, :interface, 0) do
        state.handler.interface()
      else
        %{}
      end

    {:reply, interface, state}
  end

  def handle_call(:get_interface, _from, %{mode: :process} = state) do
    # For process-mode objects, we don't have a handler interface
    # Could potentially query the process for its interface
    {:reply, %{note: "Process-mode object - interface not available"}, state}
  end

  # Catch-all handlers for AgentServer calls that might be made on objects
  def handle_call(:get_logs, _from, state) do
    {:reply, [], state}
  end

  def handle_call(:get_skills_content, _from, state) do
    {:reply, [], state}
  end

  def handle_call({:get_history, _limit}, _from, state) do
    {:reply, [], state}
  end

  def handle_call({:send_task, _task}, _from, state) do
    {:reply, {:error, :not_an_agent}, state}
  end

  def handle_call({:update_skill, _name, _content}, _from, state) do
    {:reply, {:error, :not_an_agent}, state}
  end

  @impl true
  def handle_cast({:deliver_message, from, content}, state) do
    if state.state == :error do
      Logger.warning(
        "[#{state.swarm_name}/#{state.name}] Object in error state, dropping message from #{from}"
      )

      LogStore.log(
        :warning,
        :object,
        :message_dropped,
        "Object #{state.name} dropped message (in error state)",
        swarm: state.swarm_name,
        agent: state.name,
        metadata: %{from: from, reason: :error_state}
      )

      {:noreply, state}
    else
      Logger.debug("[#{state.swarm_name}/#{state.name}] Received message from #{from}")

      # Truncate content for logging if too long
      content_preview =
        if is_binary(content) and String.length(content) > 200 do
          String.slice(content, 0, 200) <> "..."
        else
          content
        end

      LogStore.log(
        :info,
        :object,
        :message_received,
        "Object #{state.name} received message from #{from}",
        swarm: state.swarm_name,
        agent: state.name,
        metadata: %{from: from, content: content_preview}
      )

      new_state = %{state | state: :working, last_activity: DateTime.utc_now()}

      case state.mode do
        :native -> handle_native_message(from, content, new_state)
        :process -> handle_process_message(from, content, new_state)
      end
    end
  end

  @impl true
  def terminate(reason, %{mode: :native} = state) do
    if state.handler && function_exported?(state.handler, :terminate, 2) do
      state.handler.terminate(reason, state.handler_state)
    end

    :ok
  end

  def terminate(_reason, %{mode: :process} = state) do
    if state.backend_ref && state.backend_module do
      state.backend_module.stop(state.backend_ref)
    end

    :ok
  end

  # Private functions - Native mode

  defp handle_native_message(from, content, state) do
    case state.handler.handle_message(from, content, state.handler_state) do
      {:reply, response, handler_state} ->
        route_message(state.swarm_name, state.name, from, response)

        new_state = %{
          state
          | handler_state: handler_state,
            state: :idle,
            message_count: state.message_count + 1
        }

        {:noreply, new_state}

      {:send, to, message, handler_state} ->
        route_message(state.swarm_name, state.name, to, message)

        new_state = %{
          state
          | handler_state: handler_state,
            state: :idle,
            message_count: state.message_count + 1
        }

        {:noreply, new_state}

      {:broadcast, message, handler_state} ->
        content_preview =
          if is_binary(message) and String.length(message) > 200 do
            String.slice(message, 0, 200) <> "..."
          else
            message
          end

        LogStore.log(:info, :object, :broadcast, "Object #{state.name} broadcast message",
          swarm: state.swarm_name,
          agent: state.name,
          metadata: %{content: content_preview}
        )

        Router.broadcast(state.swarm_name, state.name, message)

        new_state = %{
          state
          | handler_state: handler_state,
            state: :idle,
            message_count: state.message_count + 1
        }

        {:noreply, new_state}

      {:noreply, handler_state} ->
        new_state = %{
          state
          | handler_state: handler_state,
            state: :idle,
            message_count: state.message_count + 1
        }

        {:noreply, new_state}

      {:multi, messages, handler_state} ->
        # Send multiple messages (tagged format)
        Enum.each(messages, fn
          {:send, to, msg} ->
            route_message(state.swarm_name, state.name, to, msg)

          {:broadcast, msg} ->
            Router.broadcast(state.swarm_name, state.name, msg)
        end)

        new_state = %{
          state
          | handler_state: handler_state,
            state: :idle,
            message_count: state.message_count + 1
        }

        {:noreply, new_state}

      {:send_many, messages, handler_state} ->
        # Send multiple messages (keyword/tuple format: [{target, msg}, ...])
        Enum.each(messages, fn
          {:send, to, msg} -> route_message(state.swarm_name, state.name, to, msg)
          {:broadcast, msg} -> Router.broadcast(state.swarm_name, state.name, msg)
          {to, msg} -> route_message(state.swarm_name, state.name, to, msg)
        end)

        new_state = %{
          state
          | handler_state: handler_state,
            state: :idle,
            message_count: state.message_count + 1
        }

        {:noreply, new_state}
    end
  end

  # Private functions - Process mode

  defp handle_process_message(from, content, state) do
    # Send message to backend process as JSON
    message = Jason.encode!(%{from: from, content: content})
    send_to_backend(state, message)
    {:noreply, state}
  end

  defp send_to_backend(%{backend_ref: %{port: port}}, message) do
    Port.command(port, message <> "\n")
  end

  defp send_to_backend(%{backend_module: module, backend_ref: ref}, message) do
    module.send_input(ref, message)
  end

  defp handle_process_output(data, state) do
    full_data = state.buffer <> data

    # Try to parse as JSON response
    case Jason.decode(full_data) do
      {:ok, response} ->
        process_backend_response(response, state)

      {:error, _} ->
        # Incomplete JSON, keep buffering
        {:noreply, %{state | buffer: full_data}}
    end
  end

  defp process_backend_response(response, state) do
    # Backend responds with: {"action": "reply|send|broadcast|noreply", "to": "target", "content": "..."}
    action = Map.get(response, "action", "noreply")
    to = Map.get(response, "to")
    content = Map.get(response, "content", "")

    # Resolve the target to an existing agent only — object backends are agent
    # output too, so never mint an atom from a "to" field.
    to_atom = SafeAtom.existing(to)

    case action do
      "reply" when not is_nil(to_atom) ->
        route_message(state.swarm_name, state.name, to_atom, content)

      "send" when not is_nil(to_atom) ->
        route_message(state.swarm_name, state.name, to_atom, content)

      "broadcast" ->
        Router.broadcast(state.swarm_name, state.name, content)

      _ ->
        :ok
    end

    new_state = %{state | buffer: "", state: :idle, message_count: state.message_count + 1}
    {:noreply, new_state}
  end

  defp route_message(swarm_name, from, to, content) do
    # Log the outgoing message
    content_preview =
      if is_binary(content) and String.length(content) > 200 do
        String.slice(content, 0, 200) <> "..."
      else
        content
      end

    LogStore.log(:info, :object, :message_sent, "Object #{from} sent message to #{to}",
      swarm: swarm_name,
      agent: from,
      metadata: %{to: to, content: content_preview}
    )

    # Route is now async (cast), always returns :ok
    Router.route(swarm_name, from, to, content)
  end

  defp emit_telemetry(event, state, metadata) do
    :telemetry.execute(
      [:genswarms, :object, event],
      %{time: System.system_time()},
      Map.merge(metadata, %{object: state.name, swarm: state.swarm_name, handler: state.handler})
    )
  end
end
