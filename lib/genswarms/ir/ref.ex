defmodule Genswarms.IR.Ref do
  @moduledoc """
  A reference (`ref object`) in the GenSwarms IR — the unit a resolver and the
  transparency log operate on (IR spec §2).

  A ref points at the content that occupies a slot. It is classified along two
  **orthogonal** axes:

    * **who resolves it** — `swarmidx` (the GenSwarms registry) vs an external
      resolver (OCI, model providers, ssh); and
    * **content-addressable or not** — `swarmidx`/`oci` carry a `digest`;
      `openrouter`/`ssh` do not (they may be `attested`).

  Refs exist in two forms of the same shape (§7):

    * **authored** — may omit `digest` (constraint version like `@^1.2`);
    * **resolved** — content-addressable refs carry an inline `digest`.

  `parse/1` validates structure (authored-safe). `validate_resolved/1` adds the
  resolved-form digest-presence rule. The canonical serialization is JSON, so
  `parse/1` takes a JSON-decoded map with **string keys**.
  """

  @enforce_keys [:ref, :scheme, :kind]
  defstruct [:ref, :scheme, :digest, :kind, :attested, :host]

  @type kind :: :data | :code | nil
  @type t :: %__MODULE__{
          ref: String.t(),
          scheme: String.t(),
          digest: String.t() | nil,
          kind: kind(),
          attested: boolean(),
          host: String.t() | nil
        }

  # Schemes whose content is addressed by a reproducible digest (§2.1).
  @content_addressable ~w(swarmidx oci)
  # Schemes that require a `host` field (§2.3).
  @host_required ~w(ssh)
  # Schemes that may appear bare (no `:body`): connection-style (`ssh`/`host`,
  # §3.7) and the local execution backends a translated config produces
  # (`local`/`bwrap`/`mock`) — non-package `<other>` schemes per §2.1.
  @bare_schemes ~w(ssh host local bwrap mock)

  @doc """
  Parses a JSON-decoded ref map (string keys) into a validated `t`.

  Validates structure only (so it accepts authored refs without a digest):
  a non-empty `ref` string with a scheme, a `kind` of `"data"`/`"code"`, and a
  `host` for schemes that require one. Returns `{:ok, t}` or `{:error, reason}`.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(map) when is_map(map) do
    with {:ok, ref} <- fetch_ref(map),
         {:ok, scheme} <- scheme(ref),
         {:ok, kind} <- fetch_kind(map, scheme),
         :ok <- validate_host(scheme, map),
         :ok <- validate_attested(map) do
      {:ok,
       %__MODULE__{
         ref: ref,
         scheme: scheme,
         digest: Map.get(map, "digest"),
         kind: kind,
         attested: Map.get(map, "attested", false),
         host: Map.get(map, "host")
       }}
    end
  end

  def parse(_), do: {:error, :ref_not_a_map}

  @doc "Extracts the scheme from a ref string (the part before the first `:`)."
  @spec scheme(String.t()) :: {:ok, String.t()} | {:error, term()}
  def scheme(ref) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      [scheme, body] when scheme != "" and body != "" -> {:ok, scheme}
      # Bare scheme (no `:body`) — only valid for connection-style schemes.
      [bare] when bare in @bare_schemes -> {:ok, bare}
      _ -> {:error, :invalid_ref_string}
    end
  end

  def scheme(_), do: {:error, :invalid_ref_string}

  @doc "Whether a scheme is content-addressable (carries a digest)."
  @spec content_addressable?(String.t()) :: boolean()
  def content_addressable?(scheme), do: scheme in @content_addressable

  @doc """
  Enforces the resolved-form digest rule (§2.3): a content-addressable ref MUST
  carry a well-formed `digest`; a non-hashable ref MUST NOT carry one.
  """
  @spec validate_resolved(t()) :: :ok | {:error, term()}
  def validate_resolved(%__MODULE__{scheme: scheme, digest: digest}) do
    cond do
      content_addressable?(scheme) and is_nil(digest) ->
        {:error, :missing_digest}

      content_addressable?(scheme) and not valid_digest?(digest) ->
        {:error, {:invalid_digest, digest}}

      not content_addressable?(scheme) and not is_nil(digest) ->
        {:error, :unexpected_digest}

      true ->
        :ok
    end
  end

  @doc "A digest is `\"<algo>:<hex>\"`, e.g. `\"sha256:9f2c…\"`."
  @spec valid_digest?(term()) :: boolean()
  def valid_digest?(digest) when is_binary(digest),
    do: String.match?(digest, ~r/^[a-z0-9]+:[0-9a-f]+$/)

  def valid_digest?(_), do: false

  # Private

  defp fetch_ref(map) do
    case Map.get(map, "ref") do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _ -> {:error, :missing_ref}
    end
  end

  # `kind` (data/code) describes *package content*, so it is required for
  # content-addressable refs (swarmidx/oci) and omitted for non-hashable refs
  # (model endpoints, ssh hosts), which are not packages (§2.4, §3.7 examples).
  defp fetch_kind(map, scheme) do
    case Map.get(map, "kind") do
      "data" -> {:ok, :data}
      "code" -> {:ok, :code}
      nil -> if content_addressable?(scheme), do: {:error, :missing_kind}, else: {:ok, nil}
      other -> {:error, {:invalid_kind, other}}
    end
  end

  defp validate_host(scheme, map) do
    cond do
      scheme not in @host_required -> :ok
      is_binary(Map.get(map, "host")) and Map.get(map, "host") != "" -> :ok
      true -> {:error, {:missing_host, scheme}}
    end
  end

  defp validate_attested(map) do
    case Map.get(map, "attested") do
      nil -> :ok
      v when is_boolean(v) -> :ok
      other -> {:error, {:invalid_attested, other}}
    end
  end
end
