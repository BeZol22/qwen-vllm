# OpenCode agent team: plan -> code -> review -> refactor

A five-agent pipeline for [OpenCode](https://opencode.ai), built for a single
local/self-hosted model (Qwen3.8-27B) serving **one request at a time**. The
orchestrator delegates to exactly one subagent at a time via the Task tool.

```
user -> orchestrator --Task--> planner     writes .pipeline/PLAN.md
                     --Task--> coder       implements the plan        <-+  max 4
                     --Task--> reviewer    VERDICT: APPROVE | CHANGES --+  rounds
                     --Task--> refactorer  writes .pipeline/REFACTOR.md
                     --Task--> coder -> reviewer                         max 2 rounds
                     -> final report (never commits or pushes)
```

| agent | mode | edits code | runs commands | job |
|---|---|---|---|---|
| `orchestrator` | primary | no | `git status` only | runs the loop, counts rounds, talks to you |
| `planner` | subagent | only `PLAN.md` | read-only | file-level plan + acceptance criteria |
| `coder` | subagent | **yes** | yes (no commit/push) | implements, fixes review findings |
| `reviewer` | subagent | no (`edit: deny`) | yes (runs tests) | adversarial review, structured verdict |
| `refactorer` | subagent | only `REFACTOR.md` | read-only | behaviour-preserving simplifications |

## Designed for a ~130K context window

- Every subagent starts with a **fresh context**; nothing accumulates across roles.
- State is handed over through **files** (`.pipeline/PLAN.md`, `.pipeline/REFACTOR.md`),
  not through the orchestrator's conversation.
- Subagent reports are capped (100-300 words), so the orchestrator stays small
  across many rounds.
- Agents are told to grep first, read line ranges, and `tail` noisy output.
- Loops are hard-capped (4 build rounds, 2 refactor rounds, `steps:` per agent) so
  a confused model cannot spin forever.

## Install

Agents carry **no `model:` field** - they use whatever model your OpenCode is
configured with, so the same files work at home and at work.

```bash
./install.sh /path/to/project            # agents -> <project>/.opencode/agents/
./install.sh --global                    # agents -> ~/.config/opencode/agents/
./install.sh /path/to/project home       # + opencode.json for the local vLLM server
./install.sh /path/to/project work       # + opencode.json template for work (edit it)
./install.sh /path/to/project windows    # + opencode.json for the Windows llama.cpp box
```

At work, if OpenCode already has the company model configured, the first form is
all you need. Otherwise use `work`, replace `REPLACE-WITH-SERVED-MODEL-NAME`
(three places; it must equal the name the server reports at `/v1/models`) and:

```bash
export WORK_LLM_BASE_URL=https://.../v1
export WORK_LLM_API_KEY=...
```

`limit.context` is set to 130000 for work, 160000 for home and 126000 for windows
(that box serves `--ctx-size 131072`); OpenCode uses it to
decide when to compact. `.pipeline/` is added to the project's `.gitignore`.

## Use

Start `opencode` in the project, switch to the **orchestrator** agent (Tab), and
describe the feature. You can also call one role directly: `@reviewer review my
uncommitted changes against README.md`.

## Server-side notes (vLLM)

- Needs tool calling: `--enable-auto-tool-choice --tool-call-parser qwen3_xml`.
- `--max-num-seqs 1` is fine: the pipeline is strictly sequential.
- **Use vLLM >= 0.29.** On 0.22 the `qwen3_xml` streaming parser emits phantom tool
  calls with `name: null` whenever the model makes PARALLEL tool calls (3 real calls
  stream out as 5). OpenCode then kills the subagent with
  `Expected 'function.name' to be a string`. Symptom: the planner works, the coder
  fails on its first turn, every time. If a server you cannot upgrade shows this,
  add "make exactly one tool call per response" to each agent prompt as a workaround.
- Prefix caching (vLLM >= 0.29 for this hybrid model) matters a lot here: every turn
  resends a growing prefix. Measured at home: a repeated 159K-token prompt takes 2 s
  warm vs ~60 s cold.
- Sampling is set per agent (`temperature: 0.6`, `top_p: 0.95`, Qwen's recommendation
  for thinking-mode coding). Do not go to 0 - greedy decoding makes Qwen loop.

## Known limits

- Reviewer and coder are the same model, so they share blind spots. The mitigation
  is structural: fresh context, adversarial prompt, and **the test suite as ground
  truth** - the reviewer must run the tests itself. A project without tests gets a
  much weaker review.
- `permission` rules are guard rails, not a sandbox.
- Tested end-to-end with OpenCode 1.18.31 against vLLM 0.29.0 (2026-09-19).
