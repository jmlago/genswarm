defmodule Mix.Tasks.Swarm.Logs do
  @shortdoc "Stream agent logs and conversation history"

  @moduledoc """
  Shows logs and conversation history for agents in a swarm.

  ## Usage

      mix swarm logs <swarm_name> [agent_name] [options]

  ## Options

      --follow, -f     Stream logs in real-time
      --tail N         Show last N entries (default: 50)
      --stdout         Show agent stdout output
      --events         Show all agent events (tasks, messages, lifecycle)
      --conversation   Show conversation only (default)
      --all            Show all log types
      --help, -h       Show this help

  ## Examples

      mix swarm logs my-swarm                    # All agents conversation
      mix swarm logs my-swarm researcher         # Specific agent conversation
      mix swarm logs my-swarm researcher -f      # Stream in real-time
      mix swarm logs my-swarm --stdout           # Show stdout output
      mix swarm logs my-swarm --events           # Show all events
      mix swarm logs my-swarm --all              # Show everything
      mix swarm logs my-swarm --tail 100         # Last 100 entries
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, SwarmRegistry, EnvManager}
  alias Genswarm.Observability.LogStore

  # Conversation event types
  @conversation_types [
    :user_message,
    :assistant_response,
    :tool_call,
    :tool_result,
    :system_message
  ]

  # Stdout event types
  @stdout_types [:stdout]

  # All agent event types
  @all_agent_types @conversation_types ++
                     @stdout_types ++
                     [
                       :started,
                       :stopped,
                       :start_failed,
                       :port_exit,
                       :task_sent,
                       :message_received,
                       :inbox_full
                     ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [
          follow: :boolean,
          tail: :integer,
          stdout: :boolean,
          events: :boolean,
          conversation: :boolean,
          all: :boolean,
          help: :boolean
        ],
        aliases: [f: :follow, n: :tail, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      # For streaming, we need the full app (LogStore.subscribe)
      # For static logs, just SQLite is enough
      if opts[:follow] do
        {:ok, _} = Application.ensure_all_started(:genswarm)
      else
        load_env()
        SwarmRegistry.init()
      end

      case rest do
        [swarm_name] ->
          show_logs(swarm_name, nil, opts)

        [swarm_name, agent_name] ->
          show_logs(swarm_name, String.to_atom(agent_name), opts)

        [] ->
          Output.error("Missing swarm name")
          Output.info("Usage: swarm logs <swarm_name> [agent_name]")

        _ ->
          Output.error("Usage: swarm logs <swarm_name> [agent_name]")
      end
    end
  end

  defp show_logs(swarm_name, agent_name, opts) do
    if opts[:follow] do
      stream_logs(swarm_name, agent_name, opts)
    else
      show_static_logs(swarm_name, agent_name, opts)
    end
  end

  defp show_static_logs(swarm_name, agent_name, opts) do
    limit = opts[:tail] || 50
    event_types = get_event_types(opts)

    # Query from SQLite via SwarmRegistry (persisted logs)
    query_opts = [
      swarm: swarm_name,
      category: :agent,
      limit: limit
    ]

    query_opts =
      if agent_name do
        Keyword.put(query_opts, :agent, agent_name)
      else
        query_opts
      end

    events =
      SwarmRegistry.query_events(query_opts)
      |> Enum.filter(fn e -> e.event_type in event_types end)

    if Enum.empty?(events) do
      Output.dim("No logs found")
      Output.newline()
      Output.dim("Tip: Logs appear once agents start processing. Try:")
      Output.dim("  swarm task #{swarm_name} <agent> \"Hello\"")
    else
      # Group by agent if showing all agents
      if agent_name do
        Output.header("Logs: #{agent_name}")

        events
        # Show oldest first
        |> Enum.reverse()
        |> Enum.each(&format_log_entry/1)
      else
        events
        |> Enum.reverse()
        |> Enum.group_by(& &1.agent)
        |> Enum.each(fn {agent, agent_events} ->
          Output.header("Logs: #{agent}")
          Enum.each(agent_events, &format_log_entry/1)
          Output.newline()
        end)
      end
    end
  end

  defp stream_logs(swarm_name, agent_name, opts) do
    Output.info("Streaming logs... (Ctrl+C to stop)")
    Output.newline()

    event_types = get_event_types(opts)

    # Show recent logs first (from SQLite)
    query_opts = [
      swarm: swarm_name,
      category: :agent,
      limit: 10
    ]

    query_opts =
      if agent_name do
        Keyword.put(query_opts, :agent, agent_name)
      else
        query_opts
      end

    recent =
      SwarmRegistry.query_events(query_opts)
      |> Enum.filter(fn e -> e.event_type in event_types end)

    unless Enum.empty?(recent) do
      Output.dim("Recent logs:")

      recent
      |> Enum.reverse()
      |> Enum.each(&format_log_entry/1)

      Output.newline()
      Output.dim("--- Live stream ---")
      Output.newline()
    end

    # Subscribe to real-time events
    LogStore.subscribe(swarm_name)

    stream_loop(agent_name, event_types)
  end

  defp stream_loop(agent_filter, event_types) do
    receive do
      {:log_event, event} ->
        # Check if event matches our filters
        matches_agent = is_nil(agent_filter) or event.agent == agent_filter
        matches_type = event.category == :agent and event.event_type in event_types

        if matches_agent and matches_type do
          format_log_entry(event)
        end

        stream_loop(agent_filter, event_types)

      _ ->
        stream_loop(agent_filter, event_types)
    end
  end

  defp get_event_types(opts) do
    cond do
      opts[:all] -> @all_agent_types
      opts[:events] -> @all_agent_types
      opts[:stdout] -> @stdout_types
      opts[:conversation] -> @conversation_types
      # Default to conversation
      true -> @conversation_types
    end
  end

  defp format_log_entry(event) do
    timestamp = format_timestamp(event.timestamp)

    # Format based on event type
    case event.event_type do
      type
      when type in [:user_message, :assistant_response, :tool_call, :tool_result, :system_message] ->
        format_conversation_entry(event, timestamp)

      :stdout ->
        format_stdout_entry(event, timestamp)

      :task_sent ->
        format_task_entry(event, timestamp)

      :message_received ->
        format_message_entry(event, timestamp)

      _ ->
        format_generic_entry(event, timestamp)
    end
  end

  defp format_conversation_entry(event, timestamp) do
    # Handle both atom and string keys (SQLite returns string keys)
    role = Map.get(event.metadata, :role) || Map.get(event.metadata, "role", "unknown")

    content =
      Map.get(event.metadata, :content) || Map.get(event.metadata, "content", event.message)

    role_display =
      case role do
        "user" -> Output.colorize("USER", :cyan)
        "asst" -> Output.colorize("ASST", :green)
        "tool" -> Output.colorize("TOOL", :yellow)
        "res" -> Output.colorize("RES ", :dim)
        "sys" -> Output.colorize("SYS ", :magenta)
        _ -> Output.colorize(String.upcase(role), :white)
      end

    agent = Output.colorize("[#{event.agent}]", :blue)

    # Format content - show full for conversation
    content_formatted =
      content
      # Indent continuation lines
      |> String.replace("\n", "\n       ")

    Output.puts("#{timestamp} #{agent} #{role_display}: #{content_formatted}")
  end

  defp format_stdout_entry(event, timestamp) do
    agent = Output.colorize("[#{event.agent}]", :blue)
    output = Map.get(event.metadata, :output) || Map.get(event.metadata, "output", event.message)

    # Show full output, indented
    output_formatted =
      output
      |> String.trim()
      |> String.replace("\n", "\n       ")

    Output.puts("#{timestamp} #{agent} #{Output.colorize("OUT", :cyan)}: #{output_formatted}")
  end

  defp format_task_entry(event, timestamp) do
    agent = Output.colorize("[#{event.agent}]", :blue)
    task = Map.get(event.metadata, :task) || Map.get(event.metadata, "task", event.message)

    Output.puts("#{timestamp} #{agent} #{Output.colorize("TASK", :magenta)}: #{task}")
  end

  defp format_message_entry(event, timestamp) do
    agent = Output.colorize("[#{event.agent}]", :blue)
    from = Map.get(event.metadata, :from) || Map.get(event.metadata, "from", "unknown")

    content =
      Map.get(event.metadata, :content) || Map.get(event.metadata, "content", event.message)

    Output.puts("#{timestamp} #{agent} #{Output.colorize("MSG<-#{from}", :yellow)}: #{content}")
  end

  defp format_generic_entry(event, timestamp) do
    agent = Output.colorize("[#{event.agent}]", :blue)
    type = Output.colorize(String.upcase(to_string(event.event_type)), :dim)

    Output.puts("#{timestamp} #{agent} #{type}: #{event.message}")
  end

  defp format_timestamp(%DateTime{} = datetime) do
    time = Calendar.strftime(datetime, "%H:%M:%S")
    Output.colorize("[#{time}]", :dim)
  end

  defp format_timestamp(datetime) when is_binary(datetime) do
    # SQLite timestamp format: "2024-03-24 17:19:30.123"
    time =
      case String.split(datetime, " ") do
        [_date, time_part] ->
          time_part
          |> String.split(".")
          |> List.first()

        _ ->
          datetime
      end

    Output.colorize("[#{time}]", :dim)
  end

  defp format_timestamp(_), do: Output.colorize("[--:--:--]", :dim)

  defp load_env do
    case EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[Genswarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end
  end
end
