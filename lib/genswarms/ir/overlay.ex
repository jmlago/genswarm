defmodule Genswarms.IR.Overlay do
  @moduledoc """
  `swarm.overlay` (IR2) — an ordered event log folded over a `swarm.state`
  (IR spec §4). It is both a versioned history and the control-plane command
  stream.

  `parse/1` validates the document: the envelope (`v`/`kind`/`swarm`/`apply`),
  each event's `seq`/`op`/`payload`, that `seq` is strictly ascending, that
  every `op` is a known op from the §4.3 catalogue (unknown ops fail validation
  in incremental mode — they are never silently ignored), and that each payload
  is structurally valid for its op (add_agent/add_object reuse the slot-typed
  `IR.State` parsers). Folding the log onto a state is a separate concern (§5).

  Op strings are mapped to a fixed atom set — no `String.to_atom`, so a stream of
  unknown ops cannot mint atoms.
  """

  alias Genswarms.IR.{Ref, State}

  defmodule Event do
    @moduledoc "An overlay event envelope (§4.2). `payload` stays a raw map."
    @enforce_keys [:seq, :op, :payload]
    defstruct [:seq, :op, :payload]

    @type t :: %__MODULE__{seq: integer(), op: atom(), payload: map()}
  end

  @enforce_keys [:swarm, :apply, :events]
  defstruct v: 1, kind: "swarm.overlay", swarm: nil, apply: :incremental, events: []

  @type apply_mode :: :incremental | :transactional
  @type t :: %__MODULE__{
          v: pos_integer(),
          kind: String.t(),
          swarm: String.t(),
          apply: apply_mode(),
          events: [Event.t()]
        }

  @format_version 1
  @apply_modes %{"incremental" => :incremental, "transactional" => :transactional}

  # §4.3 op catalogue. Mapped from the string form without minting atoms.
  @ops ~w(add_agent remove_agent add_object remove_object add_topology_edges
          remove_topology_edges scale_agent_group bump_package set_options
          update_config)a
  @op_map Map.new(@ops, &{Atom.to_string(&1), &1})

  # §5.2 transition policies.
  @on_inflight ~w(drain kill quarantine)
  @migration ~w(state_migrate restart)
  @bump_fields ~w(body model backend handler)

  @doc "Parses and validates a `swarm.overlay` document."
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(map) when is_map(map) do
    with :ok <- check_version(map),
         :ok <- check_kind(map),
         {:ok, swarm} <- fetch_string(map, "swarm"),
         {:ok, apply_mode} <- fetch_apply(map),
         {:ok, events} <- parse_events(map) do
      {:ok, %__MODULE__{swarm: swarm, apply: apply_mode, events: events}}
    end
  end

  def parse(_), do: {:error, :overlay_not_a_map}

  @doc "The known op atoms (§4.3)."
  @spec ops() :: [atom()]
  def ops, do: @ops

  # ── events ─────────────────────────────────────────────────────────────────

  defp parse_events(map) do
    case Map.get(map, "events") do
      events when is_list(events) -> parse_events(events, nil, [])
      _ -> {:error, :missing_events}
    end
  end

  defp parse_events([], _prev_seq, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_events([raw | rest], prev_seq, acc) do
    with {:ok, event} <- parse_event(raw, prev_seq) do
      parse_events(rest, event.seq, [event | acc])
    end
  end

  defp parse_event(%{} = m, prev_seq) do
    with {:ok, seq} <- fetch_seq(m, prev_seq),
         {:ok, op} <- fetch_op(m),
         {:ok, payload} <- fetch_payload(m),
         :ok <- validate_payload(op, payload) do
      {:ok, %Event{seq: seq, op: op, payload: payload}}
    end
  end

  defp parse_event(_, _), do: {:error, :invalid_event}

  defp fetch_seq(m, prev_seq) do
    case Map.get(m, "seq") do
      seq when is_integer(seq) ->
        # §5.1: strictly ascending.
        if is_nil(prev_seq) or seq > prev_seq,
          do: {:ok, seq},
          else: {:error, {:non_monotonic_seq, seq, prev_seq}}

      other ->
        {:error, {:invalid_seq, other}}
    end
  end

  defp fetch_op(m) do
    case Map.get(@op_map, Map.get(m, "op")) do
      nil -> {:error, {:unknown_op, Map.get(m, "op")}}
      op -> {:ok, op}
    end
  end

  defp fetch_payload(m) do
    case Map.get(m, "payload") do
      %{} = payload -> {:ok, payload}
      _ -> {:error, :invalid_payload}
    end
  end

  # ── per-op payload validation (§4.3) ────────────────────────────────────────

  defp validate_payload(:add_agent, payload), do: ok(State.parse_agent(payload))
  defp validate_payload(:add_object, payload), do: ok(State.parse_object(payload))
  defp validate_payload(:remove_agent, payload), do: name_and_inflight(payload)
  defp validate_payload(:remove_object, payload), do: name_and_inflight(payload)
  defp validate_payload(:add_topology_edges, payload), do: edges(payload)
  defp validate_payload(:remove_topology_edges, payload), do: edges(payload)
  defp validate_payload(:set_options, payload), do: map_field(payload, "options")

  defp validate_payload(:scale_agent_group, payload) do
    with {:ok, _} <- string_field(payload, "base_name"),
         :ok <- non_neg_int(payload, "target_count"),
         :ok <- inflight(payload) do
      :ok
    end
  end

  defp validate_payload(:bump_package, payload) do
    with {:ok, _} <- string_field(payload, "target"),
         :ok <- bump_field(payload),
         :ok <- digest_field(payload, "from"),
         :ok <- digest_field(payload, "to"),
         :ok <- migration(payload),
         :ok <- inflight(payload) do
      :ok
    end
  end

  defp validate_payload(:update_config, payload) do
    with {:ok, _} <- string_field(payload, "target"), do: map_field(payload, "config")
  end

  defp ok({:ok, _}), do: :ok
  defp ok({:error, _} = err), do: err

  defp name_and_inflight(payload) do
    with {:ok, _} <- string_field(payload, "name"), do: inflight(payload)
  end

  defp edges(payload) do
    case Map.get(payload, "edges") do
      list when is_list(list) ->
        if Enum.all?(list, &match?([f, t] when is_binary(f) and is_binary(t), &1)),
          do: :ok,
          else: {:error, :invalid_edges}

      _ ->
        {:error, :missing_edges}
    end
  end

  defp bump_field(payload) do
    case Map.get(payload, "field") do
      f when f in @bump_fields -> :ok
      other -> {:error, {:invalid_bump_field, other}}
    end
  end

  defp string_field(payload, key) do
    case Map.get(payload, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp map_field(payload, key) do
    case Map.get(payload, key) do
      %{} -> :ok
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp non_neg_int(payload, key) do
    case Map.get(payload, key) do
      n when is_integer(n) and n >= 0 -> :ok
      other -> {:error, {:invalid_count, key, other}}
    end
  end

  defp digest_field(payload, key) do
    if Ref.valid_digest?(Map.get(payload, key)),
      do: :ok,
      else: {:error, {:invalid_digest, key, Map.get(payload, key)}}
  end

  defp inflight(payload), do: optional_enum(payload, "on_inflight", @on_inflight)
  defp migration(payload), do: optional_enum(payload, "migration", @migration)

  defp optional_enum(payload, key, allowed) do
    case Map.get(payload, key) do
      nil -> :ok
      value -> if value in allowed, do: :ok, else: {:error, {:invalid_policy, key, value}}
    end
  end

  # ── header helpers ──────────────────────────────────────────────────────────

  defp check_version(map) do
    case Map.get(map, "v") do
      @format_version -> :ok
      other -> {:error, {:unsupported_version, other}}
    end
  end

  defp check_kind(map) do
    case Map.get(map, "kind") do
      "swarm.overlay" -> :ok
      other -> {:error, {:wrong_kind, other}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing, key}}
    end
  end

  defp fetch_apply(map) do
    case Map.get(map, "apply", "incremental") do
      mode when is_map_key(@apply_modes, mode) -> {:ok, Map.fetch!(@apply_modes, mode)}
      other -> {:error, {:invalid_apply_mode, other}}
    end
  end
end
