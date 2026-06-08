defmodule Genswarms.Backends.SSHBackendTest do
  # not async: build_remote_command/5 falls back to SUBZEROCLAW_* env vars, so
  # these tests must control the process environment (which is global).
  use ExUnit.Case, async: false

  alias Genswarms.Backends.SSHBackend

  # Clear the SUBZEROCLAW_* env fallbacks so "only when configured" assertions are
  # deterministic regardless of the host environment (e.g. a loaded .env).
  setup do
    vars = ~w(SUBZEROCLAW_API_KEY SUBZEROCLAW_MODEL SUBZEROCLAW_ENDPOINT)
    saved = Map.new(vars, fn v -> {v, System.get_env(v)} end)
    Enum.each(vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {v, nil} -> System.delete_env(v)
        {v, val} -> System.put_env(v, val)
      end)
    end)

    :ok
  end

  describe "backend_type/0" do
    test "returns :ssh" do
      assert SSHBackend.backend_type() == :ssh
    end
  end

  describe "build_connect_opts/3 (host-key verification)" do
    test "verifies host keys by default (silently_accept_hosts: false)" do
      opts = SSHBackend.build_connect_opts("agent", nil, %{})
      assert {:silently_accept_hosts, false} in opts
    end

    test "operators can explicitly opt out with silently_accept_hosts: true" do
      opts = SSHBackend.build_connect_opts("agent", nil, %{silently_accept_hosts: true})
      assert {:silently_accept_hosts, true} in opts
    end

    test "a custom verification fun is passed through verbatim" do
      verify = fn _peer, _fingerprint -> true end
      opts = SSHBackend.build_connect_opts("agent", nil, %{silently_accept_hosts: verify})
      assert {:silently_accept_hosts, ^verify} = List.keyfind(opts, :silently_accept_hosts, 0)
    end

    test "never enables interactive prompts" do
      opts = SSHBackend.build_connect_opts("agent", nil, %{})
      assert {:user_interaction, false} in opts
    end

    test "sets the user as a charlist" do
      opts = SSHBackend.build_connect_opts("alice", nil, %{})
      assert {:user, ~c"alice"} in opts
    end

    test "defaults user_dir to ~/.ssh when no key_path is given" do
      opts = SSHBackend.build_connect_opts("agent", nil, %{})
      expected = Path.expand("~/.ssh") |> String.to_charlist()
      assert {:user_dir, expected} in opts
    end

    test "includes a password option only when configured" do
      without = SSHBackend.build_connect_opts("agent", nil, %{})
      refute List.keymember?(without, :password, 0)

      with_pass = SSHBackend.build_connect_opts("agent", nil, %{password: "hunter2"})
      assert {:password, ~c"hunter2"} in with_pass
    end
  end

  describe "build_remote_command/5 (command-injection safety)" do
    @skills "/var/lib/subzeroclaw/skills"

    test "non-nixos command has no sudo and runs via env" do
      cmd =
        SSHBackend.build_remote_command("agent", "subzeroclaw", @skills, "ignored", %{
          nixos: false
        })

      refute cmd =~ "sudo"
      assert String.starts_with?(cmd, "env ")
      assert cmd =~ "SUBZEROCLAW_AGENT_NAME='agent'"
      assert String.ends_with?(cmd, "'subzeroclaw'")
    end

    test "nixos command runs subzeroclaw via sudo -u <remote_user>" do
      cmd =
        SSHBackend.build_remote_command("agent", "subzeroclaw", @skills, "subzeroclaw", %{
          nixos: true
        })

      assert cmd =~ "sudo -u 'subzeroclaw' env "
      assert String.ends_with?(cmd, "'subzeroclaw'")
    end

    test "optional env vars are included only when set" do
      base = SSHBackend.build_remote_command("a", "szc", @skills, "u", %{nixos: false})
      refute base =~ "SUBZEROCLAW_API_KEY"
      refute base =~ "SUBZEROCLAW_MODEL"
      refute base =~ "SUBZEROCLAW_ENDPOINT"

      full =
        SSHBackend.build_remote_command("a", "szc", @skills, "u", %{
          nixos: false,
          api_key: "sk-123",
          model: "claude",
          endpoint: "https://api"
        })

      assert full =~ "SUBZEROCLAW_API_KEY='sk-123'"
      assert full =~ "SUBZEROCLAW_MODEL='claude'"
      assert full =~ "SUBZEROCLAW_ENDPOINT='https://api'"
    end

    test "metacharacters in every untrusted value are single-quoted" do
      payload = "x; rm -rf / & echo $(whoami) `id`"

      cmd =
        SSHBackend.build_remote_command(payload, payload, payload, payload, %{
          nixos: true,
          api_key: payload,
          model: payload,
          endpoint: payload
        })

      # Each value appears only inside a single-quoted span. Within single
      # quotes the shell treats ; & $() `` as literal text.
      assert cmd =~ "SUBZEROCLAW_AGENT_NAME='#{payload}'"
      assert cmd =~ "SUBZEROCLAW_API_KEY='#{payload}'"
      assert cmd =~ "SUBZEROCLAW_MODEL='#{payload}'"
      assert cmd =~ "SUBZEROCLAW_ENDPOINT='#{payload}'"
      assert cmd =~ "sudo -u '#{payload}'"
    end

    test "embedded single quotes are escaped, not terminated" do
      # A naive 'wrap in quotes' would let this break out: the lone quote would
      # close the span. Proper escaping turns ' into '\''.
      cmd =
        SSHBackend.build_remote_command("a'; touch /tmp/x #", "szc", @skills, "u", %{nixos: false})

      assert cmd =~ "SUBZEROCLAW_AGENT_NAME='a'\\''; touch /tmp/x #'"
    end

    @tag :tmp_dir
    test "injection payload does NOT execute when run through a real shell", %{tmp_dir: tmp_dir} do
      marker = Path.join(tmp_dir, "pwned")
      refute File.exists?(marker)

      # An attacker-controlled agent name that tries to break out and touch a
      # marker file via several techniques at once.
      malicious_name = "agent'; touch #{marker}; echo $(touch #{marker}) `touch #{marker}`'"

      # Use `true` as the "binary" so the command exits cleanly after env runs.
      cmd =
        SSHBackend.build_remote_command(malicious_name, "true", tmp_dir, "u", %{nixos: false})

      {_out, exit_status} = System.cmd("/bin/sh", ["-c", cmd], stderr_to_stdout: true)

      # The only command executed should be `true` (exit 0); none of the
      # injected `touch` invocations may have run.
      assert exit_status == 0
      refute File.exists?(marker), "command injection executed: marker file was created"
    end

    @tag :tmp_dir
    test "the literal payload is delivered as the env value, intact", %{tmp_dir: tmp_dir} do
      payload = "v1; rm -rf / & $(reboot) `halt`"

      # Use `printenv` as the launched "binary": env exports the vars to it, and
      # it prints them. This proves the value reached the program byte-for-byte
      # without the shell expanding any metacharacter.
      cmd =
        SSHBackend.build_remote_command("agent", "printenv", tmp_dir, "u", %{
          nixos: false,
          model: payload
        })

      {out, 0} = System.cmd("/bin/sh", ["-c", cmd], stderr_to_stdout: true)

      assert out =~ "SUBZEROCLAW_MODEL=" <> payload
    end
  end
end
