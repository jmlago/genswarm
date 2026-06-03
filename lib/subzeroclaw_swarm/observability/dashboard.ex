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
  """
  @spec session_history(String.t(), String.t()) ::
          {:ok, [map()]} | {:fallback, String.t()} | {:not_found}
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

  defp topology_for(swarm_name) do
    case Router.get_topology(swarm_name) do
      %{} = adj -> Enum.map(adj, fn {from, targets} -> %{from: from, targets: targets} end)
      list when is_list(list) -> list
      _ -> []
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
  defp fold_contributions(status, contributions) do
    init = {[], %{}, nil, []}

    {sessions, extensions, pool, warns} =
      Enum.reduce(status.objects, init, fn o, {sess, ext, pool, warns} ->
        name = to_string(o.name)

        case Map.get(contributions, o.name) do
          {:error, kind} ->
            {sess, ext, pool, [warn(name, "object_#{kind}", "object #{name} #{kind}") | warns]}

          :no_dashboard ->
            {sess, ext, pool, warns}

          list when is_list(list) ->
            Enum.reduce(list, {sess, ext, pool, warns}, &merge_contribution(&1, &2, name))

          nil ->
            {sess, ext, pool, warns}

          other ->
            {sess, ext, pool, [warn(name, "object_crash", "unexpected: #{inspect(other)}") | warns]}
        end
      end)

    warns =
      if sessions == [],
        do: [warn(nil, "missing_sessions_source", "no object emitted sessions") | warns],
        else: warns

    {sessions, extensions, pool, Enum.reverse(warns)}
  end

  defp merge_contribution(%{kind: :sessions, items: items} = c, {sess, ext, pool, warns}, name) do
    if is_list(items) do
      {sess ++ items, ext, c[:pool] || pool, warns}
    else
      {sess, ext, pool, [warn(name, "invalid_sessions_payload", "items not a list") | warns]}
    end
  end

  defp merge_contribution(%{kind: :extension, name: ename, data: data}, {sess, ext, pool, warns}, _name)
       when is_binary(ename) and is_map(data) do
    {sess, Map.put(ext, ename, data), pool, warns}
  end

  defp merge_contribution(_bad, {sess, ext, pool, warns}, name) do
    {sess, ext, pool, [warn(name, "invalid_extension_payload", "malformed contribution") | warns]}
  end

  # ── helpers ────────────────────────────────────────────────────────────────
  defp normalize_edges(topology) do
    Enum.flat_map(topology, fn %{from: from, targets: targets} ->
      Enum.map(targets, fn to -> %{from: to_string(from), to: to_string(to)} end)
    end)
  end

  defp warn(object, code, reason), do: %{object: object, code: code, reason: reason}
end
