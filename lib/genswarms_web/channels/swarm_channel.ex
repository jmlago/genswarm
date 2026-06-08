defmodule GenswarmsWeb.SwarmChannel do
  @moduledoc """
  Channel for real-time swarm communication.

  Supports:
  - Sending tasks to agents
  - Getting swarm status
  - Subscribing to real-time log streams
  - Subscribing to real-time event streams
  """

  use GenswarmsWeb, :channel

  alias Genswarms.SwarmManager
  alias Genswarms.CLI.SwarmRegistry
  alias Genswarms.Observability.EventStore

  @impl true
  def join("swarm:" <> swarm_name, _params, socket) do
    # Verify swarm exists (check in-process and SQLite)
    swarm_exists =
      case SwarmManager.status(swarm_name) do
        {:ok, _status} ->
          true

        {:error, :not_found} ->
          case SwarmRegistry.get_swarm(swarm_name) do
            {:ok, _} -> true
            _ -> false
          end
      end

    if swarm_exists do
      # Subscribe to swarm events
      Phoenix.PubSub.subscribe(Genswarms.PubSub, "swarm:#{swarm_name}")
      Phoenix.PubSub.subscribe(Genswarms.PubSub, "swarm:#{swarm_name}:output")
      Phoenix.PubSub.subscribe(Genswarms.PubSub, "swarm:#{swarm_name}:routing")
      Phoenix.PubSub.subscribe(Genswarms.PubSub, "swarm:#{swarm_name}:status")

      socket =
        socket
        |> assign(:swarm_name, swarm_name)
        |> assign(:log_subscriptions, MapSet.new())
        |> assign(:event_subscriptions, MapSet.new())

      {:ok, %{swarm: swarm_name}, socket}
    else
      {:error, %{reason: "swarm_not_found"}}
    end
  end

  @impl true
  # Send task to an agent
  def handle_in("send_task", %{"agent" => agent, "task" => task}, socket) do
    swarm_name = socket.assigns.swarm_name

    case SwarmManager.send_task(swarm_name, agent, task) do
      :ok ->
        {:reply, {:ok, %{status: "sent"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: GenswarmsWeb.SwarmController.format_error(reason)}}, socket}
    end
  end

  # Get swarm status
  def handle_in("get_status", _params, socket) do
    swarm_name = socket.assigns.swarm_name

    case SwarmManager.status(swarm_name) do
      {:ok, status} ->
        {:reply, {:ok, status}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: GenswarmsWeb.SwarmController.format_error(reason)}}, socket}
    end
  end

  # Subscribe to log stream for a specific agent or all agents
  # Payload: { "agent": "agent_name" } or {} for all agents
  def handle_in("subscribe_logs", payload, socket) do
    swarm_name = socket.assigns.swarm_name
    agent = Map.get(payload, "agent")

    # Subscribe to log events PubSub
    topic =
      if agent do
        "log_store:events:#{swarm_name}:#{agent}"
      else
        "log_store:events:#{swarm_name}"
      end

    Phoenix.PubSub.subscribe(Genswarms.PubSub, topic)

    log_subs = MapSet.put(socket.assigns.log_subscriptions, {agent, topic})
    socket = assign(socket, :log_subscriptions, log_subs)

    # Send recent logs as initial data (from the shared store, so daemon swarms
    # in other BEAMs are visible too — the live stream then arrives via EventRelay).
    recent_logs =
      if agent do
        EventStore.query(swarm: swarm_name, agent: String.to_atom(agent), limit: 50)
      else
        EventStore.query(swarm: swarm_name, limit: 50)
      end
      |> Enum.map(&format_log_entry/1)
      |> Enum.reverse()

    {:reply, {:ok, %{subscribed: true, agent: agent, recent_logs: recent_logs}}, socket}
  end

  # Unsubscribe from log stream
  # Payload: { "agent": "agent_name" } or {} for all agents
  def handle_in("unsubscribe_logs", payload, socket) do
    swarm_name = socket.assigns.swarm_name
    agent = Map.get(payload, "agent")

    topic =
      if agent do
        "log_store:events:#{swarm_name}:#{agent}"
      else
        "log_store:events:#{swarm_name}"
      end

    Phoenix.PubSub.unsubscribe(Genswarms.PubSub, topic)

    log_subs = MapSet.delete(socket.assigns.log_subscriptions, {agent, topic})
    socket = assign(socket, :log_subscriptions, log_subs)

    {:reply, {:ok, %{unsubscribed: true, agent: agent}}, socket}
  end

  # Subscribe to event stream with optional filters
  # Payload: { "filters": { "level": "error", "category": "routing" } }
  def handle_in("subscribe_events", payload, socket) do
    swarm_name = socket.assigns.swarm_name
    filters = Map.get(payload, "filters", %{})

    # Subscribe to general event stream
    topic = "log_store:events:#{swarm_name}"
    Phoenix.PubSub.subscribe(Genswarms.PubSub, topic)

    event_subs = MapSet.put(socket.assigns.event_subscriptions, {filters, topic})
    socket = assign(socket, :event_subscriptions, event_subs)

    # Send recent events matching filters
    query_opts =
      [swarm: swarm_name, limit: 50]
      |> maybe_add_filter(filters, "level", :level)
      |> maybe_add_filter(filters, "category", :category)
      |> maybe_add_filter(filters, "event_type", :event_type)

    recent_events =
      EventStore.query(query_opts)
      |> Enum.map(&format_event/1)
      |> Enum.reverse()

    {:reply, {:ok, %{subscribed: true, filters: filters, recent_events: recent_events}}, socket}
  end

  # Unsubscribe from event stream
  def handle_in("unsubscribe_events", _payload, socket) do
    swarm_name = socket.assigns.swarm_name
    topic = "log_store:events:#{swarm_name}"

    Phoenix.PubSub.unsubscribe(Genswarms.PubSub, topic)

    socket = assign(socket, :event_subscriptions, MapSet.new())

    {:reply, {:ok, %{unsubscribed: true}}, socket}
  end

  @impl true
  def handle_info({:agent_output, agent, content}, socket) do
    push(socket, "agent_output", %{agent: agent, content: content})
    {:noreply, socket}
  end

  def handle_info({:message_routed, data}, socket) do
    push(socket, "message_routed", data)
    {:noreply, socket}
  end

  def handle_info({:message_broadcast, data}, socket) do
    push(socket, "message_broadcast", data)
    {:noreply, socket}
  end

  def handle_info({:agent_status, agent, state}, socket) do
    push(socket, "agent_status", %{agent: agent, state: state})
    {:noreply, socket}
  end

  def handle_info({:swarm_started, _name, status}, socket) do
    push(socket, "swarm_started", %{status: to_string(status)})
    {:noreply, socket}
  end

  def handle_info({:swarm_stopped, _name}, socket) do
    push(socket, "swarm_stopped", %{})
    {:noreply, socket}
  end

  # Dynamic swarm mutation events
  def handle_info({:agent_added, _swarm, name, spec}, socket) do
    push(socket, "agent_added", %{name: to_string(name), spec: serialize_spec(spec)})
    {:noreply, socket}
  end

  def handle_info({:agent_removed, _swarm, name}, socket) do
    push(socket, "agent_removed", %{name: to_string(name)})
    {:noreply, socket}
  end

  def handle_info({:topology_changed, _swarm}, socket) do
    push(socket, "topology_changed", %{})
    {:noreply, socket}
  end

  # Handle log events from PubSub
  def handle_info({:log_event, event}, socket) do
    # Check if event matches any log subscriptions
    if should_push_log?(socket, event) do
      push(socket, "log_entry", format_log_entry(event))
    end

    # Check if event matches any event subscriptions
    if should_push_event?(socket, event) do
      push(socket, "event", format_event(event))
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private helpers

  defp should_push_log?(socket, event) do
    log_subs = socket.assigns.log_subscriptions

    Enum.any?(log_subs, fn {agent, _topic} ->
      is_nil(agent) or event.agent == String.to_atom(agent)
    end)
  end

  defp should_push_event?(socket, event) do
    event_subs = socket.assigns.event_subscriptions

    Enum.any?(event_subs, fn {filters, _topic} ->
      matches_filters?(event, filters)
    end)
  end

  defp matches_filters?(event, filters) do
    Enum.all?(filters, fn {key, value} ->
      case key do
        "level" -> event.level == String.to_atom(value)
        "category" -> event.category == String.to_atom(value)
        "event_type" -> event.event_type == String.to_atom(value)
        _ -> true
      end
    end)
  end

  defp maybe_add_filter(opts, filters, key, opt_key) do
    case Map.get(filters, key) do
      nil -> opts
      value -> Keyword.put(opts, opt_key, String.to_atom(value))
    end
  end

  defp format_log_entry(event) do
    %{
      id: event.id,
      timestamp: format_timestamp(event.timestamp),
      level: event.level,
      agent: event.agent,
      event_type: event.event_type,
      message: event.message,
      metadata: event.metadata
    }
  end

  defp format_event(event) do
    %{
      id: event.id,
      timestamp: format_timestamp(event.timestamp),
      level: event.level,
      category: event.category,
      swarm: event.swarm,
      agent: event.agent,
      event_type: event.event_type,
      message: event.message,
      metadata: event.metadata
    }
  end

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(ts) when is_binary(ts), do: ts
  defp format_timestamp(_), do: nil

  defp serialize_spec(spec) when is_map(spec) do
    Map.new(spec, fn {k, v} -> {to_string(k), serialize_spec_value(v)} end)
  end

  defp serialize_spec(spec), do: inspect(spec)

  defp serialize_spec_value(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)
  defp serialize_spec_value(v) when is_list(v), do: Enum.map(v, &serialize_spec_value/1)
  defp serialize_spec_value(v) when is_map(v), do: serialize_spec(v)

  defp serialize_spec_value(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&serialize_spec_value/1)

  defp serialize_spec_value(v), do: v
end
