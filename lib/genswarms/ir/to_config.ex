defmodule Genswarms.IR.ToConfig do
  @moduledoc """
  The reverse of `IR.FromConfig`: turns an IR `Agent`/`Object` back into the
  runtime's config-format spec (the map `SwarmManager.add_agent/add_object`
  expect). Lets the IR executor drive the existing orchestrator.

      body {ref: "inline:<name>"} + overrides{skills,presets} -> skills/presets
      model {ref: "openrouter:x/y"}                           -> model: "x/y"
      backend {ref: "bwrap"|"local"|"mock"}                  -> :bwrap/:local/:mock
      backend {ref: "oci:n"}                                  -> {:docker, "n"}
      backend {ref: "ssh", host: h}                           -> {:ssh, h}
      handler {ref: "module:<Mod>"}                           -> the module atom
  """

  alias Genswarms.IR.State.{Agent, Object}

  @doc "IR agent -> runtime agent spec map."
  @spec agent_spec(Agent.t()) :: map()
  def agent_spec(%Agent{} = a) do
    %{
      name: a.name,
      backend: backend(a.backend),
      model: model(a.model),
      skills: Map.get(a.overrides, "skills", []),
      presets: a.overrides |> Map.get("presets", []) |> Enum.map(&String.to_atom/1),
      config: a.config
    }
  end

  @doc "IR object -> runtime object spec map."
  @spec object_spec(Object.t()) :: map()
  def object_spec(%Object{} = o) do
    %{name: o.name, handler: handler_module(o.handler), config: o.config}
  end

  # ── backend ──────────────────────────────────────────────────────────────────

  defp backend(%{scheme: "bwrap"}), do: :bwrap
  defp backend(%{scheme: "local"}), do: :local
  defp backend(%{scheme: "mock"}), do: :mock
  defp backend(%{scheme: "oci", ref: ref}), do: {:docker, String.replace_prefix(ref, "oci:", "")}
  defp backend(%{scheme: "ssh", host: host}), do: {:ssh, host}

  # ── model ────────────────────────────────────────────────────────────────────

  # The translated default (`openrouter:default`) means "no explicit model".
  defp model({:service, %{ref: "openrouter:default"}}), do: nil
  defp model({:service, %{ref: ref}}), do: String.replace_prefix(ref, "openrouter:", "")
  # A policy slot has no config-format model-string equivalent yet.
  defp model({:policy, _ref}), do: nil

  # ── handler ──────────────────────────────────────────────────────────────────

  # `module:<Mod>` -> the existing module atom (safe_concat never mints — #22).
  defp handler_module(%{ref: ref}) do
    ref |> String.replace_prefix("module:", "") |> String.split(".") |> Module.safe_concat()
  end
end
