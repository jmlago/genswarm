defmodule Genswarms.IR do
  @moduledoc """
  Public façade for the GenSwarms Intermediate Representation.

  Ties the core modules together and exposes the operations the control plane
  needs:

    * `state/1` / `overlay/1` — parse + validate IR documents (`IR.State`,
      `IR.Overlay`);
    * `apply_op/3` — the single-writer's per-op primitive: **validate the
      proposed op's security policy (`IR.OpPolicy`), then fold it structurally
      (`IR.Fold`)**. This is where authority/resource limits and structural
      preconditions are both enforced, at the one choke point every mutation
      passes through (§5.1);
    * `apply_overlay/3` — apply a whole overlay, op by op, threading the state;
    * `materialize/2` — fold a seed + overlay into the desired state / checkpoint
      (§5.4);
    * `compact/3` — checkpoint + log truncation (§5.6): fold the prefix into a
      checkpoint so later folds start from it instead of replaying the whole log.

  Everything is pure data over JSON-decoded maps — no eval, no atom minting.
  """

  alias Genswarms.IR.{State, Overlay, Fold, OpPolicy}
  alias Genswarms.IR.Overlay.Event

  @doc "Parses + validates a `swarm.state` document (§3, §6)."
  @spec state(map()) :: {:ok, State.t()} | {:error, term()}
  defdelegate state(map), to: State, as: :parse

  @doc "Parses + validates a `swarm.overlay` document (§4)."
  @spec overlay(map()) :: {:ok, Overlay.t()} | {:error, term()}
  defdelegate overlay(map), to: Overlay, as: :parse

  @doc """
  Applies one proposed op to a state: security policy first (`IR.OpPolicy`),
  then the structural fold (`IR.Fold`). Returns `{:ok, state}` or
  `{:error, {seq, reason}}` localized to the event.
  """
  @spec apply_op(State.t(), Event.t(), keyword()) ::
          {:ok, State.t()} | {:error, {integer(), term()}}
  def apply_op(%State{} = state, %Event{seq: seq} = event, opts \\ []) do
    case OpPolicy.validate(event, state, opts) do
      :ok -> Fold.fold(state, [event])
      {:error, reason} -> {:error, {seq, reason}}
    end
  end

  @doc """
  Applies a whole overlay op by op (policy + fold), threading the state. Stops
  at the first rejected op with `{:error, {seq, reason}}`.
  """
  @spec apply_overlay(State.t(), Overlay.t(), keyword()) ::
          {:ok, State.t()} | {:error, {integer(), term()}}
  def apply_overlay(%State{} = state, %Overlay{events: events}, opts \\ []) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, s} ->
      case apply_op(s, event, opts) do
        {:ok, s2} -> {:cont, {:ok, s2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Materializes a seed state + overlay into the desired state (§5.4). Structural
  fold only — use `apply_overlay/3` to also enforce op policy.
  """
  @spec materialize(State.t(), Overlay.t() | [Event.t()]) ::
          {:ok, State.t()} | {:error, {integer(), term()}}
  defdelegate materialize(seed, overlay), to: Fold, as: :fold

  @doc """
  Checkpoint + compaction (§5.6): splits the overlay's events at `at_seq`, folds
  the prefix into a checkpoint state, and returns `{:ok, checkpoint, remaining}`.

  Equivalence invariant: folding `remaining` onto `checkpoint` yields the same
  state as folding the whole overlay onto the seed.
  """
  @spec compact(State.t(), Overlay.t(), integer()) ::
          {:ok, State.t(), [Event.t()]} | {:error, {integer(), term()}}
  def compact(%State{} = seed, %Overlay{events: events}, at_seq) do
    {prefix, remaining} = Enum.split_with(events, &(&1.seq <= at_seq))

    with {:ok, checkpoint} <- Fold.fold(seed, prefix) do
      {:ok, checkpoint, remaining}
    end
  end
end
