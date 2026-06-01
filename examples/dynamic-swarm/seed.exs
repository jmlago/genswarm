# Minimal seed for the dynamic-swarm demo.
#
# This is intentionally tiny — the demo grows the swarm at runtime via
# SwarmManager.add_agent, add_object, and scale_agent_group.
#
# Backend is :mock so the example runs without an LLM provider.

%{
  name: "dynamic-demo",
  agents: [
    %{name: :worker_1, backend: :mock}
  ],
  objects: [],
  topology: []
}
