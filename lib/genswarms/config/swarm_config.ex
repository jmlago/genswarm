defmodule Genswarms.Config.SwarmConfig do
  @moduledoc """
  Swarm configuration DSL parser and validator.

  ## Configuration Format

      %{
        name: "research-swarm",
        agents: [
          %{
            name: "researcher",
            model: "anthropic/claude-sonnet-4",
            skills: ["web.md"],
            presets: [:base, :web],
            backend: :local
          },
          %{
            name: "coder",
            model: "deepseek/deepseek-chat",  # Cheaper model for coding
            skills: ["code.md"],
            presets: [:base, :code],
            backend: :local
          },
          %{
            name: "reviewer",
            model: "openai/gpt-4o",
            skills: ["review.md"],
            backend: {:ssh, "pi@192.168.1.50"}
          }
        ],
        topology: [
          {:researcher, :coder},
          {:coder, :reviewer},
          {:reviewer, :coder}
        ]
      }

  ## Agent Configuration

  Each agent supports the following fields:

  - `name` (required) - Unique identifier for the agent
  - `backend` (required) - How to run the agent (see Backend Types)
  - `model` (optional) - LLM model to use (OpenRouter format, e.g., "anthropic/claude-sonnet-4")
  - `skills` (optional) - List of skill markdown files
  - `presets` (optional) - NixOS tool presets (see Tool Presets)
  - `tools` (optional) - Individual tools to include
  - `config` (optional) - Additional backend-specific configuration

  ## Models

  Models are specified in OpenRouter format: `provider/model-name`

  Popular models:
  - `anthropic/claude-sonnet-4` - Claude Sonnet 4 (balanced)
  - `anthropic/claude-opus-4` - Claude Opus 4 (most capable)
  - `openai/gpt-4o` - GPT-4o
  - `openai/gpt-4o-mini` - GPT-4o Mini (fast/cheap)
  - `deepseek/deepseek-chat` - DeepSeek V3 (very cheap)
  - `google/gemini-2.0-flash-001` - Gemini 2.0 Flash

  See https://openrouter.ai/models for full list (600+ models)

  ## Backend Types

  - `:local` - Local Port process
  - `{:docker, container_name}` - Docker container
  - `{:docker, container_name, opts}` - Docker with options
  - `{:ssh, "user@host"}` - SSH connection
  - `{:ssh, "user@host", opts}` - SSH with options (key_path, etc.)

  ## Tool Presets (from nix/tool-presets.nix)

  - `:base` - Core utilities (coreutils, bash, grep, sed, awk, find)
  - `:web` - HTTP tools (curl, wget, jq, httpie, w3m)
  - `:code` - Development tools (git, gcc, make, ripgrep, fd)
  - `:python` - Python environment with common packages
  - `:node` - Node.js environment
  - `:data` - Data processing (jq, csvkit, miller, sqlite, duckdb)
  - `:docs` - Document processing (pandoc, texlive, imagemagick)
  - `:network` - Network tools (curl, ssh, rsync, netcat)
  - `:cloud` - Cloud CLIs (aws, gcloud, kubectl, terraform)
  - `:ai` - AI/ML libraries (openai, anthropic, tiktoken)

  ## Individual Tools

  Agents can also specify individual tools by atom name:
  - `:git`, `:curl`, `:wget`, `:jq`, `:ripgrep`, `:fd`, `:fzf`
  - `:python`, `:node`, `:ruby`, `:go`, `:rustc`
  - `:docker`, `:podman`, `:kubectl`
  - `:gh` (GitHub CLI), `:glab` (GitLab CLI)
  - See nix/tool-presets.nix for full list
  """

  defstruct [
    :name,
    :agents,
    :objects,
    :topology,
    :skills_base_dir,
    :created_at,
    options: %{}
  ]

  @type backend ::
          :bwrap
          | {:bwrap, map()}
          | :local
          | {:docker, String.t()}
          | {:docker, String.t(), map()}
          | {:ssh, String.t()}
          | {:ssh, String.t(), map()}

  @type agent_config :: %{
          required(:name) => String.t() | atom(),
          required(:backend) => backend(),
          optional(:model) => String.t(),
          optional(:endpoint) => String.t(),
          optional(:skills) => [String.t()],
          optional(:tools) => [atom()],
          optional(:presets) => [atom()],
          optional(:config) => map()
        }

  @type object_config :: %{
          required(:name) => atom() | String.t(),
          optional(:handler) => module(),
          optional(:backend) => backend(),
          optional(:config) => map()
        }
  # Note: Objects require either :handler (for native Elixir) or :backend (for Docker/SSH)

  # Available tool presets (defined in nix/tool-presets.nix)
  @valid_presets ~w(base web code python node data docs network system security containers cloud ai)a

  # Common individual tools
  @valid_tools ~w(git curl wget jq yq tree htop ripgrep rg fd fzf ag vim neovim nano
                  python python3 node nodejs ruby go rustc cargo make cmake gcc clang
                  sqlite postgresql mysql redis duckdb pandoc pdftotext ssh rsync
                  netcat httpie docker podman kubectl gh glab miller csvkit xsv
                  ffmpeg imagemagick pytest ruff mypy black flake8 pip poetry uv)a

  @type topology_edge :: {atom(), atom()}

  @type t :: %__MODULE__{
          name: String.t(),
          agents: [agent_config()],
          objects: [object_config()],
          topology: [topology_edge()],
          skills_base_dir: String.t() | nil,
          created_at: DateTime.t(),
          options: map()
        }

  @doc """
  Parses and validates a swarm configuration map.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(config) when is_map(config) do
    with {:ok, name} <- validate_name(config),
         {:ok, agents} <- validate_agents(config),
         {:ok, objects} <- validate_objects(config),
         {:ok, topology} <- validate_topology(config, agents, objects),
         {:ok, options} <- validate_options(config) do
      {:ok,
       %__MODULE__{
         name: name,
         agents: normalize_agents(agents),
         objects: normalize_objects(objects),
         topology: normalize_topology(topology),
         skills_base_dir: Map.get(config, :skills_base_dir),
         created_at: DateTime.utc_now(),
         options: options
       }}
    end
  end

  def parse(_), do: {:error, :invalid_config_format}

  @doc """
  Builds an adjacency map from the topology edges.

  Returns a map where keys are source agents and values are
  lists of target agents they can send messages to.
  """
  @spec build_adjacency_map([topology_edge()]) :: %{atom() => [atom()]}
  def build_adjacency_map(topology) do
    Enum.reduce(topology, %{}, fn {from, to}, acc ->
      Map.update(acc, from, [to], &[to | &1])
    end)
  end

  @doc """
  Checks if a message from source to target is allowed by topology.
  """
  @spec can_send?(t(), atom(), atom()) :: boolean()
  def can_send?(%__MODULE__{topology: topology}, from, to) do
    Enum.any?(topology, fn {source, target} ->
      source == from && target == to
    end)
  end

  @doc """
  Gets the backend module for a backend type.
  """
  @spec backend_module(backend()) :: module()
  def backend_module(:bwrap), do: Genswarms.Backends.BwrapBackend
  def backend_module({:bwrap, _}), do: Genswarms.Backends.BwrapBackend
  def backend_module(:local), do: Genswarms.Backends.LocalBackend
  def backend_module({:docker, _}), do: Genswarms.Backends.DockerBackend
  def backend_module({:docker, _, _}), do: Genswarms.Backends.DockerBackend
  def backend_module({:ssh, _}), do: Genswarms.Backends.SSHBackend
  def backend_module({:ssh, _, _}), do: Genswarms.Backends.SSHBackend
  def backend_module(:mock), do: Genswarms.Backends.MockBackend
  def backend_module({:mock, _}), do: Genswarms.Backends.MockBackend

  @doc """
  Gets the backend configuration from the backend spec.
  """
  @spec backend_config(backend()) :: map()
  def backend_config(:bwrap), do: %{}
  def backend_config({:bwrap, opts}), do: opts
  def backend_config(:local), do: %{}
  def backend_config({:docker, image}), do: %{image: image}
  def backend_config({:docker, image, opts}), do: Map.merge(%{image: image}, opts)
  def backend_config(:mock), do: %{}
  def backend_config({:mock, opts}), do: opts
  def backend_config({:ssh, host}), do: %{host: host}
  def backend_config({:ssh, host, opts}), do: Map.merge(%{host: host}, opts)

  # Private validation functions

  # A safe identifier: starts with a letter, then alphanumerics / underscore / hyphen.
  # Used for both swarm and agent names because these flow into OS process names,
  # container names, file paths, and (historically) shell command strings.
  # \A...\z (not ^...$): ^/$ match at line boundaries, so ^...$ would accept a
  # trailing newline ("valid\n"); \A...\z anchor the whole string.
  @name_regex ~r/\A[a-zA-Z][a-zA-Z0-9_-]*\z/

  @doc """
  Returns true if `name` is a valid agent/swarm identifier (starts with a letter,
  then alphanumeric/underscore/hyphen, whole-string anchored).

  Public so runtime creation paths (e.g. the dynamic add-agent API) can reject
  unsafe names with the same rule used at config-parse time.
  """
  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(name) when is_atom(name), do: valid_identifier?(Atom.to_string(name))
  def valid_identifier?(name) when is_binary(name), do: String.match?(name, @name_regex)
  def valid_identifier?(_), do: false

  defp validate_name(%{name: name}) when is_binary(name) and byte_size(name) > 0 do
    if valid_identifier?(name) do
      {:ok, name}
    else
      {:error,
       {:invalid_name,
        "Name must start with a letter and contain only alphanumeric, underscore, or hyphen characters"}}
    end
  end

  defp validate_name(%{name: name}) when is_atom(name), do: {:ok, Atom.to_string(name)}
  defp validate_name(_), do: {:error, :missing_name}

  defp validate_agents(%{agents: agents}) when is_list(agents) and length(agents) > 0 do
    results = Enum.map(agents, &validate_agent/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] -> {:ok, agents}
      [first_error | _] -> first_error
    end
  end

  defp validate_agents(_), do: {:error, :missing_or_empty_agents}

  defp validate_agent(%{name: name, backend: backend} = agent)
       when (is_binary(name) or is_atom(name)) and name != "" do
    with :ok <- validate_agent_name(name),
         :ok <- validate_backend(backend),
         :ok <- validate_skills(agent),
         :ok <- validate_tools(agent),
         :ok <- validate_presets(agent) do
      {:ok, agent}
    end
  end

  # Allow agents without explicit backend (will default to bwrap)
  defp validate_agent(%{name: name} = agent)
       when (is_binary(name) or is_atom(name)) and name != "" do
    with :ok <- validate_agent_name(name),
         :ok <- validate_skills(agent),
         :ok <- validate_tools(agent),
         :ok <- validate_presets(agent) do
      {:ok, agent}
    end
  end

  defp validate_agent(_), do: {:error, :invalid_agent_config}

  defp validate_agent_name(name) do
    if valid_identifier?(name) do
      :ok
    else
      {:error,
       {:invalid_agent_name,
        "Agent name must start with a letter and contain only alphanumeric, underscore, or hyphen characters"}}
    end
  end

  defp validate_backend(:bwrap), do: :ok
  defp validate_backend({:bwrap, opts}) when is_map(opts), do: :ok
  defp validate_backend(:local), do: :ok
  defp validate_backend({:docker, container}) when is_binary(container), do: :ok

  defp validate_backend({:docker, container, opts}) when is_binary(container) and is_map(opts),
    do: :ok

  defp validate_backend({:ssh, host}) when is_binary(host), do: :ok
  defp validate_backend({:ssh, host, opts}) when is_binary(host) and is_map(opts), do: :ok
  defp validate_backend(:mock), do: :ok
  defp validate_backend({:mock, opts}) when is_map(opts), do: :ok
  defp validate_backend(backend), do: {:error, {:invalid_backend, backend}}

  defp validate_skills(%{skills: skills}) when is_list(skills) do
    if Enum.all?(skills, &is_binary/1) do
      :ok
    else
      {:error, :invalid_skills_format}
    end
  end

  defp validate_skills(_), do: :ok

  defp validate_tools(%{tools: tools}) when is_list(tools) do
    if Enum.all?(tools, &is_atom/1) do
      invalid = Enum.filter(tools, &(&1 not in @valid_tools))

      case invalid do
        [] -> :ok
        _ -> {:error, {:unknown_tools, invalid}}
      end
    else
      {:error, :invalid_tools_format}
    end
  end

  defp validate_tools(_), do: :ok

  defp validate_presets(%{presets: presets}) when is_list(presets) do
    if Enum.all?(presets, &is_atom/1) do
      invalid = Enum.filter(presets, &(&1 not in @valid_presets))

      case invalid do
        [] -> :ok
        _ -> {:error, {:unknown_presets, invalid}}
      end
    else
      {:error, :invalid_presets_format}
    end
  end

  defp validate_presets(_), do: :ok

  defp validate_topology(%{topology: topology}, agents, objects) when is_list(topology) do
    # Combine agent and object names for topology validation
    agent_names = Enum.map(agents, fn %{name: name} -> normalize_name(name) end) |> MapSet.new()
    object_names = Enum.map(objects, fn %{name: name} -> normalize_name(name) end) |> MapSet.new()
    all_names = MapSet.union(agent_names, object_names)

    errors =
      topology
      |> Enum.with_index()
      |> Enum.flat_map(fn {edge, idx} ->
        case validate_edge(edge, all_names, idx) do
          :ok -> []
          {:error, err} -> [err]
        end
      end)

    case errors do
      [] -> {:ok, topology}
      _ -> {:error, {:invalid_topology, errors}}
    end
  end

  defp validate_topology(_, _, _), do: {:ok, []}

  defp validate_edge({from, to}, agent_names, _idx)
       when (is_atom(from) or is_binary(from)) and (is_atom(to) or is_binary(to)) do
    from_name = normalize_name(from)
    to_name = normalize_name(to)

    cond do
      not MapSet.member?(agent_names, from_name) ->
        {:error, {:unknown_agent, from_name}}

      not MapSet.member?(agent_names, to_name) ->
        {:error, {:unknown_agent, to_name}}

      true ->
        :ok
    end
  end

  defp validate_edge(edge, _, idx), do: {:error, {:invalid_edge_format, idx, edge}}

  defp validate_options(config) do
    options = Map.get(config, :options, %{})
    {:ok, options}
  end

  defp validate_objects(%{objects: objects}) when is_list(objects) do
    results = Enum.map(objects, &validate_object/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] -> {:ok, objects}
      [first_error | _] -> first_error
    end
  end

  defp validate_objects(_), do: {:ok, []}

  # Native object with handler
  defp validate_object(%{name: name, handler: handler} = object)
       when (is_binary(name) or is_atom(name)) and name != "" and is_atom(handler) do
    # Verify handler module exists and implements the behaviour
    if Code.ensure_loaded?(handler) do
      if function_exported?(handler, :init, 1) and function_exported?(handler, :handle_message, 3) do
        {:ok, object}
      else
        {:error, {:invalid_handler, handler, "must implement init/1 and handle_message/3"}}
      end
    else
      # Allow handler to not be loaded yet (it may be in the host application)
      {:ok, object}
    end
  end

  # Docker/SSH object with backend (no handler required)
  defp validate_object(%{name: name, backend: backend} = object)
       when (is_binary(name) or is_atom(name)) and name != "" do
    case validate_backend(backend) do
      :ok -> {:ok, object}
      error -> error
    end
  end

  defp validate_object(_), do: {:error, :invalid_object_config}

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: String.to_atom(name)

  defp normalize_agents(agents) do
    Enum.map(agents, fn agent ->
      agent
      |> Map.update!(:name, &normalize_name/1)
      # Default to bwrap for 10k+ scale
      |> Map.put_new(:backend, :bwrap)
    end)
  end

  defp normalize_topology(topology) do
    Enum.map(topology, fn {from, to} ->
      {normalize_name(from), normalize_name(to)}
    end)
  end

  defp normalize_objects(objects) do
    Enum.map(objects, fn object ->
      Map.update!(object, :name, &normalize_name/1)
    end)
  end
end
