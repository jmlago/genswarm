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
      do:
        {:reply, ~s({"error":{"code":"http_404","message":"page not found","type":"permanent"}}),
         state}

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

  defmodule RecorderHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(config), do: {:ok, %{test_pid: Map.fetch!(config, :test_pid)}}
    @impl true
    def handle_message(from, content, state) do
      send(state.test_pid, {:recorded, from, content})
      {:noreply, state}
    end

    @impl true
    def interface(), do: %{}
  end

  defmodule WeirdErrorHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_config), do: {:ok, %{}}
    # An error whose code/message are NOT strings — upstream services do this.
    @impl true
    def handle_message(_from, _content, state),
      do: {:reply, ~s({"error":{"code":{"upstream":502},"message":["bad","gateway"]}}), state}

    @impl true
    def interface(), do: %{}
  end

  defmodule ThrowingHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_config), do: {:ok, %{}}
    @impl true
    def handle_message(_from, _content, _state), do: throw(:tantrum)
    @impl true
    def interface(), do: %{}
  end

  defmodule ExitingHandler do
    @behaviour Genswarms.Objects.ObjectHandler
    @impl true
    def init(_config), do: {:ok, %{}}
    @impl true
    def handle_message(_from, _content, _state), do: exit(:bailed)
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
        %{name: :silent, handler: SilentHandler},
        %{name: :recorder, handler: RecorderHandler, config: %{test_pid: self()}},
        %{name: :weird, handler: WeirdErrorHandler},
        %{name: :thrower, handler: ThrowingHandler},
        %{name: :exiter, handler: ExitingHandler}
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
        {:silent, :alpha},
        # no back-edge: a plain send to the recorder arms nothing.
        {:alpha, :recorder},
        {:alpha, :weird},
        {:alpha, :thrower},
        {:alpha, :exiter}
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

  test "an ask FROM a non-agent is dropped without crashing anything",
       %{swarm: swarm, workspace: ws} do
    # API misuse guard: agents and objects share the Registry keyspace, so
    # answering a non-agent would cast an unknown message into an ObjectServer.
    Router.ask(swarm, :echo, :silent, "x", "ask_from_obj")
    Process.sleep(200)
    refute File.exists?(reply_path(ws, "ask_from_obj"))

    # the router and the objects survive: a legitimate ask still works
    corr = "ask_after_misuse"
    Router.ask(swarm, :alpha, :echo, "ping", corr)
    assert {:ok, %{"ok" => true}} = await_reply(ws, corr)
  end

  test "non-binary ask content is refused with a typed envelope (router survives)",
       %{swarm: swarm, workspace: ws} do
    # Written as an outbox file the way a misbehaving agent would: JSON object
    # content instead of a string. Goes through the real LogWatcher pattern
    # guards — the file is dropped as invalid, nothing crashes.
    outbox = Path.join(ws, ".outbox")
    File.mkdir_p!(outbox)

    File.write!(
      Path.join(outbox, "0001_echo_bad.json"),
      ~s({"to":"echo","content":{"a":1},"reply_to":"ask_nonbin"})
    )

    Process.sleep(700)
    refute File.exists?(reply_path(ws, "ask_nonbin"))

    # router still routes; a follow-up ask works
    corr = "ask_after_nonbin"
    Router.ask(swarm, :alpha, :echo, "ping", corr)
    assert {:ok, %{"ok" => true}} = await_reply(ws, corr)
  end

  test ~s(an outbox file with "reply_to": null routes as a PLAIN send, not a dropped ask),
       %{workspace: ws} do
    # Review round 3 finding 4: pre-existing writers include a literal
    # `"reply_to": null` in plain sends. That used to match the ask clause,
    # fail correlation-id validation, and be deleted WITHOUT routing — the
    # send silently vanished. nil must mean "no ask": fall through to the
    # plain-send clause.
    outbox = Path.join(ws, ".outbox")
    File.mkdir_p!(outbox)

    File.write!(
      Path.join(outbox, "0001_recorder_null.json"),
      ~s({"to":"recorder","content":"plain hello","reply_to":null})
    )

    assert_receive {:recorded, :alpha, "plain hello"}, 3_000

    # routed as a send: consumed, and no reply file materialized anywhere
    assert Path.wildcard(Path.join(outbox, "*.json")) == []
    assert Path.wildcard(Path.join([ws, ".inbox", "replies", "*.json"])) == []
  end

  test "a non-stringable error code still yields a typed envelope and the object survives",
       %{swarm: swarm, workspace: ws} do
    # Review round 3 finding 5: normalize_error ran to_string/1 on the
    # object's error fields OUTSIDE the handler rescue — a map code (e.g.
    # {"error":{"code":{"upstream":502}}}) raised Protocol.UndefinedError,
    # crashed the ObjectServer, and stranded the asker until timeout.
    corr = "ask_weird_1"
    Router.ask(swarm, :alpha, :weird, "anything", corr)

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == false
    assert is_binary(env["error"]["code"])
    assert env["error"]["code"] =~ "upstream"

    # the object lived through it: a follow-up ask is answered
    corr2 = "ask_weird_2"
    Router.ask(swarm, :alpha, :weird, "again", corr2)
    assert {:ok, %{"ok" => false}} = await_reply(ws, corr2)
  end

  test "a handler that throws is a typed handler_error, not an ObjectServer crash",
       %{swarm: swarm, workspace: ws} do
    corr = "ask_throw_1"
    Router.ask(swarm, :alpha, :thrower, "x", corr)

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == false
    assert env["error"]["code"] == "handler_error"
    assert env["error"]["message"] =~ "tantrum"

    # the object survives: a legitimate ask elsewhere still works
    corr2 = "ask_after_throw"
    Router.ask(swarm, :alpha, :echo, "ping", corr2)
    assert {:ok, %{"ok" => true}} = await_reply(ws, corr2)
  end

  test "a handler that exits is a typed handler_error, not an ObjectServer crash",
       %{swarm: swarm, workspace: ws} do
    corr = "ask_exit_1"
    Router.ask(swarm, :alpha, :exiter, "x", corr)

    assert {:ok, env} = await_reply(ws, corr)
    assert env["ok"] == false
    assert env["error"]["code"] == "handler_error"
    assert env["error"]["message"] =~ "bailed"

    corr2 = "ask_after_exit"
    Router.ask(swarm, :alpha, :echo, "ping", corr2)
    assert {:ok, %{"ok" => true}} = await_reply(ws, corr2)
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
