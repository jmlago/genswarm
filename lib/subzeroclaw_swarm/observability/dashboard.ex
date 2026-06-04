defmodule SubzeroclawSwarm.Observability.Dashboard do
  @moduledoc """
  Pure aggregation for the read-only dashboard endpoint. `assemble/4` takes live
  swarm status, raw topology, per-object dashboard contributions, and a timestamp,
  and produces the normalized aggregate map (nodes/edges/sessions/extensions/
  summary/warnings). No side effects — `build/1` (the live wrapper) gathers data.

  `contributions` maps an object name (atom) to one of:
    - a list of contributions (the callback's return)
    - `:no_dashboard` (object has no dashboard/1)
    - `{:error, :timeout}` | `{:error, :crash}` (the caller's timebox failed)
  """

  alias SubzeroclawSwarm.SwarmManager
  alias SubzeroclawSwarm.Routing.Router
  alias SubzeroclawSwarm.Objects.ObjectServer
  alias SubzeroclawSwarm.Agents.AgentServer

  @type warning :: %{object: String.t() | nil, code: String.t(), reason: String.t()}

  # ── live wrapper ─────────────────────────────────────────────────────────────
  @spec build(String.t()) :: {:ok, map()} | {:error, :not_found}
  def build(swarm_name) do
    case SwarmManager.status(swarm_name) do
      {:ok, status} ->
        topology = topology_for(swarm_name)
        contributions = fetch_contributions(swarm_name, status.objects)
        {:ok, assemble(status, topology, contributions, DateTime.utc_now())}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Canonical transcript for a session. Asks each object's session_history/3 (durable,
  Store-backed) and returns the first `{:ok, turns}`; otherwise `{:not_found}`.
  Bodies are NEVER in the snapshot — fetched only here.

  Note: there is no slot-level fallback. The ephemeral `AgentServer` history is the
  routed-message log, not the user-facing conversation, so it is not a meaningful
  transcript source — when no durable Store is present, the transcript is simply
  unavailable (a durable, session-keyed Store such as Wingston's `conversation_turns`
  is required). See spec §7.2c.
  """
  @spec session_history(String.t(), String.t()) :: {:ok, [map()]} | {:not_found}
  def session_history(swarm_name, session_id) do
    case SwarmManager.status(swarm_name) do
      {:ok, status} ->
        Enum.find_value(status.objects, {:not_found}, fn o ->
          case ObjectServer.get_session_history(swarm_name, o.name, session_id, %{}) do
            {:ok, turns} -> {:ok, turns}
            _ -> false
          end
        end)

      _ ->
        {:not_found}
    end
  end

  @doc """
  Raw output for a session's currently-bound slot (ephemeral — wiped on slot
  recycle). Resolves session→slot from the live `:sessions` contributions and reads
  the slot's `AgentServer` logs. `{:ok, entries}` | `{:not_found}`.
  """
  @spec session_logs(String.t(), String.t()) :: {:ok, [map()]} | {:not_found}
  def session_logs(swarm_name, session_id) do
    with {:ok, status} <- SwarmManager.status(swarm_name),
         {:ok, slot} <- resolve_slot(swarm_name, status, session_id) do
      {:ok, AgentServer.get_logs(swarm_name, slot)}
    else
      _ -> {:not_found}
    end
  rescue
    _ -> {:not_found}
  end

  # session_id → bound slot atom (only ever an already-interned pool atom, so
  # `to_existing_atom` is safe — no atom-table DoS from request input).
  defp resolve_slot(swarm_name, status, session_id) do
    case Enum.find(session_items(swarm_name, status), &(to_string(&1[:session_id] || &1["session_id"]) == session_id)) do
      nil ->
        :not_found

      item ->
        try do
          {:ok, String.to_existing_atom(to_string(item[:agent] || item["agent"]))}
        rescue
          ArgumentError -> :not_found
        end
    end
  end

  defp session_items(swarm_name, status) do
    Enum.flat_map(status.objects, fn o ->
      case safe_get_dashboard(swarm_name, o.name) do
        list when is_list(list) ->
          list |> Enum.filter(&(&1[:kind] == :sessions)) |> Enum.flat_map(&(&1[:items] || []))

        _ ->
          []
      end
    end)
  end

  defp topology_for(swarm_name) do
    case Router.get_topology(swarm_name) do
      {:ok, adj} when is_map(adj) ->
        Enum.map(adj, fn {from, targets} -> %{from: from, targets: List.wrap(targets)} end)

      %{} = adj ->
        Enum.map(adj, fn {from, targets} -> %{from: from, targets: List.wrap(targets)} end)

      list when is_list(list) ->
        list

      _ ->
        []
    end
  end

  defp fetch_contributions(swarm_name, objects) do
    Map.new(objects, fn o -> {o.name, safe_get_dashboard(swarm_name, o.name)} end)
  end

  defp safe_get_dashboard(swarm_name, object_name) do
    ObjectServer.get_dashboard(swarm_name, object_name)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :crash}
  end

  # ── pure aggregation ─────────────────────────────────────────────────────────
  @spec assemble(map(), list(), map(), DateTime.t()) :: map()
  def assemble(status, topology, contributions, now) do
    nodes = classify_nodes(status, contributions)
    {sessions, extensions, pool, warnings} = fold_contributions(status, contributions)

    %{
      swarm: status.name,
      status: to_string(status.status),
      uptime_s: DateTime.diff(now, status.started_at),
      generated_at: now,
      data_source: "in_process",
      summary: %{
        agents: length(status.agents),
        objects: length(status.objects),
        pool: pool
      },
      nodes: nodes,
      edges: normalize_edges(topology),
      sessions: sessions,
      extensions: extensions,
      warnings: warnings
    }
  end

  # ── nodes ──────────────────────────────────────────────────────────────────
  defp classify_nodes(status, contributions) do
    sess_by_agent = session_by_agent(contributions)

    objects =
      Enum.map(status.objects, fn o ->
        %{name: to_string(o.name), type: "object", subtype: subtype(o[:handler])}
      end)

    agents =
      Enum.map(status.agents, fn a ->
        base = %{name: to_string(a.name), type: "agent", state: to_string(a.state)}

        case Map.get(sess_by_agent, to_string(a.name)) do
          nil -> base
          sid -> Map.put(base, :session_id, sid)
        end
      end)

    objects ++ agents
  end

  defp subtype(nil), do: nil
  defp subtype(handler), do: handler |> Module.split() |> List.last() |> Macro.underscore()

  defp session_by_agent(contributions) do
    contributions
    |> Enum.filter(fn {_obj, v} -> is_list(v) end)
    |> Enum.flat_map(fn {_obj, list} -> list end)
    |> Enum.filter(&(&1[:kind] == :sessions and is_list(&1[:items])))
    |> Enum.flat_map(& &1.items)
    |> Enum.reduce(%{}, fn s, acc ->
      case {s[:agent], s[:session_id]} do
        {nil, _} -> acc
        {agent, sid} -> Map.put(acc, to_string(agent), sid)
      end
    end)
  end

  # ── contributions ──────────────────────────────────────────────────────────
  # Accumulator: {sessions, extensions, pool, saw_sessions?, warnings}. A valid
  # `:sessions` contribution (even with zero items) means a source exists, so
  # `missing_sessions_source` fires only when NONE was seen.
  defp fold_contributions(status, contributions) do
    init = {[], %{}, nil, false, []}

    {sessions, extensions, pool, saw_sessions, warns} =
      Enum.reduce(status.objects, init, fn o, acc ->
        name = to_string(o.name)

        case Map.get(contributions, o.name) do
          {:error, kind} -> put_warn(acc, name, "object_#{kind}", "object #{name} #{kind}")
          :no_dashboard -> acc
          nil -> acc
          list when is_list(list) -> Enum.reduce(list, acc, &merge_contribution(&1, &2, name))
          other -> put_warn(acc, name, "object_crash", "unexpected: #{inspect(other)}")
        end
      end)

    warns =
      if saw_sessions,
        do: warns,
        else: [warn(nil, "missing_sessions_source", "no object emitted sessions") | warns]

    {sessions, extensions, pool, Enum.reverse(warns)}
  end

  defp merge_contribution(%{kind: :sessions, items: items} = c, {sess, ext, pool, _saw, warns}, _name)
       when is_list(items) do
    {sess ++ items, ext, c[:pool] || pool, true, warns}
  end

  defp merge_contribution(%{kind: :sessions}, {sess, ext, pool, saw, warns}, name) do
    {sess, ext, pool, saw, [warn(name, "invalid_sessions_payload", "items not a list") | warns]}
  end

  defp merge_contribution(%{kind: :extension, name: ename, data: data}, {sess, ext, pool, saw, warns}, _name)
       when is_binary(ename) and is_map(data) do
    {sess, Map.put(ext, ename, data), pool, saw, warns}
  end

  defp merge_contribution(_bad, {sess, ext, pool, saw, warns}, name) do
    {sess, ext, pool, saw, [warn(name, "invalid_extension_payload", "malformed contribution") | warns]}
  end

  defp put_warn({sess, ext, pool, saw, warns}, object, code, reason) do
    {sess, ext, pool, saw, [warn(object, code, reason) | warns]}
  end

  # ── helpers ────────────────────────────────────────────────────────────────
  defp normalize_edges(topology) do
    Enum.flat_map(topology, fn %{from: from, targets: targets} ->
      Enum.map(targets, fn to -> %{from: to_string(from), to: to_string(to)} end)
    end)
  end

  defp warn(object, code, reason), do: %{object: object, code: code, reason: reason}
end
