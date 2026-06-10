defmodule Genswarms.Agents.Ask do
  @moduledoc """
  Correlated synchronous object calls (`swarm-msg ask`) — the pure helpers.

  An agent's `swarm-msg ask <object> '{...}'` writes an outbox file carrying a
  `reply_to` correlation id, then blocks polling
  `{workspace}/.inbox/replies/{correlation_id}.json`. The engine routes the
  request to the object (Router → ObjectServer), wraps the object's `{:reply, …}`
  in the typed envelope below, and writes it to that reply file — instead of
  injecting it into the agent as a new conversational turn. The blocked
  `swarm-msg ask` prints the envelope on its stdout, so the result lands inline
  in the SAME LLM turn (the shell tool is synchronous).

  The envelope is ALWAYS well-formed JSON — an object error, a missing target, a
  denied route, or a timeout all become `ok: false` envelopes; the model never
  sees a raw exception or an unexplained hang:

      {"ok":true,"result":{...},"error":null,"timeout":false,
       "correlation_id":"...","duration_ms":12}

      {"ok":false,"result":{...},
       "error":{"code":"not_allowed","message":"not_allowed","type":"unknown"},
       "timeout":false,"correlation_id":"...","duration_ms":9}

  An object reply whose top-level JSON carries an `"error"` key is surfaced as
  `ok: false` with the error normalized into `{code, message, type}`; objects
  may populate `type` with `"permanent"` or `"transient"` so the model knows
  whether retrying can ever help. The engine only carries the field.

  Late replies are impossible by construction: a reply file for a correlation id
  nobody is waiting on is simply never read (swarm-msg deletes its own file
  after reading; stale files are swept with the workspace).
  """

  require Logger

  @replies_subdir ".inbox/replies"

  # Correlation ids come from inside the agent sandbox, and they become file
  # names — accept only a conservative charset so a compromised agent cannot
  # traverse out of its own replies dir (e.g. "../../...").
  @corr_re ~r/^[A-Za-z0-9._-]{1,128}$/

  @doc """
  Whether a correlation id is safe to use as a reply file name.
  """
  @spec valid_correlation_id?(term()) :: boolean()
  def valid_correlation_id?(corr) when is_binary(corr) do
    corr != "" and
      corr not in [".", ".."] and
      Regex.match?(@corr_re, corr) and
      Path.basename(corr) == corr
  end

  def valid_correlation_id?(_), do: false

  @doc """
  Build the reply envelope for an object's reply (or non-reply) to an ask.

  `response` is whatever the object handler produced: a JSON binary (the normal
  case), `nil` (the handler returned `{:noreply, …}` or a send-elsewhere shape —
  the ask is acknowledged with `result: nil`), or any other term (stringified).
  """
  @spec envelope(binary() | nil | term(), String.t(), non_neg_integer()) :: map()
  def envelope(nil, corr, duration_ms) do
    %{
      ok: true,
      result: nil,
      error: nil,
      timeout: false,
      correlation_id: corr,
      duration_ms: duration_ms
    }
  end

  def envelope(response, corr, duration_ms) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, %{"error" => err} = decoded} ->
        %{
          ok: false,
          result: decoded,
          error: normalize_error(err),
          timeout: false,
          correlation_id: corr,
          duration_ms: duration_ms
        }

      {:ok, decoded} ->
        %{
          ok: true,
          result: decoded,
          error: nil,
          timeout: false,
          correlation_id: corr,
          duration_ms: duration_ms
        }

      {:error, _} ->
        # Not JSON — pass the raw text through rather than guessing.
        %{
          ok: true,
          result: %{"raw" => response},
          error: nil,
          timeout: false,
          correlation_id: corr,
          duration_ms: duration_ms
        }
    end
  end

  def envelope(response, corr, duration_ms),
    do: envelope(inspect(response), corr, duration_ms)

  @doc """
  Build an engine-generated failure envelope (route denied, target missing,
  process-mode object, …). `type` defaults to `"permanent"`: every engine
  failure here is a configuration/topology fact a retry cannot change.
  """
  @spec error_envelope(String.t(), String.t(), String.t(), String.t()) :: map()
  def error_envelope(corr, code, message, type \\ "permanent") do
    %{
      ok: false,
      result: nil,
      error: %{code: code, message: message, type: type},
      timeout: false,
      correlation_id: corr,
      duration_ms: 0
    }
  end

  @doc """
  Write an envelope to the agent's reply file, atomically (tmp + rename), so the
  polling `swarm-msg ask` can never read a half-written file. Returns `:ok` or
  `{:error, reason}`; the caller treats failures as "reply dropped" (the asker's
  timeout envelope is the catch-all).
  """
  @spec write_reply(String.t() | nil, String.t(), map()) :: :ok | {:error, term()}
  def write_reply(workspace, corr, envelope) do
    cond do
      workspace in [nil, ""] ->
        {:error, :no_workspace}

      not valid_correlation_id?(corr) ->
        {:error, :invalid_correlation_id}

      true ->
        dir = Path.join(Path.expand(workspace), @replies_subdir)
        final = Path.join(dir, corr <> ".json")
        tmp = Path.join(dir, ".tmp_" <> corr)

        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(tmp, Jason.encode!(envelope)),
             :ok <- File.rename(tmp, final) do
          :ok
        else
          {:error, reason} = error ->
            Logger.warning("ask: failed to write reply #{corr}: #{inspect(reason)}")
            error
        end
    end
  end

  # An object's "error" value may be a bare string ("not_allowed") or a map
  # ({"code": "...", "message": "...", "type": "permanent"}). Normalize both to
  # {code, message, type}; the object's own fields win.
  defp normalize_error(err) when is_map(err) do
    %{
      code: to_string(Map.get(err, "code", "error")),
      message: to_string(Map.get(err, "message", Map.get(err, "code", "error"))),
      type: to_string(Map.get(err, "type", "unknown"))
    }
  end

  defp normalize_error(err) when is_binary(err),
    do: %{code: err, message: err, type: "unknown"}

  defp normalize_error(err),
    do: %{code: "error", message: inspect(err), type: "unknown"}
end
