defmodule Mix.Tasks.Swarm.Env do
  @shortdoc "Manage environment variables"

  @moduledoc """
  Manages environment variables in .env files.

  ## Usage

      mix swarm env list              # List all variables
      mix swarm env get <key>         # Get a specific variable
      mix swarm env set <key> <value> # Set a variable
      mix swarm env unset <key>       # Remove a variable

  ## Options

      --file FILE    Use a specific .env file (default: .env)

  ## Examples

      mix swarm env list
      mix swarm env get ANTHROPIC_API_KEY
      mix swarm env set PORT 3000
      mix swarm env set ANTHROPIC_API_KEY sk-ant-...
      mix swarm env unset DEBUG
      mix swarm env list --file .env.production
  """

  use Mix.Task

  alias Genswarm.CLI.{Output, EnvManager}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [file: :string, help: :boolean],
        aliases: [f: :file, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      env_file = opts[:file] || ".env"

      case rest do
        ["list"] ->
          list_vars(env_file)

        ["get", key] ->
          get_var(key, env_file)

        ["set", key, value] ->
          set_var(key, value, env_file)

        ["unset", key] ->
          unset_var(key, env_file)

        ["set", key] ->
          Output.error("Missing value for #{key}")
          Output.info("Usage: mix swarm env set #{key} <value>")

        [] ->
          list_vars(env_file)

        [cmd | _] ->
          Output.error("Unknown subcommand: #{cmd}")
          Output.info("Available: list, get, set, unset")
      end
    end
  end

  defp list_vars(env_file) do
    case EnvManager.list(env_file) do
      {:ok, vars} when vars == [] ->
        Output.info("No variables in #{env_file}")

      {:ok, vars} ->
        Output.header("Environment: #{env_file}")

        Enum.each(vars, fn {key, value} ->
          # Mask sensitive values
          display_value = mask_sensitive(key, value)
          Output.puts(Output.kv(key, display_value))
        end)

        Output.newline()
        Output.dim("#{length(vars)} variable(s)")

      {:error, {:read_error, :enoent}} ->
        Output.warning("File not found: #{env_file}")
        Output.info("Create it with: cp .env.example .env")

      {:error, reason} ->
        Output.error("Failed to read #{env_file}: #{inspect(reason)}")
    end
  end

  defp get_var(key, env_file) do
    case EnvManager.get(key, env_file) do
      {:ok, value} ->
        # For getting, show the full value (user explicitly asked)
        Output.puts(value)

      {:error, :not_found} ->
        Output.error("Variable not found: #{key}")
        System.halt(1)

      {:error, {:read_error, :enoent}} ->
        Output.error("File not found: #{env_file}")
        System.halt(1)

      {:error, reason} ->
        Output.error("Failed to read: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp set_var(key, value, env_file) do
    case EnvManager.set(key, value, env_file) do
      :ok ->
        Output.success("Set #{key}")

      {:error, :invalid_key} ->
        Output.error("Invalid key: #{key}")

        Output.info(
          "Keys must start with a letter or underscore and contain only alphanumeric characters"
        )

        System.halt(1)

      {:error, reason} ->
        Output.error("Failed to set variable: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp unset_var(key, env_file) do
    case EnvManager.unset(key, env_file) do
      :ok ->
        Output.success("Removed #{key}")

      {:error, :file_not_found} ->
        Output.error("File not found: #{env_file}")
        System.halt(1)

      {:error, reason} ->
        Output.error("Failed to remove variable: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Mask values for sensitive keys
  defp mask_sensitive(key, value) do
    sensitive_patterns = [
      ~r/key/i,
      ~r/secret/i,
      ~r/password/i,
      ~r/token/i,
      ~r/credential/i,
      ~r/auth/i
    ]

    is_sensitive = Enum.any?(sensitive_patterns, &Regex.match?(&1, key))

    if is_sensitive and String.length(value) > 8 do
      prefix = String.slice(value, 0, 4)
      suffix = String.slice(value, -4, 4)
      "#{prefix}...#{suffix}"
    else
      value
    end
  end
end
