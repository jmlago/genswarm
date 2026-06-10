defmodule Genswarms.Agents.AskFlowTest do
  @moduledoc """
  End-to-end tests for the synchronous ask path (genswarms#53 G1):

      agent outbox file {to, content, reply_to}
        → LogWatcher (correlation id validated)
        → Router.ask (topology check, NO awaiting flag)
        → ObjectServer.deliver_ask (handler runs, reply → typed envelope)
        → AgentServer.deliver_ask_reply (envelope written to
          {workspace}/.inbox/replies/{corr}.json — never injected as a turn)

  The contrast test pins the bypass: a PLAIN send to a reply-expecting object
  sets `awaiting_reply` (the #49 ordering guard); an ask must not.

  async: false — shares the global AgentRegistry/Router.
  """
  use ExUnit.Case, async: false

  alias Genswarms.{SwarmManager, Routing.Router}
  alias Genswarms.Agents.AgentServer
  alias Genswarms.CLI.SwarmRegistry

  defmodule EchoHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_config), do: {:ok, %{}}
    @impl true
    def handle_message(_from, content, state),
      do: {:reply, Jason.encode!(%{"got" => content}), state}

    @impl true
    def interface(), do: %{}
  end

  defmodule ErrorHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_config), do: {:ok, %{}}
    @impl true
    def handle_message(_from, _content, state),
      do: {:reply, ~s({"error":{"code":"http_404","message":"page not found","type":"permanent"}}), state}

    @impl true
    def interface(), do: %{}
  end

  defmodule SilentHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_config), do: {:ok, %{}}
    @impl true
    def handle_message(_from, _content, state), do: {:noreply, state}
    @impl true
    def interface(), do: %{}
  end

  setup do
    swarm = "ask-flow-#{System.unique_integer([:positive])}"
    workspace = Path.join(System.tmp_dir!(), swarm)
    File.mkdir_p!(workspace)

    config = %{
      name: swarm,
      agents: [
        %{name: :alpha, backend: :mock, config: %{workspace: workspace}}
      ],
      objects: [
        %{name: :echo, handler: EchoHandler},
        %{name: :broken, handler: ErrorHandler},
        %{name: :silent, handler: SilentHandler}
      ],
      topology: [
        # back-edges present: these objects COULD reply asynchronously, which
        # is exactly what makes the plain-send path set awaiting_reply — and
        # what the ask path must bypass.
        {:alpha, :echo},
        {:echo, :alpha},
        {:alpha, :broken},
        {:broken, :alpha},
        {:alpha, :silent},
        {:silent, :alpha}
      ]
    }

    {:ok, ^swarm} = SwarmManager.start_from_config(config)
    SwarmRegistry.clear_overlay(swarm)

    on_exit(fn ->
      SwarmManager.stop(swarm)
      SwarmRegistry.clear_overlay(swarm)
      File.rm_rf(workspace)
    end)

    {:ok, swarm: swarm, workspace: workspace}
  end

  defp reply_path(ws, corr), do: Path.join([ws, ".inbox", "replies", corr <> ".json"])

  defp await_reply(ws, corr, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(reply_path(ws, corr), deadline)
  end

  defp do_await(path, deadline) do
    cond do
      File.exists?(path) ->
        {:ok, path |> File.read!() |> Jason.decode!()}

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(20)
        do_await(path, deadline)
    end
  end

  defp awaiting?(swarm, agent) do
    :sys.get_state(AgentServer.via_tuple(swarm, agent)).awaiting_reply
  end

  test "full chain: outbox ask file → envelope reply file, no turn injected",
       %{swarm: swarm, workspace: ws} do
    # Write the ask exactly as swarm-msg ask does; the agent's LogWatcher
    # (poll interval 500ms) picks it up and drives the whole chain.
    outbox = Path.join(ws, ".outbox")
    File.mkdir_p!(outbox)
    corr = "ask_e2e_1"

    File.write!(
      Path.join(outbox, "0001_echo_test.json"),
      Jason.encode!(%{to: "echo", content: ~s({"q":1}), reply_to: corr})
    )

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == true
    assert env["result"] == %{"got" => ~s({"q":1})}
    assert env["correlation_id"] == corr
    assert env["timeout"] == false

    # The ask did NOT arm the async-ordering guard...
    refute awaiting?(swarm, :alpha)
    # ...and the outbox file was consumed.
    assert Path.wildcard(Path.join(outbox, "*.json")) == []
  end

  test "contrast: a PLAIN send to a reply-expecting object sets awaiting_reply",
       %{swarm: swarm} do
    refute awaiting?(swarm, :alpha)

    # :silent has a back-edge (reply-expecting) but never replies, so the flag
    # stays observable. (:echo would clear it instantly via its reply.)
    Router.route(swarm, :alpha, :silent, "fire and forget")

    deadline = System.monotonic_time(:millisecond) + 1_000

    wait = fn wait ->
      cond do
        awaiting?(swarm, :alpha) -> :ok
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(10) && wait.(wait)
      end
    end

    assert wait.(wait) == :ok
  end

  test "an object error reply is lifted into a typed ok:false envelope",
       %{swarm: swarm, workspace: ws} do
    corr = "ask_err_1"
    Router.ask(swarm, :alpha, :broken, "anything", corr)

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == false
    assert env["error"]["code"] == "http_404"
    assert env["error"]["type"] == "permanent"
    refute awaiting?(swarm, :alpha)
  end

  test "a handler that does not reply still acknowledges the ask (result: nil)",
       %{swarm: swarm, workspace: ws} do
    corr = "ask_silent_1"
    Router.ask(swarm, :alpha, :silent, "anything", corr)

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == true
    assert env["result"] == nil
  end

  test "a denied route answers immediately with route_denied (no timeout wait)",
       %{swarm: swarm, workspace: ws} do
    corr = "ask_denied_1"
    # No :alpha → :nonexistent_edge edge in the topology.
    Router.ask(swarm, :alpha, :metrics_unknown, "x", corr)

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == false
    assert env["error"]["code"] == "route_denied"
    assert env["error"]["type"] == "permanent"
  end

  test "an ask to an agent (not an object) is a typed error", %{swarm: swarm, workspace: ws} do
    # Give alpha a self-edge? Not needed: agents can route to other agents via
    # topology; here we ask :alpha itself via a back-edge target. Build the
    # edge dynamically to keep the setup topology clean.
    :ok = SwarmManager.add_topology_edges(swarm, [{:alpha, :alpha}])

    corr = "ask_agent_1"
    Router.ask(swarm, :alpha, :alpha, "x", corr)

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == false
    assert env["error"]["code"] == "not_an_object"
  end
end
