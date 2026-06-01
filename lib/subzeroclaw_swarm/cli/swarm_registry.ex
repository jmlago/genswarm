defmodule SubzeroclawSwarm.CLI.SwarmRegistry do
  @moduledoc """
  SQLite-backed registry for tracking running swarms.

  Stores swarm state independently of any running process, allowing the CLI
  to query and manage swarms without requiring the dashboard.

  ## Database Schema

      swarms:
        - name (primary key)
        - status: running | stopped | crashed
        - pid: OS process ID
        - config_path: path to config file
        - log_path: path to event log file
        - started_at: timestamp
        - stopped_at: timestamp (nullable)
  """

  @db_path ".swarm/swarms.db"
  @events_dir ".swarm/events"

  # Open database with busy timeout for concurrency
  defp open_db do
    {:ok, db} = Exqlite.Sqlite3.open(db_path())
    # Set busy timeout to wait up to 5 seconds if database is locked
    Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout=5000")
    {:ok, db}
  end

  @doc """
  Ensures the database and tables exist.
  """
  def init do
    ensure_dir()
    {:ok, db} = open_db()

    # Enable WAL mode for better concurrency (allows concurrent reads while writing)
    Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout=5000")

    Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS swarms (
        name TEXT PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'stopped',
        pid INTEGER,
        config_path TEXT,
        log_path TEXT,
        started_at TEXT,
        stopped_at TEXT
      )
    """)

    Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        level TEXT NOT NULL,
        category TEXT NOT NULL,
        swarm TEXT,
        agent TEXT,
        event_type TEXT NOT NULL,
        message TEXT NOT NULL,
        metadata TEXT
      )
    """)

    Exqlite.Sqlite3.execute(db, """
      CREATE INDEX IF NOT EXISTS idx_events_swarm ON events(swarm)
    """)

    Exqlite.Sqlite3.execute(db, """
      CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)
    """)

    # Tasks table for cross-process task delivery
    Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        swarm TEXT NOT NULL,
        agent TEXT NOT NULL,
        task TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        processed_at TEXT
      )
    """)

    Exqlite.Sqlite3.execute(db, """
      CREATE INDEX IF NOT EXISTS idx_tasks_pending ON tasks(swarm, status) WHERE status = 'pending'
    """)

    # Swarm overlays (dynamic mutation event log)
    Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS swarm_overlays (
        swarm TEXT NOT NULL,
        seq INTEGER NOT NULL,
        op TEXT NOT NULL,
        payload TEXT NOT NULL,
        applied_at TEXT NOT NULL,
        PRIMARY KEY (swarm, seq)
      )
    """)

    Exqlite.Sqlite3.execute(db, """
      CREATE INDEX IF NOT EXISTS idx_overlays_swarm ON swarm_overlays(swarm, seq)
    """)

    # Swarm commands (CLI → daemon bridge)
    Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS swarm_commands (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        swarm TEXT NOT NULL,
        op TEXT NOT NULL,
        payload TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        result TEXT,
        created_at TEXT NOT NULL,
        processed_at TEXT
      )
    """)

    Exqlite.Sqlite3.execute(db, """
      CREATE INDEX IF NOT EXISTS idx_commands_pending ON swarm_commands(swarm, status) WHERE status = 'pending'
    """)

    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Queues a task for an agent in a daemon swarm.
  """
  def queue_task(swarm_name, agent_name, task) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        INSERT INTO tasks (swarm, agent, task, status, created_at)
        VALUES (?, ?, ?, 'pending', datetime('now', 'subsec'))
      """)

    Exqlite.Sqlite3.bind(stmt, [swarm_name, to_string(agent_name), task])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Gets pending tasks for a swarm.
  """
  def get_pending_tasks(swarm_name) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        SELECT id, agent, task FROM tasks
        WHERE swarm = ? AND status = 'pending'
        ORDER BY created_at ASC
      """)

    Exqlite.Sqlite3.bind(stmt, [swarm_name])
    tasks = collect_task_rows(db, stmt, [])

    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    tasks
  end

  @doc """
  Marks a task as processed.
  """
  def mark_task_processed(task_id) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        UPDATE tasks SET status = 'processed', processed_at = datetime('now', 'subsec')
        WHERE id = ?
      """)

    Exqlite.Sqlite3.bind(stmt, [task_id])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  defp collect_task_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [id, agent, task]} ->
        row = %{id: id, agent: String.to_atom(agent), task: task}
        collect_task_rows(db, stmt, [row | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  @doc """
  Registers a swarm as starting.
  """
  def register_swarm(name, pid, config_path) do
    ensure_dir()
    log_path = Path.join(events_dir(), "#{name}.log")
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        INSERT OR REPLACE INTO swarms (name, status, pid, config_path, log_path, started_at, stopped_at)
        VALUES (?, 'running', ?, ?, ?, datetime('now'), NULL)
      """)

    Exqlite.Sqlite3.bind(stmt, [name, pid, config_path, log_path])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    {:ok, log_path}
  end

  @doc """
  Marks a swarm as stopped.
  """
  def mark_stopped(name) do
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        UPDATE swarms SET status = 'stopped', stopped_at = datetime('now'), pid = NULL
        WHERE name = ?
      """)

    Exqlite.Sqlite3.bind(stmt, [name])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Deletes a swarm and all its data from the registry.
  This removes the swarm entry, all events, and all pending tasks.
  """
  def delete_swarm(name) do
    ensure_db_exists()
    {:ok, db} = open_db()

    # Delete from swarms table
    {:ok, stmt1} = Exqlite.Sqlite3.prepare(db, "DELETE FROM swarms WHERE name = ?")
    Exqlite.Sqlite3.bind(stmt1, [name])
    Exqlite.Sqlite3.step(db, stmt1)
    Exqlite.Sqlite3.release(db, stmt1)

    # Delete events for this swarm
    {:ok, stmt2} = Exqlite.Sqlite3.prepare(db, "DELETE FROM events WHERE swarm = ?")
    Exqlite.Sqlite3.bind(stmt2, [name])
    Exqlite.Sqlite3.step(db, stmt2)
    Exqlite.Sqlite3.release(db, stmt2)

    # Delete pending tasks for this swarm
    {:ok, stmt3} = Exqlite.Sqlite3.prepare(db, "DELETE FROM tasks WHERE swarm = ?")
    Exqlite.Sqlite3.bind(stmt3, [name])
    Exqlite.Sqlite3.step(db, stmt3)
    Exqlite.Sqlite3.release(db, stmt3)

    # Delete overlay events for this swarm
    {:ok, stmt4} = Exqlite.Sqlite3.prepare(db, "DELETE FROM swarm_overlays WHERE swarm = ?")
    Exqlite.Sqlite3.bind(stmt4, [name])
    Exqlite.Sqlite3.step(db, stmt4)
    Exqlite.Sqlite3.release(db, stmt4)

    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Deletes all files associated with a swarm.
  This includes log files and swarm data directories.
  """
  def delete_swarm_files(name) do
    # Delete .swarm/logs/<name>.log
    log_file = Path.join([File.cwd!(), ".swarm", "logs", "#{name}.log"])
    if File.exists?(log_file), do: File.rm(log_file)

    # Delete ~/.subzeroclaw/swarms/<name>/
    swarm_dir = Path.join([System.user_home!(), ".subzeroclaw", "swarms", name])
    if File.exists?(swarm_dir), do: File.rm_rf(swarm_dir)

    :ok
  end

  @doc """
  Clears all events from the database.
  """
  def clear_all_events do
    ensure_db_exists()
    {:ok, db} = open_db()

    Exqlite.Sqlite3.execute(db, "DELETE FROM events")
    Exqlite.Sqlite3.execute(db, "DELETE FROM tasks")

    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Marks a swarm as crashed.
  """
  def mark_crashed(name) do
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        UPDATE swarms SET status = 'crashed', stopped_at = datetime('now')
        WHERE name = ?
      """)

    Exqlite.Sqlite3.bind(stmt, [name])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Gets info about a swarm.
  """
  def get_swarm(name) do
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        SELECT name, status, pid, config_path, log_path, started_at, stopped_at
        FROM swarms WHERE name = ?
      """)

    Exqlite.Sqlite3.bind(stmt, [name])

    result =
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, row} ->
          [name, status, pid, config_path, log_path, started_at, stopped_at] = row

          {:ok,
           %{
             name: name,
             status: String.to_atom(status),
             pid: pid,
             config_path: config_path,
             log_path: log_path,
             started_at: started_at,
             stopped_at: stopped_at
           }}

        :done ->
          {:error, :not_found}
      end

    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    result
  end

  @doc """
  Lists all swarms.
  """
  def list_swarms do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        SELECT name, status, pid, config_path, log_path, started_at, stopped_at
        FROM swarms ORDER BY started_at DESC
      """)

    swarms = collect_rows(db, stmt, [])

    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    swarms
  end

  @doc """
  Lists running swarms (verifies PIDs are alive).
  """
  def list_running do
    list_swarms()
    |> Enum.filter(fn s -> s.status == :running and process_alive?(s.pid) end)
  end

  @doc """
  Logs an event to SQLite.
  """
  def log_event(level, category, event_type, message, opts \\ []) do
    ensure_db_exists()
    {:ok, db} = open_db()

    swarm = Keyword.get(opts, :swarm)
    agent = Keyword.get(opts, :agent)
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        INSERT INTO events (timestamp, level, category, swarm, agent, event_type, message, metadata)
        VALUES (datetime('now', 'subsec'), ?, ?, ?, ?, ?, ?, ?)
      """)

    Exqlite.Sqlite3.bind(stmt, [
      to_string(level),
      to_string(category),
      swarm,
      if(agent, do: to_string(agent), else: nil),
      to_string(event_type),
      message,
      Jason.encode!(metadata)
    ])

    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Queries events from SQLite.
  """
  def query_events(opts \\ []) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {where_clauses, params} = build_where_clauses(opts)
    limit = Keyword.get(opts, :limit, 50)

    where_sql =
      if where_clauses == [], do: "", else: "WHERE " <> Enum.join(where_clauses, " AND ")

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        SELECT id, timestamp, level, category, swarm, agent, event_type, message, metadata
        FROM events #{where_sql}
        ORDER BY timestamp DESC
        LIMIT #{limit}
      """)

    Exqlite.Sqlite3.bind(stmt, params)
    events = collect_event_rows(db, stmt, [])

    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    events
  end

  @doc """
  Checks if a process is alive by PID.
  """
  def process_alive?(nil), do: false

  def process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Cleans up stale entries (marks crashed if PID is dead).
  """
  def cleanup_stale do
    list_swarms()
    |> Enum.filter(fn s -> s.status == :running and not process_alive?(s.pid) end)
    |> Enum.each(fn s -> mark_crashed(s.name) end)
  end

  # -- Swarm commands (CLI/REST → daemon bridge) --

  @doc """
  Enqueues a command to be processed by the daemon owning a swarm.
  Returns the command ID.
  """
  @spec enqueue_command(String.t(), atom(), map()) :: {:ok, integer()}
  def enqueue_command(swarm_name, op, payload) do
    ensure_db_exists()
    {:ok, db} = open_db()

    encoded = Jason.encode!(encode_overlay_value(payload))

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        INSERT INTO swarm_commands (swarm, op, payload, status, created_at)
        VALUES (?, ?, ?, 'pending', datetime('now', 'subsec'))
      """)

    Exqlite.Sqlite3.bind(stmt, [swarm_name, to_string(op), encoded])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)

    {:ok, [[id]]} = Exqlite.Sqlite3.fetch_all(db, last_insert_rowid_stmt(db))
    Exqlite.Sqlite3.close(db)
    {:ok, id}
  end

  @doc """
  Returns all pending commands for a daemon to process.
  """
  @spec get_pending_commands(String.t()) :: [%{id: integer(), op: atom(), payload: map()}]
  def get_pending_commands(swarm_name) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        SELECT id, op, payload FROM swarm_commands
        WHERE swarm = ? AND status = 'pending'
        ORDER BY created_at ASC
      """)

    Exqlite.Sqlite3.bind(stmt, [swarm_name])
    rows = collect_command_rows(db, stmt, [])

    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    rows
  end

  @doc """
  Marks a command as processed, storing the result (encoded as JSON string).
  """
  @spec mark_command_done(integer(), term()) :: :ok
  def mark_command_done(command_id, result) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        UPDATE swarm_commands
        SET status = 'done', result = ?, processed_at = datetime('now', 'subsec')
        WHERE id = ?
      """)

    Exqlite.Sqlite3.bind(stmt, [Jason.encode!(encode_overlay_value(result)), command_id])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Fetches a command result by ID. Returns nil if still pending or unknown.
  """
  @spec get_command_result(integer()) :: {atom(), term()} | nil
  def get_command_result(command_id) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, "SELECT status, result FROM swarm_commands WHERE id = ?")

    Exqlite.Sqlite3.bind(stmt, [command_id])

    result =
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, [status, nil]} -> {String.to_atom(status), nil}
        {:row, [status, result_json]} ->
          {String.to_atom(status), result_json |> Jason.decode!() |> decode_overlay_value()}
        :done -> nil
      end

    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    result
  end

  defp collect_command_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [id, op, payload_json]} ->
        payload = payload_json |> Jason.decode!() |> decode_overlay_value()
        row = %{id: id, op: String.to_atom(op), payload: payload}
        collect_command_rows(db, stmt, [row | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp last_insert_rowid_stmt(db) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT last_insert_rowid()")
    stmt
  end

  # -- Overlay (dynamic swarm event log) --

  @doc """
  Appends an event to a swarm's overlay log.
  """
  @spec append_overlay(String.t(), atom(), map()) :: :ok
  def append_overlay(swarm_name, op, payload) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        INSERT INTO swarm_overlays (swarm, seq, op, payload, applied_at)
        VALUES (?, COALESCE((SELECT MAX(seq) FROM swarm_overlays WHERE swarm = ?), 0) + 1,
                ?, ?, datetime('now', 'subsec'))
      """)

    encoded_payload = Jason.encode!(encode_overlay_value(payload))

    Exqlite.Sqlite3.bind(stmt, [swarm_name, swarm_name, to_string(op), encoded_payload])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  @doc """
  Loads all overlay events for a swarm in order.
  Returns `[{op, payload}]`.
  """
  @spec load_overlay(String.t()) :: [{atom(), map()}]
  def load_overlay(swarm_name) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
        SELECT op, payload FROM swarm_overlays
        WHERE swarm = ?
        ORDER BY seq ASC
      """)

    Exqlite.Sqlite3.bind(stmt, [swarm_name])
    events = collect_overlay_rows(db, stmt, [])

    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    events
  end

  @doc """
  Clears the overlay for a swarm.
  """
  @spec clear_overlay(String.t()) :: :ok
  def clear_overlay(swarm_name) do
    ensure_db_exists()
    {:ok, db} = open_db()

    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "DELETE FROM swarm_overlays WHERE swarm = ?")
    Exqlite.Sqlite3.bind(stmt, [swarm_name])
    Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    :ok
  end

  defp collect_overlay_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [op, payload_json]} ->
        payload = payload_json |> Jason.decode!() |> decode_overlay_value()
        collect_overlay_rows(db, stmt, [{String.to_atom(op), payload} | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  # Serialization: atoms get a "~" prefix, tuples become lists.
  # Anonymous functions raise.
  defp encode_overlay_value(value) when is_atom(value) and value not in [nil, true, false] do
    "~" <> Atom.to_string(value)
  end

  defp encode_overlay_value(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&encode_overlay_value/1)
  end

  defp encode_overlay_value(value) when is_list(value) do
    Enum.map(value, &encode_overlay_value/1)
  end

  defp encode_overlay_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {encode_overlay_key(k), encode_overlay_value(v)} end)
    |> Map.new()
  end

  defp encode_overlay_value(value) when is_function(value) do
    raise ArgumentError, "Cannot serialize function in overlay payload"
  end

  defp encode_overlay_value(value), do: value

  defp encode_overlay_key(k) when is_atom(k), do: "~" <> Atom.to_string(k)
  defp encode_overlay_key(k), do: k

  defp decode_overlay_value("~" <> rest) do
    String.to_atom(rest)
  end

  defp decode_overlay_value(value) when is_list(value) do
    Enum.map(value, &decode_overlay_value/1)
  end

  defp decode_overlay_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {decode_overlay_key(k), decode_overlay_value(v)} end)
    |> Map.new()
  end

  defp decode_overlay_value(value), do: value

  defp decode_overlay_key("~" <> rest), do: String.to_atom(rest)
  defp decode_overlay_key(k), do: k

  # Private

  defp db_path do
    case Application.get_env(:subzeroclaw_swarm, :db_path) do
      nil -> Path.join(File.cwd!(), @db_path)
      path -> Path.expand(path)
    end
  end

  defp events_dir do
    case Application.get_env(:subzeroclaw_swarm, :events_dir) do
      nil -> Path.join(File.cwd!(), @events_dir)
      path -> Path.expand(path)
    end
  end

  defp ensure_dir do
    File.mkdir_p!(Path.dirname(db_path()))
    File.mkdir_p!(events_dir())
  end

  defp ensure_db_exists do
    # init() is idempotent (CREATE TABLE IF NOT EXISTS), so we always run it
    # to pick up schema additions (e.g. swarm_overlays added in a later release)
    # if the DB file pre-existed without them.
    init()
  end

  defp collect_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [name, status, pid, config_path, log_path, started_at, stopped_at]} ->
        row = %{
          name: name,
          status: String.to_atom(status),
          pid: pid,
          config_path: config_path,
          log_path: log_path,
          started_at: started_at,
          stopped_at: stopped_at
        }

        collect_rows(db, stmt, [row | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp collect_event_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [id, timestamp, level, category, swarm, agent, event_type, message, metadata]} ->
        row = %{
          id: id,
          timestamp: timestamp,
          level: String.to_atom(level),
          category: String.to_atom(category),
          swarm: swarm,
          agent: if(agent, do: String.to_atom(agent), else: nil),
          event_type: String.to_atom(event_type),
          message: message,
          metadata: Jason.decode!(metadata || "{}")
        }

        collect_event_rows(db, stmt, [row | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp build_where_clauses(opts) do
    clauses = []
    params = []

    {clauses, params} =
      if opts[:swarm] do
        {clauses ++ ["swarm = ?"], params ++ [opts[:swarm]]}
      else
        {clauses, params}
      end

    {clauses, params} =
      if opts[:agent] do
        {clauses ++ ["agent = ?"], params ++ [to_string(opts[:agent])]}
      else
        {clauses, params}
      end

    {clauses, params} =
      if opts[:category] do
        {clauses ++ ["category = ?"], params ++ [to_string(opts[:category])]}
      else
        {clauses, params}
      end

    {clauses, params} =
      if opts[:level] do
        {clauses ++ ["level = ?"], params ++ [to_string(opts[:level])]}
      else
        {clauses, params}
      end

    {clauses, params} =
      if opts[:event_type] do
        {clauses ++ ["event_type = ?"], params ++ [to_string(opts[:event_type])]}
      else
        {clauses, params}
      end

    {clauses, params} =
      if opts[:minutes] do
        {clauses ++ ["timestamp >= datetime('now', ?)"], params ++ ["-#{opts[:minutes]} minutes"]}
      else
        {clauses, params}
      end

    {clauses, params}
  end
end
