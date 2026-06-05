# Use a temp SQLite DB for tests to avoid clobbering the dev .genswarms/swarms.db
test_db =
  Path.join(System.tmp_dir!(), "subzero_swarm_test_#{System.unique_integer([:positive])}.db")

test_events =
  Path.join(System.tmp_dir!(), "subzero_swarm_test_events_#{System.unique_integer([:positive])}")

Application.put_env(:genswarms, :db_path, test_db)
Application.put_env(:genswarms, :events_dir, test_events)

ExUnit.after_suite(fn _ ->
  File.rm(test_db)
  File.rm_rf(test_events)
end)

# Start the Phoenix endpoint (server: false in test) so Phoenix.ConnTest can
# dispatch requests in-process for controller tests.
case Supervisor.start_child(Genswarms.Supervisor, GenswarmsWeb.Endpoint) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start()
