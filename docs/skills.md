# Skills

Skills are markdown files that define an agent's role, capabilities, and behavior. Each agent is assigned a list of skills in its config; when the agent starts, those files are copied into the agent's own skills directory with template variables resolved per agent.

Two components are involved:

- `Genswarms.Skills.SkillsManager` — a GenServer that loads the skills repository (`priv/skills` by default) into an ETS cache on startup and serves skill content over the REST API.
- `Genswarms.Agents.AgentServer` — at agent start, `prepare_skills/1` resolves each skill entry to a source path, substitutes template variables, and writes the result into the agent's per-agent skills directory.

## What a skill is

A skill is a plain markdown file — there is no special schema. Its contents become part of the agent's instructions. A typical skill describes the agent's role, lists capabilities and guidelines, and explains how to communicate with other agents.

```markdown
# My Custom Skill

You are a specialist in [domain]. Your role is to [description].

## Capabilities
- Capability 1
- Capability 2

## Guidelines
1. Guideline 1
2. Guideline 2

## Communication
When communicating with other agents, use the @agent_name: prefix.
```

See [messaging.md](messaging.md) for the `@agent_name:` syntax skills should reference.

## Assigning skills in config

List skills on each agent with the `skills:` key. Plain filenames are resolved against the skills directory (`priv/skills` by default).

```elixir
%{
  name: "example-swarm",
  agents: [
    %{name: :researcher, backend: :local, skills: ["web.md"]},
    %{name: :coder, backend: :local, skills: ["code.md", "review.md"]}
  ],
  topology: [{:researcher, :coder}]
}
```

Each skill entry is resolved to a source path by `AgentServer.prepare_skills/1` in one of three ways:

| Entry form | Resolved against |
|------------|------------------|
| Absolute path (`/opt/skills/custom.md`) | used as-is |
| Relative path starting with `.` (`./skills/custom.md`, `../shared.md`) | the project root (`:project_root` app env, falling back to the current working directory) |
| Anything else — a simple filename (`web.md`) | the skills directory (`priv/skills` by default) |

In every case only the basename (`Path.basename/1`) is used for the destination file inside the agent's skills directory. The agent's skills directory is `<swarm_data_dir>/<swarm>/<agent>/skills`, where `swarm_data_dir` defaults to `~/.subzeroclaw/swarms`.

## Built-in skills

The repository ships these skills in `priv/skills/`:

| Skill | Description |
|-------|-------------|
| `web.md` | Web research specialist — search, summarize, and cite sources |
| `code.md` | Code implementation specialist — write, refactor, debug, and test code |
| `review.md` | Code review specialist — review for correctness, security, and quality |
| `secret.md` | Minimal example skill used in tests |
| `swarm_architect.md` | Designs swarm topologies and agent configurations |
| `swarm-fixer.md` | Diagnoses and repairs swarm issues |

On startup, `SkillsManager` loads every `*.md` file from the skills directory into an ETS cache. The skills directory defaults to `priv/skills` and is configured by the `:skills_dir` application environment key.

> The `:skills_dir` app env key is populated from the `SKILLS_DIR` OS
> environment variable in `config/config.exs` and `config/runtime.exs`
> (`skills_dir: System.get_env("SKILLS_DIR", "priv/skills")`). So setting the
> `SKILLS_DIR` environment variable and setting the `:genswarms, :skills_dir`
> application key are the same thing — `SKILLS_DIR` is the user-facing knob,
> `:skills_dir` is where it lands internally. See
> [getting-started.md](getting-started.md) for the environment variable list.

## Template variables

Skills support template variables that are substituted when the skill is deployed to a specific agent. Resolution happens at agent start, per agent, in `AgentServer.prepare_skills/1` via a literal string replacement of the following tokens:

| Variable | Resolved to |
|----------|-------------|
| `{{agent_name}}` | the agent's name (e.g. `fixer_3`) |
| `{{swarm_name}}` | the swarm name |
| `{{workspace}}` | the agent's workspace path (the `:workspace` backend config key, or `""` if unset) |

These are the only template variables. Any other `{{...}}` token is left untouched.

```markdown
# Fixer Agent

You are {{agent_name}} in the {{swarm_name}} swarm.
Your workspace is {{workspace}}.

Write output files to your workspace directory.
```

## Creating custom skills

Drop a new markdown file into `priv/skills/` (or point an agent at any path using the relative/absolute forms above), then reference it from the agent's `skills:` list.

```bash
# Add a skill file
$ cat > priv/skills/planner.md <<'EOF'
# Planner Skill

You are {{agent_name}}, the planner for {{swarm_name}}.
Break tasks into steps and delegate them with @agent_name: prefixes.
EOF
```

```elixir
%{name: :planner, backend: :local, skills: ["planner.md"]}
```

`SkillsManager.reload_skills/0` clears the ETS cache and reloads every skill from the skills directory on disk, which is useful while iterating during development:

```elixir
Genswarms.Skills.SkillsManager.reload_skills()
```

Note that this refreshes the repository cache used by the REST API; agents copy their skills at start, so already-running agents keep the skill files they were deployed with until they restart.

## Per-agent workspaces

Each agent's workspace is the `workspace` key inside its `config` map (a backend
key — see [configuration.md](configuration.md)). It is mounted read-write into
the sandbox and is where the file-inbox and file-outbox live (see
[messaging.md](messaging.md)).

```elixir
%{
  name: :fixer,
  backend: :bwrap,
  config: %{workspace: "/tmp/example-swarm/fixer"}
}
```

To run a pool of identical agents, scale the group at runtime with
[`genswarms scale`](cli.md) (or `SwarmManager.scale_agent_group/4`, or the scale
REST endpoint). Scaling uses an existing group member's spec as a template and
creates `fixer_1`, `fixer_2`, … Each replica gets its own `workspace`, derived
by `maybe_rename_workspace/4` in `swarm_manager.ex`:

- If the workspace ends with `/` followed by the template agent's name, that
  suffix is replaced with the replica name.
  `/tmp/example-swarm/fixer` → `/tmp/example-swarm/fixer_1`,
  `/tmp/example-swarm/fixer_2`.
- Otherwise the replica name is appended as a path segment (`Path.join/2`).
  `/tmp/example-swarm/work` →
  `/tmp/example-swarm/work/fixer_1`, `/tmp/example-swarm/work/fixer_2`.

Because `{{workspace}}` and `{{agent_name}}` are resolved per instance, a single
templated skill file produces correct, instance-specific instructions across the
whole pool.

> Note: there is no config-time `count:` key. An agent definition always maps to
> one agent; multiple instances come from runtime scaling.

## Skills over the REST API

`SkillsManager` (the repository) and the per-agent skills directories are exposed through the API. See [rest-api.md](rest-api.md) for full request/response details.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/skills` | List available skills in the repository |
| GET | `/api/skills/:name` | Get a skill's content |
| GET | `/api/swarms/:swarm_name/agents/:agent_name/skills` | Get a deployed agent's skills |
| PUT | `/api/swarms/:swarm_name/agents/:agent_name/skills/:skill_name` | Update a deployed agent's skill |

## See also

- [configuration.md](configuration.md) — assigning `skills:` on agents
- [messaging.md](messaging.md) — the `@agent_name:` syntax and `swarm-msg` that skills drive
- [rest-api.md](rest-api.md) — skills endpoints and agent skill management
- [getting-started.md](getting-started.md) — the `SKILLS_DIR` environment variable
