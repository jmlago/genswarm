# General application configuration
import Config

config :genswarm,
  ecto_repos: [],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :genswarm, GenswarmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: GenswarmWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Genswarm.PubSub

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :swarm, :agent]

# Use Jason for JSON parsing
config :phoenix, :json_library, Jason

# Durable cross-process event store backend (see Genswarm.Observability.EventStore).
# Swap to a Postgres/Redis/batching backend here as load grows.
config :genswarm, :event_store, Genswarm.Observability.EventStore.Sqlite

# Genswarm specific configuration
config :genswarm,
  # Default path to subzeroclaw binary
  subzeroclaw_path: System.get_env("SUBZEROCLAW_PATH", "subzeroclaw"),
  # Base directory for swarm data
  swarm_data_dir: System.get_env("SWARM_DATA_DIR", "~/.subzeroclaw/swarms"),
  # Default skills directory
  skills_dir: System.get_env("SKILLS_DIR", "priv/skills")

# Import environment specific config
import_config "#{config_env()}.exs"
