defmodule Genswarms.Agents.AgentProtocolTest do
  use ExUnit.Case, async: true

  alias Genswarms.Agents.AgentProtocol

  describe "encode_task/2" do
    test "encodes task with default orchestrator" do
      json = AgentProtocol.encode_task("analyze this code")
      decoded = Jason.decode!(json)

      assert decoded["type"] == "task"
      assert decoded["content"] == "analyze this code"
      assert decoded["from"] == "orchestrator"
    end

    test "encodes task with custom from" do
      json = AgentProtocol.encode_task("do something", "coordinator")
      decoded = Jason.decode!(json)

      assert decoded["from"] == "coordinator"
    end

    # Regression: the agent runtime reads stdin line-by-line and runs one turn
    # per physical line. A multi-line task must therefore arrive as ONE line —
    # its newlines escaped to literal "\n" — or it fans out into one reply per
    # line (the restart-flood bug). subzeroclaw's unescape_turn restores them.
    test "escapes newlines so a multi-line task stays one physical line" do
      json = AgentProtocol.encode_task("line1\nline2\nline3")
      content = Jason.decode!(json)["content"]

      refute content =~ "\n"
      assert content == "line1\\nline2\\nline3"
    end

    test "escapes backslashes so the escaping round-trips losslessly" do
      # user literally typed "a\nb" (backslash, n) — must survive, NOT become a newline
      json = AgentProtocol.encode_task("a\\nb")
      content = Jason.decode!(json)["content"]

      refute content =~ "\n"
      assert content == "a\\\\nb"
    end

    test "leaves single-line content untouched" do
      content = Jason.decode!(AgentProtocol.encode_task("just one line"))["content"]
      assert content == "just one line"
    end
  end

  describe "encode_message/2" do
    test "encodes inter-agent message" do
      json = AgentProtocol.encode_message("here are the results", :researcher)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "message"
      assert decoded["content"] == "here are the results"
      assert decoded["from"] == "researcher"
    end
  end

  describe "encode_system/1" do
    test "encodes system command" do
      json = AgentProtocol.encode_system("status")
      decoded = Jason.decode!(json)

      assert decoded["type"] == "system"
      assert decoded["command"] == "status"
    end
  end

  describe "decode/1" do
    test "decodes task message" do
      json = ~s({"type": "task", "content": "test", "from": "orchestrator"})
      assert {:ok, msg} = AgentProtocol.decode(json)

      assert msg.type == :task
      assert msg.content == "test"
      assert msg.from == "orchestrator"
    end

    test "decodes output message" do
      json = ~s({"type": "output", "content": "Working on it..."})
      assert {:ok, msg} = AgentProtocol.decode(json)

      assert msg.type == :output
      assert msg.content == "Working on it..."
    end

    test "decodes send message" do
      json = ~s({"type": "send", "to": "coder", "content": "implement this"})
      assert {:ok, msg} = AgentProtocol.decode(json)

      assert msg.type == :send
      assert msg.to == :coder
      assert msg.content == "implement this"
    end

    test "decodes broadcast message" do
      json = ~s({"type": "broadcast", "content": "done!"})
      assert {:ok, msg} = AgentProtocol.decode(json)

      assert msg.type == :broadcast
      assert msg.content == "done!"
    end

    test "decodes status message" do
      json = ~s({"type": "status", "state": "idle"})
      assert {:ok, msg} = AgentProtocol.decode(json)

      assert msg.type == :status
      assert msg.state == "idle"
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = AgentProtocol.decode("not json")
    end

    test "returns error for missing type" do
      json = ~s({"content": "no type field"})
      assert {:error, :missing_type} = AgentProtocol.decode(json)
    end
  end

  describe "parse_output/1" do
    test "parses output without mentions" do
      messages = AgentProtocol.parse_output("Just regular output")

      assert length(messages) == 1
      assert hd(messages).type == :output
      assert hd(messages).content == "Just regular output"
    end

    test "parses output with single swarm message" do
      output = """
      Some output
      <<SWARM_MSG:TO=coder:START>>
      please implement this function
      <<SWARM_MSG:END>>
      More output
      """

      messages = AgentProtocol.parse_output(output)

      assert Enum.any?(messages, &(&1.type == :send && &1.to == :coder))
      assert Enum.any?(messages, &(&1.type == :output))
    end

    test "parses output with multiple swarm messages" do
      output = """
      <<SWARM_MSG:TO=researcher:START>>
      find docs
      <<SWARM_MSG:END>>
      <<SWARM_MSG:TO=coder:START>>
      implement it
      <<SWARM_MSG:END>>
      """

      messages = AgentProtocol.parse_output(output)

      send_messages = Enum.filter(messages, &(&1.type == :send))
      assert length(send_messages) == 2
    end

    test "parses broadcast swarm message" do
      output = """
      <<SWARM_MSG:BROADCAST:START>>
      task completed
      <<SWARM_MSG:END>>
      """

      messages = AgentProtocol.parse_output(output)

      assert Enum.any?(messages, &(&1.type == :broadcast))
    end
  end

  describe "routable?/1" do
    test "send is routable" do
      assert AgentProtocol.routable?(:send)
    end

    test "broadcast is routable" do
      assert AgentProtocol.routable?(:broadcast)
    end

    test "output is not routable" do
      refute AgentProtocol.routable?(:output)
    end

    test "status is not routable" do
      refute AgentProtocol.routable?(:status)
    end
  end
end
