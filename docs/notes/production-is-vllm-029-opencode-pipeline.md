---
name: production-is-vllm-029-opencode-pipeline
description: Since 2026-09-19 the qwen38 service runs vLLM 0.29.0 (166400 ctx, prefix caching); chosen for the OpenCode multi-agent pipeline, which 0.22 cannot serve
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T02:00:00.000Z
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

The work deployment has the same model with a ~130K window, so the template is sized
for that: file-based handoff in `.pipeline/`, capped subagent reports, no `model:`
field in agents. `~/qwen-vllm` is a git repo (branch main); the user pushes it to a
private remote themselves -- never push for them unasked.
See [[vllm-029-breaks-this-model]] for the HND requirement.
