defmodule Genswarms.Backends.DockerBackendTest do
  use ExUnit.Case, async: true

  alias Genswarms.Backends.DockerBackend

  describe "build_docker_args/8 (command-injection hardening)" do
    test "returns a flat argv list of strings (no shell string)" do
      args =
        DockerBackend.build_docker_args("szc-s-a", "img:tag", nil, nil, nil, nil, "agentA", %{})

      assert is_list(args)
      assert Enum.all?(args, &is_binary/1)
      # container name is a single discrete element right after --name
      assert ["--name", "szc-s-a" | _] = drop_until(args, "--name")
    end

    test "env values are literal argv elements; a malicious model cannot split argv or inject" do
      evil = "x'; touch /tmp/pwned #"
      args = DockerBackend.build_docker_args("c", "i", nil, "sk-secret", evil, nil, "a", %{})

      # the whole malicious value is ONE element, verbatim (quote preserved, not interpreted)
      assert "SUBZEROCLAW_MODEL=#{evil}" in args
      assert "SUBZEROCLAW_API_KEY=sk-secret" in args
      # it did not break out into separate tokens
      refute "touch" in args
      refute "/tmp/pwned" in args
    end

    test "default container command is argv ['sh','-c',script] (runs in the container, not host)" do
      args = DockerBackend.build_docker_args("c", "i", nil, nil, nil, nil, "a", %{})
      assert ["sh", "-c", script] = Enum.take(args, -3)
      assert script =~ "subzeroclaw"
    end

    test "a string :cmd is wrapped as sh -c (container shell); a list :cmd is used as argv" do
      str =
        DockerBackend.build_docker_args("c", "i", nil, nil, nil, nil, "a", %{cmd: "python app.py"})

      assert Enum.take(str, -3) == ["sh", "-c", "python app.py"]

      lst =
        DockerBackend.build_docker_args("c", "i", nil, nil, nil, nil, "a", %{
          cmd: ["python", "app.py"]
        })

      assert Enum.take(lst, -2) == ["python", "app.py"]
    end
  end

  describe "network: :isolated" do
    test "drops the container network (--network none, never a net named 'isolated')" do
      args = isolated_args()
      assert ["--network", "none" | _] = drop_until(args, "--network")
      refute "isolated" in args
    end

    test "routes the agent's curl through the egress socket via CURL_HOME" do
      assert "CURL_HOME=/workspace" in isolated_args()
    end

    test "mounts the per-agent workspace at /workspace so .curlrc is visible" do
      assert "/tmp/szc-ws/agent:/workspace" in isolated_args()
    end

    test "mounts the per-agent egress volume (sidecar socket lives there)" do
      # container_name in build/1 is "szc-test-agent"
      assert "szc-egress-szc-test-agent:/egress" in isolated_args()
    end
  end

  describe "default (network: :open)" do
    test "no forced network, no CURL_HOME, no egress volume" do
      args = build(%{})
      refute "none" in args
      refute "CURL_HOME=/workspace" in args
      refute Enum.any?(args, &String.contains?(&1, "/egress"))
    end

    test "an explicit docker network name still passes through" do
      assert ["--network", "my-net" | _] = drop_until(build(%{network: "my-net"}), "--network")
    end
  end

  # Builds the docker run argv for the agent container.
  defp build(config) do
    DockerBackend.build_docker_args(
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

  defp isolated_args, do: build(%{network: :isolated, workspace: "/tmp/szc-ws/agent"})

  # return the list starting at the first occurrence of `val`
  defp drop_until([val | _] = rest, val), do: rest
  defp drop_until([_ | t], val), do: drop_until(t, val)
  defp drop_until([], _val), do: []
end
