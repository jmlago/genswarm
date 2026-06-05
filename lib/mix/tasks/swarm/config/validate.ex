defmodule Mix.Tasks.Swarm.Config.Validate do
  @shortdoc "Validate swarm configuration files"

  @moduledoc """
  Validates swarm configuration files for correctness.

  Uses the actual Genswarm.Config.Loader to parse and validate
  configurations, ensuring they will work when the swarm is started.

  Checks:
  - File format (exs, json, yaml)
  - Required fields (name, agents, topology)
  - Agent configuration (name, backend, model, presets, tools)
  - Object configuration (name, handler or backend)
  - Topology validity (all referenced agents/objects exist)
  - Skill file existence
  - Handler module existence (for native objects)

  ## Usage

      mix swarm config validate <file>
      mix swarm config validate swarms/*.exs
      swarm check <file>

  ## Options

      --quiet, -q    Only output errors

  ## Examples

      mix swarm config validate swarms/my_swarm.exs
      mix swarm config validate swarms/*.exs
      mix swarm config validate config.json --quiet
      swarm check my-swarm.exs
  """

  use Mix.Task

  alias Genswarm.CLI.Output
  alias Genswarm.Config.Loader

  @impl Mix.Task
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [quiet: :boolean, help: :boolean],
        aliases: [q: :quiet, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      if Enum.empty?(files) do
        Output.error("No files specified")
        Output.info("Usage: swarm check <file.exs>")
        Output.info("       mix swarm config validate <file>")
        System.halt(1)
      else
        # Expand globs
        expanded_files =
          files
          |> Enum.flat_map(&Path.wildcard/1)
          |> Enum.filter(&File.regular?/1)

        if Enum.empty?(expanded_files) do
          Output.error("No matching files found")
          System.halt(1)
        else
          results = Enum.map(expanded_files, &validate_file(&1, opts))

          valid_count = Enum.count(results, &(&1 == :ok))
          error_count = length(results) - valid_count

          Output.newline()

          if error_count > 0 do
            Output.error("#{error_count} file(s) have errors")
            System.halt(1)
          else
            Output.success("#{valid_count} file(s) validated successfully")
          end
        end
      end
    end
  end

  defp validate_file(path, opts) do
    quiet = opts[:quiet]

    unless quiet do
      Output.info("Validating: #{path}")
    end

    case do_validate(path) do
      {:ok, config} ->
        unless quiet do
          Output.success("  Valid")
          show_summary(config)
        end

        :ok

      {:error, errors} when is_list(errors) ->
        Output.error("  Invalid: #{path}")

        Enum.each(errors, fn error ->
          Output.puts("    #{Output.colorize("•", :red)} #{format_error(error)}")
        end)

        {:error, errors}

      {:error, error} ->
        Output.error("  Invalid: #{path}")
        Output.puts("    #{Output.colorize("•", :red)} #{format_error(error)}")
        {:error, error}
    end
  end

  defp do_validate(path) do
    # Check file exists
    if not File.exists?(path) do
      {:error, {:file_not_found, path}}
    else
      # Check file extension
      ext = Path.extname(path) |> String.downcase()

      if ext not in [".exs", ".json", ".yaml", ".yml"] do
        {:error, {:unsupported_format, ext}}
      else
        # Try to load and parse using the real Loader
        case Loader.load(path) do
          {:ok, config} ->
            # Additional validation (skill files, etc.)
            case validate_skills(config, path) do
              [] ->
                {:ok, config}

              errors ->
                {:error, errors}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  # Validate that all skill files exist
  defp validate_skills(config, path) do
    base_dir = Path.dirname(path)
    skills_dir = Application.get_env(:genswarm, :skills_dir, "priv/skills")

    Enum.flat_map(config.agents, fn agent ->
      skills = Map.get(agent, :skills, [])

      Enum.flat_map(skills, fn skill ->
        skill_paths = [
          Path.join(base_dir, skill),
          Path.join(skills_dir, skill),
          skill
        ]

        if Enum.any?(skill_paths, &File.exists?/1) do
          []
        else
          [{:skill_not_found, skill, agent.name}]
        end
      end)
    end)
  end

  defp show_summary(config) do
    agent_count = length(config.agents)
    object_count = length(config.objects || [])
    edge_count = length(config.topology)

    Output.dim("    #{agent_count} agent(s), #{object_count} object(s), #{edge_count} edge(s)")
  end

  # Error formatting
  defp format_error({:file_not_found, path}), do: "File not found: #{path}"
  defp format_error({:unsupported_format, ext}), do: "Unsupported format: #{ext}"
  defp format_error(:missing_name), do: "Missing required field: name"
  defp format_error(:missing_or_empty_agents), do: "Agents list is required and cannot be empty"
  defp format_error(:invalid_config_format), do: "Config must be a map"

  defp format_error({:invalid_name, msg}), do: "Invalid swarm name: #{msg}"

  defp format_error(:invalid_agent_config), do: "Agent config invalid (requires name + backend)"

  defp format_error({:invalid_backend, backend}),
    do: "Invalid backend: #{inspect(backend)}"

  defp format_error(:invalid_skills_format), do: "Skills must be a list of strings"
  defp format_error(:invalid_tools_format), do: "Tools must be a list of atoms"
  defp format_error(:invalid_presets_format), do: "Presets must be a list of atoms"

  defp format_error({:unknown_tools, tools}),
    do: "Unknown tools: #{inspect(tools)}"

  defp format_error({:unknown_presets, presets}),
    do: "Unknown presets: #{inspect(presets)}"

  defp format_error(:invalid_object_config),
    do: "Object config invalid (requires name + handler or backend)"

  defp format_error({:invalid_handler, handler, msg}),
    do: "Invalid handler #{inspect(handler)}: #{msg}"

  defp format_error({:invalid_topology, errors}) do
    "Topology errors:\n" <>
      Enum.map_join(errors, "\n", fn err ->
        "      - #{format_topology_error(err)}"
      end)
  end

  defp format_error({:skill_not_found, skill, agent}),
    do: "Agent '#{agent}' skill not found: #{skill}"

  defp format_error({:eval_error, exception}),
    do: "Parse error: #{Exception.message(exception)}"

  defp format_error({:read_error, reason}), do: "Read error: #{inspect(reason)}"
  defp format_error(other), do: inspect(other)

  defp format_topology_error({:unknown_agent, name}),
    do: "References unknown agent/object: #{name}"

  defp format_topology_error({:invalid_edge_format, idx, edge}),
    do: "Edge #{idx} has invalid format: #{inspect(edge)}"

  defp format_topology_error(other), do: inspect(other)
end
