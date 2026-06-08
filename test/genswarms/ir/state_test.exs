defmodule Genswarms.IR.StateTest do
  use ExUnit.Case, async: true

  alias Genswarms.IR.State
  alias Genswarms.IR.State.{Agent, Object}

  # The resolved research-swarm from spec §3.7 (digests shortened to valid hex).
  defp valid_doc do
    %{
      "v" => 1,
      "kind" => "swarm.state",
      "name" => "research-swarm",
      "phase" => "desired",
      "agents" => [
        %{
          "name" => "researcher",
          "body" => %{
            "ref" => "swarmidx:jmlago/web-researcher@1.2.3",
            "digest" => "sha256:9f2c1a",
            "kind" => "data"
          },
          "model" => %{"ref" => "openrouter:anthropic/claude-sonnet-4", "attested" => true},
          "backend" => %{
            "ref" => "oci:szc-agent-code",
            "digest" => "sha256:71de00",
            "kind" => "data"
          },
          "overrides" => %{"presets" => ["base", "web"]}
        },
        %{
          "name" => "coder",
          "body" => %{
            "ref" => "swarmidx:jmlago/coder@0.4.0",
            "digest" => "sha256:3a8f00",
            "kind" => "data"
          },
          "model" => %{
            "policy" => %{
              "ref" => "swarmidx:jmlago/cost-router@1.0",
              "digest" => "sha256:11bc00",
              "kind" => "data"
            }
          },
          "backend" => %{
            "ref" => "oci:szc-agent-code",
            "digest" => "sha256:71de00",
            "kind" => "data"
          }
        }
      ],
      "objects" => [
        %{
          "name" => "task_board",
          "handler" => %{
            "ref" => "swarmidx:jmlago/task-board@1.0.0",
            "digest" => "sha256:7b11ff",
            "kind" => "code"
          },
          "config" => %{"max_items" => 64}
        }
      ],
      "topology" => [
        ["researcher", "task_board"],
        ["task_board", "researcher"],
        ["coder", "task_board"]
      ],
      "options" => %{"log_level" => "info"}
    }
  end

  defp put_agent(doc, idx, key, value) do
    update_in(doc, ["agents", Access.at(idx), key], fn _ -> value end)
  end

  describe "parse/1 (happy path)" do
    test "parses the resolved research-swarm" do
      {:ok, state} = State.parse(valid_doc())

      assert state.name == "research-swarm"
      assert state.phase == :desired
      assert length(state.agents) == 2
      assert length(state.objects) == 1

      assert state.topology == [
               {"researcher", "task_board"},
               {"task_board", "researcher"},
               {"coder", "task_board"}
             ]

      assert %Agent{name: "researcher"} = hd(state.agents)
      assert %Object{name: "task_board"} = hd(state.objects)
    end

    test "model slot is a service ref or a {policy, ref}" do
      {:ok, state} = State.parse(valid_doc())
      [researcher, coder] = state.agents

      assert {:service, %{scheme: "openrouter"}} = researcher.model
      assert {:policy, %{scheme: "swarmidx", kind: :data}} = coder.model
    end

    test "topology may contain cycles (researcher <-> task_board)" do
      {:ok, state} = State.parse(valid_doc())
      assert {"researcher", "task_board"} in state.topology
      assert {"task_board", "researcher"} in state.topology
    end
  end

  describe "header validation" do
    test "rejects an unsupported format version" do
      assert {:error, {:unsupported_version, 2}} = State.parse(%{valid_doc() | "v" => 2})
    end

    test "rejects the wrong kind" do
      assert {:error, {:wrong_kind, "swarm.overlay"}} =
               State.parse(%{valid_doc() | "kind" => "swarm.overlay"})
    end

    test "rejects a missing/invalid phase" do
      assert {:error, {:invalid_phase, nil}} = State.parse(Map.delete(valid_doc(), "phase"))
      assert {:error, {:invalid_phase, "live"}} = State.parse(%{valid_doc() | "phase" => "live"})
    end
  end

  describe "§6 invariants" do
    test "rejects duplicate names across agents and objects" do
      doc = put_agent(valid_doc(), 1, "name", "task_board")
      assert {:error, {:duplicate_name, "task_board"}} = State.parse(doc)
    end

    test "rejects a topology edge to an unknown node" do
      doc = update_in(valid_doc(), ["topology"], &(&1 ++ [["coder", "ghost"]]))
      assert {:error, {:unknown_edge_endpoint, "ghost"}} = State.parse(doc)
    end
  end

  describe "§6.2 slot-typing" do
    test "agent.body must be kind data" do
      bad = %{"ref" => "swarmidx:a/b@1", "digest" => "sha256:aa", "kind" => "code"}

      assert {:error, {:slot_type_mismatch, "body", _}} =
               State.parse(put_agent(valid_doc(), 0, "body", bad))
    end

    test "object.handler must be kind code" do
      bad = %{"ref" => "swarmidx:a/b@1", "digest" => "sha256:aa", "kind" => "data"}
      doc = update_in(valid_doc(), ["objects", Access.at(0), "handler"], fn _ -> bad end)
      assert {:error, {:slot_type_mismatch, "handler", _}} = State.parse(doc)
    end

    test "agent.backend must not be a swarmidx ref" do
      bad = %{"ref" => "swarmidx:a/b@1", "digest" => "sha256:aa", "kind" => "data"}

      assert {:error, {:slot_type_mismatch, "backend", _}} =
               State.parse(put_agent(valid_doc(), 0, "backend", bad))
    end

    test "a service model ref must not be swarmidx" do
      bad = %{"ref" => "swarmidx:a/b@1", "digest" => "sha256:aa", "kind" => "data"}

      assert {:error, {:slot_type_mismatch, "model", _}} =
               State.parse(put_agent(valid_doc(), 0, "model", bad))
    end

    test "a missing slot is rejected" do
      doc = update_in(valid_doc(), ["agents", Access.at(0)], &Map.delete(&1, "model"))
      assert {:error, {:missing_slot, "model"}} = State.parse(doc)
    end
  end

  describe "validate_resolved/1 (digest presence §6.4)" do
    test "the resolved doc passes" do
      {:ok, state} = State.parse(valid_doc())
      assert State.validate_resolved(state) == :ok
    end

    test "an authored body ref (no digest) fails resolved validation" do
      authored = %{"ref" => "swarmidx:jmlago/web-researcher@^1.2", "kind" => "data"}
      {:ok, state} = State.parse(put_agent(valid_doc(), 0, "body", authored))

      # parse (authored-safe) succeeds; validate_resolved catches the missing digest
      assert {:error, {:unresolved_ref, "swarmidx:jmlago/web-researcher@^1.2", :missing_digest}} =
               State.validate_resolved(state)
    end
  end
end
