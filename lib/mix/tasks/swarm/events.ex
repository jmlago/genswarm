defmodule Mix.Tasks.Swarm.Events do
  @shortdoc "Query and stream swarm events"

  @moduledoc """
  Query and stream events from the centralized log store.

  ## Usage

      mix swarm events [options]

  ## Options

      --errors, -e        Show only errors
      --warnings, -w      Show warnings and errors
      -n, --minutes N     Events from the last N minutes
      -s, --swarm NAME    Filter by swarm name
      -a, --agent NAME    Filter by agent name
      --category CAT      Filter by category (backend, routing, agent, object, swarm, system)
      --type TYPE         Filter by event type
      --limit N           Maximum events to return (default: 50)
      --follow, -f        Stream events in real-time
      --stats             Show event statistics
      --help, -h          Show this help

  ## Categories

      backend   - Docker/SSH container events (start, stop, connect, build)
      routing   - Message routing events (routed, broadcast, invalid_route)
      agent     - Agent events (started, stopped, stdout, task_sent, message_received, conversation logs)
      object    - Object events (started, stopped, message_received, message_sent, custom logs)
      swarm     - Swarm lifecycle (started, stopped, partial_start)
      system    - API/system errors (api_key_invalid, api_key_missing, rate_limit)

  ## Event Types (--type)

      # agent category
      stdout, task_sent, message_received, user_message, assistant_response,
      tool_call, tool_result, started, stopped, port_exit, inbox_full

      # backend category
      docker_start, docker_stop, docker_start_failed, image_build_start,
      ssh_connect, ssh_connect_failed, ssh_agent_start

      # routing category
      message_routed, message_broadcast, invalid_route, target_not_found

      # system category
      api_key_invalid, api_key_missing, rate_limit, quota_exceeded

  ## Examples

      mix swarm events                        # Last 50 events
      mix swarm events --errors               # Errors only
      mix swarm events --errors -n 5          # Errors from last 5 minutes
      mix swarm events -s my-swarm            # Filter by swarm
      mix swarm events -s my-swarm -a coder   # Filter by agent
      mix swarm events --category backend     # Backend events only
      mix swarm events --follow               # Stream in real-time
      mix swarm events --stats                # Event statistics
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, SwarmRegistry}

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        strict: [
          errors: :boolean,
          warnings: :boolean,
          minutes: :integer,
          swarm: :string,
          agent: :string,
          category: :string,
          type: :string,
          limit: :integer,
          follow: :boolean,
          stats: :boolean,
          help: :boolean
        ],
        aliases: [
          e: :errors,
          w: :warnings,
          n: :minutes,
          s: :swarm,
          a: :agent,
          f: :follow,
          h: :help
        ]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      load_env()
      SwarmRegistry.init()
      query_events(opts)
    end
  end

  defp load_env do
    alias Genswarm.CLI.EnvManager
    case EnvManager.auto_load() do
      {:ok, path} -> IO.puts("[Genswarm] Loaded environment from #{path}")
      {:error, :not_found} -> :ok
    end
  end

  defp query_events(opts) do
    query_opts = build_query_opts(opts)
    events = SwarmRegistry.query_events(query_opts)

    if Enum.empty?(events) do
      Output.dim("No events found")
    else
      Output.header("Events (#{length(events)})")
      Enum.each(events, &format_event/1)
    end
  end

  defp build_query_opts(opts) do
    query_opts = []

    query_opts =
      cond do
        opts[:errors] -> Keyword.put(query_opts, :level, :error)
        opts[:warnings] -> Keyword.put(query_opts, :level, [:error, :warning])
        true -> query_opts
      end

    query_opts =
      if opts[:minutes] do
        Keyword.put(query_opts, :minutes, opts[:minutes])
      else
        query_opts
      end

    query_opts =
      if opts[:swarm] do
        Keyword.put(query_opts, :swarm, opts[:swarm])
      else
        query_opts
      end

    query_opts =
      if opts[:agent] do
        Keyword.put(query_opts, :agent, String.to_atom(opts[:agent]))
      else
        query_opts
      end

    query_opts =
      if opts[:category] do
        Keyword.put(query_opts, :category, String.to_atom(opts[:category]))
      else
        query_opts
      end

    query_opts =
      if opts[:type] do
        Keyword.put(query_opts, :event_type, String.to_atom(opts[:type]))
      else
        query_opts
      end

    query_opts =
      if opts[:limit] do
        Keyword.put(query_opts, :limit, opts[:limit])
      else
        Keyword.put(query_opts, :limit, 50)
      end

    query_opts
  end

  defp format_event(event) do
    timestamp = format_timestamp(event.timestamp)
    level = format_level(event.level)
    category = Output.colorize("[#{event.category}]", :dim)

    # Build context string
    context_parts = []
    context_parts = if event.swarm, do: context_parts ++ [event.swarm], else: context_parts

    context_parts =
      if event.agent, do: context_parts ++ [to_string(event.agent)], else: context_parts

    context =
      if context_parts == [],
        do: "",
        else: " " <> Output.colorize(Enum.join(context_parts, "/"), :cyan)

    event_type = Output.colorize("#{event.event_type}", :white)

    Output.puts("#{timestamp} #{level} #{category}#{context} #{event_type}")
    Output.puts("  #{event.message}")

    # Show relevant metadata
    if map_size(event.metadata) > 0 do
      useful_meta =
        event.metadata
        # Skip verbose fields in summary
        |> Map.drop([:output_snippet, :buffer_tail, :last_logs])
        |> Enum.take(3)

      unless Enum.empty?(useful_meta) do
        meta_str =
          Enum.map(useful_meta, fn {k, v} ->
            value =
              if is_binary(v) and String.length(v) > 50 do
                String.slice(v, 0, 50) <> "..."
              else
                inspect(v)
              end

            "#{k}=#{value}"
          end)
          |> Enum.join(" ")

        Output.puts("  " <> Output.colorize(meta_str, :dim))
      end
    end
  end

  defp format_timestamp(datetime) when is_binary(datetime) do
    # SQLite format: "2024-03-24 10:30:00.123456"
    time =
      case String.split(datetime, " ") do
        [_, time_part] -> String.slice(time_part, 0, 8)
        _ -> datetime
      end

    Output.colorize("[#{time}]", :dim)
  end

  defp format_timestamp(%DateTime{} = datetime) do
    time = Calendar.strftime(datetime, "%H:%M:%S")
    Output.colorize("[#{time}]", :dim)
  end

  defp format_level(:error), do: Output.colorize("ERROR", :red)
  defp format_level(:warning), do: Output.colorize("WARN ", :yellow)
  defp format_level(:info), do: Output.colorize("INFO ", :cyan)
  defp format_level(:debug), do: Output.colorize("DEBUG", :dim)
  defp format_level("error"), do: Output.colorize("ERROR", :red)
  defp format_level("warning"), do: Output.colorize("WARN ", :yellow)
  defp format_level("info"), do: Output.colorize("INFO ", :cyan)
  defp format_level("debug"), do: Output.colorize("DEBUG", :dim)
  defp format_level(other), do: to_string(other)
end
