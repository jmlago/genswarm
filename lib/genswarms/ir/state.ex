defmodule Genswarms.IR.State do
  @moduledoc """
  `swarm.state` (IR1) — a snapshot of a swarm: agents, objects, topology and
  options, in one of two phases (IR spec §3).

  `parse/1` takes a JSON-decoded map (string keys) and returns a validated
  `t` (struct, atom keys) or `{:error, reason}`. Validation enforces the §6
  invariants that hold at the data level:

    1. unique names across agents and objects;
    2. every topology endpoint references an existing node;
    3. slot-typing (§6.2) — `body` is `kind: data`, `handler` is `kind: code`,
       `backend` is a non-`swarmidx` execution ref, `model` is a service ref or
       a `{policy: ref}`;
    5. a declared `phase`.

  Invariant 4 (resolved-form digests) is `validate_resolved/1`, since it only
  applies to a resolved document (§7). Pure data, no eval.
  """

  alias Genswarms.IR.Ref

  defmodule Agent do
    @moduledoc "An agent node (§3.2)."
    @enforce_keys [:name, :body, :model, :backend]
    defstruct [:name, :body, :model, :backend, overrides: %{}, config: %{}]

    @type model_slot :: {:service, Ref.t()} | {:policy, Ref.t()}
    @type t :: %__MODULE__{
            name: String.t(),
            body: Ref.t(),
            model: model_slot(),
            backend: Ref.t(),
            overrides: map(),
            config: map()
          }
  end

  defmodule Object do
    @moduledoc "A non-agentic object node (§3.4); its handler is `kind: code`."
    @enforce_keys [:name, :handler]
    defstruct [:name, :handler, config: %{}]

    @type t :: %__MODULE__{name: String.t(), handler: Ref.t(), config: map()}
  end

  @enforce_keys [:name, :phase]
  defstruct v: 1,
            kind: "swarm.state",
            name: nil,
            phase: nil,
            agents: [],
            objects: [],
            topology: [],
            options: %{}

  @type phase :: :desired | :observed
  @type edge :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          v: pos_integer(),
          kind: String.t(),
          name: String.t(),
          phase: phase(),
          agents: [Agent.t()],
          objects: [Object.t()],
          topology: [edge()],
          options: map()
        }

  @format_version 1
  @phases %{"desired" => :desired, "observed" => :observed}

  @doc "Parses and validates a `swarm.state` document (authored or resolved)."
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(map) when is_map(map) do
    with :ok <- check_version(map),
         :ok <- check_kind(map),
         {:ok, name} <- fetch_string(map, "name"),
         {:ok, phase} <- fetch_phase(map),
         {:ok, agents} <- parse_list(map, "agents", &parse_agent/1, required: true),
         {:ok, objects} <- parse_list(map, "objects", &parse_object/1),
         {:ok, topology} <- parse_topology(map) do
      state = %__MODULE__{
        name: name,
        phase: phase,
        agents: agents,
        objects: objects,
        topology: topology,
        options: Map.get(map, "options", %{})
      }

      with :ok <- validate(state), do: {:ok, state}
    end
  end

  def parse(_), do: {:error, :state_not_a_map}

  @doc "Runs the data-level §6 invariants (unique names, valid edges)."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = state) do
    with :ok <- unique_names(state), do: valid_edges(state)
  end

  @doc """
  Resolved-form check (§6.4): every content-addressable ref carries a digest and
  no non-hashable ref does. Run on a resolved document before it is executed.
  """
  @spec validate_resolved(t()) :: :ok | {:error, term()}
  def validate_resolved(%__MODULE__{} = state) do
    state
    |> refs()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case Ref.validate_resolved(ref) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:unresolved_ref, ref.ref, reason}}}
      end
    end)
  end

  @doc "All refs in the state (bodies, model service/policy refs, backends, handlers)."
  @spec refs(t()) :: [Ref.t()]
  def refs(%__MODULE__{agents: agents, objects: objects}) do
    agent_refs =
      Enum.flat_map(agents, fn a ->
        [a.body, a.backend, model_ref(a.model)]
      end)

    object_refs = Enum.map(objects, & &1.handler)
    agent_refs ++ object_refs
  end

  defp model_ref({:service, ref}), do: ref
  defp model_ref({:policy, ref}), do: ref

  # ── element parsing ──────────────────────────────────────────────────────

  @doc "Parses+validates a single agent map (slot-typed). Reused by IR.Overlay."
  @spec parse_agent(map()) :: {:ok, Agent.t()} | {:error, term()}
  def parse_agent(%{} = m) do
    with {:ok, name} <- fetch_string(m, "name"),
         {:ok, body} <- parse_typed_ref(m, "body", :data),
         {:ok, model} <- parse_model_slot(m),
         {:ok, backend} <- parse_backend(m) do
      {:ok,
       %Agent{
         name: name,
         body: body,
         model: model,
         backend: backend,
         overrides: Map.get(m, "overrides", %{}),
         config: Map.get(m, "config", %{})
       }}
    end
  end

  def parse_agent(_), do: {:error, :invalid_agent}

  @doc "Parses+validates a single object map (handler is kind:code). Reused by IR.Overlay."
  @spec parse_object(map()) :: {:ok, Object.t()} | {:error, term()}
  def parse_object(%{} = m) do
    with {:ok, name} <- fetch_string(m, "name"),
         {:ok, handler} <- parse_typed_ref(m, "handler", :code) do
      {:ok, %Object{name: name, handler: handler, config: Map.get(m, "config", %{})}}
    end
  end

  def parse_object(_), do: {:error, :invalid_object}

  # A slot ref that must have a specific content kind (body→data, handler→code).
  defp parse_typed_ref(m, key, expected_kind) do
    with {:ok, ref} <- parse_ref_at(m, key) do
      if ref.kind == expected_kind,
        do: {:ok, ref},
        else: {:error, {:slot_type_mismatch, key, expected: expected_kind, got: ref.kind}}
    end
  end

  # agent.backend: an execution-service ref, never swarmidx (§6.2).
  defp parse_backend(m) do
    with {:ok, ref} <- parse_ref_at(m, "backend") do
      if ref.scheme == "swarmidx",
        do: {:error, {:slot_type_mismatch, "backend", reason: :swarmidx_not_allowed}},
        else: {:ok, ref}
    end
  end

  # agent.model: a service ref (external, non-swarmidx) OR {policy: ref⟨policy⟩}.
  defp parse_model_slot(m) do
    case Map.get(m, "model") do
      %{"policy" => policy} ->
        with {:ok, ref} <- Ref.parse(policy) do
          if ref.kind == :data,
            do: {:ok, {:policy, ref}},
            else: {:error, {:slot_type_mismatch, "model.policy", expected: :data, got: ref.kind}}
        end

      %{} = service ->
        with {:ok, ref} <- Ref.parse(service) do
          if ref.scheme == "swarmidx",
            do: {:error, {:slot_type_mismatch, "model", reason: :service_ref_not_swarmidx}},
            else: {:ok, {:service, ref}}
        end

      nil ->
        {:error, {:missing_slot, "model"}}

      _ ->
        {:error, {:invalid_model_slot, m["model"]}}
    end
  end

  defp parse_ref_at(m, key) do
    case Map.get(m, key) do
      nil -> {:error, {:missing_slot, key}}
      ref_map -> Ref.parse(ref_map)
    end
  end

  defp parse_topology(map) do
    case Map.get(map, "topology", []) do
      edges when is_list(edges) -> parse_edges(edges, [])
      _ -> {:error, :invalid_topology}
    end
  end

  defp parse_edges([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_edges([[from, to] | rest], acc) when is_binary(from) and is_binary(to),
    do: parse_edges(rest, [{from, to} | acc])

  defp parse_edges([bad | _], _acc), do: {:error, {:invalid_edge, bad}}

  defp parse_list(map, key, fun, opts \\ []) do
    case Map.get(map, key) do
      nil ->
        if opts[:required], do: {:error, {:missing, key}}, else: {:ok, []}

      list when is_list(list) ->
        reduce_parse(list, fun, [])

      _ ->
        {:error, {:invalid, key}}
    end
  end

  defp reduce_parse([], _fun, acc), do: {:ok, Enum.reverse(acc)}

  defp reduce_parse([item | rest], fun, acc) do
    case fun.(item) do
      {:ok, parsed} -> reduce_parse(rest, fun, [parsed | acc])
      {:error, _} = err -> err
    end
  end

  # ── invariants ───────────────────────────────────────────────────────────

  defp unique_names(%__MODULE__{agents: agents, objects: objects}) do
    names = Enum.map(agents, & &1.name) ++ Enum.map(objects, & &1.name)
    dups = names -- Enum.uniq(names)

    case dups do
      [] -> :ok
      [d | _] -> {:error, {:duplicate_name, d}}
    end
  end

  defp valid_edges(%__MODULE__{agents: agents, objects: objects, topology: topology}) do
    nodes = MapSet.new(Enum.map(agents, & &1.name) ++ Enum.map(objects, & &1.name))

    Enum.reduce_while(topology, :ok, fn {from, to}, :ok ->
      cond do
        not MapSet.member?(nodes, from) -> {:halt, {:error, {:unknown_edge_endpoint, from}}}
        not MapSet.member?(nodes, to) -> {:halt, {:error, {:unknown_edge_endpoint, to}}}
        true -> {:cont, :ok}
      end
    end)
  end

  # ── header helpers ─────────────────────────────────────────────────────────

  defp check_version(map) do
    case Map.get(map, "v") do
      @format_version -> :ok
      other -> {:error, {:unsupported_version, other}}
    end
  end

  defp check_kind(map) do
    case Map.get(map, "kind") do
      "swarm.state" -> :ok
      other -> {:error, {:wrong_kind, other}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing, key}}
    end
  end

  defp fetch_phase(map) do
    case Map.get(@phases, Map.get(map, "phase")) do
      nil -> {:error, {:invalid_phase, Map.get(map, "phase")}}
      phase -> {:ok, phase}
    end
  end
end
