---
date: 2026-06-06
authors: [genlayer]
categories: [Guides]
slug: set-up-a-genswarm-with-your-agent
description: >-
  Don't read the docs — hand your coding agent the GenSwarms skill and let it
  install, configure, and launch a swarm for you.
---

# Don't read the docs — let your agent run the swarm

The fastest way to stand up your first GenSwarm isn't to read a getting-started
guide. It's to hand that guide to an agent.

GenSwarms ships a single canonical **skill** — a structured markdown file that
teaches a coding agent how to operate the framework end to end: build the CLI,
write a swarm config, start the daemon, send tasks, and watch events stream back.
Point your agent at it and ask for a swarm. It does the rest.

<!-- more -->

## The idea

A *skill* is just a markdown file with a bit of front matter — the
[Anthropic Agent Skills][skills] format. GenSwarms keeps one at the repo root,
[`SKILL.md`][skillmd]. Its front matter tells an agent exactly when to reach for
it:

```yaml
name: operating-genswarms
description: Operate and orchestrate genswarms agent swarms — author swarm
  configs, build the CLI, and start/manage/observe/scale swarms via the
  genswarms CLI or REST API.
```

The body is the operator's quick path: prerequisites, a bring-up checklist, a
minimal config, the essential commands, and the gotchas that trip people up. It's
written to be *consumed by a model*, not skimmed by a human — so the highest-value
move is to let the model consume it.

## What you need first

The agent will build and run things for you, but two things have to exist on your
machine:

- **Elixir 1.14+ / Erlang OTP 27+** — or [Nix][nix], which the repo pins for you
  (`nix develop`).
- **A `SUBZEROCLAW_API_KEY`** — your LLM provider key, so the agents in the swarm
  can actually think.

That's it. Everything else — building the `genswarms` binary, scaffolding a
project, writing the config — is what the agent handles.

## Option A — hand the agent the skill once

If you're already working in the GenSwarms repo with a coding agent (Claude Code,
or anything that can read files and run commands), just tell it to read the skill
and go. Paste this:

```text
Read SKILL.md in this repo and use it to set up and run a GenSwarm.
I want two agents — a "researcher" and a "coder" — wired so the researcher
can hand work to the coder. Build the CLI, write the config, start the swarm,
send the researcher a test task, and show me the live logs.
```

Not in the repo yet? Point it at the raw file — any agent that can fetch a URL
will do:

```text
Read https://raw.githubusercontent.com/genlayerlabs/genswarms/main/SKILL.md
and follow it to clone genswarms, then set up and launch a small swarm.
```

## Option B — install it as a reusable skill

If your agent supports [Agent Skills][skills] (Claude Code does), install the
skill once and it becomes available automatically — the agent pulls it in
whenever you talk about running a swarm, no copy-paste required:

```bash
# personal skill, available in every project
mkdir -p ~/.claude/skills/operating-genswarms
curl -sL https://raw.githubusercontent.com/genlayerlabs/genswarms/main/SKILL.md \
  -o ~/.claude/skills/operating-genswarms/SKILL.md
```

Now just ask, in plain language:

```text
Set up a GenSwarm with a researcher and a coder and give the researcher a task.
```

The agent recognizes the skill from its description, loads it, and follows the
same path.

## What the agent actually does

Whichever route you take, the skill walks the agent through the same bring-up.
Under the hood it's running these — handy to know so you can follow along:

```bash
# build the CLI and scaffold a project
mix deps.get && mix escript.build      # produces ./genswarms
genswarms init my-swarm && cd my-swarm
cp .env.example .env                   # drop in SUBZEROCLAW_API_KEY

# validate, then launch
genswarms config validate swarms/example_swarm.exs
genswarms up                           # optional API server (REST + WebSocket)
genswarms start swarms/example_swarm.exs

# drive it
genswarms status example-swarm
genswarms task example-swarm researcher "Find recent papers on agent swarms"
genswarms logs example-swarm -f        # live stream of messages, crashes, restarts
```

The config it writes is a small declarative map — agents, optional deterministic
objects, and a directed topology that says who may talk to whom:

```elixir
%{
  name: "example-swarm",
  agents: [
    %{name: :researcher, backend: :local, skills: ["web.md"]},
    %{name: :coder,      backend: :local, skills: ["code.md"]}
  ],
  topology: [
    {:researcher, :coder}   # researcher may hand work to coder
  ]
}
```

From here the swarm is live: tasks flow along the topology, each agent runs as an
isolated worker, and if one crashes the runtime restarts it without taking down
the rest.

## Why this works

GenSwarms is a *declared* runtime — agents are unpredictable, but the swarm around
them is explicit, observable, and recoverable. That structure is exactly what
makes it safe to let an agent operate: the config is a small, reviewable artifact,
every action shows up in the event stream, and nothing happens that you can't see
or stop.

So the loop closes nicely — you use one agent to set up a swarm of agents, and you
can read back everything it did.

## Next steps

- [Getting started](../../getting-started.md) — the full human walkthrough.
- [Configuration](../../configuration.md) — the swarm DSL in depth.
- [CLI reference](../../cli.md) — every command and flag.
- [`SKILL.md` on GitHub][skillmd] — the skill itself.

[skills]: https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview
[skillmd]: https://github.com/genlayerlabs/genswarms/blob/main/SKILL.md
[nix]: https://nixos.org/download
