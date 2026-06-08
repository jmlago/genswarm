defmodule GenswarmsWeb.Cors do
  @moduledoc """
  CORS origin policy for the API.

  Corsica calls `allowed_origin?/2` per request (an MFA `:origins` option), so
  the allowlist is resolved at request time and can come from runtime config.

  Policy (configured via `GENSWARMS_CORS_ORIGINS`):

    * unset / blank → only local development origins (`localhost`, `127.0.0.1`,
      `[::1]` on any port/scheme) are allowed. Secure default for a local-first
      tool — a browser on another site cannot read the API cross-origin.
    * `"*"` → allow any origin (opt back into the old permissive behaviour; only
      do this behind the API token, see `Genswarms.Auth`).
    * comma-separated list → exact-match allowlist of those origins.

  Non-browser clients (the CLI, curl) send no `Origin` header and are unaffected
  — CORS only governs browser cross-origin reads.
  """

  @localhost_default [
    ~r/^https?:\/\/localhost(:\d+)?$/,
    ~r/^https?:\/\/127\.0\.0\.1(:\d+)?$/,
    ~r/^https?:\/\/\[::1\](:\d+)?$/
  ]

  @doc """
  Corsica MFA callback: true if `origin` is permitted by the current setting.
  """
  @spec allowed_origin?(Plug.Conn.t(), binary()) :: boolean()
  def allowed_origin?(_conn, origin), do: allowed?(origin, origins_setting())

  @doc """
  Resolves the configured origins: `:all` or a list of string/`Regex` matchers.
  """
  @spec origins_setting() :: :all | [String.t() | Regex.t()]
  def origins_setting do
    case Application.get_env(:genswarms, :cors_origins) do
      nil -> @localhost_default
      "" -> @localhost_default
      "*" -> :all
      val when is_binary(val) -> val |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      val when is_list(val) -> val
    end
  end

  @doc """
  Pure membership check used by `allowed_origin?/2` (exposed for testing).
  """
  @spec allowed?(binary(), :all | [String.t() | Regex.t()]) :: boolean()
  def allowed?(_origin, :all), do: true

  def allowed?(origin, matchers) when is_list(matchers) do
    Enum.any?(matchers, &origin_matches?(origin, &1))
  end

  defp origin_matches?(origin, %Regex{} = re), do: Regex.match?(re, origin)
  defp origin_matches?(origin, str) when is_binary(str), do: origin == str
  defp origin_matches?(_origin, _other), do: false
end
