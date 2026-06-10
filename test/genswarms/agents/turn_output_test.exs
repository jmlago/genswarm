defmodule Genswarms.Agents.TurnOutputTest do
  use ExUnit.Case, async: true

  alias Genswarms.Agents.TurnOutput

  # Build the buffer exactly the way AgentServer accumulates it: the wrapper's
  # JSON lines arrive as {:eol, line} Port messages and are CONCATENATED with no
  # separator (buffer <> data).
  defp wrapped(lines) do
    lines
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("")
  end

  describe "segments/1" do
    test "splits concatenated JSON objects" do
      buffer =
        wrapped([
          %{type: "output", content: "a"},
          %{type: "log", content: "[1] model..."},
          %{type: "output", content: "b"}
        ])

      assert [
               {:json, %{"type" => "output", "content" => "a"}},
               {:json, %{"type" => "log", "content" => "[1] model..."}},
               {:json, %{"type" => "output", "content" => "b"}}
             ] = TurnOutput.segments(buffer)
    end

    test "braces and }{ inside JSON strings do not split objects" do
      buffer = wrapped([%{type: "output", content: ~s(a }{"fake":1} b)}])
      assert [{:json, %{"content" => content}}] = TurnOutput.segments(buffer)
      assert content == ~s(a }{"fake":1} b)
    end

    test "raw text between objects is kept, not dropped" do
      buffer =
        Jason.encode!(%{type: "output", content: "x"}) <>
          "RAW" <> Jason.encode!(%{type: "output", content: "y"})

      assert [
               {:json, %{"content" => "x"}},
               {:raw, "RAW"},
               {:json, %{"content" => "y"}}
             ] = TurnOutput.segments(buffer)
    end

    test "a truncated trailing object is kept as raw text" do
      buffer = Jason.encode!(%{type: "output", content: "x"}) <> ~s({"type":"outp)
      assert [{:json, _}, {:raw, ~s({"type":"outp)}] = TurnOutput.segments(buffer)
    end

    test "plain non-JSON buffer (mock backends) is one raw segment" do
      assert [{:raw, "hello world"}] = TurnOutput.segments("hello world")
    end
  end

  describe "reply_text/1" do
    test "a realistic turn: glued prompt, final text, marker — yields the answer" do
      # subzeroclaw emits "\n> " after the previous turn; the pending "> " is
      # completed by this turn's first stdout line.
      buffer =
        wrapped([
          %{type: "output", content: "> From https://docs.example.com/:"},
          %{type: "output", content: "The page is a navigation index."},
          %{type: "output", content: ""},
          %{type: "output", content: "<<TURN_COMPLETE>>"}
        ])

      assert TurnOutput.reply_text(buffer) ==
               "From https://docs.example.com/:\nThe page is a navigation index."
    end

    test "stderr-tagged log lines (banners, diagnostics) are excluded" do
      buffer =
        wrapped([
          %{type: "log", content: "[1] profile:edge..."},
          %{type: "output", content: "> The answer."},
          %{type: "log", content: "[2] profile:edge..."},
          %{type: "output", content: "<<TURN_COMPLETE>>"}
        ])

      assert TurnOutput.reply_text(buffer) == "The answer."
    end

    test "send/broadcast/status/exit wrapper lines are mechanics, not reply text" do
      buffer =
        wrapped([
          %{type: "send", to: "sender", content: "{\"action\":\"reply\"}"},
          %{type: "output", content: "> Done."},
          %{type: "status", state: "idle"},
          %{type: "exit", status: 0}
        ])

      assert TurnOutput.reply_text(buffer) == "Done."
    end

    test "a markdown blockquote in the reply survives prompt-stripping" do
      buffer =
        wrapped([
          %{type: "output", content: "> > the docs say hello"},
          %{type: "output", content: "<<TURN_COMPLETE>>"}
        ])

      assert TurnOutput.reply_text(buffer) == "> the docs say hello"
    end

    test "a turn with only mechanics yields the empty string" do
      buffer =
        wrapped([
          %{type: "log", content: "error: max turns (16) reached"},
          %{type: "output", content: "> "},
          %{type: "output", content: "<<TURN_COMPLETE>>"}
        ])

      assert TurnOutput.reply_text(buffer) == ""
    end

    test "plain-text buffers (mock backend) pass through with markers stripped" do
      assert TurnOutput.reply_text("hello<<TURN_COMPLETE>>") == "hello"
    end
  end
end
