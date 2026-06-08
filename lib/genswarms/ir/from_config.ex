defmodule Genswarms.IR.FromConfig do
  @moduledoc """
  Translates a current GenSwarms swarm config (the `.exs`/`.json`/`.yaml` DSL)
  into a `swarm.state` IR document (phase `desired`).

  The DSL describes *local, inline* things; the IR is built for content-addressed
  *packages*. Until the registry (`swarmidx`) exists, local things become
  non-package `<other>` refs (§2.1) and the agent persona becomes an *inline*
  body — when a config is later published with `gsp`, those `inline:`/`local:`/…
  refs become real `swarmidx:`/`oci:` packages with digests.

  Mapping:

      agent.skills/presets   -> body  {ref: "inline:<name>", kind: data}
                                       + overrides {skills, presets}
      agent.model "x/y"      -> model {ref: "openrouter:x/y", attested: true}
      backend :bwrap/:local/:mock -> {ref: "bwrap"|"local"|"mock"}
      backend {:docker, n}   -> {ref: "oci:<n>", kind: data}
      backend {:ssh, "u@h"}  -> {ref: "ssh", host: "u@h"}
      object.handler Mod     -> handler {ref: "module:<Mod>", kind: code}

  Returns a validated `IR.State` (`{:ok, state}`) so any mapping that violates
  the §6 invariants is caught immediately.
  """

  alias Genswarms.IR

  @doc "Translates a swarm config map into a validated `swarm.state` (IR1)."
  @spec from_config(map()) :: {:ok, IR.State.t()} | {:error, term()}
  def from_config(config) when is_map(config) do
    with {:ok, agents} <- map_each(Map.get(config, :agents, []), &agent/1),
         {:ok, objects} <- map_each(Map.get(config, :objects, []), &object/1) do
      IR.state(%{
        "v" => 1,
        "kind" => "swarm.state",
        "name" => to_string(Map.get(config, :name, "swarm")),
        "phase" => "desired",
        "agents" => agents,
        "objects" => objects,
        "topology" => topology(Map.get(config, :topology, [])),
        "options" => stringify_keys(Map.get(config, :options, %{}))
      })
    end
  end

  def from_config(_), do: {:error, :config_not_a_map}

  # ── agents ──────────────────────────────────────────────────────────────────

  defp agent(%{} = a) do
    name = to_string(Map.get(a, :name))

    with {:ok, backend} <- backend_ref(Map.get(a, :backend, :bwrap)) do
      {:ok,
       %{
         "name" => name,
         "body" => %{"ref" => "inline:" <> name, "kind" => "data"},
         "model" => model_slot(Map.get(a, :model)),
         "backend" => backend,
         "overrides" => overrides(a),
         "config" => stringify_keys(Map.get(a, :config, %{}))
       }}
    end
  end

  defp agent(_), do: {:error, :invalid_agent_config}

  # The persona becomes an inline body; skills/presets ride in overrides.
  defp overrides(a) do
    %{
      "skills" => Map.get(a, :skills, []),
      "presets" => a |> Map.get(:presets, []) |> Enum.map(&to_string/1)
    }
  end

  # A model string ("provider/model", OpenRouter format) -> a service ref.
  defp model_slot(model) do
    %{"ref" => "openrouter:" <> to_string(model || "default"), "attested" => true}
  end

  defp backend_ref(:local), do: {:ok, %{"ref" => "local"}}
  defp backend_ref(:bwrap), do: {:ok, %{"ref" => "bwrap"}}
  defp backend_ref(:mock), do: {:ok, %{"ref" => "mock"}}
  defp backend_ref({:bwrap, _opts}), do: {:ok, %{"ref" => "bwrap"}}
  defp backend_ref({:mock, _opts}), do: {:ok, %{"ref" => "mock"}}
  defp backend_ref({:docker, name}), do: {:ok, oci(name)}
  defp backend_ref({:docker, name, _opts}), do: {:ok, oci(name)}
  defp backend_ref({:ssh, host}), do: {:ok, %{"ref" => "ssh", "host" => to_string(host)}}
  defp backend_ref({:ssh, host, _opts}), do: {:ok, %{"ref" => "ssh", "host" => to_string(host)}}
  defp backend_ref(other), do: {:error, {:unsupported_backend, other}}

  defp oci(name), do: %{"ref" => "oci:" <> to_string(name), "kind" => "data"}

  # ── objects ─────────────────────────────────────────────────────────────────

  defp object(%{handler: handler} = o) when not is_nil(handler) do
    {:ok,
     %{
       "name" => to_string(Map.get(o, :name)),
       "handler" => %{"ref" => "module:" <> inspect(handler), "kind" => "code"},
       "config" => stringify_keys(Map.get(o, :config, %{}))
     }}
  end

  # IR objects are handler (code) nodes; a backend-only object has no IR §3.4
  # equivalent yet.
  defp object(%{}), do: {:error, :object_without_handler}
  defp object(_), do: {:error, :invalid_object_config}

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp topology(edges) do
    Enum.map(edges, fn {from, to} -> [to_string(from), to_string(to)] end)
  end

  defp map_each(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, mapped} -> {:cont, {:ok, acc ++ [mapped]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp map_each(_, _), do: {:error, :not_a_list}

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify_keys(other), do: other
end
