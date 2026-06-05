defmodule Genswarm.CLI.ProjectGenerator do
  @moduledoc """
  Generates new swarm project structure.

  Creates a complete project scaffold with:
  - .env.example with documented variables
  - .gitignore with appropriate entries
  - swarms/ directory with example configuration
  - skills/ directory with example skills
  - docker/ directory with Dockerfile and compose file
  - logs/ directory for agent output
  - .swarm/ directory for runtime data
  """

  @doc """
  Generates a new project in the given directory.
  """
  @spec generate(String.t()) :: :ok | {:error, term()}
  def generate(dir) do
    expanded_dir = Path.expand(dir)

    if File.exists?(expanded_dir) and not empty_dir?(expanded_dir) do
      {:error, :directory_not_empty}
    else
      do_generate(expanded_dir)
    end
  end

  defp empty_dir?(dir) do
    case File.ls(dir) do
      {:ok, []} -> true
      {:ok, [".git"]} -> true
      _ -> false
    end
  end

  defp do_generate(dir) do
    # Create directories
    dirs = [
      dir,
      Path.join(dir, ".swarm"),
      Path.join(dir, "swarms"),
      Path.join(dir, "skills"),
      Path.join(dir, "docker"),
      Path.join(dir, "logs")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)

    # Generate files
    files = [
      {".env.example", env_example()},
      {".gitignore", gitignore()},
      {"swarms/example_swarm.exs", example_swarm_config()},
      {"swarms/README.md", swarms_readme()},
      {"skills/research.md", research_skill()},
      {"skills/code.md", code_skill()},
      {"skills/README.md", skills_readme()},
      {"docker/Dockerfile.agent", dockerfile_agent()},
      {"docker/docker-compose.yml", docker_compose()},
      {"logs/.gitkeep", ""}
    ]

    Enum.each(files, fn {relative_path, content} ->
      path = Path.join(dir, relative_path)
      File.write!(path, content)
    end)

    :ok
  end

  defp env_example do
    """
    # Genswarm Configuration
    # Copy this file to .env and fill in your values
    # Then: source .env (or the CLI will auto-load it)

    # =============================================================================
    # Subzeroclaw Agent Configuration
    # =============================================================================

    # API key for LLM provider (OpenRouter, Anthropic, OpenAI, etc.)
    export SUBZEROCLAW_API_KEY=

    # Model to use (e.g., anthropic/claude-sonnet-4, deepseek/deepseek-chat, etc.)
    export SUBZEROCLAW_MODEL=anthropic/claude-sonnet-4

    # API endpoint (optional, defaults based on key format)
    # export SUBZEROCLAW_ENDPOINT=https://openrouter.ai/api/v1/chat/completions

    # =============================================================================
    # Phoenix Server Configuration
    # =============================================================================

    # Server port (default: 4000)
    export PORT=4000

    # Phoenix secret key base (generate with: mix phx.gen.secret)
    # export SECRET_KEY_BASE=

    # Host for the server (default: localhost)
    # export PHX_HOST=localhost

    # =============================================================================
    # Paths
    # =============================================================================

    # Skills directory (default: priv/skills)
    # export SKILLS_DIR=priv/skills

    # Swarm data directory (default: ~/.subzeroclaw/swarms)
    # export SWARM_DATA_DIR=~/.subzeroclaw/swarms

    # Subzeroclaw source directory (for Docker containers)
    # export SUBZEROCLAW_SRC=../subzeroclaw

    # =============================================================================
    # Debug Options
    # =============================================================================

    # Enable debug logging
    # export SWARM_DEBUG=1

    # Log level (debug, info, warn, error)
    export LOG_LEVEL=info
    """
  end

  defp gitignore do
    """
    # Dependencies
    /deps
    /_build
    /node_modules

    # Environment
    .env
    .env.local
    .env.*.local

    # Runtime data
    .swarm/
    logs/*.txt
    logs/*.log

    # Elixir
    *.beam
    *.ez
    erl_crash.dump

    # Editor
    .idea/
    .vscode/
    *.swp
    *.swo
    *~

    # OS
    .DS_Store
    Thumbs.db

    # Secrets
    *.pem
    *.key
    secrets/

    # Build artifacts
    /priv/static/assets/
    /cover/
    /doc/

    # Test
    /tmp/
    """
  end

  defp example_swarm_config do
    """
    # Example swarm configuration
    # Two agents that can communicate with each other
    # Each agent can have its own model (OpenRouter format: provider/model-name)

    %{
      name: "example-swarm",
      description: "A simple two-agent swarm for demonstration",

      agents: [
        %{
          name: :researcher,
          backend: :local,
          # Model in OpenRouter format - see https://openrouter.ai/models
          model: "anthropic/claude-sonnet-4",
          skills: ["research.md"],
          config: %{
            system_prompt: \"\"\"
            You are a research assistant. Your job is to gather information
            and provide detailed analysis. When you need coding help, send
            a message to the coder agent.

            To send a message to another agent, use:
            <<SWARM_MSG:TO=coder:START>>
            Your message here
            <<SWARM_MSG:END>>
            \"\"\"
          }
        },
        %{
          name: :coder,
          backend: :local,
          # Use a cheaper/faster model for coding tasks
          model: "deepseek/deepseek-chat",
          skills: ["code.md"],
          config: %{
            system_prompt: \"\"\"
            You are a coding assistant. Your job is to write and review code.
            When you need research or information, send a message to the
            researcher agent.

            To send a message to another agent, use:
            <<SWARM_MSG:TO=researcher:START>>
            Your message here
            <<SWARM_MSG:END>>
            \"\"\"
          }
        }
      ],

      # Communication topology: who can send messages to whom
      # Format: {from, to} - directed edges
      topology: [
        {:researcher, :coder},
        {:coder, :researcher}
      ]
    }
    """
  end

  defp swarms_readme do
    """
    # Swarm Configurations

    This directory contains swarm configuration files.

    ## File Format

    Configurations can be written in:
    - `.exs` - Elixir terms (recommended)
    - `.json` - JSON format
    - `.yaml` / `.yml` - YAML format

    ## Structure

    ```elixir
    %{
      name: "swarm-name",
      description: "What this swarm does",

      agents: [
        %{
          name: :agent_name,
          backend: :local,           # or {:docker, "container"} or {:ssh, "user@host"}
          model: "anthropic/claude-sonnet-4",  # OpenRouter format (optional)
          skills: ["skill1.md"],     # List of skill files
          config: %{
            system_prompt: "Agent instructions..."
          }
        }
      ],

      topology: [
        {:agent1, :agent2},          # agent1 can send to agent2
        {:agent2, :agent1}           # agent2 can send to agent1
      ]
    }
    ```

    ## Backend Types

    - `:local` - Local process (default)
    - `{:docker, "container_name"}` - Docker container
    - `{:docker, "container_name", opts}` - Docker with options
    - `{:ssh, "user@host"}` - Remote SSH connection
    - `{:ssh, "user@host", opts}` - SSH with options

    ## Tool Presets

    Available tool presets for agents:
    - `base` - Basic file and shell tools
    - `web` - Web browsing and fetching
    - `code` - Programming tools
    - `python` - Python development
    - `node` - Node.js development
    - `data` - Data processing
    - `docs` - Documentation tools
    - `network` - Network utilities
    - `system` - System administration
    - `security` - Security testing
    - `containers` - Docker/container tools
    - `cloud` - Cloud provider CLIs
    - `ai` - AI/ML tools

    ## Running a Swarm

    ```bash
    swarm start swarms/example_swarm.exs
    swarm status
    swarm task example-swarm researcher "Research topic X"
    swarm stop example-swarm
    ```
    """
  end

  defp research_skill do
    """
    # Research Skill

    You are an expert researcher with the following capabilities:

    ## Information Gathering

    - Search the web for current information
    - Read and summarize documents
    - Extract key facts and data points
    - Verify information across multiple sources

    ## Analysis

    - Identify patterns and trends
    - Compare and contrast different viewpoints
    - Evaluate source credibility
    - Synthesize findings into coherent summaries

    ## Output Format

    When presenting research findings:

    1. **Summary** - Brief overview of key findings
    2. **Details** - In-depth analysis with citations
    3. **Sources** - List of references used
    4. **Confidence** - Assessment of information reliability

    ## Best Practices

    - Always cite sources
    - Distinguish between facts and opinions
    - Note any conflicting information
    - Highlight areas of uncertainty
    """
  end

  defp code_skill do
    """
    # Coding Skill

    You are an expert software developer with the following capabilities:

    ## Languages

    - Python, JavaScript/TypeScript, Elixir
    - Go, Rust, Ruby, Java
    - Shell scripting (Bash, Zsh)
    - SQL and database queries

    ## Development Practices

    - Write clean, maintainable code
    - Follow language-specific conventions
    - Include appropriate error handling
    - Write tests when appropriate

    ## Code Review

    When reviewing code:
    - Check for bugs and edge cases
    - Evaluate performance implications
    - Suggest improvements
    - Verify security best practices

    ## Documentation

    - Write clear comments
    - Document public APIs
    - Include usage examples
    - Explain complex algorithms

    ## Output Format

    When providing code:

    ```language
    // Code with comments explaining key parts
    ```

    **Explanation**: Brief description of what the code does and why.
    """
  end

  defp skills_readme do
    """
    # Skills

    Skills are markdown files that define agent capabilities and behaviors.

    ## Creating Skills

    Each skill file should include:

    1. **Title** - What capability this skill provides
    2. **Description** - Detailed explanation of the skill
    3. **Guidelines** - How to apply the skill
    4. **Examples** - Sample outputs or behaviors

    ## Using Skills

    Reference skills in your swarm configuration:

    ```elixir
    %{
      name: :my_agent,
      skills: ["research.md", "code.md"]
    }
    ```

    Skills are copied to the agent's workspace and included in their context.

    ## Best Practices

    - Keep skills focused on one capability
    - Use clear, actionable language
    - Include examples when helpful
    - Update skills based on agent performance
    """
  end

  defp dockerfile_agent do
    """
    # Base Dockerfile for swarm agents
    # Customize for your specific needs

    FROM ubuntu:22.04

    # Avoid interactive prompts
    ENV DEBIAN_FRONTEND=noninteractive

    # Install base dependencies
    RUN apt-get update && apt-get install -y \\
        curl \\
        git \\
        jq \\
        ripgrep \\
        python3 \\
        python3-pip \\
        nodejs \\
        npm \\
        && rm -rf /var/lib/apt/lists/*

    # Install Claude Code CLI (adjust as needed)
    # RUN npm install -g @anthropic/claude-code

    # Create agent workspace
    WORKDIR /workspace

    # Copy skills
    COPY skills/ /workspace/skills/

    # Set up entrypoint
    ENTRYPOINT ["/bin/bash"]
    """
  end

  defp docker_compose do
    """
    # Docker Compose for local development
    # Customize for your swarm configuration

    version: '3.8'

    services:
      # Example agent container
      agent-base:
        build:
          context: .
          dockerfile: Dockerfile.agent
        volumes:
          - ../skills:/workspace/skills:ro
          - ../logs:/workspace/logs
        environment:
          - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
        stdin_open: true
        tty: true

      # Add more agent containers as needed
      # researcher:
      #   extends: agent-base
      #   container_name: swarm-researcher
      #
      # coder:
      #   extends: agent-base
      #   container_name: swarm-coder
    """
  end
end
