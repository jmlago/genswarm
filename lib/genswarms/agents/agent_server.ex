defmodule Genswarms.Agents.AgentServer do
  @moduledoc """
  GenServer wrapping a single agent process/container/connection.

  Responsibilities:
  - Manages the backend (Port/Docker/SSH)
  - Maintains an inbox queue for incoming messages
  - Decodes agent output and routes to Router
  - Handles Port/SSH messages
  - Tracks agent state (idle/working/error)
  """

  use GenServer
  require Logger

  alias Genswarms.Agents.{AgentProtocol, Ask, Inbox}
  alias Genswarms.Observability.LogStore
  alias Genswarms.Config.SwarmConfig
  alias Genswarms.Objects.ObjectServer
  alias Genswarms.Routing.Router

  # How long (ms) to wait for an async object reply before giving up and
  # releasing the inbox.  Configurable via :genswarms, :awaiting_reply_timeout.
  #
  # Must exceed the slowest reply-expecting object's reply latency (e.g. a
  # headless-browser render up to ~45s); too short releases queued tasks before
  # the reply and re-introduces mis-ordering.  Objects sitting on a reply-edge
  # MUST eventually reply (or broadcast/send) to the agent, or the agent stalls
  # until this timeout.
  @default_awaiting_timeout_ms 90_000

  defstruct [
    :name,
    :swarm_name,
    :backend_module,
    :backend_ref,
    :backend_config,
    :inbox,
    :skills,
    :skills_dir,
    :log_watcher,
    state: :initializing,
    buffer: "",
    message_count: 0,
    file_inbox_seq: 0,
    history: [],
    started_at: nil,
    last_activity: nil,
    # --- reply auto-delivery (genswarms#53 G2) ---
    # When `reply_to` (agent config) names an object, the turn's derived reply
    # text (AgentProtocol.reply_text/1) is delivered there once per turn — unless
    # the agent already explicitly sent to that target during that turn. A
    # COMPLETED turn's delivery is never invalidated by the next turn starting
    # (its text answers its own message); only a wall-clock-expired turn is
    # discarded. nil ⇒ feature off (default).
    reply_to: nil,
    reply_grace_ms: 1_000,
    turn_seq: 0,
    # Set of {target, turn_seq} marks: the agent explicitly sent to `target`
    # during turn `turn_seq` ({:__broadcast__, seq} marks a broadcast, which
    # reaches the sink too if it's in the topology). Attribution is exact: the
    # synchronous outbox sweep at TURN_COMPLETE stamps turn N's sends with N
    # even though the next turn may begin in the same handle_info. Only
    # maintained when reply_to is set (nothing consumes marks otherwise), and
    # every mark is pruned once its turn's delivery decision is final — in
    # the {:auto_deliver, ...} handler, or drop_own_turn_marks/1 on the skip
    # paths — so the set stays bounded. Survives turn transitions by design —
    # a pending delivery for turn N is checked after N+1 has begun.
    turn_sends: MapSet.new(),
    # --- per-turn wall clock (genswarms#53 G3) ---
    # `turn_timeout_ms` (agent config) bounds a single turn end-to-end. On
    # expiry the turn is marked expired (telemetry :turn_timeout) and a LATE
    # <<TURN_COMPLETE>> no longer auto-delivers its stale text. nil ⇒ off
    # (default — current behavior).
    turn_timeout_ms: nil,
    turn_timer_ref: nil,
    turn_expired: false,
    # --- async-reply ordering guard ---
    # When the agent has sent a message to an object that can reply (the object
    # is in the agent's incoming topology), we set awaiting_reply: true.  Any
    # new user task that arrives while awaiting is pushed into the Inbox instead
    # of being forwarded to the backend immediately.  This prevents the race
    # where a fast follow-up user message overtakes the still-pending object
    # reply and causes mis-correlation of turns.
    #
    # cleared_by: clear_awaiting/2 (Router calls this when the object reply
    # arrives), or the :awaiting_timeout safety valve.
    awaiting_reply: false,
    awaiting_since: nil,
    awaiting_timer_ref: nil
  ]

  @type state :: :initializing | :idle | :working | :error | :stopped
  @type t :: %__MODULE__{
          name: atom(),
          swarm_name: String.t(),
          backend_module: module(),
          backend_ref: term(),
          backend_config: map(),
          inbox: Inbox.t(),
          skills: [String.t()],
          skills_dir: String.t() | nil,
          state: state(),
          buffer: binary(),
          message_count: non_neg_integer(),
          started_at: DateTime.t() | nil,
          last_activity: DateTime.t() | nil,
          awaiting_reply: boolean(),
          awaiting_since: integer() | nil,
          awaiting_timer_ref: reference() | nil
        }

  # Client API

  @doc """
  Starts an agent server.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    swarm_name = Keyword.fetch!(opts, :swarm_name)
    registry_name = via_tuple(swarm_name, name)
    GenServer.start_link(__MODULE__, opts, name: registry_name)
  end

  @doc """
  Returns the via tuple for Registry lookup.
  """
  def via_tuple(swarm_name, agent_name) do
    {:via, Registry, {Genswarms.AgentRegistry, {swarm_name, agent_name}, :agent}}
  end

  @doc """
  Sends a task to the agent.
  """
  def send_task(swarm_name, agent_name, task) do
    GenServer.call(via_tuple(swarm_name, agent_name), {:send_task, task})
  end

  @doc """
  Delivers a message from another agent.
  """
  def deliver_message(swarm_name, agent_name, from, content) do
    GenServer.cast(via_tuple(swarm_name, agent_name), {:deliver_message, from, content})
  end

  @doc """
  Delivers the envelope answering one of this agent's asks (`swarm-msg ask`).

  Written to `{workspace}/.inbox/replies/{correlation_id}.json`, where the
  agent's blocked `swarm-msg ask` is polling — NOT injected as a new
  conversational turn, and the awaiting-reply flag is untouched (an ask is
  synchronous from the agent's perspective; there is no async reply to guard).
  A dead or unknown agent makes this a no-op: the reply is dropped and the
  asker's own timeout envelope is the catch-all.
  """
  def deliver_ask_reply(swarm_name, agent_name, correlation_id, envelope) do
    GenServer.cast(
      via_tuple(swarm_name, agent_name),
      {:deliver_ask_reply, correlation_id, envelope}
    )
  end

  @doc """
  Gets the current state of the agent.
  """
  def get_state(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_state)
  end

  @doc """
  Gets agent status info.
  """
  def get_status(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_status)
  end

  @doc """
  Gets agent message history.
  """
  def get_history(swarm_name, agent_name, limit \\ 100) do
    GenServer.call(via_tuple(swarm_name, agent_name), {:get_history, limit})
  end

  @doc """
  Gets agent skills content (reads the markdown files).
  """
  def get_skills_content(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_skills_content)
  end

  @doc """
  Updates a skill file for an agent.
  """
  def update_skill(swarm_name, agent_name, skill_name, content) do
    GenServer.call(via_tuple(swarm_name, agent_name), {:update_skill, skill_name, content})
  end

  @doc """
  Gets the agent's conversation logs (from subzeroclaw log files).
  """
  def get_logs(swarm_name, agent_name) do
    GenServer.call(via_tuple(swarm_name, agent_name), :get_logs)
  end

  @doc """
  Stops the agent.
  """
  def stop(swarm_name, agent_name) do
    GenServer.stop(via_tuple(swarm_name, agent_name))
  end

  @doc """
  Marks the agent as awaiting an async object reply.

  Called by the Router when it routes a message FROM this agent TO an object
  that has a return-path edge back to the agent (object is in the agent's
  incoming topology).  While awaiting, new user tasks are queued in the Inbox
  rather than forwarded to the backend immediately, preserving reply ordering.
  """
  def set_awaiting(swarm_name, agent_name) do
    GenServer.cast(via_tuple(swarm_name, agent_name), :set_awaiting)
  end

  @doc """
  Clears the awaiting-reply flag.

  Called by the Router when it delivers a message FROM an object TO this agent
  (i.e., the expected reply arrived).  After clearing, the agent's Inbox is
  processed on the next TURN_COMPLETE as normal.
  """
  def clear_awaiting(swarm_name, agent_name) do
    GenServer.cast(via_tuple(swarm_name, agent_name), :clear_awaiting)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    swarm_name = Keyword.fetch!(opts, :swarm_name)
    backend = Keyword.fetch!(opts, :backend)
    skills = Keyword.get(opts, :skills, [])
    model = Keyword.get(opts, :model)
    endpoint = Keyword.get(opts, :endpoint)
    presets = Keyword.get(opts, :presets, [])
    agent_config = Keyword.get(opts, :config, %{})
    connections = Keyword.get(opts, :connections, [])

    backend_module = SwarmConfig.backend_module(backend)

    # Separate backend-relevant keys from domain-specific keys
    # Backend keys control the execution environment (workspace, mounts, resources)
    # Domain keys are application-specific (population_size, max_iterations, etc.)
    backend_keys = ~w(workspace extra_path extra_ro_binds extra_rw_binds extra_env
                      memory_limit cpu_shares tasks_max subzeroclaw_path presets network
                      max_turns)a

    {backend_overrides, _domain_config} = Map.split(agent_config, backend_keys)

    backend_config =
      SwarmConfig.backend_config(backend)
      |> Map.merge(backend_overrides)
      |> maybe_put(:model, model)
      |> maybe_put(:endpoint, endpoint)
      |> maybe_put(:presets, presets)
      |> maybe_put(:connections, connections)

    state = %__MODULE__{
      name: name,
      swarm_name: swarm_name,
      backend_module: backend_module,
      backend_config: backend_config,
      inbox: Inbox.new(),
      skills: skills,
      started_at: DateTime.utc_now(),
      # G2 opt-in: deliver each turn's final text to this object automatically.
      reply_to: agent_config |> Map.get(:reply_to) |> normalize_reply_to(),
      reply_grace_ms: positive_int(agent_config, :reply_grace_ms, 1_000),
      # G3 opt-in: per-turn wall clock.
      turn_timeout_ms: positive_int(agent_config, :turn_timeout_ms, nil)
    }

    # Start backend asynchronously
    send(self(), :start_backend)

    {:ok, state}
  end

  @impl true
  def handle_info(:start_backend, state) do
    Logger.info("[#{state.swarm_name}/#{state.name}] Starting backend...")

    skills_dir = prepare_skills(state)

    config =
      state.backend_config
      |> Map.put(:skills_dir, skills_dir)
      |> Map.put(:swarm_name, state.swarm_name)

    case state.backend_module.start(to_string(state.name), config) do
      {:ok, ref} ->
        Logger.info("[#{state.swarm_name}/#{state.name}] Backend started")
        emit_telemetry(:agent_started, state, %{backend: state.backend_module.backend_type()})

        # Start log watcher for message routing
        log_dir = skills_dir |> Path.dirname() |> Path.join("logs")

        {:ok, watcher} =
          Genswarms.Agents.LogWatcher.start_link(
            swarm_name: state.swarm_name,
            agent_name: state.name,
            log_dir: log_dir,
            workspace: Map.get(state.backend_config, :workspace),
            # Accumulate poll-routed sends for the TURN_COMPLETE sweep only
            # when something will actually sweep them: with reply_to off there
            # is no auto-delivery to suppress and no sweep to clear the
            # accumulator, so tracking would only leak.
            track_sends: state.reply_to != nil
          )

        {:noreply,
         %{
           state
           | backend_ref: ref,
             skills_dir: skills_dir,
             state: :idle,
             last_activity: DateTime.utc_now(),
             log_watcher: watcher
         }}

      {:error, reason} ->
        Logger.error(
          "[#{state.swarm_name}/#{state.name}] Failed to start backend: #{inspect(reason)}"
        )

        emit_telemetry(:agent_error, state, %{
          reason: inspect(reason),
          backend: state.backend_module.backend_type()
        })

        {:noreply, %{state | state: :error}}
    end
  end

  # Handle Port messages
  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{backend_ref: %{port: port}} = state) do
    handle_agent_output(line, state)
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{backend_ref: %{port: port}} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{backend_ref: %{port: port}} = state) do
    Logger.warning("[#{state.swarm_name}/#{state.name}] Port exited with status #{status}")

    # Buffer tail kept for debugging an unexpected exit.
    buffer_tail =
      if byte_size(state.buffer) > 0 do
        String.slice(state.buffer, -500, 500)
      else
        nil
      end

    emit_telemetry(:agent_stopped, state, %{
      exit_status: status,
      buffer_tail: buffer_tail,
      level: :warning
    })

    # Serial turns queue mid-turn tasks in the Inbox — a backend death strands
    # them (a :stopped agent never dispatches again). The engine's job is to
    # make that loss visible (review round 3 finding 3b); requeue/retry policy
    # belongs to the application.
    queued = Inbox.size(state.inbox)

    if queued > 0 do
      Logger.warning(
        "[#{state.swarm_name}/#{state.name}] Backend exited with #{queued} queued task(s) " <>
          "still in the inbox — they will never be dispatched"
      )

      emit_telemetry(:inbox_dropped, state, %{count: queued, exit_status: status})
    end

    {:noreply, %{state | state: :stopped}}
  end

  # Generic port message handling
  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    handle_agent_output(data, state)
  end

  # Safety timeout: the expected object reply never arrived (object crashed, message
  # dropped, etc.).  Release the Inbox so the agent can continue.
  def handle_info(:awaiting_timeout, state) do
    if state.awaiting_reply do
      elapsed_ms = System.monotonic_time(:millisecond) - (state.awaiting_since || 0)

      Logger.warning(
        "[#{state.swarm_name}/#{state.name}] Awaiting-reply timeout after #{elapsed_ms}ms — " <>
          "releasing inbox (object reply may have been lost)"
      )

      new_state = %{
        state
        | awaiting_reply: false,
          awaiting_since: nil,
          awaiting_timer_ref: nil
      }

      {:noreply, maybe_process_inbox(new_state)}
    else
      # Timer fired after clear_awaiting already ran; nothing to do.
      {:noreply, %{state | awaiting_timer_ref: nil}}
    end
  end

  # G3: the per-turn wall clock fired. Only meaningful if the SAME turn is
  # still running — a stale timer (the turn completed; a new one may even have
  # started) is a no-op. The engine's job ends at making the timeout visible:
  # it does not kill the backend (that policy belongs to the application).
  def handle_info({:turn_timeout, seq}, state) do
    if seq == state.turn_seq and state.state == :working do
      Logger.warning(
        "[#{state.swarm_name}/#{state.name}] Turn #{seq} exceeded #{state.turn_timeout_ms}ms wall clock — late output will not be auto-delivered"
      )

      emit_telemetry(:turn_timeout, state, %{turn: seq, timeout_ms: state.turn_timeout_ms})
      {:noreply, %{state | turn_expired: true, turn_timer_ref: nil}}
    else
      {:noreply, state}
    end
  end

  # G2: the grace window after a completed turn has elapsed — deliver that
  # turn's reply text to the configured reply sink. A completed turn's answer
  # stays valid even if the next turn has already begun (it answers its own
  # message; rapid follow-ups must not lose replies). The ONLY suppression is
  # an explicit send (or broadcast) the agent itself made DURING that exact
  # turn — exact {target, seq} match, stamped by the synchronous sweep, so a
  # send in one turn can never eat a different turn's answer. Consumed marks
  # are pruned. (Expired turns were never scheduled; see schedule_auto_deliver.)
  def handle_info({:auto_deliver, seq, text}, state) do
    explicit? =
      MapSet.member?(state.turn_sends, {state.reply_to, seq}) or
        MapSet.member?(state.turn_sends, {:__broadcast__, seq})

    state =
      if explicit? do
        emit_telemetry(:auto_deliver_skipped, state, %{reason: :explicit_send, turn: seq})
        state
      else
        deliver_to_sink(state, seq, text)
      end

    # Prune everything this turn could still consume — marks for seqs <= this
    # one are spent (deliveries fire in seq order).
    pruned =
      state.turn_sends
      |> Enum.reject(fn {_target, s} -> s <= seq end)
      |> MapSet.new()

    {:noreply, %{state | turn_sends: pruned}}
  end

  def handle_info(msg, state) do
    Logger.debug("[#{state.swarm_name}/#{state.name}] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:send_task, task}, _from, state) do
    case state.state do
      s when s in [:idle, :working] ->
        # Queue the task in the Inbox instead of forwarding it to the backend
        # when the agent is (a) waiting for an async object reply, or (b) still
        # WORKING on a previous turn. (b) makes turns strictly serial: the old
        # behavior wrote the task straight into the backend's stdin FIFO mid-
        # turn, which broke turn accounting — the in-flight turn's output was
        # attributed to the new sequence, and the queued task's own completion
        # arrived with the agent already :idle, so its reply was never
        # auto-delivered and no telemetry fired. Queued tasks are released (in
        # order) via maybe_process_inbox/1 on the next TURN_COMPLETE; the
        # backend sees the same serial order it always effectively processed.
        if state.awaiting_reply or state.state == :working do
          history_entry = %{
            type: :task,
            content: task,
            timestamp: DateTime.utc_now()
          }

          case Inbox.push(state.inbox, %{
                 from: "orchestrator",
                 content: task,
                 received_at: DateTime.utc_now(),
                 task?: true
               }) do
            {:ok, new_inbox} ->
              Logger.debug(
                "[#{state.swarm_name}/#{state.name}] Task queued in Inbox (#{if state.awaiting_reply, do: "awaiting reply", else: "turn in progress"})"
              )

              {:reply, :ok, %{state | inbox: new_inbox, history: [history_entry | state.history]}}

            {:error, :inbox_full} ->
              Logger.warning(
                "[#{state.swarm_name}/#{state.name}] Inbox full, refusing queued task"
              )

              # Tell the caller the truth: an :ok here silently dropped the
              # task (review round 3 finding 3a) and nobody could react.
              {:reply, {:error, :inbox_full}, state}
          end
        else
          state = begin_turn(state)
          message = AgentProtocol.encode_task(task)
          send_to_backend(state, message)
          emit_telemetry(:task_sent, state, %{task: task})

          history_entry = %{
            type: :task,
            content: task,
            timestamp: DateTime.utc_now()
          }

          new_history = [history_entry | state.history]

          {:reply, :ok,
           %{state | state: :working, history: new_history, last_activity: DateTime.utc_now()}}
        end

      :error ->
        {:reply, {:error, :agent_error}, state}

      :stopped ->
        {:reply, {:error, :agent_stopped}, state}

      :initializing ->
        {:reply, {:error, :agent_initializing}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      name: state.name,
      swarm_name: state.swarm_name,
      state: state.state,
      backend: state.backend_module.backend_type(),
      inbox_size: Inbox.size(state.inbox),
      message_count: state.message_count,
      skills: state.skills,
      started_at: state.started_at,
      last_activity: state.last_activity
    }

    {:reply, status, state}
  end

  def handle_call({:get_history, limit}, _from, state) do
    history = Enum.take(state.history, limit)
    {:reply, history, state}
  end

  def handle_call(:get_skills_content, _from, state) do
    skills_content =
      if state.skills_dir && File.dir?(state.skills_dir) do
        state.skills_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn filename ->
          path = Path.join(state.skills_dir, filename)
          content = File.read!(path)
          %{name: filename, content: content, path: path}
        end)
      else
        []
      end

    {:reply, skills_content, state}
  end

  def handle_call({:update_skill, skill_name, content}, _from, state) do
    cond do
      is_nil(state.skills_dir) ->
        {:reply, {:error, :no_skills_dir}, state}

      not safe_skill_name?(skill_name) ->
        # skill_name is an attacker-controlled URL segment; reject anything that
        # is not a plain filename so it cannot traverse out of skills_dir
        # (e.g. "../../etc/cron.d/x" via %2F-encoded slashes) into an arbitrary
        # file write.
        {:reply, {:error, :invalid_skill_name}, state}

      true ->
        path = Path.join(state.skills_dir, skill_name)

        case File.write(path, content) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:get_logs, _from, state) do
    logs =
      if state.skills_dir do
        # Logs are in sibling directory to skills
        logs_dir = state.skills_dir |> Path.dirname() |> Path.join("logs")

        if File.dir?(logs_dir) do
          logs_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".txt"))
          |> Enum.sort()
          |> Enum.flat_map(fn filename ->
            path = Path.join(logs_dir, filename)
            content = File.read!(path)
            parse_subzeroclaw_log(content, filename)
          end)
        else
          []
        end
      else
        []
      end

    {:reply, logs, state}
  end

  @impl true
  def handle_cast({:deliver_message, from, content}, state) do
    # A delivered message clears the awaiting gate atomically with delivery, so
    # a racing send_task is still gated until the reply is in.  We do this
    # unconditionally at the top of the handler — any delivered message means
    # the agent is no longer awaiting — before the rest of the delivery logic
    # runs on the already-cleared state.
    state =
      if state.awaiting_reply do
        cancel_awaiting_timer(state.awaiting_timer_ref)
        %{state | awaiting_reply: false, awaiting_since: nil, awaiting_timer_ref: nil}
      else
        state
      end

    # Log incoming message
    content_preview =
      if String.length(content) > 100 do
        String.slice(content, 0, 100) <> "..."
      else
        content
      end

    LogStore.log(
      :info,
      :agent,
      :message_received,
      "Message received from #{from}: #{content_preview}",
      swarm: state.swarm_name,
      agent: state.name,
      metadata: %{from: from, content: content}
    )

    # Add to history
    history_entry = %{
      type: :incoming,
      from: from,
      content: content,
      timestamp: DateTime.utc_now()
    }

    case Inbox.push(state.inbox, %{from: from, content: content, received_at: DateTime.utc_now()}) do
      {:ok, new_inbox} ->
        new_history = [history_entry | state.history]

        # Write to file-inbox (parallel delivery for bwrap agents)
        seq = state.file_inbox_seq + 1
        write_file_inbox(state, seq, from, content)

        # Send to agent immediately if idle
        if state.state == :idle do
          state = begin_turn(state)
          message = AgentProtocol.encode_message(content, from)
          send_to_backend(state, message)
          emit_telemetry(:message_delivered, state, %{from: from})

          {:noreply,
           %{
             state
             | inbox: new_inbox,
               history: new_history,
               file_inbox_seq: seq,
               state: :working,
               last_activity: DateTime.utc_now()
           }}
        else
          {:noreply, %{state | inbox: new_inbox, history: new_history, file_inbox_seq: seq}}
        end

      {:error, :inbox_full} ->
        Logger.warning(
          "[#{state.swarm_name}/#{state.name}] Inbox full, dropping message from #{from}"
        )

        LogStore.log(:warning, :agent, :inbox_full, "Inbox full, dropped message from #{from}",
          swarm: state.swarm_name,
          agent: state.name,
          metadata: %{from: from, content_preview: content_preview}
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:set_awaiting, state) do
    # Cancel any pre-existing stale timer before arming a new one.
    cancel_awaiting_timer(state.awaiting_timer_ref)

    timeout_ms =
      Application.get_env(:genswarms, :awaiting_reply_timeout, @default_awaiting_timeout_ms)

    timer_ref = Process.send_after(self(), :awaiting_timeout, timeout_ms)

    Logger.debug(
      "[#{state.swarm_name}/#{state.name}] Awaiting async object reply (timeout #{timeout_ms}ms)"
    )

    {:noreply,
     %{
       state
       | awaiting_reply: true,
         awaiting_since: System.monotonic_time(:millisecond),
         awaiting_timer_ref: timer_ref
     }}
  end

  def handle_cast(:clear_awaiting, state) do
    cancel_awaiting_timer(state.awaiting_timer_ref)

    Logger.debug("[#{state.swarm_name}/#{state.name}] Cleared awaiting-reply flag")

    {:noreply, %{state | awaiting_reply: false, awaiting_since: nil, awaiting_timer_ref: nil}}
  end

  # Answer to one of this agent's asks: write the envelope where the blocked
  # `swarm-msg ask` is polling. No state change — in particular this does NOT
  # touch awaiting_reply and does NOT inject a turn (that is the whole point
  # of the ask path). Failures are logged and dropped; the asker's timeout
  # envelope is the catch-all.
  def handle_cast({:deliver_ask_reply, corr, envelope}, state) do
    workspace = Map.get(state.backend_config, :workspace)

    case Ask.write_reply(workspace, corr, envelope) do
      :ok ->
        Logger.debug("[#{state.swarm_name}/#{state.name}] Ask reply written: #{corr}")

      {:error, reason} ->
        Logger.warning(
          "[#{state.swarm_name}/#{state.name}] Dropping ask reply #{corr}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clear any pending timers so they don't fire into a dead process.
    cancel_awaiting_timer(state.awaiting_timer_ref)
    if state.turn_timer_ref, do: Process.cancel_timer(state.turn_timer_ref)

    if state.backend_ref do
      state.backend_module.stop(state.backend_ref)
    end

    :ok
  end

  # Private functions

  # A skill name is safe only if it is a single plain filename: non-empty, not a
  # directory reference, and free of any path separator or null byte. The
  # `Path.basename(name) == name` check is the core guard — basename strips every
  # directory component, so any name containing "/" or "\\" (or being "../foo")
  # fails it. This prevents update_skill from writing outside skills_dir.
  defp safe_skill_name?(name) when is_binary(name) do
    name != "" and
      name not in [".", ".."] and
      not String.contains?(name, ["/", "\\", "\0"]) and
      Path.basename(name) == name
  end

  defp safe_skill_name?(_), do: false

  defp handle_agent_output(data, state) do
    full_data = state.buffer <> data

    # Check for API errors in output
    case detect_api_error(full_data) do
      {error_type, error_msg} ->
        LogStore.log(:error, :system, error_type, error_msg,
          swarm: state.swarm_name,
          agent: state.name,
          metadata: %{output_snippet: String.slice(full_data, 0, 200)}
        )

      nil ->
        :ok
    end

    # Check for completion signals:
    # - "<<TURN_COMPLETE>>" after a turn finishes
    # - "> " prompt when agent is idle (initial startup or waiting)
    turn_complete = String.contains?(full_data, "<<TURN_COMPLETE>>")

    initial_idle =
      (String.ends_with?(full_data, "> ") or full_data == "> ") and state.state == :starting

    if turn_complete or initial_idle do
      # Keep the raw turn output: reply-text derivation (G2) does its own
      # marker/prompt stripping (AgentProtocol owns the stdout grammar).
      raw_turn = full_data
      working_turn? = turn_complete and state.state == :working

      # Remove markers from output before processing
      full_data = AgentProtocol.strip_turn_markers(full_data)

      # Log stdout output to LogStore
      unless full_data == "" or String.trim(full_data) == "" do
        output_preview =
          if String.length(full_data) > 200 do
            String.slice(full_data, 0, 200) <> "..."
          else
            full_data
          end

        LogStore.log(
          :info,
          :agent,
          :stdout,
          "Agent output: #{String.replace(output_preview, "\n", " ")}",
          swarm: state.swarm_name,
          agent: state.name,
          metadata: %{
            output: full_data,
            output_length: String.length(full_data)
          }
        )
      end

      # Agent finished output - now parse for @mentions and route messages
      # This ensures we capture the COMPLETE message before routing
      messages = AgentProtocol.parse_output(full_data)

      # Route messages
      Logger.debug("[#{state.swarm_name}/#{state.name}] Parsed #{length(messages)} messages")

      Enum.each(messages, fn msg ->
        Logger.debug("[#{state.swarm_name}/#{state.name}] Routing: #{inspect(msg)}")
        route_message(msg, state)
      end)

      # Add to history
      history_entries =
        Enum.map(messages, fn msg ->
          %{
            type: :outgoing,
            message_type: msg.type,
            to: Map.get(msg, :to),
            content: msg.content,
            timestamp: DateTime.utc_now()
          }
        end)

      # This turn's explicit sends, with EXACT attribution to this turn's seq:
      #   - legacy stdout-protocol sends parsed above;
      #   - outbox sends, ALL of them via the synchronous sweep: targets the
      #     watcher's 500ms poll routed mid-turn (its accumulator) plus files
      #     still on disk, drained right now. The agent cannot write more
      #     files after emitting <<TURN_COMPLETE>> (it is blocked at the
      #     prompt), so everything the sweep returns belongs to this turn —
      #     attribution is independent of poll timing and involves no async
      #     cast that could be processed after the next turn began and stamp
      #     the wrong seq (review round 3 finding 1).
      #
      # Marks exist solely to suppress auto-delivery, so with reply_to off
      # (the default) NOTHING ever consumes them — recording any would leak
      # unboundedly (review round 3 finding 2). Same for non-working turns
      # (startup banner / stale output): they never schedule a delivery.
      new_marks =
        if working_turn? and state.reply_to != nil do
          legacy = for %{type: :send, to: to} <- messages, do: {to, state.turn_seq}
          swept = for to <- sweep_outbox(state), do: {to, state.turn_seq}
          MapSet.new(legacy ++ swept)
        else
          MapSet.new()
        end

      # The turn ended — its wall clock (if any) is done.
      if state.turn_timer_ref, do: Process.cancel_timer(state.turn_timer_ref)

      new_state = %{
        state
        | buffer: "",
          state: :idle,
          message_count: state.message_count + length(messages),
          history: history_entries ++ state.history,
          last_activity: DateTime.utc_now(),
          turn_sends: MapSet.union(state.turn_sends, new_marks),
          turn_timer_ref: nil
      }

      # G2: schedule auto-delivery of this turn's reply text (only for a real
      # completed working turn — never for the startup banner).
      new_state =
        if working_turn? do
          schedule_auto_deliver(new_state, raw_turn)
        else
          new_state
        end

      # Process next inbox message if any
      new_state = maybe_process_inbox(new_state)
      {:noreply, new_state}
    else
      # Still receiving output - just accumulate in buffer
      {:noreply, %{state | buffer: full_data, last_activity: DateTime.utc_now()}}
    end
  end

  # ── G2 reply auto-delivery helpers ──────────────────────────────────────────

  # Deliver to the sink, verifying it actually is a live OBJECT first: agents
  # and objects share the Registry keyspace, so a typo'd or agent-typed
  # reply_to would otherwise silently no-op (while telemetry claimed delivery)
  # or inject the text into another AGENT — bypassing topology entirely and
  # enabling unbounded agent↔agent loops.
  defp deliver_to_sink(state, seq, text) do
    case Registry.lookup(Genswarms.AgentRegistry, {state.swarm_name, state.reply_to}) do
      [{_pid, :object}] ->
        # Delivered DIRECTLY to the sink object, not via Router.route: the
        # target is operator configuration (agent config), not model output,
        # so topology validation adds nothing — and routing would arm the
        # async-reply ordering guard if the sink had a back-edge, gating the
        # agent's inbox for a delivery that expects no reply.
        ObjectServer.deliver_message(state.swarm_name, state.reply_to, state.name, text)
        emit_telemetry(:auto_delivered, state, %{turn: seq, bytes: byte_size(text)})
        state

      other ->
        reason = if other == [], do: :sink_not_found, else: :sink_not_an_object

        Logger.warning(
          "[#{state.swarm_name}/#{state.name}] reply_to #{inspect(state.reply_to)} #{reason} — reply NOT delivered"
        )

        emit_telemetry(:auto_deliver_failed, state, %{reason: reason, turn: seq})
        state
    end
  end

  # Synchronously drain this agent's .outbox via its LogWatcher, returning
  # this turn's routed plain-send targets (poll-accumulated + just drained) so
  # the caller can stamp them with the turn they belong to. Best-effort: with
  # a dead/slow watcher the turn proceeds without suppression marks — worst
  # case a doubled reply, never a lost one.
  defp sweep_outbox(%{log_watcher: watcher} = state) when is_pid(watcher) do
    Genswarms.Agents.LogWatcher.sweep_outbox(watcher)
  catch
    kind, reason ->
      Logger.warning(
        "[#{state.swarm_name}/#{state.name}] outbox sweep failed (#{kind}: #{inspect(reason)}) — this turn's explicit sends will not suppress auto-delivery"
      )

      []
  end

  defp sweep_outbox(_state), do: []

  # A new piece of work is being handed to the backend: a new turn begins.
  # Bump the sequence and arm the per-turn wall clock if configured.
  # `turn_sends` is deliberately NOT reset here: a COMPLETED previous turn may
  # still have its auto-delivery pending in the grace window, and its
  # suppression mark must survive this turn starting (see handle_info
  # {:auto_deliver, ...} — suppression compares per-target send seq, not a
  # per-turn flag).
  defp begin_turn(state) do
    if state.turn_timer_ref, do: Process.cancel_timer(state.turn_timer_ref)
    seq = state.turn_seq + 1

    timer_ref =
      if state.turn_timeout_ms do
        Process.send_after(self(), {:turn_timeout, seq}, state.turn_timeout_ms)
      end

    # Drop any stale buffered output (harness startup banners and similar
    # idle-time noise) so it can't leak into this turn's derived reply text.
    # Turns are serial (a task arriving mid-turn queues in the Inbox), so
    # nothing in-flight is ever discarded here.
    %{state | buffer: "", turn_seq: seq, turn_timer_ref: timer_ref, turn_expired: false}
  end

  defp normalize_reply_to(nil), do: nil
  defp normalize_reply_to(name) when is_atom(name), do: name
  defp normalize_reply_to(name) when is_binary(name), do: String.to_atom(name)

  # Config timing values must be positive integers; anything else would crash
  # Process.send_after on the FIRST task — as a restart loop. Warn and fall
  # back to the default instead.
  defp positive_int(config, key, default) do
    case Map.get(config, key, default) do
      nil ->
        default

      n when is_integer(n) and n > 0 ->
        n

      bad ->
        Logger.warning(
          "agent config #{key}=#{inspect(bad)} is not a positive integer — using #{inspect(default)}"
        )

        default
    end
  end

  # Derive the turn's reply text and schedule its delivery after the grace
  # window. The grace exists for one reason: an explicit outbox send written
  # this turn may still be sitting in .outbox/ (the LogWatcher polls every
  # 500ms), so delivering instantly could double up with it. No reply_to ⇒
  # feature off. An empty derivation with the feature on is the silent-drop
  # signal — emit no_final_text so the application can recover (re-prompt,
  # fallback); the engine's job is to make it visible, not to handle it.
  defp schedule_auto_deliver(%{reply_to: nil} = state, _raw_turn), do: state

  # G3: the wall clock expired before this turn completed — its text answers a
  # question the application has already recovered from. Discard, visibly.
  defp schedule_auto_deliver(%{turn_expired: true} = state, _raw_turn) do
    emit_telemetry(:auto_deliver_skipped, state, %{reason: :turn_expired, turn: state.turn_seq})
    drop_own_turn_marks(state)
  end

  defp schedule_auto_deliver(state, raw_turn) do
    case AgentProtocol.reply_text(raw_turn) do
      "" ->
        emit_telemetry(:no_final_text, state, %{turn: state.turn_seq})
        drop_own_turn_marks(state)

      text ->
        Process.send_after(self(), {:auto_deliver, state.turn_seq, text}, state.reply_grace_ms)
        state
    end
  end

  # A turn whose delivery is SKIPPED (expired / no final text) never gets an
  # {:auto_deliver, seq, …} message — the normal prune site — so its freshly
  # stamped marks would sit in turn_sends forever (review round 3 finding 2).
  # Drop exactly this turn's marks, here, because this is the moment the
  # turn's delivery decision is final. Pruning anywhere broader is NOT safe:
  # earlier turns' deliveries can still be pending right now (each fires at
  # its own completion + grace, which lands after THIS turn's completion
  # whenever grace exceeds the inter-turn gap), and begin_turn runs before
  # the previous turn's grace elapses for the same reason — so neither may
  # touch other turns' marks. The {:auto_deliver, seq} handler prunes
  # s <= seq safely only because deliveries fire in seq order.
  defp drop_own_turn_marks(state) do
    seq = state.turn_seq

    pruned =
      state.turn_sends
      |> Enum.reject(fn {_target, s} -> s == seq end)
      |> MapSet.new()

    %{state | turn_sends: pruned}
  end

  defp route_message(%{type: :send, to: to, content: content}, state) do
    Router.route(state.swarm_name, state.name, to, content)
  end

  defp route_message(%{type: :broadcast, content: content}, state) do
    Router.broadcast(state.swarm_name, state.name, content)
  end

  defp route_message(%{type: :output, content: content}, state) do
    # Broadcast output to subscribers
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{state.swarm_name}:output",
      {:agent_output, state.name, content}
    )
  end

  defp route_message(%{type: :status, state: agent_state}, state) do
    Phoenix.PubSub.broadcast(
      Genswarms.PubSub,
      "swarm:#{state.swarm_name}:status",
      {:agent_status, state.name, agent_state}
    )

    # Return the new state to update - handled specially in handle_agent_output
    {:update_state, String.to_atom(agent_state)}
  end

  defp route_message(_msg, _state), do: :ok

  defp maybe_process_inbox(%{state: :idle, inbox: inbox} = state) do
    case Inbox.pop(inbox) do
      {:ok, %{content: content, task?: true}, new_inbox} ->
        # Queued user task — encode as a task (not a message) so the agent
        # receives it byte-identical to a directly-delivered task.
        state = begin_turn(state)
        message = AgentProtocol.encode_task(content)
        send_to_backend(state, message)
        emit_telemetry(:task_sent, state, %{task: content})
        %{state | inbox: new_inbox, state: :working}

      {:ok, %{from: from, content: content}, new_inbox} ->
        state = begin_turn(state)
        message = AgentProtocol.encode_message(content, from)
        send_to_backend(state, message)
        %{state | inbox: new_inbox, state: :working}

      {:empty, _} ->
        state
    end
  end

  defp maybe_process_inbox(state), do: state

  defp send_to_backend(%{backend_ref: %{port: port}}, message) do
    Port.command(port, message <> "\n")
  end

  defp send_to_backend(%{backend_module: module, backend_ref: ref}, message) do
    module.send_input(ref, message)
  end

  # Write message to file-inbox at {workspace}/.inbox/{seq}_{from}.json
  # This provides a reliable file-based delivery channel for bwrap agents
  # that may not parse stdin JSON messages correctly.
  defp write_file_inbox(state, seq, from, content) do
    workspace = Map.get(state.backend_config, :workspace)

    if workspace && workspace != "" do
      inbox_dir = Path.join(Path.expand(workspace), ".inbox")

      try do
        File.mkdir_p!(inbox_dir)

        filename = String.pad_leading(Integer.to_string(seq), 4, "0") <> "_#{from}.json"
        file_path = Path.join(inbox_dir, filename)

        msg_data =
          Jason.encode!(%{
            from: from,
            content: content,
            seq: seq,
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        File.write!(file_path, msg_data)
      rescue
        e ->
          Logger.debug(
            "[#{state.swarm_name}/#{state.name}] File-inbox write failed: #{inspect(e)}"
          )
      end
    end
  end

  defp prepare_skills(state) do
    skills_base =
      Application.get_env(:genswarms, :swarm_data_dir, "~/.subzeroclaw/swarms")

    skills_dir = Path.expand("#{skills_base}/#{state.swarm_name}/#{state.name}/skills")

    File.mkdir_p!(skills_dir)

    # Copy skills - handle absolute, relative (./), and simple paths
    priv_skills = Application.get_env(:genswarms, :skills_dir, "priv/skills")
    project_root = Application.get_env(:genswarms, :project_root) || File.cwd!()

    Enum.each(state.skills, fn skill_file ->
      # Resolve the source path
      src =
        cond do
          # Absolute path
          String.starts_with?(skill_file, "/") ->
            skill_file

          # Relative path (./something or ../something)
          String.starts_with?(skill_file, ".") ->
            Path.expand(skill_file, project_root)

          # Simple filename - look in priv/skills
          true ->
            Path.join(priv_skills, skill_file)
        end

      # Use basename for the destination
      dst = Path.join(skills_dir, Path.basename(skill_file))

      # Create parent directory if needed
      File.mkdir_p!(Path.dirname(dst))

      if File.exists?(src) do
        # Copy and resolve template variables
        content = File.read!(src)
        workspace = Map.get(state.backend_config, :workspace, "")

        resolved =
          content
          |> String.replace("{{agent_name}}", to_string(state.name))
          |> String.replace("{{swarm_name}}", to_string(state.swarm_name))
          |> String.replace("{{workspace}}", to_string(workspace))

        File.write!(dst, resolved)
        Logger.debug("[#{state.swarm_name}/#{state.name}] Copied skill: #{src} -> #{dst}")
      else
        Logger.warning("Skill file not found: #{src}")
      end
    end)

    skills_dir
  end

  # Parse subzeroclaw log file format
  # Format: [timestamp] ROLE: content
  # Roles: USER, TOOL, RES, ASST, COMPACT, SYS
  defp parse_subzeroclaw_log(content, session_id) do
    lines = String.split(content, "\n")

    # Skip header line (=== session_id timestamp)
    lines = Enum.drop_while(lines, &String.starts_with?(&1, "==="))

    # Parse entries - they can be multi-line
    parse_log_entries(lines, session_id, [])
  end

  defp parse_log_entries([], _session_id, acc), do: Enum.reverse(acc)

  defp parse_log_entries([line | rest], session_id, acc) do
    # Try to match [timestamp] ROLE: content
    case Regex.run(~r/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (\w+): (.*)$/, line) do
      [_, timestamp, role, content] ->
        # Collect continuation lines (lines that don't start with [timestamp])
        {continuation, remaining} =
          Enum.split_while(rest, fn l ->
            not Regex.match?(~r/^\[\d{4}-\d{2}-\d{2}/, l) and l != ""
          end)

        full_content = [content | continuation] |> Enum.join("\n")

        entry = %{
          session_id: session_id,
          timestamp: timestamp,
          role: String.downcase(role),
          content: full_content
        }

        parse_log_entries(remaining, session_id, [entry | acc])

      nil ->
        # Skip non-matching lines (empty lines, etc.)
        parse_log_entries(rest, session_id, acc)
    end
  end

  # Detect API errors in agent output
  defp detect_api_error(output) do
    cond do
      String.contains?(output, "401") and String.contains?(output, "Unauthorized") ->
        {:api_key_invalid, "API authentication failed (401 Unauthorized)"}

      String.contains?(output, "invalid_api_key") or String.contains?(output, "Invalid API Key") ->
        {:api_key_invalid, "Invalid API key"}

      (String.contains?(output, "API_KEY") or String.contains?(output, "api_key")) and
          String.contains?(output, "not set") ->
        {:api_key_missing, "API key not configured"}

      String.contains?(output, "SUBZEROCLAW_API_KEY") and String.contains?(output, "required") ->
        {:api_key_missing, "SUBZEROCLAW_API_KEY environment variable required"}

      String.contains?(output, "rate_limit") or String.contains?(output, "Rate limit") or
          String.contains?(output, "429") ->
        {:rate_limit, "API rate limit exceeded"}

      String.contains?(output, "insufficient_quota") or String.contains?(output, "quota exceeded") ->
        {:quota_exceeded, "API quota exceeded"}

      true ->
        nil
    end
  end

  defp emit_telemetry(event, state, metadata) do
    :telemetry.execute(
      [:genswarms, :agent, event],
      %{time: System.system_time()},
      Map.merge(metadata, %{agent: state.name, swarm: state.swarm_name})
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Cancel a pending awaiting-reply timer if one exists.
  defp cancel_awaiting_timer(nil), do: :ok
  defp cancel_awaiting_timer(ref), do: Process.cancel_timer(ref)
end
