defmodule SwarmMsgAskTest do
  @moduledoc """
  `swarm-msg ask` must publish an outbox file carrying a safe reply_to
  correlation id, block until the engine writes the reply envelope, print it
  verbatim, and on timeout print a well-formed ok:false/timeout:true envelope —
  its stdout is ALWAYS exactly one JSON envelope.
  """
  use ExUnit.Case, async: false

  @script Path.join(File.cwd!(), "swarm-msg")

  setup do
    base = Path.join(System.tmp_dir!(), "ask_sh_#{System.unique_integer([:positive])}")
    outbox = Path.join(base, ".outbox")
    replies = Path.join(base, ".inbox/replies")
    File.mkdir_p!(outbox)
    File.mkdir_p!(replies)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, outbox: outbox, replies: replies}
  end

  defp ask(outbox, replies, to, msg, timeout_s) do
    System.cmd("sh", [@script, "ask", to, msg],
      env: [
        {"OUTBOX_DIR", outbox},
        {"ASK_REPLY_DIR", replies},
        {"SWARM_ASK_TIMEOUT", to_string(timeout_s)}
      ],
      stderr_to_stdout: true
    )
  end

  test "publishes an outbox file with a safe reply_to correlation id",
       %{outbox: outbox, replies: replies} do
    {_out, 0} = ask(outbox, replies, "browse", ~s({"action":"render"}), 0)

    [file] = Path.wildcard(Path.join(outbox, "*.json"))
    decoded = file |> File.read!() |> Jason.decode!()

    assert decoded["to"] == "browse"
    assert decoded["content"] == ~s({"action":"render"})
    assert Genswarms.Agents.Ask.valid_correlation_id?(decoded["reply_to"])
  end

  test "prints the engine-written envelope and consumes the reply file",
       %{outbox: outbox, replies: replies} do
    # Simulate the engine in one task: watch the outbox for the ask, then
    # write the reply envelope for its correlation id (atomic tmp + rename).
    engine =
      Task.async(fn ->
        deadline = System.monotonic_time(:millisecond) + 3_000

        with {:ok, corr} <- wait_for_ask(outbox, deadline) do
          tmp = Path.join(replies, ".tmp_" <> corr)
          File.write!(tmp, Jason.encode!(%{ok: true, result: %{"x" => 1}, correlation_id: corr}))
          File.rename!(tmp, Path.join(replies, corr <> ".json"))
          :ok
        end
      end)

    {out, 0} = ask(outbox, replies, "browse", ~s({"action":"render"}), 5)
    assert :ok = Task.await(engine, 5_000)

    env = Jason.decode!(out)
    assert env["ok"] == true
    assert env["result"] == %{"x" => 1}
    # the reply file is consumed after reading
    assert Path.wildcard(Path.join(replies, "*.json")) == []
  end

  test "prints a typed timeout envelope when no reply arrives",
       %{outbox: outbox, replies: replies} do
    {out, 0} = ask(outbox, replies, "browse", "x", 1)

    env = Jason.decode!(out)
    assert env["ok"] == false
    assert env["timeout"] == true
    assert env["error"]["code"] == "timeout"
    assert env["error"]["type"] == "transient"
    assert is_binary(env["correlation_id"])
  end

  defp wait_for_ask(outbox, deadline) do
    case Path.wildcard(Path.join(outbox, "*.json")) do
      [file | _] ->
        {:ok, file |> File.read!() |> Jason.decode!() |> Map.fetch!("reply_to")}

      [] ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :no_ask_published}
        else
          Process.sleep(20)
          wait_for_ask(outbox, deadline)
        end
    end
  end
end
