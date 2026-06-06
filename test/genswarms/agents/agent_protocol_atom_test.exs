defmodule Genswarms.Agents.AgentProtocolAtomTest do
  @moduledoc """
  Agent output is untrusted (a prompt-injected/compromised agent controls it), so
  routing targets it names must resolve to existing atoms only — never mint. This
  covers the SWARM_MSG (`parse_output/1`) and JSON (`decode/1`) paths.
  """
  # async: false for the atom_count invariant (no concurrent minting).
  use ExUnit.Case, async: false

  alias Genswarms.Agents.AgentProtocol

  # Interned at compile time, so it is a guaranteed-existing atom for the
  # "valid target" cases.
  @existing :agent_protocol_existing_target

  defp fresh, do: "ghost_" <> Integer.to_string(System.unique_integer([:positive]))

  describe "parse_output/1 (SWARM_MSG targets)" do
    test "drops a send to an unknown agent (no :send message)" do
      out = "hi <<SWARM_MSG:TO=#{fresh()}:START>>\npayload<<SWARM_MSG:END>>"
      messages = AgentProtocol.parse_output(out)

      assert Enum.any?(messages, &(&1.type == :output))
      refute Enum.any?(messages, &(&1.type == :send))
    end

    test "keeps a send to an existing agent, resolved to its atom" do
      out = "<<SWARM_MSG:TO=#{@existing}:START>>\npayload<<SWARM_MSG:END>>"
      messages = AgentProtocol.parse_output(out)

      send = Enum.find(messages, &(&1.type == :send))
      assert send.to == @existing
      assert send.content == "payload"
    end
  end

  describe "decode/1 (JSON targets)" do
    test "an unknown send target becomes nil (dropped downstream)" do
      {:ok, msg} = AgentProtocol.decode(~s({"type":"send","to":"#{fresh()}","content":"x"}))
      assert msg.type == :send
      assert msg.to == nil
    end

    test "a known send target resolves to its atom" do
      {:ok, msg} = AgentProtocol.decode(~s({"type":"send","to":"#{@existing}","content":"x"}))
      assert msg.to == @existing
    end

    test "an unknown message type becomes :unknown (not minted)" do
      {:ok, msg} = AgentProtocol.decode(~s({"type":"#{fresh()}","content":"x"}))
      assert msg.type == :unknown
    end
  end

  describe "atom-table invariant under hostile agent output" do
    test "flooding distinct unknown targets/types mints no atoms" do
      flood = fn ->
        AgentProtocol.parse_output("<<SWARM_MSG:TO=#{fresh()}:START>>\nx<<SWARM_MSG:END>>")
        AgentProtocol.decode(~s({"type":"send","to":"#{fresh()}","content":"x"}))
        AgentProtocol.decode(~s({"type":"#{fresh()}","content":"x"}))
      end

      for _ <- 1..20, do: flood.()
      before = :erlang.system_info(:atom_count)
      for _ <- 1..300, do: flood.()
      after_count = :erlang.system_info(:atom_count)

      assert after_count == before, "agent-output parsing minted #{after_count - before} atoms"
    end
  end
end
