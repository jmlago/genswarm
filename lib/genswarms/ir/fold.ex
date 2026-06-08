defmodule Genswarms.IR.Fold do
  @moduledoc """
  `fold(state, events)` — applies an overlay's events to a `swarm.state` in `seq`
  order and returns the resulting state (IR spec §5.4).

  Pure and deterministic: it performs **no** runtime effects (no spawns, no
  message sends) — those are the control plane's job. Each op enforces its
  precondition and folding stops at the first violation, returning
  `{:error, {seq, reason}}` so the failure is localized to an event.

  `scale_agent_group base→N` materializes the group into instance nodes
  `base#1 … base#N` (the template `base` is replaced) and fans every edge
  incident on the group out to each instance (§4.4).
  """

  alias Genswarms.IR.{State, Overlay}
  alias Genswarms.IR.Overlay.Event

  @doc "Folds an overlay (or a list of events) onto a state."
  @spec fold(State.t(), Overlay.t() | [Event.t()]) ::
          {:ok, State.t()} | {:error, {integer(), term()}}
  def fold(%State{} = state, %Overlay{events: events}), do: fold(state, events)

  def fold(%State{} = state, events) when is_list(events) do
    Enum.reduce_while(events, {:ok, state}, fn %Event{seq: seq} = event, {:ok, s} ->
      case apply_event(s, event) do
        {:ok, s2} -> {:cont, {:ok, s2}}
        {:error, reason} -> {:halt, {:error, {seq, reason}}}
      end
    end)
  end

  # ── op application ──────────────────────────────────────────────────────────

  defp apply_event(s, %Event{op: :add_agent, payload: p}) do
    with {:ok, agent} <- State.parse_agent(p) do
      if node_exists?(s, agent.name),
        do: {:error, {:agent_exists, agent.name}},
        else: {:ok, %{s | agents: s.agents ++ [agent]}}
    end
  end

  defp apply_event(s, %Event{op: :add_object, payload: p}) do
    with {:ok, object} <- State.parse_object(p) do
      if node_exists?(s, object.name),
        do: {:error, {:object_exists, object.name}},
        else: {:ok, %{s | objects: s.objects ++ [object]}}
    end
  end

  defp apply_event(s, %Event{op: :remove_agent, payload: %{"name" => name}}) do
    if Enum.any?(s.agents, &(&1.name == name)) do
      {:ok,
       %{
         s
         | agents: Enum.reject(s.agents, &(&1.name == name)),
           topology: drop_incident(s.topology, name)
       }}
    else
      {:error, {:agent_not_found, name}}
    end
  end

  defp apply_event(s, %Event{op: :remove_object, payload: %{"name" => name}}) do
    if Enum.any?(s.objects, &(&1.name == name)) do
      {:ok,
       %{
         s
         | objects: Enum.reject(s.objects, &(&1.name == name)),
           topology: drop_incident(s.topology, name)
       }}
    else
      {:error, {:object_not_found, name}}
    end
  end

  defp apply_event(s, %Event{op: :add_topology_edges, payload: %{"edges" => edges}}) do
    pairs = Enum.map(edges, fn [f, t] -> {f, t} end)

    case Enum.find(pairs, fn {f, t} -> not node_exists?(s, f) or not node_exists?(s, t) end) do
      nil ->
        {:ok, %{s | topology: s.topology ++ Enum.reject(pairs, &(&1 in s.topology))}}

      {f, t} ->
        missing = if node_exists?(s, f), do: t, else: f
        {:error, {:unknown_edge_endpoint, missing}}
    end
  end

  defp apply_event(s, %Event{op: :remove_topology_edges, payload: %{"edges" => edges}}) do
    drop = MapSet.new(Enum.map(edges, fn [f, t] -> {f, t} end))
    {:ok, %{s | topology: Enum.reject(s.topology, &MapSet.member?(drop, &1))}}
  end

  defp apply_event(s, %Event{op: :set_options, payload: %{"options" => opts}}) do
    {:ok, %{s | options: Map.merge(s.options, opts)}}
  end

  defp apply_event(s, %Event{op: :update_config, payload: %{"target" => target, "config" => cfg}}) do
    update_config(s, target, cfg)
  end

  defp apply_event(s, %Event{op: :bump_package, payload: p}) do
    bump(s, p["target"], p["field"], p["from"], p["to"])
  end

  defp apply_event(s, %Event{
         op: :scale_agent_group,
         payload: %{"base_name" => base, "target_count" => n}
       }) do
    scale_group(s, base, n)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp node_exists?(s, name),
    do: Enum.any?(s.agents, &(&1.name == name)) or Enum.any?(s.objects, &(&1.name == name))

  defp drop_incident(topology, name),
    do: Enum.reject(topology, fn {f, t} -> f == name or t == name end)

  defp update_config(s, target, cfg) do
    cond do
      agent = Enum.find(s.agents, &(&1.name == target)) ->
        updated = %{agent | config: Map.merge(agent.config, cfg)}
        {:ok, %{s | agents: replace_named(s.agents, target, updated)}}

      object = Enum.find(s.objects, &(&1.name == target)) ->
        updated = %{object | config: Map.merge(object.config, cfg)}
        {:ok, %{s | objects: replace_named(s.objects, target, updated)}}

      true ->
        {:error, {:target_not_found, target}}
    end
  end

  defp replace_named(list, name, replacement),
    do: Enum.map(list, fn item -> if item.name == name, do: replacement, else: item end)

  # ── bump_package ────────────────────────────────────────────────────────────

  defp bump(s, target, field, from, to) do
    cond do
      agent = Enum.find(s.agents, &(&1.name == target)) ->
        with {:ok, updated} <- bump_agent(agent, field, from, to),
             do: {:ok, %{s | agents: replace_named(s.agents, target, updated)}}

      object = Enum.find(s.objects, &(&1.name == target)) ->
        with {:ok, updated} <- bump_object(object, field, from, to),
             do: {:ok, %{s | objects: replace_named(s.objects, target, updated)}}

      true ->
        {:error, {:target_not_found, target}}
    end
  end

  defp bump_agent(agent, "body", from, to),
    do: with({:ok, ref} <- swap(agent.body, from, to), do: {:ok, %{agent | body: ref}})

  defp bump_agent(agent, "backend", from, to),
    do: with({:ok, ref} <- swap(agent.backend, from, to), do: {:ok, %{agent | backend: ref}})

  defp bump_agent(agent, "model", from, to) do
    {tag, ref} = agent.model

    with {:ok, swapped} <- swap(ref, from, to),
         do: {:ok, %{agent | model: {tag, swapped}}}
  end

  defp bump_agent(_agent, field, _from, _to), do: {:error, {:invalid_bump_field, field}}

  defp bump_object(object, "handler", from, to),
    do: with({:ok, ref} <- swap(object.handler, from, to), do: {:ok, %{object | handler: ref}})

  defp bump_object(_object, field, _from, _to), do: {:error, {:invalid_bump_field, field}}

  # Swap a ref's digest, asserting the current digest matches `from` (§4.5 guard).
  defp swap(%{digest: from} = ref, from, to), do: {:ok, %{ref | digest: to}}

  defp swap(%{digest: actual}, from, _to),
    do: {:error, {:bump_digest_mismatch, expected: from, got: actual}}

  # ── scale_agent_group (§4.4) ────────────────────────────────────────────────

  defp scale_group(s, base, n) do
    members = Enum.filter(s.agents, &group_member?(&1.name, base))

    case template_for(members, base) do
      nil ->
        {:error, {:scale_base_not_found, base}}

      template ->
        instances = for i <- 1..n//1, do: %{template | name: instance_name(base, i)}
        others = Enum.reject(s.agents, &group_member?(&1.name, base))
        member_names = MapSet.new(Enum.map(members, & &1.name))
        topology = fan_out_edges(s.topology, base, member_names, n)
        {:ok, %{s | agents: others ++ instances, topology: topology}}
    end
  end

  # An agent belongs to group `base` if it is `base` itself or `base#<int>`.
  defp group_member?(name, base) do
    name == base or
      case String.split(name, "#", parts: 2) do
        [^base, suffix] -> match?({_, ""}, Integer.parse(suffix))
        _ -> false
      end
  end

  defp template_for([], _base), do: nil

  defp template_for(members, base) do
    agent = Enum.find(members, &(&1.name == base)) || hd(members)
    %{agent | name: base}
  end

  defp instance_name(base, i), do: base <> "#" <> Integer.to_string(i)

  # Rewrite edges: endpoints on the group normalize to `base`, then every edge
  # mentioning `base` fans out to base#1..base#n. Non-group edges are untouched.
  defp fan_out_edges(topology, base, member_names, n) do
    in_group = fn name -> name == base or MapSet.member?(member_names, name) end

    topology
    |> Enum.flat_map(fn {f, t} ->
      nf = if in_group.(f), do: base, else: f
      nt = if in_group.(t), do: base, else: t
      expand_edge(nf, nt, base, n)
    end)
    |> Enum.uniq()
  end

  defp expand_edge(base, base, base, n),
    do: for(i <- 1..n//1, do: {instance_name(base, i), instance_name(base, i)})

  defp expand_edge(base, t, base, n), do: for(i <- 1..n//1, do: {instance_name(base, i), t})
  defp expand_edge(f, base, base, n), do: for(i <- 1..n//1, do: {f, instance_name(base, i)})
  defp expand_edge(f, t, _base, _n), do: [{f, t}]
end
