---
name: production-is-vllm-029-opencode-pipeline
description: Since 2026-09-19 the qwen38 service runs vLLM 0.29.0 (166400 ctx, prefix caching); chosen for the OpenCode multi-agent pipeline, which 0.22 cannot serve
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T21:30:00.000Z
---

**`qwen38.service` now runs `~/qwen-vllm/serve-qwen38-029.sh`** (vLLM 0.29.0 in
`~/vllm-029-env`, fp8 KV, `VLLM_KV_CACHE_LAYOUT=HND`, 166400 ctx, MTP + CUDA graphs).
Rollback: `~/.config/systemd/user/qwen38.service.bak-022` -> `serve-qwen38.sh`
(vLLM 0.22, 190400 ctx). This supersedes the "stay on 0.22" parts of older notes;
the KV-dtype decision (fp8) in [[kv-dtype-decision-stay-on-fp8]] still stands.

**Why the switch:** the user's goal is agentic coding with OpenCode -- an
orchestrator plus planner/coder/reviewer/refactorer subagents, one active at a time
(template: `~/qwen-vllm/opencode-agents/`, toy project:
`~/Documents/opencode_sample_project`; user confirmed it works 2026-09-19). Two
things made 0.29 mandatory, not just nicer:
* **vLLM 0.22's `qwen3_xml` streaming tool parser is broken for PARALLEL tool calls**:
  3 real calls stream as 5, the extras with `function.name: null`; OpenCode aborts
  the subagent with `Expected 'function.name' to be a string`. Planner survived
  (serial calls), coder died on turn one every time. 0.29.0: 3 in, 3 out, clean.
* Prefix caching (2 s vs ~60 s on a repeated 159K prompt) suits the resend-heavy loop.

## Where agent files live: `agents/`, plural -- and it shadows the singular

MEASURED on opencode **v2.0.10**, because two spellings are in circulation and
guessing wrong is silent. The loader globs **both**:

```
{agent,agents}/**/*.md    subagents (primary: false)
{mode,modes}/*.md         primary agents
```

so `~/.config/opencode/agent/` and `~/.config/opencode/agents/` are both read, and
`opencode-agents/install.sh` writing the plural was never broken. Two things are
worth not re-deriving:

* **On a name clash the PLURAL copy wins.** Verified by putting the same `coder.md`
  in both dirs with different `description:` fields, across service restarts: one
  `coder` is loaded, always the one from `agents/`. So a leftover singular copy is
  dead weight, and editing it looks like OpenCode ignoring your changes. `install.sh`
  now prints `SHADOWED:` for each such file. Plural is also what OpenCode's own docs
  give, for global and project scope alike, which settles which one to keep.
* `**/` matches zero directories here, so files sitting directly in `agents/` load;
  they do not need a subdirectory.

**The check itself has a trap.** `opencode debug agents` is answered by the
background service (`opencode serve --service`), and right after that service is
killed or restarted it returns `[]` -- not an error, just an empty list. Two
separate conclusions here were wrong because of it. Call it until it returns the
built-ins (`Build`, `Plan`, `Title`, ...) before believing anything it says.

The work deployment has the same model with a ~130K window, so the template is sized
for that: file-based handoff in `.pipeline/`, capped subagent reports, no `model:`
field in agents. `~/qwen-vllm` is a git repo (branch main); the user pushes it to a
private remote themselves -- never push for them unasked.
See [[vllm-029-breaks-this-model]] for the HND requirement.
