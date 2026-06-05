defmodule GenswarmWeb.EventsController do
  @moduledoc """
  REST API controller for querying events from LogStore.
  """

  use GenswarmWeb, :controller

  alias Genswarm.Observability.LogStore

  @doc """
  Lists events with optional filtering.

  GET /api/events
  Query params:
    - level: error, warning, info, debug
    - category: backend, routing, agent, swarm, system
    - swarm: swarm name
    - agent: agent name
    - event_type: specific event type
    - minutes: events from last N minutes
    - limit: max events (default 100)
  """
  def index(conn, params) do
    query_opts = build_query_opts(params)
    events = LogStore.query(query_opts)

    json(conn, %{
      events: Enum.map(events, &format_event/1),
      count: length(events),
      query: Map.new(query_opts)
    })
  end

  @doc """
  Lists events for a specific swarm.

  GET /api/swarms/:swarm_name/events
  """
  def swarm_events(conn, %{"swarm_name" => swarm_name} = params) do
    query_opts =
      params
      |> Map.put("swarm", swarm_name)
      |> build_query_opts()

    events = LogStore.query(query_opts)

    json(conn, %{
      events: Enum.map(events, &format_event/1),
      count: length(events),
      swarm: swarm_name
    })
  end

  @doc """
  Lists events for a specific agent.

  GET /api/swarms/:swarm_name/agents/:agent_name/events
  """
  def agent_events(conn, %{"swarm_name" => swarm_name, "agent_name" => agent_name} = params) do
    query_opts =
      params
      |> Map.put("swarm", swarm_name)
      |> Map.put("agent", agent_name)
      |> build_query_opts()

    events = LogStore.query(query_opts)

    json(conn, %{
      events: Enum.map(events, &format_event/1),
      count: length(events),
      swarm: swarm_name,
      agent: agent_name
    })
  end

  # Build query options from params
  defp build_query_opts(params) do
    opts = []

    opts =
      if params["level"] do
        level = String.to_existing_atom(params["level"])
        Keyword.put(opts, :level, level)
      else
        opts
      end

    opts =
      if params["category"] do
        category = String.to_existing_atom(params["category"])
        Keyword.put(opts, :category, category)
      else
        opts
      end

    opts =
      if params["swarm"] do
        Keyword.put(opts, :swarm, params["swarm"])
      else
        opts
      end

    opts =
      if params["agent"] do
        agent = String.to_atom(params["agent"])
        Keyword.put(opts, :agent, agent)
      else
        opts
      end

    opts =
      if params["event_type"] do
        event_type = String.to_existing_atom(params["event_type"])
        Keyword.put(opts, :event_type, event_type)
      else
        opts
      end

    opts =
      if params["minutes"] do
        minutes = String.to_integer(params["minutes"])
        Keyword.put(opts, :minutes, minutes)
      else
        opts
      end

    limit =
      case params["limit"] do
        nil -> 100
        l when is_binary(l) -> String.to_integer(l)
        l when is_integer(l) -> l
      end

    Keyword.put(opts, :limit, limit)
  end

  # Format event for JSON response
  defp format_event(event) do
    %{
      id: event.id,
      timestamp: DateTime.to_iso8601(event.timestamp),
      level: event.level,
      category: event.category,
      swarm: event.swarm,
      agent: event.agent,
      event_type: event.event_type,
      message: event.message,
      metadata: event.metadata
    }
  end
end
