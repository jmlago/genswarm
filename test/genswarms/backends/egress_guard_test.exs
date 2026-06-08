defmodule Genswarms.Backends.EgressGuardTest do
  use ExUnit.Case, async: false

  alias Genswarms.Backends.EgressGuard

  describe "isolated?/1" do
    test "true only for network: :isolated" do
      assert EgressGuard.isolated?(%{network: :isolated})
      refute EgressGuard.isolated?(%{network: :open})
      refute EgressGuard.isolated?(%{})
      refute EgressGuard.isolated?(%{network: "isolated"})
    end
  end

  describe "bwrap_net_args/1" do
    test "drops the net namespace only under isolation" do
      assert EgressGuard.bwrap_net_args(%{network: :isolated}) == ["--unshare-net"]
      assert EgressGuard.bwrap_net_args(%{network: :open}) == []
      # default (no key) must keep current behavior — network stays available
      assert EgressGuard.bwrap_net_args(%{}) == []
    end
  end

  describe "resolve_endpoint/1" do
    setup do
      saved = System.get_env("SUBZEROCLAW_ENDPOINT")
      System.delete_env("SUBZEROCLAW_ENDPOINT")

      on_exit(fn ->
        if saved,
          do: System.put_env("SUBZEROCLAW_ENDPOINT", saved),
          else: System.delete_env("SUBZEROCLAW_ENDPOINT")
      end)
    end

    test "explicit config endpoint wins" do
      assert EgressGuard.resolve_endpoint(%{endpoint: "https://example.test/v1"}) ==
               "https://example.test/v1"
    end

    test "falls back to env, then to the default" do
      System.put_env("SUBZEROCLAW_ENDPOINT", "https://env.test/v1")
      assert EgressGuard.resolve_endpoint(%{}) == "https://env.test/v1"

      System.delete_env("SUBZEROCLAW_ENDPOINT")
      assert EgressGuard.resolve_endpoint(%{}) =~ "openrouter.ai"
    end
  end

  describe "resolve_allowed_endpoint/1 (endpoint allowlist)" do
    setup do
      saved_ep = System.get_env("SUBZEROCLAW_ENDPOINT")
      saved_allow = System.get_env("GENSWARMS_ALLOWED_ENDPOINTS")
      System.put_env("SUBZEROCLAW_ENDPOINT", "https://llm.server.test/v1")
      System.delete_env("GENSWARMS_ALLOWED_ENDPOINTS")

      on_exit(fn ->
        restore("SUBZEROCLAW_ENDPOINT", saved_ep)
        restore("GENSWARMS_ALLOWED_ENDPOINTS", saved_allow)
      end)
    end

    test "no per-agent endpoint -> operator endpoint, always allowed" do
      assert EgressGuard.resolve_allowed_endpoint(%{}) ==
               {:ok, "https://llm.server.test/v1"}
    end

    test "per-agent endpoint on the server's own host is allowed" do
      assert EgressGuard.resolve_allowed_endpoint(%{endpoint: "https://llm.server.test/other"}) ==
               {:ok, "https://llm.server.test/other"}
    end

    test "per-agent endpoint on an untrusted host is rejected (fail closed)" do
      assert EgressGuard.resolve_allowed_endpoint(%{endpoint: "https://attacker.test/v1"}) ==
               {:error, {:endpoint_not_allowed, "https://attacker.test/v1"}}
    end

    test "GENSWARMS_ALLOWED_ENDPOINTS extends the allowlist" do
      System.put_env("GENSWARMS_ALLOWED_ENDPOINTS", "api.anthropic.com, openrouter.ai")

      assert EgressGuard.resolve_allowed_endpoint(%{endpoint: "https://api.anthropic.com/v1"}) ==
               {:ok, "https://api.anthropic.com/v1"}

      assert {:error, {:endpoint_not_allowed, _}} =
               EgressGuard.resolve_allowed_endpoint(%{endpoint: "https://evil.test/v1"})
    end

    test "allowed_endpoint_hosts includes the server host and configured hosts" do
      System.put_env("GENSWARMS_ALLOWED_ENDPOINTS", "Foo.Example.COM ,bar.test")
      hosts = EgressGuard.allowed_endpoint_hosts()
      assert "llm.server.test" in hosts
      # normalized to lowercase + trimmed
      assert "foo.example.com" in hosts
      assert "bar.test" in hosts
    end

    test "start_forwarder refuses a disallowed endpoint without writing .curlrc" do
      ws = Path.join(System.tmp_dir!(), "szc_egress_allowlist_test")
      File.rm_rf!(ws)
      File.mkdir_p!(ws)
      on_exit(fn -> File.rm_rf!(ws) end)

      assert {:error, {:endpoint_not_allowed, _}} =
               EgressGuard.start_forwarder(ws, %{endpoint: "https://attacker.test/v1"})

      refute File.exists?(Path.join(ws, ".curlrc"))
      refute File.exists?(Path.join(ws, ".llm.sock"))
    end
  end

  describe "endpoint_target/1" do
    test "uses the scheme default port when none is given" do
      assert EgressGuard.endpoint_target("https://api.example.com/v1") ==
               {:ok, {"api.example.com", 443}}

      assert EgressGuard.endpoint_target("http://api.example.com/v1") ==
               {:ok, {"api.example.com", 80}}
    end

    test "honors an explicit port" do
      assert EgressGuard.endpoint_target("https://api.example.com:8443/v1") ==
               {:ok, {"api.example.com", 8443}}
    end

    test "rejects junk" do
      assert EgressGuard.endpoint_target("not a url") == {:error, :invalid_endpoint}
      assert EgressGuard.endpoint_target("") == {:error, :invalid_endpoint}
      assert EgressGuard.endpoint_target(nil) == {:error, :invalid_endpoint}
    end
  end

  describe "socat_command/3" do
    test "pins the forwarder destination on the host side" do
      {exe, [left, right]} =
        EgressGuard.socat_command("/tmp/ws/.llm.sock", "api.example.com", 443)

      # listener side
      assert left =~ "UNIX-LISTEN:/tmp/ws/.llm.sock"
      assert left =~ "fork"
      assert left =~ "mode=0600"
      assert left =~ "unlink-early"
      # destination is fixed to the resolved endpoint — the agent cannot redirect it
      assert right == "TCP:api.example.com:443"
      # executable is resolved (or nil if socat is genuinely absent)
      assert is_nil(exe) or String.ends_with?(exe, "socat")
    end
  end

  describe "curlrc_content/0" do
    test "routes curl through the sandbox-side socket" do
      content = EgressGuard.curlrc_content()
      assert content =~ ~s(unix-socket = ")
      assert content =~ EgressGuard.sandbox_socket()
      assert EgressGuard.sandbox_socket() == "/workspace/.llm.sock"
    end
  end

  describe "host_socket_path/1" do
    test "places the socket inside the agent workspace" do
      assert EgressGuard.host_socket_path("/tmp/ws") == "/tmp/ws/.llm.sock"
    end
  end

  describe "start_forwarder/2 + stop_forwarder/1" do
    setup do
      # A clean, comma-free workspace path (like the real /tmp/szc-workspace/<id>).
      ws = Path.join(System.tmp_dir!(), "szc_egress_guard_test")
      File.rm_rf!(ws)
      File.mkdir_p!(ws)

      # Allow the test endpoint through the allowlist.
      saved_allow = System.get_env("GENSWARMS_ALLOWED_ENDPOINTS")
      System.put_env("GENSWARMS_ALLOWED_ENDPOINTS", "api.example.com")

      on_exit(fn ->
        File.rm_rf!(ws)
        restore("GENSWARMS_ALLOWED_ENDPOINTS", saved_allow)
      end)

      {:ok, ws: ws}
    end

    test "writes .curlrc, opens the socket, and cleans up", %{ws: ws} do
      result = EgressGuard.start_forwarder(ws, %{endpoint: "https://api.example.com/v1"})

      case result do
        {:ok, guard} ->
          # .curlrc was injected so the agent's curl uses the socket
          assert File.read!(Path.join(ws, ".curlrc")) =~ "unix-socket"
          assert guard.socket_path == Path.join(ws, ".llm.sock")

          # the forwarder actually came up and created the listener socket
          wait_for_socket(guard.socket_path)
          assert File.exists?(guard.socket_path)

          EgressGuard.stop_forwarder(guard)
          refute File.exists?(guard.socket_path)

        {:error, :socat_not_found} ->
          # environment without socat — the pure invariants above still cover it
          assert true
      end
    end

    test "stop is a no-op on nil" do
      assert EgressGuard.stop_forwarder(nil) == :ok
    end
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  # socat creates the listener socket asynchronously after spawn
  defp wait_for_socket(path, attempts \\ 50)
  defp wait_for_socket(_path, 0), do: :timeout

  defp wait_for_socket(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      wait_for_socket(path, attempts - 1)
    end
  end
end
