defmodule Mix.Tasks.Swarm.Init do
  @shortdoc "Create a new swarm project"

  @moduledoc """
  Creates a new swarm project with standard directory structure.

  ## Usage

      mix swarm init [directory]

  If no directory is specified, creates the project in the current directory.

  ## Generated Structure

      my-project/
        .env.example      # Template environment file
        .env              # Actual secrets (gitignored)
        .gitignore        # Standard ignores
        .swarm/           # Runtime data (gitignored)
        swarms/
          example_swarm.exs  # Example swarm config
          README.md          # Config documentation
        skills/
          research.md     # Example research skill
          code.md         # Example coding skill
          README.md       # Skills documentation
        docker/
          Dockerfile.agent    # Base agent Dockerfile
          docker-compose.yml  # Local dev compose
        logs/             # Agent logs (gitignored)
          .gitkeep

  ## Options

      --force    Overwrite existing files

  ## Examples

      mix swarm init                    # Current directory
      mix swarm init my-project         # New directory
      mix swarm init ~/projects/swarm   # Absolute path
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, ProjectGenerator}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [force: :boolean, help: :boolean],
        aliases: [f: :force, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      dir = List.first(rest) || "."
      do_init(dir, opts)
    end
  end

  defp do_init(dir, opts) do
    expanded = Path.expand(dir)
    dir_name = Path.basename(expanded)

    Output.header("Creating new swarm project")
    Output.info("Directory: #{expanded}")
    Output.newline()

    # Check if directory exists and has content
    if File.exists?(expanded) and not empty_or_git_only?(expanded) and not opts[:force] do
      Output.error("Directory is not empty: #{expanded}")
      Output.info("Use --force to overwrite existing files")
      System.halt(1)
    end

    case ProjectGenerator.generate(dir) do
      :ok ->
        Output.success("Project created successfully!")
        Output.newline()

        Output.puts(Output.colorize("Next steps:", :bold))
        Output.newline()

        if dir != "." do
          Output.puts("  cd #{dir_name}")
        end

        Output.puts("  cp .env.example .env")
        Output.puts("  # Edit .env with your API keys")
        Output.puts("  swarm up")
        Output.puts("  swarm start swarms/example_swarm.exs")
        Output.newline()

      {:error, :directory_not_empty} ->
        Output.error("Directory is not empty: #{expanded}")
        Output.info("Use --force to overwrite existing files")
        System.halt(1)

      {:error, reason} ->
        Output.error("Failed to create project: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp empty_or_git_only?(dir) do
    case File.ls(dir) do
      {:ok, []} -> true
      {:ok, [".git"]} -> true
      {:ok, [".git", ".gitignore"]} -> true
      _ -> false
    end
  end
end
