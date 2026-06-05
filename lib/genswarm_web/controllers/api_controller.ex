defmodule GenswarmWeb.ApiController do
  @moduledoc """
  API root controller - returns API information.
  """

  use GenswarmWeb, :controller

  @api_version "1.0.0"

  @doc """
  Returns API information.

  GET /
  """
  def index(conn, _params) do
    json(conn, %{
      name: "Genswarm API",
      version: @api_version,
      description: "AI agent swarm orchestration API",
      endpoints: %{
        swarms: "/api/swarms",
        events: "/api/events",
        skills: "/api/skills",
        config: "/api/config/validate"
      },
      websocket: %{
        url: "/swarm",
        channel: "swarm:{swarm_name}",
        events: %{
          client_to_server: [
            "send_task",
            "get_status",
            "subscribe_logs",
            "unsubscribe_logs",
            "subscribe_events",
            "unsubscribe_events"
          ],
          server_to_client: [
            "agent_output",
            "message_routed",
            "message_broadcast",
            "agent_status",
            "swarm_stopped",
            "log_entry",
            "event"
          ]
        }
      },
      documentation: %{
        swarm_management: [
          %{method: "GET", path: "/api/swarms", description: "List all swarms"},
          %{method: "POST", path: "/api/swarms", description: "Create swarm"},
          %{method: "GET", path: "/api/swarms/:name", description: "Get detailed status"},
          %{method: "DELETE", path: "/api/swarms/:name", description: "Stop swarm (?purge=true to delete all)"},
          %{method: "POST", path: "/api/swarms/:name/pause", description: "Pause containers"},
          %{method: "POST", path: "/api/swarms/:name/resume", description: "Resume containers"},
          %{method: "POST", path: "/api/swarms/:name/restart", description: "Restart (?delete=true for clean)"},
          %{method: "POST", path: "/api/swarms/:name/message", description: "Route message between agents"},
          %{method: "POST", path: "/api/swarms/clean", description: "Clean stopped/crashed (?all=true to clear events)"}
        ],
        agent_operations: [
          %{method: "GET", path: "/api/swarms/:name/agents", description: "List agents"},
          %{method: "GET", path: "/api/swarms/:name/agents/:agent", description: "Get agent status"},
          %{method: "POST", path: "/api/swarms/:name/agents/:agent/task", description: "Send task"},
          %{method: "POST", path: "/api/swarms/:name/agents/:agent/restart", description: "Restart agent"},
          %{method: "GET", path: "/api/swarms/:name/agents/:agent/logs", description: "Get logs"},
          %{method: "GET", path: "/api/swarms/:name/agents/:agent/history", description: "Get history"},
          %{method: "GET", path: "/api/swarms/:name/agents/:agent/skills", description: "Get skills"},
          %{method: "PUT", path: "/api/swarms/:name/agents/:agent/skills/:skill", description: "Update skill"}
        ],
        topology_events: [
          %{method: "GET", path: "/api/swarms/:name/topology", description: "Get topology"},
          %{method: "GET", path: "/api/swarms/:name/messages", description: "Get message log"},
          %{method: "GET", path: "/api/events", description: "Query events (with filters)"},
          %{method: "GET", path: "/api/swarms/:name/events", description: "Swarm events"}
        ],
        skills_config: [
          %{method: "GET", path: "/api/skills", description: "List available skills"},
          %{method: "GET", path: "/api/skills/:name", description: "Get skill content"},
          %{method: "POST", path: "/api/config/validate", description: "Validate config"}
        ]
      }
    })
  end
end
