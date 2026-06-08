---
description: The GenSwarms Intermediate Representation (IR) — swarm.state and swarm.overlay, the pure data model that validates, mutates, and drives swarms, and the default control-plane gate.
---

# Intermediate representation (IR)

The **IR** is a pure-data model of a swarm. It lets GenSwarms *describe*, *validate*,
*mutate*, and *drive* a swarm as plain JSON-shaped data — with no `Code.eval`, no
shell, and no atom minting from untrusted input. It is also the foundation the
`gsp` package ecosystem (sharing reusable agent definitions) builds on.

It lives in `Genswarms.IR.*` and is exposed through the `Genswarms.IR` façade.

!!! note "Status"
    The IR core, the config→IR translator, the op-validation policy, the
    reconcile/actuation layer, and the **default validation gate** are all
    wired and in use. The package registry (`swarmidx`) and ref `resolve` step
    (constraints → content digests) are future work; until then, configs map to
    *inline*/`oci:`/`ssh` refs rather than published `swarmidx:` packages.

## The two representations

| Representation | Module | What it is |
|----------------|--------|------------|
| `swarm.state` (IR1) | `Genswarms.IR.State` | A snapshot of a swarm: agents, objects, topology, options — in a declared `phase` (`desired` or `observed`). |
| `swarm.overlay` (IR2) | `Genswarms.IR.Overlay` | An ordered log of mutation events (`add_agent`, `scale_agent_group`, `bump_package`, …) that folds over a `swarm.state`. |

A swarm is the result of folding overlays onto a seed state:

```
materialized_state = fold(seed_state, overlay_events)
```

`fold/2` (`Genswarms.IR.Fold`) is **pure**: it applies events in `seq` order and
performs no runtime effects. Executing the result against the live system is a
separate concern (see [Actuation](#actuation)).

### swarm.state (IR1)

Each agent has three orthogonal slots, each answering a different question:

| Slot | Question | Example |
|------|----------|---------|
| `body` | **who is the agent / what does it do** (its persona, today the skills) | `{"ref": "inline:researcher", "kind": "data"}` |
| `model` | **which LLM** | `{"ref": "openrouter:anthropic/claude-sonnet-4", "attested": true}` |
| `backend` | **where it runs** | `{"ref": "bwrap"}` / `{"ref": "oci:web"}` / `{"ref": "ssh", "host": "pi@h"}` |

Objects have a `handler` slot (`kind: code`). References (`Genswarms.IR.Ref`) carry
a content `digest` when they are content-addressable (`swarmidx:`/`oci:`), or are
marked `attested` when they are not (`openrouter:`, `ssh`).

A `swarm.state` must satisfy the structural invariants on parse: unique node
names, every topology endpoint exists, and **slot-typing** — `body`/`policy` are
`kind: data`, `handler` is `kind: code`. That data/code split is the privilege
boundary: data is loadable from anywhere, code is not.

### swarm.overlay (IR2) — op catalogue

| `op` | Payload | Effect |
|------|---------|--------|
| `add_agent` / `add_object` | a full agent/object | add a node (name must be new) |
| `remove_agent` / `remove_object` | `{name}` | remove the node and its edges |
| `add_topology_edges` / `remove_topology_edges` | `{edges}` | add/remove edges |
| `scale_agent_group` | `{base_name, target_count}` | materialize `base#1..base#N` |
| `bump_package` | `{target, field, from, to}` | swap a slot's digest (`from` must match) |
| `set_options` | `{options}` | merge into `options` |
| `update_config` | `{target, config}` | merge into a node's config |

Unknown ops fail validation — they are never silently ignored, and op strings are
matched against a fixed set (no atom minting).

## The public API

```elixir
alias Genswarms.IR

{:ok, state}   = IR.state(state_map)        # parse + validate a swarm.state
{:ok, overlay} = IR.overlay(overlay_map)    # parse + validate a swarm.overlay

# apply one proposed op: security policy first, then structural fold
{:ok, state2} = IR.apply_op(state, event)
# apply a whole overlay, op by op
{:ok, state3} = IR.apply_overlay(state, overlay)

# fold a seed + overlay into the desired state
{:ok, desired} = IR.materialize(seed, overlay)
# checkpoint + log compaction
{:ok, checkpoint, remaining} = IR.compact(seed, overlay, at_seq)
```

`apply_op/3` is the single choke point where **both** the security policy
(`IR.OpPolicy`) and the structural preconditions (`IR.Fold`) are enforced.

## From your config

`Genswarms.IR.FromConfig` translates the existing `.exs`/`.json`/`.yaml`
[swarm configuration](configuration.md) into a validated `swarm.state`:

| Config | IR |
|--------|-----|
| `skills` / `presets` | `body {ref: "inline:<name>"}` + `overrides` |
| `model: "x/y"` | `{ref: "openrouter:x/y", attested: true}` |
| `backend: :bwrap` / `:local` / `:mock` | bare refs `{ref: "bwrap"}` … |
| `backend: {:docker, n}` | `{ref: "oci:<n>"}` |
| `backend: {:ssh, "u@h"}` | `{ref: "ssh", host: "u@h"}` |
| `object.handler Mod` | `{ref: "module:<Mod>", kind: code}` |

## The default control-plane gate

The IR is wired into the orchestrator as a **strict, fail-closed gate**
(`Genswarms.IR.Gate`), so it governs every swarm without changing how agents are
spawned:

- **On swarm start** — the config must translate to a valid `swarm.state` (the
  §6 invariants). An invalid or untranslatable config is **refused before
  spawning**.
- **On `add_agent`** — rejects host-escape backend config keys
  (`subzeroclaw_path`, `extra_ro_binds`, `extra_rw_binds`, `extra_path`) and the
  per-swarm agent cap.
- **On `scale_agent_group`** — enforces the agent cap.

The cap defaults to `config :genswarms, :max_agents_per_swarm` (100) and applies
to **dynamic** mutations, not to operator-authored configs.

## Actuation

`Genswarms.IR.Reconcile.plan(desired, observed)` computes the ordered actions
that bring a live swarm to a desired state (start/restart/stop nodes, add/remove
edges) — pure, no runtime access.

`Genswarms.IR.Executor` runs that plan against the orchestrator: it reads the
live config (`observed`) and translates each action into a `SwarmManager` call.
`Executor.reconcile(swarm, desired)` does the whole loop — observed → plan →
apply.

## Design spec

The normative format and semantics (the ref model, the §6 invariants, the op
catalogue, fold/materialize/compaction) are defined in the GenSwarms IR
specification. This page documents what is implemented and usable today.
