defmodule Genswarms.Observability.TelemetryBridge do
  @moduledoc """
  Bridges the framework's `:telemetry` event stream into `LogStore`.

  The orchestrator already emits a rich, consistent telemetry vocabulary from
  every meaningful state transition (`[:genswarms, :swarm|:agent|:object|:router,
  <event>]`), but those events only fed metrics handlers — they never reached the
  durable, queryable `LogStore` nor the WebSocket event stream.

  This handler attaches once at application start and translates each telemetry
  event into a `LogStore.log/5` call. Because `LogStore.log/5` both persists
  (ETS + SQLite) and broadcasts `{:log_event, event}` over PubSub, a single
  bridge makes the whole vocabulary:

    * queryable (`LogStore.query`, the `/api/events` endpoints, `swarm events`)
    * streamable in real time (the `event`/`log_entry` pushes in `SwarmChannel`)

  This is the single source of truth for "what happened in a swarm". Adding a new
  observable transition means emitting a telemetry event — nothing else.

  See `docs/observability.md` for the event taxonomy this produces.
  """

  require Logger

  alias Genswarms.Observability.LogStore

  @handler_id "genswarms-telemetry-bridge"

  @doc """
  Attaches the bridge handler to every `[:genswarms, <domain>, <event>]` telemetry
  event. Idempotent: a duplicate attach is treated as success.
  """
  @spec attach() :: :ok
  def attach do
    events = telemetry_events()

    case :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the bridge handler (used in tests)."
  @spec detach() :: :ok
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  # The framework uses a fixed, known set of event names per domain. We attach to
  # the concrete `[:genswarms, domain, event]` triples so unrelated `:genswarms`
  # telemetry (if any is ever added) is not silently swept in.
  def telemetry_events do
    for {domain, events} <- known_events(), event <- events do
      [:genswarms, domain, event]
    end
  end

  @doc false
  def handle_event([:genswarms, domain, event], _measurements, metadata, _config) do
    LogStore.log(
      metadata[:level] || level_for(event),
      category_for(domain),
      event,
      message_for(domain, event, metadata),
      swarm: metadata[:swarm],
      agent: metadata[:agent] || metadata[:object],
      metadata: sanitize(metadata)
    )
  rescue
    # Observability must never take down the process that emitted the event.
    err ->
      Logger.warning("TelemetryBridge dropped #{inspect(event)}: #{inspect(err)}")
      :ok
  end

  # ── mapping ──────────────────────────────────────────────────────────────────

  # LogStore documents its categories as :backend/:routing/:agent/:swarm/:system.
  # The `:router` telemetry domain maps to the `:routing` category for consistency.
  defp category_for(:router), do: :routing
  defp category_for(domain), do: domain

  # An emitter may pass `level:` in its telemetry metadata to set the LogStore
  # level explicitly (e.g. a partial swarm start, an unexpected agent exit);
  # otherwise it is derived from the event name below.
  defp level_for(event) do
    name = Atom.to_string(event)

    cond do
      String.contains?(name, "error") -> :error
      String.contains?(name, "failed") -> :error
      String.contains?(name, "invalid") -> :warning
      String.contains?(name, "not_found") -> :warning
      String.contains?(name, "full") -> :warning
      true -> :info
    end
  end

  defp message_for(:router, :message_routed, %{from: from, to: to}),
    do: "message routed #{from} → #{to}"

  defp message_for(:router, :message_broadcast, %{from: from}),
    do: "broadcast from #{from}"

  defp message_for(:agent, event, %{agent: agent}),
    do: "agent #{agent} #{humanize(event)}"

  defp message_for(:object, event, %{object: object}),
    do: "object #{object} #{humanize(event)}"

  defp message_for(:swarm, event, %{swarm: swarm}),
    do: "swarm #{swarm} #{event |> Atom.to_string() |> String.replace_prefix("swarm_", "")}"

  defp message_for(domain, event, _metadata),
    do: "#{domain} #{humanize(event)}"

  defp humanize(event), do: event |> Atom.to_string() |> String.replace("_", " ")

  # The :level override is a logging concern, not part of the event payload.
  defp sanitize(metadata), do: do_sanitize(Map.drop(metadata, [:level]))

  # Keep metadata JSON-friendly and avoid persisting large/opaque terms. We drop
  # the keys LogStore already lifts to columns (swarm/agent/object) to avoid
  # duplicating them inside the metadata blob.
  defp do_sanitize(metadata) do
    metadata
    |> Map.drop([:swarm, :agent, :object])
    |> Map.new(fn {k, v} -> {k, sanitize_value(v)} end)
  end

  defp sanitize_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp sanitize_value(v) when is_atom(v), do: v
  defp sanitize_value(v) when is_list(v), do: Enum.map(v, &sanitize_value/1)

  # Structs (DateTime, Time, custom structs, …) are maps but do NOT implement
  # Enumerable, so the generic map clause's Map.new/2 would raise
  # Protocol.UndefinedError and the whole event would be dropped. Render them
  # opaque instead. (This clause MUST precede the is_map/1 clause.)
  defp sanitize_value(%_{} = v), do: inspect(v)

  defp sanitize_value(v) when is_map(v),
    do: Map.new(v, fn {k, val} -> {k, sanitize_value(val)} end)

  defp sanitize_value(v), do: inspect(v)

  # The framework's emitted telemetry vocabulary, by domain. Extend here (and in
  # docs/observability.md) when a new observable transition is added.
  defp known_events do
    %{
      swarm: [:swarm_started, :swarm_stopped],
      agent: [
        :agent_started,
        :agent_stopped,
        :agent_error,
        :agent_added,
        :agent_removed,
        :task_sent,
        :message_delivered
      ],
      object: [
        :object_started,
        :object_stopped,
        :object_error,
        :object_added,
        :object_removed
      ],
      router: [:message_routed, :message_broadcast, :invalid_route]
    }
  end
end
