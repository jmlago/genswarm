# Use a temp SQLite DB for tests to avoid clobbering the dev .swarm/swarms.db
test_db = Path.join(System.tmp_dir!(), "subzero_swarm_test_#{System.unique_integer([:positive])}.db")
test_events = Path.join(System.tmp_dir!(), "subzero_swarm_test_events_#{System.unique_integer([:positive])}")
Application.put_env(:genswarm, :db_path, test_db)
Application.put_env(:genswarm, :events_dir, test_events)

ExUnit.after_suite(fn _ ->
  File.rm(test_db)
  File.rm_rf(test_events)
end)

ExUnit.start()
