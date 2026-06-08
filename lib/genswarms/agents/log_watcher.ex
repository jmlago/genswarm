defmodule Genswarms.Agents.LogWatcher do
  @moduledoc """
  Watches agent log files for SWARM_MSG patterns and routes messages.
  """

  use GenServer
  require Logger

  alias Genswarms.Routing.Router
  alias Genswarms.Observability.LogStore

  @poll_interval 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    swarm_name = Keyword.fetch!(opts, :swarm_name)
    agent_name = Keyword.fetch!(opts, :agent_name)
    log_dir = Keyword.fetch!(opts, :log_dir)
    workspace = Keyword.get(opts, :workspace)

    state = %{
      swarm_name: swarm_name,
      agent_name: agent_name,
      log_dir: log_dir,
      workspace: workspace,
      last_positions: %{}
    }

    Process.send_after(self(), :poll, @poll_interval)
    {:ok, state}
  end

  def handle_info(:poll, state) do
    new_state = state |> poll_logs() |> poll_outbox()
    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, new_state}
  end

  defp poll_logs(state) do
    case File.ls(state.log_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".txt"))
        |> Enum.map(&Path.join(state.log_dir, &1))
        |> Enum.reduce(state, &process_log_file/2)

      {:error, _} ->
        state
    end
  end

  defp process_log_file(file_path, state) do
    last_pos = Map.get(state.last_positions, file_path, 0)

    case File.stat(file_path) do
      {:ok, %{size: size}} when size > last_pos ->
        case File.read(file_path) do
          {:ok, content} ->
            new_content = binary_part(content, last_pos, size - last_pos)

            # Parse and log conversation entries
            log_conversation_entries(new_content, state)

            # Parse swarm messages for routing.
            messages = parse_swarm_messages(new_content)

            # Deduplication is already handled by position tracking — we only
            # ever read content past last_pos, so each message is seen once. The
            # old per-message hash set was redundant and grew without bound
            # (keyed on file position + index, so entries never collided) — an
            # unbounded per-agent memory leak (audit finding 32). Just route.
            Enum.each(messages, fn msg -> route_message(msg, state) end)

            %{state | last_positions: Map.put(state.last_positions, file_path, size)}

          {:error, _} ->
            state
        end

      _ ->
        state
    end
  end

  defp parse_swarm_messages(content) do
    # Match RES: entries containing SWARM_MSG
    res_blocks =
      ~r/\] RES: (.*?)(?=\n\[\d{4}-|\z)/s
      |> Regex.scan(content)

    messages = Enum.flat_map(res_blocks, fn [_, res] -> parse_msg_block(res) end)

    # Debug: log if we found multiple messages
    if length(messages) > 1 do
      Logger.debug("Found #{length(messages)} SWARM_MSG blocks in single poll")
    end

    messages
  end

  defp parse_msg_block(content) do
    # Match SWARM_MSG blocks - newline after START is optional
    sends =
      ~r/<<SWARM_MSG:TO=([a-zA-Z_][a-zA-Z0-9_]*):START>>\n?(.*?)<<SWARM_MSG:END>>/s
      |> Regex.scan(content)
      |> Enum.map(fn [_, to, msg] ->
        %{type: :send, to: String.to_atom(to), content: String.trim(msg)}
      end)

    broadcasts =
      ~r/<<SWARM_MSG:BROADCAST:START>>\n?(.*?)<<SWARM_MSG:END>>/s
      |> Regex.scan(content)
      |> Enum.map(fn [_, msg] -> %{type: :broadcast, content: String.trim(msg)} end)

    sends ++ broadcasts
  end

  defp route_message(%{type: :send, to: to, content: content}, state) do
    Logger.info("[#{state.swarm_name}/#{state.agent_name}] Routing message to #{to}")

    content_preview =
      if String.length(content) > 100 do
        String.slice(content, 0, 100) <> "..."
      else
        content
      end

    LogStore.log(
      :info,
      :routing,
      :message_routed,
      "Message: #{state.agent_name} -> #{to}: #{content_preview}",
      swarm: state.swarm_name,
      agent: state.agent_name,
      metadata: %{from: state.agent_name, to: to, content: content}
    )

    Router.route(state.swarm_name, state.agent_name, to, content)
  end

  defp route_message(%{type: :broadcast, content: content}, state) do
    Logger.info("[#{state.swarm_name}/#{state.agent_name}] Broadcasting message")

    content_preview =
      if String.length(content) > 100 do
        String.slice(content, 0, 100) <> "..."
      else
        content
      end

    LogStore.log(
      :info,
      :routing,
      :message_broadcast,
      "Broadcast from #{state.agent_name}: #{content_preview}",
      swarm: state.swarm_name,
      agent: state.agent_name,
      metadata: %{from: state.agent_name, content: content}
    )

    Router.broadcast(state.swarm_name, state.agent_name, content)
  end

  # Parse and log conversation entries from subzeroclaw log format
  # Format: [timestamp] ROLE: content
  defp log_conversation_entries(content, state) do
    # Match log entries: [YYYY-MM-DD HH:MM:SS] ROLE: content
    ~r/\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (\w+): (.*?)(?=\n\[\d{4}-\d{2}-\d{2}|\z)/s
    |> Regex.scan(content)
    |> Enum.each(fn [_, timestamp, role, content] ->
      role_lower = String.downcase(role)
      content_trimmed = String.trim(content)

      # Skip empty content
      unless content_trimmed == "" do
        event_type =
          case role_lower do
            "user" -> :user_message
            "asst" -> :assistant_response
            "tool" -> :tool_call
            "res" -> :tool_result
            "sys" -> :system_message
            "compact" -> :context_compact
            _ -> :log_entry
          end

        # Determine log level based on content
        level =
          cond do
            String.contains?(content_trimmed, "error") or
                String.contains?(content_trimmed, "Error") ->
              :warning

            role_lower == "sys" ->
              :debug

            true ->
              :info
          end

        # Truncate content for the message, keep full in metadata
        preview =
          if String.length(content_trimmed) > 150 do
            String.slice(content_trimmed, 0, 150) <> "..."
          else
            content_trimmed
          end

        LogStore.log(level, :agent, event_type, "[#{role_lower}] #{preview}",
          swarm: state.swarm_name,
          agent: state.agent_name,
          metadata: %{
            role: role_lower,
            timestamp: timestamp,
            content: content_trimmed
          }
        )
      end
    end)
  end

  # ============================================================================
  # Outbox: file-based outbound message routing
  # ============================================================================
  #
  # Agents write JSON files to /workspace/.outbox/ to send messages:
  #   {"to": "target_name", "content": "message body"}
  # or for broadcasts:
  #   {"broadcast": true, "content": "message body"}
  #
  # Files are processed in sorted order and deleted after routing.
  # This eliminates the need for swarm-msg send in agent skills.

  defp poll_outbox(state) do
    workspace = Map.get(state, :workspace)

    if workspace do
      outbox_dir = Path.join(Path.expand(workspace), ".outbox")
      do_poll_outbox(outbox_dir, state)
    else
      state
    end
  end

  defp do_poll_outbox(outbox_dir, state) do
    case File.ls(outbox_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.each(fn filename ->
          process_outbox_file(Path.join(outbox_dir, filename), state)
        end)

        state

      {:error, _} ->
        state
    end
  end

  defp process_outbox_file(file_path, state) do
    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"to" => to, "content" => msg}} ->
            Logger.info("[#{state.swarm_name}/#{state.agent_name}] Outbox → #{to}")
            Router.route(state.swarm_name, state.agent_name, String.to_atom(to), msg)
            File.rm(file_path)

          {:ok, %{"broadcast" => true, "content" => msg}} ->
            Logger.info("[#{state.swarm_name}/#{state.agent_name}] Outbox broadcast")
            Router.broadcast(state.swarm_name, state.agent_name, msg)
            File.rm(file_path)

          _ ->
            Logger.warning(
              "[#{state.swarm_name}/#{state.agent_name}] Invalid outbox file: #{Path.basename(file_path)}"
            )

            File.rm(file_path)
        end

      {:error, _} ->
        :ok
    end
  end
end
