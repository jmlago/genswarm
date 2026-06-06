defmodule Genswarms.Backends.EndpointPolicy do
  @moduledoc """
  Resolves the `{endpoint, api_key}` a backend should pass to an agent, applying
  an SSRF / credential-exfiltration policy (audit finding 28, CWE-918).

  The problem: every backend used to do

      endpoint = config[:endpoint] || env "SUBZEROCLAW_ENDPOINT"
      api_key  = config[:api_key]  || env "SUBZEROCLAW_API_KEY"

  and forward both to the agent. A per-agent `endpoint` is attacker-influenceable
  (it flows in through the add-agent / create API), so an attacker could point it
  at their host and receive the operator's server-env LLM **API key**.

  Policy:

    * `endpoint` = `config[:endpoint]` (per-agent override) else the server env.
    * An explicit `config[:api_key]` is always honored (the caller chose to pair
      its own key with its own endpoint).
    * The **server-env** `SUBZEROCLAW_API_KEY` is forwarded only with a *trusted*
      endpoint: one that is unset (default), equal to the server's own
      `SUBZEROCLAW_ENDPOINT`, or whose host is in the `GENSWARMS_ALLOWED_ENDPOINTS`
      allowlist. For any other (e.g. per-agent custom) endpoint the env key is
      withheld.

  To pair a custom endpoint with a key, either add its host to
  `GENSWARMS_ALLOWED_ENDPOINTS` (then the env key is forwarded), or set an
  explicit `:api_key` in that agent's config. Note: the dynamic add-agent API
  (`parse_agent_spec`) does not currently parse `:api_key`, so the explicit-key
  route applies to `.exs`/`config`-loaded agents — API-added agents with a
  custom endpoint must use the allowlist.

  This stops the env key from ever being co-forwarded to an untrusted endpoint,
  while leaving the common cases (no custom endpoint; or custom endpoint with an
  explicit key; or an allowlisted endpoint) working.
  """

  @doc """
  Returns `{endpoint, api_key}` per the policy above. Both may be `nil`.
  """
  @spec resolve(map()) :: {String.t() | nil, String.t() | nil}
  def resolve(config) when is_map(config) do
    env_endpoint = System.get_env("SUBZEROCLAW_ENDPOINT")
    endpoint = Map.get(config, :endpoint) || env_endpoint

    api_key =
      case Map.get(config, :api_key) do
        explicit when is_binary(explicit) and explicit != "" ->
          explicit

        _ ->
          if trusted_endpoint?(endpoint, env_endpoint) do
            System.get_env("SUBZEROCLAW_API_KEY")
          else
            nil
          end
      end

    {endpoint, api_key}
  end

  @doc """
  True if `endpoint` is trusted to receive the server's env API key.
  """
  @spec trusted_endpoint?(String.t() | nil, String.t() | nil) :: boolean()
  def trusted_endpoint?(nil, _env_endpoint), do: true

  def trusted_endpoint?(endpoint, env_endpoint) do
    endpoint == env_endpoint or endpoint_allowed?(endpoint)
  end

  defp endpoint_allowed?(endpoint) do
    case allowed_hosts() do
      [] -> false
      hosts -> host_of(endpoint) in hosts
    end
  end

  defp allowed_hosts do
    (System.get_env("GENSWARMS_ALLOWED_ENDPOINTS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp host_of(_), do: nil
end
