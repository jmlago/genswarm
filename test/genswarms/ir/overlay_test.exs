defmodule Genswarms.IR.OverlayTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR.Overlay
  alias Genswarms.IR.Overlay.Event

  defp body_ref,
    do: %{
      "ref" => "swarmidx:jmlago/fact-checker@0.2.0",
      "digest" => "sha256:e09a00",
      "kind" => "data"
    }

  defp backend_ref,
    do: %{"ref" => "oci:szc-agent-code", "digest" => "sha256:71de00", "kind" => "data"}

  # The research-swarm overlay from spec §4.6 (digests shortened to valid hex).
  defp valid_doc do
    %{
      "v" => 1,
      "kind" => "swarm.overlay",
      "swarm" => "research-swarm",
      "apply" => "incremental",
      "events" => [
        %{
          "seq" => 1,
          "op" => "add_agent",
          "payload" => %{
            "name" => "fact_checker",
            "body" => body_ref(),
            "model" => %{"ref" => "openrouter:openai/gpt-4o-mini", "attested" => true},
            "backend" => backend_ref()
          }
        },
        %{
          "seq" => 2,
          "op" => "add_topology_edges",
          "payload" => %{"edges" => [["reviewer", "fact_checker"], ["fact_checker", "reviewer"]]}
        },
        %{
          "seq" => 3,
          "op" => "scale_agent_group",
          "payload" => %{"base_name" => "coder", "target_count" => 3, "on_inflight" => "drain"}
        },
        %{
          "seq" => 4,
          "op" => "bump_package",
          "payload" => %{
            "target" => "reviewer",
            "field" => "body",
            "from" => "sha256:c50e00",
            "to" => "sha256:f7aa00",
            "migration" => "state_migrate",
            "on_inflight" => "drain"
          }
        },
        %{
          "seq" => 5,
          "op" => "remove_agent",
          "payload" => %{"name" => "researcher", "on_inflight" => "drain"}
        }
      ]
    }
  end

  defp put_event(doc, idx, key, value),
    do: update_in(doc, ["events", Access.at(idx), key], fn _ -> value end)

  defp put_payload(doc, idx, payload),
    do: update_in(doc, ["events", Access.at(idx), "payload"], fn _ -> payload end)

  describe "parse/1 (happy path)" do
    test "parses the research-swarm overlay" do
      {:ok, overlay} = Overlay.parse(valid_doc())

      assert overlay.swarm == "research-swarm"
      assert overlay.apply == :incremental
      assert length(overlay.events) == 5

      ops = Enum.map(overlay.events, & &1.op)

      assert ops == [
               :add_agent,
               :add_topology_edges,
               :scale_agent_group,
               :bump_package,
               :remove_agent
             ]

      assert %Event{seq: 1, op: :add_agent} = hd(overlay.events)
    end

    test "apply mode defaults to incremental when omitted" do
      {:ok, overlay} = Overlay.parse(Map.delete(valid_doc(), "apply"))
      assert overlay.apply == :incremental
    end

    test "transactional apply mode is accepted" do
      {:ok, overlay} = Overlay.parse(%{valid_doc() | "apply" => "transactional"})
      assert overlay.apply == :transactional
    end
  end

  describe "envelope validation" do
    test "rejects unsupported version / wrong kind / missing swarm / bad apply" do
      assert {:error, {:unsupported_version, 2}} = Overlay.parse(%{valid_doc() | "v" => 2})

      assert {:error, {:wrong_kind, "swarm.state"}} =
               Overlay.parse(%{valid_doc() | "kind" => "swarm.state"})

      assert {:error, {:missing, "swarm"}} = Overlay.parse(Map.delete(valid_doc(), "swarm"))

      assert {:error, {:invalid_apply_mode, "soon"}} =
               Overlay.parse(%{valid_doc() | "apply" => "soon"})
    end
  end

  describe "seq ordering (§5.1)" do
    test "rejects a non-monotonic seq" do
      doc = put_event(valid_doc(), 1, "seq", 1)
      assert {:error, {:non_monotonic_seq, 1, 1}} = Overlay.parse(doc)
    end

    test "rejects a non-integer seq" do
      doc = put_event(valid_doc(), 0, "seq", "1")
      assert {:error, {:invalid_seq, "1"}} = Overlay.parse(doc)
    end
  end

  describe "op catalogue (§4.3)" do
    test "an unknown op fails validation (never silently ignored)" do
      doc = put_event(valid_doc(), 0, "op", "drop_database")
      assert {:error, {:unknown_op, "drop_database"}} = Overlay.parse(doc)
    end

    test "unknown op strings are never interned as atoms" do
      # Deterministic (concurrency-safe): if parsing minted an atom for the op
      # string, String.to_existing_atom/1 would stop raising for it.
      for n <- 1..200 do
        op = "ghost_op_#{n}"
        assert {:error, {:unknown_op, ^op}} = Overlay.parse(put_event(valid_doc(), 0, "op", op))
        assert_raise ArgumentError, fn -> String.to_existing_atom(op) end
      end
    end
  end

  describe "per-op payload validation" do
    test "add_agent enforces slot-typing (a code body is rejected)" do
      bad = %{
        "name" => "x",
        "body" => %{body_ref() | "kind" => "code"},
        "model" => %{"ref" => "openrouter:m", "attested" => true},
        "backend" => backend_ref()
      }

      assert {:error, {:slot_type_mismatch, "body", _}} =
               Overlay.parse(put_payload(valid_doc(), 0, bad))
    end

    test "remove_agent requires a name" do
      assert {:error, {:missing_field, "name"}} = Overlay.parse(put_payload(valid_doc(), 4, %{}))
    end

    test "add_topology_edges requires well-formed edges" do
      assert {:error, :invalid_edges} =
               Overlay.parse(put_payload(valid_doc(), 1, %{"edges" => [["a"]]}))
    end

    test "scale_agent_group rejects a negative target_count" do
      bad = %{"base_name" => "coder", "target_count" => -1}

      assert {:error, {:invalid_count, "target_count", -1}} =
               Overlay.parse(put_payload(valid_doc(), 2, bad))
    end

    test "bump_package validates field and digests" do
      base = %{
        "target" => "reviewer",
        "field" => "body",
        "from" => "sha256:aa",
        "to" => "sha256:bb"
      }

      assert {:error, {:invalid_bump_field, "soul"}} =
               Overlay.parse(put_payload(valid_doc(), 3, %{base | "field" => "soul"}))

      assert {:error, {:invalid_digest, "to", "latest"}} =
               Overlay.parse(put_payload(valid_doc(), 3, %{base | "to" => "latest"}))
    end

    test "invalid transition policies are rejected" do
      bad = %{"name" => "researcher", "on_inflight" => "yolo"}

      assert {:error, {:invalid_policy, "on_inflight", "yolo"}} =
               Overlay.parse(put_payload(valid_doc(), 4, bad))
    end
  end
end
