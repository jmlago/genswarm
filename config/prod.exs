import Config

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration
config :genswarm, GenswarmWeb.Endpoint, server: true
