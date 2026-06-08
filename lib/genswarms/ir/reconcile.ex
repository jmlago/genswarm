defmodule Genswarms.IR.Reconcile do
  @moduledoc """
  Computes the plan that drives a live swarm's **observed** state toward a
  **desired** state — the pure half of actuation (the reconciler lives in the
  gap between desired and observed, §3.1).

  `plan(desired, observed)` returns an ordered list of actions. It is pure: it
  does not touch the runtime. An executor (separate, effectful) maps each action
  onto the orchestrator (SwarmManager/AgentServer) — that is where the runtime
  decisions live and is built next.

  Ordering is safe to apply top-to-bottom: new nodes are started before edges
  reference them, and nodes are stopped last (the runtime drops their incident
  edges):

      start nodes → restart changed nodes → add edges → remove edges → stop nodes

  A node counts as *changed* when its spec differs (body/model/backend/handler/
  overrides/config) — actuated as a restart for now; digest-only `bump_package`
  hot-swaps are a later refinement (they need the overlay op, not just the diff).
  """

  alias Genswarms.IR.State

  @type action ::
          {:start_agent, State.Agent.t()}
          | {:restart_agent, State.Agent.t()}
          | {:stop_agent, String.t()}
          | {:start_object, State.Object.t()}
          | {:restart_object, State.Object.t()}
          | {:stop_object, String.t()}
          | {:add_edge, State.edge()}
          | {:remove_edge, State.edge()}

  @doc "Ordered actions that bring `observed` to `desired`."
  @spec plan(State.t(), State.t()) :: [action()]
  def plan(%State{} = desired, %State{} = observed) do
    {a_start, a_restart, a_stop} =
      diff_nodes(desired.agents, observed.agents, :start_agent, :restart_agent, :stop_agent)

    {o_start, o_restart, o_stop} =
      diff_nodes(desired.objects, observed.objects, :start_object, :restart_object, :stop_object)

    {e_add, e_remove} = diff_edges(desired.topology, observed.topology)

    a_start ++ o_start ++ a_restart ++ o_restart ++ e_add ++ e_remove ++ a_stop ++ o_stop
  end

  @doc "True when no actions are needed (observed already equals desired)."
  @spec converged?(State.t(), State.t()) :: boolean()
  def converged?(desired, observed), do: plan(desired, observed) == []

  # ── node diff ───────────────────────────────────────────────────────────────

  defp diff_nodes(desired, observed, start_tag, restart_tag, stop_tag) do
    observed_by = Map.new(observed, &{&1.name, &1})
    desired_names = MapSet.new(desired, & &1.name)
    observed_names = MapSet.new(Map.keys(observed_by))

    starts =
      for node <- desired, not MapSet.member?(observed_names, node.name), do: {start_tag, node}

    stops =
      for node <- observed,
          not MapSet.member?(desired_names, node.name),
          do: {stop_tag, node.name}

    restarts =
      for node <- desired,
          MapSet.member?(observed_names, node.name),
          node != Map.fetch!(observed_by, node.name),
          do: {restart_tag, node}

    {starts, restarts, stops}
  end

  # ── edge diff ───────────────────────────────────────────────────────────────

  defp diff_edges(desired, observed) do
    desired_set = MapSet.new(desired)
    observed_set = MapSet.new(observed)

    add = for e <- desired, not MapSet.member?(observed_set, e), do: {:add_edge, e}
    remove = for e <- observed, not MapSet.member?(desired_set, e), do: {:remove_edge, e}
    {add, remove}
  end
end
