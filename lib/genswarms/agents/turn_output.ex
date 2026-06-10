defmodule Genswarms.Agents.TurnOutput do
  @moduledoc """
  Derive an agent turn's user-facing reply text from its accumulated output.

  The wrapper (`priv/szc-wrapper-fifo.sh`) emits one JSON object per line of the
  harness's stdout — `{"type":"output","content":"..."}` — and tags harness
  stderr (per-call banners, diagnostics) as `{"type":"log",...}`. The
  AgentServer accumulates these into a single per-turn buffer (lines are
  concatenated as they arrive), so the buffer is a sequence of back-to-back
  JSON objects, possibly with raw text in between (mock/test backends write
  plain text).

  `reply_text/1` reconstructs the harness's stdout for the turn — the
  `"output"`-typed contents in order, plus any raw non-JSON segments — and
  strips the protocol mechanics: `<<TURN_COMPLETE>>` markers and bare `> `
  prompts. Because the harness prints the model's text only when the model
  finishes (and its progress banners go to stderr), what remains IS the turn's
  final answer.

  This is deliberately a pure function so it can be pinned by tests: it is the
  single place that knows the stdout grammar.
  """

  @doc """
  The turn's reply text: harness stdout minus protocol mechanics. `""` when the
  turn produced no user-facing text.
  """
  @spec reply_text(String.t()) :: String.t()
  def reply_text(buffer) when is_binary(buffer) do
    buffer
    |> segments()
    |> Enum.flat_map(&segment_text/1)
    |> Enum.join("\n")
    |> clean()
  end

  @doc """
  Split a buffer into `{:json, map}` and `{:raw, text}` segments. Top-level
  JSON objects are found with a depth/string-aware scan (the buffer is
  CONCATENATED objects — `}{"` boundaries — not a JSON array, and object
  contents may contain braces inside strings). An undecodable `{...}` span is
  kept as raw text rather than dropped. Public for tests.
  """
  @spec segments(String.t()) :: [{:json, map()} | {:raw, String.t()}]
  def segments(buffer) do
    scan(buffer, [], "")
  end

  # ── scanner ────────────────────────────────────────────────────────────────

  defp scan("", acc, raw), do: Enum.reverse(flush_raw(acc, raw))

  defp scan(<<"{", _::binary>> = rest, acc, raw) do
    case take_object(rest, 0, false, false, "") do
      {:ok, object, remainder} ->
        seg =
          case Jason.decode(object) do
            {:ok, map} when is_map(map) -> {:json, map}
            _ -> {:raw, object}
          end

        scan(remainder, [seg | flush_raw(acc, raw)], "")

      :incomplete ->
        # Unbalanced braces to end-of-buffer (e.g. a truncated final chunk) —
        # keep the tail as raw text so nothing is silently dropped.
        Enum.reverse(flush_raw(flush_raw(acc, raw), rest))
    end
  end

  defp scan(<<ch::utf8, rest::binary>>, acc, raw),
    do: scan(rest, acc, raw <> <<ch::utf8>>)

  defp flush_raw(acc, ""), do: acc
  defp flush_raw(acc, raw), do: [{:raw, raw} | acc]

  # take_object(buffer, depth, in_string?, escaped?, taken)
  defp take_object("", _depth, _in_s, _esc, _taken), do: :incomplete

  defp take_object(<<ch::utf8, rest::binary>>, depth, in_s, esc, taken) do
    taken = taken <> <<ch::utf8>>

    cond do
      esc -> take_object(rest, depth, in_s, false, taken)
      in_s and ch == ?\\ -> take_object(rest, depth, true, true, taken)
      in_s and ch == ?" -> take_object(rest, depth, false, false, taken)
      in_s -> take_object(rest, depth, true, false, taken)
      ch == ?" -> take_object(rest, depth, true, false, taken)
      ch == ?{ -> take_object(rest, depth + 1, false, false, taken)
      ch == ?} and depth == 1 -> {:ok, taken, rest}
      ch == ?} -> take_object(rest, depth - 1, false, false, taken)
      true -> take_object(rest, depth, false, false, taken)
    end
  end

  # ── segment → user-facing lines ────────────────────────────────────────────

  # Harness stdout lines. Everything else from the wrapper is mechanics:
  # "log" (stderr diagnostics), "send"/"broadcast" (routed separately),
  # "status"/"exit"/"error" (lifecycle).
  defp segment_text({:json, %{"type" => "output", "content" => content}})
       when is_binary(content),
       do: [content]

  defp segment_text({:json, _}), do: []
  defp segment_text({:raw, text}), do: [text]

  # ── protocol cleanup ───────────────────────────────────────────────────────

  defp clean(text) do
    text
    |> String.replace("<<TURN_COMPLETE>>", "")
    |> String.trim()
    |> strip_prompt()
    |> String.trim()
  end

  # The harness prints its input prompt as "> " with no trailing newline, so it
  # is consumed at the START of the NEXT turn's first output line ("> From
  # https://..."). Exactly one pending prompt can be glued there — strip exactly
  # one, from the head of the turn text only, so a reply that legitimately
  # begins with a markdown "> quote" survives ("> > quote" → "> quote").
  defp strip_prompt("> " <> rest), do: rest
  defp strip_prompt(">"), do: ""
  defp strip_prompt(text), do: text
end
