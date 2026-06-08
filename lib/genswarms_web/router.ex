defmodule GenswarmsWeb.Router do
  use GenswarmsWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    # Origins are restricted to an allowlist resolved at request time from
    # GENSWARMS_CORS_ORIGINS (defaults to local dev origins). See GenswarmsWeb.Cors.
    plug Corsica,
      origins: {GenswarmsWeb.Cors, :allowed_origin?, []},
      allow_headers: :all,
      allow_methods: :all

    # Corsica handles (and halts) CORS preflight OPTIONS before this point, so
    # authentication only applies to actual API requests.
    plug GenswarmsWeb.Plugs.ApiAuth
  end

  # API root - returns API info
  scope "/", GenswarmsWeb do
    pipe_through :api

    get "/", ApiController, :index
  end

  scope "/api", GenswarmsWeb do
    pipe_through :api

    # Swarm management
    get "/swarms", SwarmController, :index
    post "/swarms", SwarmController, :create
    get "/swarms/:name", SwarmController, :show
    delete "/swarms/:name", SwarmController, :delete

    # Swarm lifecycle operations
    post "/swarms/:name/pause", SwarmController, :pause
    post "/swarms/:name/resume", SwarmController, :resume
    post "/swarms/:name/restart", SwarmController, :restart
    post "/swarms/:name/message", SwarmController, :route_message

    # Bulk operations
    post "/swarms/clean", SwarmController, :clean

    # Agent operations
    get "/swarms/:swarm_name/agents", SwarmController, :list_agents
    get "/swarms/:swarm_name/agents/:agent_name", SwarmController, :show_agent
    post "/swarms/:swarm_name/agents/:agent_name/task", SwarmController, :send_task
    post "/swarms/:swarm_name/agents/:agent_name/restart", SwarmController, :restart_agent
    get "/swarms/:swarm_name/agents/:agent_name/history", SwarmController, :agent_history
    get "/swarms/:swarm_name/agents/:agent_name/logs", SwarmController, :agent_logs
    get "/swarms/:swarm_name/agents/:agent_name/skills", SwarmController, :agent_skills

    put "/swarms/:swarm_name/agents/:agent_name/skills/:skill_name",
        SwarmController,
        :update_skill

    # Topology (read + mutation)
    get "/swarms/:swarm_name/topology", SwarmController, :topology
    patch "/swarms/:swarm_name/topology", SwarmController, :patch_topology

    # Dynamic agents and objects
    post "/swarms/:swarm_name/agents", SwarmController, :add_agent
    delete "/swarms/:swarm_name/agents/:agent_name", SwarmController, :remove_agent
    post "/swarms/:swarm_name/agents/:base_name/scale", SwarmController, :scale_agent_group
    post "/swarms/:swarm_name/objects", SwarmController, :add_object
    delete "/swarms/:swarm_name/objects/:object_name", SwarmController, :remove_object

    # Object introspection (read-only live state)
    get "/swarms/:swarm_name/objects", SwarmController, :list_objects
    get "/swarms/:swarm_name/objects/:object_name", SwarmController, :show_object

    # Overlay
    get "/swarms/:swarm_name/overlay", SwarmController, :show_overlay
    delete "/swarms/:swarm_name/overlay", SwarmController, :clear_overlay
    post "/swarms/:swarm_name/snapshot", SwarmController, :snapshot

    # Messages
    get "/swarms/:swarm_name/messages", SwarmController, :messages

    # Events (centralized logging)
    get "/events", EventsController, :index
    get "/swarms/:swarm_name/events", EventsController, :swarm_events
    get "/swarms/:swarm_name/agents/:agent_name/events", EventsController, :agent_events

    # Skills
    get "/skills", SkillsController, :index
    get "/skills/:name", SkillsController, :show

    # Config validation
    post "/config/validate", ConfigController, :validate
  end
end
