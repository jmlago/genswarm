defmodule Genswarms.Agents.SubzeroclawLogParserTest do
  use ExUnit.Case, async: true

  alias Genswarms.Agents.AgentServer

  @sid "abc123.txt"

  test "parses roled entries and skips the header" do
    log = """
    === abc123 Thu Jun 11 11:26:54 2026
    [2026-06-11 11:26:54] USER: hello
    [2026-06-11 11:26:58] ASST: hi there
    """

    assert [
             %{role: "user", content: "hello", session_id: @sid},
             %{role: "asst", content: "hi there"}
           ] = AgentServer.parse_subzeroclaw_log(log, @sid)
  end

  test "a multi-line entry survives past blank lines until the next roled line" do
    # The SYSTEM entry (subzeroclaw logs the system prompt at session start) is
    # full of blank lines — base prompt, then one "--- SKILL: x ---" block per
    # skill. Truncating at the first blank line silently dropped every skill.
    log = """
    === abc123 Thu Jun 11 11:26:54 2026
    [2026-06-11 11:26:54] SYSTEM: You are SubZeroClaw, a minimal agentic assistant.
    Be concise. Just do it.

    --- SKILL: test-skill.md ---
    # Test Skill
    Always be testing.

    Second paragraph after blank line.

    [2026-06-11 11:26:54] USER: hello
    """

    assert [%{role: "system", content: system}, %{role: "user", content: "hello"}] =
             AgentServer.parse_subzeroclaw_log(log, @sid)

    assert system =~ "--- SKILL: test-skill.md ---"
    assert system =~ "Second paragraph after blank line."
    # blank lines inside the entry are preserved, trailing ones trimmed
    assert system =~ "Just do it.\n\n--- SKILL"
    refute system =~ ~r/\n\s*\z/
  end
end
