defmodule Genswarms.IR.RefTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR.Ref

  describe "parse/1" do
    test "parses a resolved swarmidx body ref (content-addressable, kind data)" do
      {:ok, ref} =
        Ref.parse(%{
          "ref" => "swarmidx:jmlago/web-researcher@1.2.3",
          "digest" => "sha256:9f2c1a",
          "kind" => "data"
        })

      assert ref.scheme == "swarmidx"
      assert ref.kind == :data
      assert ref.digest == "sha256:9f2c1a"
      assert ref.attested == false
    end

    test "parses an oci backend ref" do
      {:ok, ref} =
        Ref.parse(%{"ref" => "oci:szc-agent-code", "digest" => "sha256:71de00", "kind" => "data"})

      assert ref.scheme == "oci"
    end

    test "parses a non-hashable model ref with attested" do
      {:ok, ref} =
        Ref.parse(%{
          "ref" => "openrouter:anthropic/claude-sonnet-4",
          "kind" => "data",
          "attested" => true
        })

      assert ref.scheme == "openrouter"
      assert ref.attested == true
      assert ref.digest == nil
    end

    test "parses an ssh ref carrying a host" do
      {:ok, ref} = Ref.parse(%{"ref" => "ssh", "kind" => "data", "host" => "pi@192.168.1.50"})
      assert ref.scheme == "ssh"
      assert ref.host == "pi@192.168.1.50"
    end

    test "parses a handler ref as kind code" do
      {:ok, ref} =
        Ref.parse(%{
          "ref" => "swarmidx:jmlago/task-board@1.0.0",
          "digest" => "sha256:7b11ff",
          "kind" => "code"
        })

      assert ref.kind == :code
    end

    test "rejects a missing/blank ref" do
      assert Ref.parse(%{"kind" => "data"}) == {:error, :missing_ref}
      assert Ref.parse(%{"ref" => "", "kind" => "data"}) == {:error, :missing_ref}
    end

    test "rejects a ref string without a scheme" do
      assert Ref.parse(%{"ref" => "no-scheme", "kind" => "data"}) ==
               {:error, :invalid_ref_string}
    end

    test "rejects a missing or invalid kind" do
      assert Ref.parse(%{"ref" => "oci:x"}) == {:error, :missing_kind}

      assert Ref.parse(%{"ref" => "oci:x", "kind" => "binary"}) ==
               {:error, {:invalid_kind, "binary"}}
    end

    test "rejects an ssh ref without a host" do
      assert Ref.parse(%{"ref" => "ssh", "kind" => "data"}) == {:error, {:missing_host, "ssh"}}
    end

    test "rejects a non-boolean attested" do
      assert Ref.parse(%{"ref" => "oci:x", "kind" => "data", "attested" => "yes"}) ==
               {:error, {:invalid_attested, "yes"}}
    end

    test "rejects a non-map" do
      assert Ref.parse("oci:x") == {:error, :ref_not_a_map}
    end
  end

  describe "scheme/1 and content_addressable?/1" do
    test "extracts the scheme" do
      assert Ref.scheme("swarmidx:jmlago/coder@0.4.0") == {:ok, "swarmidx"}
      assert Ref.scheme("oci:img") == {:ok, "oci"}
    end

    test "rejects malformed ref strings" do
      assert Ref.scheme("nocolon") == {:error, :invalid_ref_string}
      assert Ref.scheme(":empty-scheme") == {:error, :invalid_ref_string}
      assert Ref.scheme("swarmidx:") == {:error, :invalid_ref_string}
    end

    test "swarmidx and oci are content-addressable; openrouter and ssh are not" do
      assert Ref.content_addressable?("swarmidx")
      assert Ref.content_addressable?("oci")
      refute Ref.content_addressable?("openrouter")
      refute Ref.content_addressable?("ssh")
    end
  end

  describe "validate_resolved/1 (digest presence rule §2.3)" do
    defp ref!(map), do: Ref.parse(map) |> elem(1)

    test "content-addressable ref with a valid digest passes" do
      ref = ref!(%{"ref" => "swarmidx:a/b@1.0.0", "digest" => "sha256:9f2c", "kind" => "data"})
      assert Ref.validate_resolved(ref) == :ok
    end

    test "content-addressable ref without a digest fails (unresolved)" do
      ref = ref!(%{"ref" => "swarmidx:a/b@1.0.0", "kind" => "data"})
      assert Ref.validate_resolved(ref) == {:error, :missing_digest}
    end

    test "content-addressable ref with a malformed digest fails" do
      ref = ref!(%{"ref" => "oci:img", "digest" => "notadigest", "kind" => "data"})
      assert {:error, {:invalid_digest, "notadigest"}} = Ref.validate_resolved(ref)
    end

    test "non-hashable ref must not carry a digest" do
      ref = ref!(%{"ref" => "openrouter:x", "digest" => "sha256:9f2c", "kind" => "data"})
      assert Ref.validate_resolved(ref) == {:error, :unexpected_digest}
    end

    test "non-hashable ref without a digest passes" do
      ref = ref!(%{"ref" => "openrouter:x", "kind" => "data", "attested" => true})
      assert Ref.validate_resolved(ref) == :ok
    end
  end

  describe "valid_digest?/1" do
    test "accepts <algo>:<hex>, rejects the rest" do
      assert Ref.valid_digest?("sha256:9f2c1a3b")
      refute Ref.valid_digest?("sha256")
      refute Ref.valid_digest?("9f2c1a3b")
      refute Ref.valid_digest?("sha256:ZZZZ")
      refute Ref.valid_digest?(nil)
    end
  end
end
