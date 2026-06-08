defmodule Genswarms.Backends.Bwrap.CgroupManagerTest do
  use ExUnit.Case, async: true

  alias Genswarms.Backends.Bwrap.CgroupManager

  @moduletag :bwrap

  describe "create_scope/3 (argv shape & injection safety)" do
    # create_scope wraps the bwrap argv list with systemd-run and returns
    # {executable, args, scope_name} for spawn_executable. No shell is involved,
    # so any untrusted element of the command list must survive as a single,
    # byte-for-byte argv entry.

    test "returns {executable, args, scope_name}" do
      {exe, args, scope} = CgroupManager.create_scope("agent-1", ["bwrap", "--version"])

      assert is_binary(exe)
      assert String.ends_with?(exe, "systemd-run")
      assert is_list(args)
      assert Enum.all?(args, &is_binary/1)
      assert is_binary(scope)
    end

    test "executable is no longer the first element of args" do
      {exe, args, _scope} = CgroupManager.create_scope("agent-1", ["bwrap"])
      # Old behaviour put systemd-run inside the arg string; now it is separate.
      refute exe in args
      assert List.first(args) == "--user"
    end

    test "the command argv is preserved intact as the trailing elements" do
      command = ["bwrap", "--bind", "/a; rm -rf /", "/x", "--", "wrapper", "id"]
      {_exe, args, _scope} = CgroupManager.create_scope("agent-1", command)

      # Exact suffix match proves nothing was split, merged, or reordered.
      assert Enum.take(args, -length(command)) == command
    end

    test "a '--' separator precedes the command argv" do
      command = ["bwrap", "arg"]
      {_exe, args, _scope} = CgroupManager.create_scope("agent-1", command)

      sep_idx = Enum.find_index(args, &(&1 == "--"))
      assert sep_idx != nil
      assert Enum.drop(args, sep_idx + 1) == command
    end

    test "a malicious command element stays a single literal argv entry" do
      payload = "x; touch /tmp/pwned && echo $(whoami)"
      {_exe, args, _scope} = CgroupManager.create_scope("agent-1", ["bwrap", payload])

      assert payload in args
      assert Enum.count(args, &(&1 == payload)) == 1

      offenders = Enum.filter(args, &(String.contains?(&1, "touch /tmp/pwned") and &1 != payload))
      assert offenders == []
    end

    test "scope name is sanitized from the sandbox id" do
      {_exe, _args, scope} = CgroupManager.create_scope("swarm/agent name!", ["bwrap"])

      assert String.starts_with?(scope, "szc-")
      # Only safe characters remain in the unit name.
      assert scope =~ ~r/^szc-[a-zA-Z0-9\-_]+$/
    end

    test "a malicious sandbox id cannot inject into the unit flag" do
      {_exe, args, scope} = CgroupManager.create_scope("a; rm -rf / #", ["bwrap"])

      unit_flag = Enum.find(args, &String.starts_with?(&1, "--unit="))
      assert unit_flag == "--unit=#{scope}"
      refute unit_flag =~ "rm -rf"
    end

    test "resource limits become discrete --property args" do
      {_exe, args, _scope} =
        CgroupManager.create_scope("agent-1", ["bwrap"], %{
          memory_max: "256M",
          cpu_shares: 100,
          tasks_max: 50
        })

      assert "--property=MemoryMax=256M" in args
      assert "--property=CPUWeight=100" in args
      assert "--property=TasksMax=50" in args
    end

    test "omitted resource limits produce no --property args" do
      {_exe, args, _scope} = CgroupManager.create_scope("agent-1", ["bwrap"], %{})
      refute Enum.any?(args, &String.starts_with?(&1, "--property="))
    end

    test "includes the systemd-run flags needed for I/O forwarding" do
      {_exe, args, _scope} = CgroupManager.create_scope("agent-1", ["bwrap"])

      assert "--user" in args
      assert "--pipe" in args
      assert "--quiet" in args
      assert "--slice=subzeroclaw" in args
    end
  end
end
