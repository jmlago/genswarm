defmodule Genswarms.SafeAtom do
  @moduledoc """
  Safe conversion of untrusted strings into atoms.

  Calling `String.to_atom/1` on attacker-controlled input is an atom-table
  exhaustion DoS: the BEAM atom table is bounded (~1M entries by default) and is
  never garbage-collected, so a stream of requests carrying distinct values
  (`?agent=a1`, `a2`, … `a999999`) eventually crashes the whole node.

  Names that legitimately refer to live entities — swarms, agents, event levels,
  categories — were already interned as atoms when the swarm/config was loaded
  or the agent was started. So request handlers that merely *look up*, *route to*
  or *filter by* such a name should resolve it with `existing/1`, which converts
  only to an already-existing atom and returns `nil` for anything else. A `nil`
  result means "no such known name", which the caller maps to a 404, an empty
  result, or a non-match — never to a freshly minted atom.

  Atom *creation* from operator-controlled input (loading a swarm config, adding
  an agent) is bounded and intentional; those paths keep using
  `String.to_atom/1`.
  """

  @doc """
  Converts `value` to an already-existing atom, or returns `nil`.

  Atoms pass through unchanged. Binaries are converted only if the atom already
  exists. Anything else (including non-binaries) returns `nil`.
  """
  @spec existing(term()) :: atom() | nil
  def existing(value) when is_atom(value), do: value

  def existing(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  def existing(_), do: nil
end
