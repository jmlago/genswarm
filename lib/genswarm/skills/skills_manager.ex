defmodule Genswarm.Skills.SkillsManager do
  @moduledoc """
  GenServer for managing agent skills.

  Provides:
  - ETS-based caching of skill files
  - Loading skills from the skills repository (priv/skills)
  - Deploying skills to agent-specific directories
  - Watching for skill file changes (in development)
  """

  use GenServer
  require Logger

  @ets_table :subzeroclaw_skills

  defstruct [:skills_dir, :swarm_data_dir]

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Lists all available skills in the repository.
  """
  @spec list_skills() :: [String.t()]
  def list_skills do
    GenServer.call(__MODULE__, :list_skills)
  end

  @doc """
  Gets the content of a skill file.
  """
  @spec get_skill(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def get_skill(skill_name) do
    GenServer.call(__MODULE__, {:get_skill, skill_name})
  end

  @doc """
  Reloads all skills from disk.
  """
  @spec reload_skills() :: :ok
  def reload_skills do
    GenServer.call(__MODULE__, :reload_skills)
  end

  @doc """
  Deploys skills for a specific agent in a swarm.

  Creates the agent's skills directory and copies the specified skills.
  Returns the path to the skills directory.
  """
  @spec deploy_for_agent(String.t(), atom(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def deploy_for_agent(swarm_name, agent_name, skills) do
    GenServer.call(__MODULE__, {:deploy_for_agent, swarm_name, agent_name, skills})
  end

  @doc """
  Cleans up skills directories for a stopped swarm.
  """
  @spec cleanup_swarm(String.t()) :: :ok
  def cleanup_swarm(swarm_name) do
    GenServer.call(__MODULE__, {:cleanup_swarm, swarm_name})
  end

  @doc """
  Gets the path where an agent's skills are deployed.
  """
  @spec get_agent_skills_dir(String.t(), atom()) :: String.t()
  def get_agent_skills_dir(swarm_name, agent_name) do
    GenServer.call(__MODULE__, {:get_agent_skills_dir, swarm_name, agent_name})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for caching
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    skills_dir =
      Application.get_env(:genswarm, :skills_dir, "priv/skills")
      |> Path.expand()

    swarm_data_dir =
      Application.get_env(:genswarm, :swarm_data_dir, "~/.subzeroclaw/swarms")
      |> Path.expand()

    state = %__MODULE__{
      skills_dir: skills_dir,
      swarm_data_dir: swarm_data_dir
    }

    # Load skills on startup
    load_skills(state)

    {:ok, state}
  end

  @impl true
  def handle_call(:list_skills, _from, state) do
    skills =
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {name, _content, _mtime} -> name end)
      |> Enum.sort()

    {:reply, skills, state}
  end

  def handle_call({:get_skill, skill_name}, _from, state) do
    case :ets.lookup(@ets_table, skill_name) do
      [{^skill_name, content, _mtime}] ->
        {:reply, {:ok, content}, state}

      [] ->
        # Try loading from disk
        case load_skill_from_disk(state.skills_dir, skill_name) do
          {:ok, content} ->
            {:reply, {:ok, content}, state}

          :error ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call(:reload_skills, _from, state) do
    :ets.delete_all_objects(@ets_table)
    load_skills(state)
    {:reply, :ok, state}
  end

  def handle_call({:deploy_for_agent, swarm_name, agent_name, skills}, _from, state) do
    agent_skills_dir =
      Path.join([state.swarm_data_dir, swarm_name, to_string(agent_name), "skills"])

    case File.mkdir_p(agent_skills_dir) do
      :ok ->
        # Copy each skill
        results =
          Enum.map(skills, fn skill_name ->
            deploy_skill(state.skills_dir, agent_skills_dir, skill_name)
          end)

        errors = Enum.filter(results, &match?({:error, _}, &1))

        if Enum.empty?(errors) do
          Logger.info("Deployed #{length(skills)} skills to #{agent_skills_dir}")
          {:reply, {:ok, agent_skills_dir}, state}
        else
          {:reply, {:error, {:partial_deploy, errors}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:mkdir_failed, reason}}, state}
    end
  end

  def handle_call({:cleanup_swarm, swarm_name}, _from, state) do
    swarm_dir = Path.join(state.swarm_data_dir, swarm_name)

    if File.exists?(swarm_dir) do
      File.rm_rf!(swarm_dir)
      Logger.info("Cleaned up swarm directory: #{swarm_dir}")
    end

    {:reply, :ok, state}
  end

  def handle_call({:get_agent_skills_dir, swarm_name, agent_name}, _from, state) do
    dir = Path.join([state.swarm_data_dir, swarm_name, to_string(agent_name), "skills"])
    {:reply, dir, state}
  end

  # Private functions

  defp load_skills(state) do
    skills_dir = state.skills_dir

    if File.exists?(skills_dir) do
      case File.ls(skills_dir) do
        {:ok, files} ->
          skill_files = Enum.filter(files, &String.ends_with?(&1, ".md"))

          Enum.each(skill_files, fn file ->
            load_skill_to_cache(skills_dir, file)
          end)

          Logger.info("Loaded #{length(skill_files)} skills from #{skills_dir}")

        {:error, reason} ->
          Logger.warning("Failed to list skills directory: #{inspect(reason)}")
      end
    else
      Logger.info("Skills directory does not exist: #{skills_dir}")
      File.mkdir_p(skills_dir)
    end
  end

  defp load_skill_to_cache(skills_dir, filename) do
    path = Path.join(skills_dir, filename)

    case File.read(path) do
      {:ok, content} ->
        mtime = File.stat!(path).mtime
        :ets.insert(@ets_table, {filename, content, mtime})

      {:error, reason} ->
        Logger.warning("Failed to load skill #{filename}: #{inspect(reason)}")
    end
  end

  defp load_skill_from_disk(skills_dir, skill_name) do
    path = Path.join(skills_dir, skill_name)

    case File.read(path) do
      {:ok, content} ->
        mtime = File.stat!(path).mtime
        :ets.insert(@ets_table, {skill_name, content, mtime})
        {:ok, content}

      {:error, _} ->
        :error
    end
  end

  defp deploy_skill(source_dir, target_dir, skill_name) do
    source_path = Path.join(source_dir, skill_name)
    target_path = Path.join(target_dir, skill_name)

    # First check cache
    case :ets.lookup(@ets_table, skill_name) do
      [{^skill_name, content, _mtime}] ->
        File.write(target_path, content)

      [] ->
        # Try from disk
        case File.copy(source_path, target_path) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {skill_name, reason}}
        end
    end
  end
end
