defmodule SwarmMsgOutboxTest do
  @moduledoc """
  The swarm-msg outbox writer must not collide/overwrite on concurrent sends
  (racy count-based seq) and must publish files atomically (audit finding 36).
  """
  use ExUnit.Case, async: false

  @script Path.join(File.cwd!(), "swarm-msg")

  setup do
    dir = Path.join(System.tmp_dir!(), "outbox_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp send(dir, to, msg) do
    System.cmd("sh", [@script, "send", to, msg],
      env: [{"OUTBOX_DIR", dir}],
      stderr_to_stdout: true
    )
  end

  test "two sends produce two distinct files (no seq collision/overwrite)", %{dir: dir} do
    {_, 0} = send(dir, "coder", "first")
    {_, 0} = send(dir, "coder", "second")

    files = Path.wildcard(Path.join(dir, "*.json"))
    assert length(files) == 2, "expected 2 outbox files, got #{length(files)}"
  end

  test "each file is complete, valid JSON addressed to the target", %{dir: dir} do
    {_, 0} = send(dir, "reviewer", "hello world")

    [file] = Path.wildcard(Path.join(dir, "*.json"))
    decoded = file |> File.read!() |> Jason.decode!()
    assert decoded["to"] == "reviewer"
    assert decoded["content"] == "hello world"
  end

  test "no temp files are left behind (atomic rename)", %{dir: dir} do
    {_, 0} = send(dir, "x", "y")
    assert Path.wildcard(Path.join(dir, ".tmp_*")) == []
  end
end
