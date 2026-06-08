defmodule Genswarms.Backends.LocalBackendTest do
  # not async: spawns a real OS process and touches the filesystem
  use ExUnit.Case, async: false

  alias Genswarms.Backends.LocalBackend

  describe "build_args/3" do
    test "returns argv as separate literal elements (no shell string)" do
      assert LocalBackend.build_args("researcher", "subzeroclaw", "/skills") ==
               ["researcher", "subzeroclaw", "/skills"]
    end

    test "keeps a name with shell metacharacters intact as a single arg" do
      evil = "a; touch /tmp/pwned"
      assert [^evil, "subzeroclaw", ""] = LocalBackend.build_args(evil, "subzeroclaw", nil)
    end
  end

  describe "start/2 spawns via argv (command-injection regression test)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gs_local_be_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      argv_out = Path.join(tmp, "argv.txt")
      # A stub "wrapper" that records the argv it actually received, then exits.
      stub = Path.join(tmp, "stub-wrapper.sh")
      File.write!(stub, """
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "#{argv_out}"
      exit 0
      """)
      File.chmod!(stub, 0o755)
      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, tmp: tmp, stub: stub, argv_out: argv_out}
    end

    test "a malicious agent name is passed literally and NOT shell-executed", ctx do
      marker = Path.join(ctx.tmp, "INJECTED")
      # If the name were interpolated into a /bin/sh -c string, this would run `touch marker`.
      evil_name = "evil; touch #{marker} #"

      {:ok, ref} =
        LocalBackend.start(evil_name, %{
          wrapper_path: ctx.stub,
          subzeroclaw_path: "subzeroclaw",
          skills_dir: nil
        })

      # wait for the stub to record argv (it exits immediately after writing)
      wait_until(fn -> File.exists?(ctx.argv_out) end)
      LocalBackend.stop(ref)

      argv = ctx.argv_out |> File.read!() |> String.split("\n", trim: true)

      # the entire malicious string arrived as ONE argv element, verbatim
      assert hd(argv) == evil_name
      # and the injection side-effect never happened
      refute File.exists?(marker), "command injection: marker file was created"
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
