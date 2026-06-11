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
  # traverse out of its own replies dir (e.g. "../../..."). \A/\z, not ^/$:
  # $ matches before a trailing newline, which would smuggle "abc\n" through.
  @corr_re ~r/\A[A-Za-z0-9._-]{1,128}\z/

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
      {:ok, decoded} ->
        wrap_decoded(decoded, corr, duration_ms)

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

  # A native handler may reply with a map directly (instead of an encoded
  # binary) — same semantics as its decoded-JSON equivalent.
  def envelope(response, corr, duration_ms) when is_map(response),
    do: wrap_decoded(response, corr, duration_ms)

  def envelope(response, corr, duration_ms),
    do: envelope(inspect(response), corr, duration_ms)

  defp wrap_decoded(decoded, corr, duration_ms) do
    case error_value(decoded) do
      nil ->
        %{
          ok: true,
          result: decoded,
          error: nil,
          timeout: false,
          correlation_id: corr,
          duration_ms: duration_ms
        }

      err ->
        %{
          ok: false,
          result: decoded,
          error: normalize_error(err),
          timeout: false,
          correlation_id: corr,
          duration_ms: duration_ms
        }
    end
  end

  # A truthy top-level "error" marks a failed reply. `"error": null`/`false`
  # (the common JSON-RPC success shape — and this module's own envelopes) is
  # success, not an error.
  defp error_value(%{} = map) do
    case Map.get(map, "error", Map.get(map, :error)) do
      nil -> nil
      false -> nil
      err -> err
    end
  end

  defp error_value(_), do: nil

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
          prune_stale(dir)
          :ok
        else
          {:error, reason} = error ->
            Logger.warning("ask: failed to write reply #{corr}: #{inspect(reason)}")
            error
        end
    end
  end

  # Replies that landed after their asker's timeout are never read — sweep
  # anything older than an hour so the directory doesn't creep on chatty
  # agents with flaky objects. Best-effort by design.
  @stale_after_seconds 3_600
  defp prune_stale(dir) do
    cutoff = System.os_time(:second) - @stale_after_seconds

    case File.ls(dir) do
      {:ok, files} ->
        for f <- files,
            path = Path.join(dir, f),
            match?({:ok, %{mtime: mtime}} when mtime < cutoff, stat_seconds(path)) do
          File.rm(path)
        end

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp stat_seconds(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, %{mtime: stat.mtime}}
      other -> other
    end
  end

  # An object's "error" value may be a bare string ("not_allowed") or a map
  # ({"code": "...", "message": "...", "type": "permanent"} — string or atom
  # keys). Normalize both to {code, message, type}; the object's fields win.
  defp normalize_error(err) when is_map(err) do
    code = err_field(err, :code, "error")

    %{
      code: stringify(code),
      message: stringify(err_field(err, :message, code)),
      type: stringify(err_field(err, :type, "unknown"))
    }
  end

  defp normalize_error(err) when is_binary(err),
    do: %{code: err, message: err, type: "unknown"}

  defp normalize_error(err),
    do: %{code: "error", message: inspect(err), type: "unknown"}

  defp err_field(map, key, default),
    do: Map.get(map, to_string(key), Map.get(map, key, default))

  # Error fields come from the OBJECT's reply — nothing guarantees they are
  # strings ({"error":{"code":{"upstream":502}}} is real upstream output).
  # to_string/1 raises Protocol.UndefinedError on maps/lists, and this runs
  # OUTSIDE the object server's handler rescue, so it crashed the ObjectServer
  # and stranded the asker (review round 3 finding 5). Binaries pass through;
  # atoms keep their historical to_string form (:permanent → "permanent",
  # nil → ""); everything else is inspected.
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_atom(v), do: to_string(v)
  defp stringify(v), do: inspect(v)
end
