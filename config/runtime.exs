import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# temporary config files are read.

# Only configure web endpoint if running as a server (not as CLI escript)
# PHX_SERVER=true indicates we want the web server
if config_env() == :prod and System.get_env("PHX_SERVER") == "true" do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Bind to loopback by default so a fresh deployment is not exposed on every
  # interface. Set GENSWARMS_HTTP_IP (e.g. "0.0.0.0" or "::") to widen exposure
  # — pair that with GENSWARMS_API_TOKEN (see Genswarms.Auth).
  bind_ip = Genswarms.Config.NetConfig.bind_ip(System.get_env("GENSWARMS_HTTP_IP"))

  config :genswarms, GenswarmsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: bind_ip,
      port: port
    ],
    secret_key_base: secret_key_base
end

# Genswarms runtime configuration
config :genswarms,
  subzeroclaw_path: System.get_env("SUBZEROCLAW_PATH", "subzeroclaw"),
  swarm_data_dir: System.get_env("SWARM_DATA_DIR", "~/.subzeroclaw/swarms"),
  skills_dir: System.get_env("SKILLS_DIR", "priv/skills")
