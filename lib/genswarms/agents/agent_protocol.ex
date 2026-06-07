defmodule Genswarms.Agents.AgentProtocol do
  @moduledoc """
  JSON protocol for orchestrator-agent communication.

  ## Orchestrator → Agent Messages

      {"type": "task", "content": "analyze...", "from": "orchestrator"}
      {"type": "message", "from": "researcher", "content": "found..."}
      {"type": "system", "command": "status"}

  ## Agent → Orchestrator Messages

      {"type": "output", "content": "Working on..."}
      {"type": "send", "to": "coder", "content": "implement..."}
      {"type": "broadcast", "content": "done"}
      {"type": "status", "state": "idle"}
  """

  @type message_type ::
          :task | :message | :system | :output | :send | :broadcast | :status

  @type outbound_message :: %{
          required(:type) => :task | :message | :system,
          optional(:content) => String.t(),
          optional(:from) => String.t(),
          optional(:command) => String.t()
        }

  @type inbound_message :: %{
          required(:type) => :output | :send | :broadcast | :status,
          optional(:content) => String.t(),
          optional(:to) => String.t(),
          optional(:state) => String.t()
        }

  @doc """
  Encodes a task message to send to an agent.
  """
  @spec encode_task(String.t(), String.t()) :: binary()
  def encode_task(content, from \\ "orchestrator") do
    Jason.encode!(%{
      type: "task",
      content: escape_turn(content),
      from: from
    })
  end

  @doc """
  Encodes an inter-agent message.
  """
  @spec encode_message(String.t(), String.t()) :: binary()
  def encode_message(content, from) do
    Jason.encode!(%{
      type: "message",
      content: escape_turn(content),
      from: to_string(from)
    })
  end

  # One agent-bound message MUST reach the agent as exactly one turn. The
  # subzeroclaw runtime reads its stdin line-by-line and runs a full agentic
  # turn (LLM call + reply) per physical line, and the szc-wrapper expands a
  # JSON `content` field's newlines back into real newlines before feeding it in.
  # So a multi-line task/message (e.g. a conversation-rehydration preamble, or a
  # multi-line policy reply) would otherwise fan out into one reply PER LINE —
  # the restart-flood bug. We escape embedded newlines here (backslash -> "\\",
  # newline -> "\n") so the message stays a single physical line all the way to
  # the agent; subzeroclaw's `unescape_turn` restores the real newlines before
  # running the turn. Single-line messages are unaffected (no newlines to escape).
  defp escape_turn(content) do
    content
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
  end

  @doc """
  Encodes a system command.
  """
  @spec encode_system(String.t()) :: binary()
  def encode_system(command) do
    Jason.encode!(%{
      type: "system",
      command: command
    })
  end

  @doc """
  Decodes a message from an agent.

  Returns `{:ok, parsed_message}` or `{:error, reason}`.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => type} = msg} ->
        {:ok, normalize_message(type, msg)}

      {:ok, _} ->
        {:error, :missing_type}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Parses raw agent output for swarm messages.

  Only supports the swarm-msg CLI tool format:
    <<SWARM_MSG:TO=agent_name:START>>
    message content
    <<SWARM_MSG:END>>

  Returns a list of messages extracted from the output.
  """
  @spec parse_output(String.t()) :: [map()]
  def parse_output(output) do
    messages = parse_swarm_messages(output)

    # Always include the full output (cleaned) as first message
    [%{type: :output, content: clean_output(output)} | messages]
  end

  # Parse <<SWARM_MSG:TO=agent:START>>...<<SWARM_MSG:END>> format
  defp parse_swarm_messages(output) do
    # Pattern for: <<SWARM_MSG:TO=agent_name:START>>\ncontent\n<<SWARM_MSG:END>>
    send_pattern = ~r/<<SWARM_MSG:TO=([a-zA-Z_][a-zA-Z0-9_]*):START>>\n(.*?)<<SWARM_MSG:END>>/s

    # Pattern for: <<SWARM_MSG:BROADCAST:START>>\ncontent\n<<SWARM_MSG:END>>
    broadcast_pattern = ~r/<<SWARM_MSG:BROADCAST:START>>\n(.*?)<<SWARM_MSG:END>>/s

    send_messages =
      Regex.scan(send_pattern, output)
      |> Enum.map(fn [_full, target, content] ->
        %{type: :send, to: String.to_atom(target), content: String.trim(content)}
      end)

    broadcast_messages =
      Regex.scan(broadcast_pattern, output)
      |> Enum.map(fn [_full, content] ->
        %{type: :broadcast, content: String.trim(content)}
      end)

    send_messages ++ broadcast_messages
  end

  # Remove swarm message markers from output for cleaner display
  defp clean_output(output) do
    output
    |> String.replace(~r/<<SWARM_MSG:[^>]+>>\n?/, "")
    |> String.replace("<<SWARM_MSG:END>>\n?", "")
    |> String.trim()
  end

  @doc """
  Checks if a message type is routable to other agents.
  """
  @spec routable?(atom()) :: boolean()
  def routable?(:send), do: true
  def routable?(:broadcast), do: true
  def routable?(_), do: false

  # Private functions

  defp normalize_message("task", msg) do
    %{
      type: :task,
      content: Map.get(msg, "content", ""),
      from: Map.get(msg, "from", "orchestrator")
    }
  end

  defp normalize_message("message", msg) do
    %{
      type: :message,
      content: Map.get(msg, "content", ""),
      from: Map.get(msg, "from") |> maybe_to_atom()
    }
  end

  defp normalize_message("system", msg) do
    %{
      type: :system,
      command: Map.get(msg, "command", "")
    }
  end

  defp normalize_message("output", msg) do
    %{
      type: :output,
      content: Map.get(msg, "content", "")
    }
  end

  defp normalize_message("send", msg) do
    %{
      type: :send,
      to: Map.get(msg, "to") |> maybe_to_atom(),
      content: Map.get(msg, "content", "")
    }
  end

  defp normalize_message("broadcast", msg) do
    %{
      type: :broadcast,
      content: Map.get(msg, "content", "")
    }
  end

  defp normalize_message("status", msg) do
    %{
      type: :status,
      state: Map.get(msg, "state", "unknown")
    }
  end

  defp normalize_message(type, msg) do
    %{
      type: String.to_atom(type),
      raw: msg
    }
  end

  defp maybe_to_atom(nil), do: nil
  defp maybe_to_atom(s) when is_binary(s), do: String.to_atom(s)
  defp maybe_to_atom(a) when is_atom(a), do: a
end
