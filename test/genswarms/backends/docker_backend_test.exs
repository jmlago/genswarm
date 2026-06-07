defmodule Genswarms.Backends.DockerBackendTest do
  use ExUnit.Case, async: true

  alias Genswarms.Backends.DockerBackend

  defp build(config) do
    DockerBackend.build_docker_command(
      "szc-test-agent",
      "szc-agent-base:latest",
      # skills_dir nil keeps the builder free of filesystem side effects
      nil,
      "test-key",
      "test-model",
      config[:endpoint],
      "agent",
      config
    )
  end

  describe "network: :isolated" do
    test "drops the container network entirely" do
      cmd = build(%{network: :isolated, workspace: "/tmp/szc-ws/agent"})
      assert cmd =~ "--network none"
      # never resolves :isolated to a docker network named 'isolated'
      refute cmd =~ "--network isolated"
    end

    test "routes the agent's curl through the bind-mounted socket via CURL_HOME" do
      cmd = build(%{network: :isolated, workspace: "/tmp/szc-ws/agent"})
      assert cmd =~ "CURL_HOME=/workspace"
    end

    test "mounts the (per-agent) workspace at /workspace so the socket is visible" do
      cmd = build(%{network: :isolated, workspace: "/tmp/szc-ws/agent"})
      assert cmd =~ "/tmp/szc-ws/agent:/workspace"
    end
  end

  describe "default (network: :open)" do
    test "keeps current behavior — no forced network, no CURL_HOME" do
      cmd = build(%{})
      refute cmd =~ "--network none"
      refute cmd =~ "CURL_HOME"
    end

    test "an explicit docker network name still passes through" do
      cmd = build(%{network: "my-net"})
      assert cmd =~ "--network my-net"
    end
  end
end
