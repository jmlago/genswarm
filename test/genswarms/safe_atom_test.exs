defmodule Genswarms.SafeAtomTest do
  # async: false so the atom-count invariant test below is measured in the sync
  # phase, where no concurrent test can mint atoms during the measurement window.
  use ExUnit.Case, async: false

  alias Genswarms.SafeAtom

  describe "existing/1" do
    test "converts a binary that names an already-existing atom" do
      # :erlang is guaranteed to exist as an atom.
      assert SafeAtom.existing("erlang") == :erlang
    end

    test "returns the atom unchanged when given an atom" do
      assert SafeAtom.existing(:already_an_atom) == :already_an_atom
      assert SafeAtom.existing(nil) == nil
      assert SafeAtom.existing(true) == true
    end

    test "returns nil for a binary whose atom does not exist" do
      # A string that has never been (and won't be) interned.
      assert SafeAtom.existing("nope_this_atom_was_never_created_12345") == nil
    end

    test "returns nil for non-binary, non-atom input" do
      assert SafeAtom.existing(123) == nil
      assert SafeAtom.existing(1.5) == nil
      assert SafeAtom.existing(["a"]) == nil
      assert SafeAtom.existing(%{}) == nil
      assert SafeAtom.existing({:a, :b}) == nil
    end

    test "resolves an atom created elsewhere at runtime" do
      # Intern an atom, then prove existing/1 can resolve it by name.
      _ = :erlang.binary_to_atom("safe_atom_runtime_probe", :utf8)
      assert SafeAtom.existing("safe_atom_runtime_probe") == :safe_atom_runtime_probe
    end

    test "does NOT create a new atom for an unknown binary (DoS invariant)" do
      # The core security property: feeding distinct unknown strings must never
      # grow the atom table. Build strings the compiler/runtime cannot have
      # interned, then assert the atom count is unchanged.
      unique =
        for i <- 1..500 do
          "safe_atom_dos_probe_" <> Integer.to_string(i) <> "_" <> Integer.to_string(i * 7919)
        end

      before = :erlang.system_info(:atom_count)
      results = Enum.map(unique, &SafeAtom.existing/1)
      after_count = :erlang.system_info(:atom_count)

      assert Enum.all?(results, &is_nil/1)
      assert after_count == before, "existing/1 minted atoms: #{after_count - before} new"
    end
  end
end
