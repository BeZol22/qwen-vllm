# OpenCode agent team: (intake ->) plan -> code -> review -> refactor

> **Current way of working (2026-09-20): no scripts, nothing installed.** Copy the folder
> [`ticket-template/`](ticket-template/) once per ticket, open `opencode` in the copy, and
> follow [`ticket-template/HOW-TO.md`](ticket-template/HOW-TO.md). The folder carries its own
> `opencode.jsonc`, agents, commands and skills.
> The script-based flow described below (`install.ps1`, `install.sh`, `new-ticket.ps1`) is
> **superseded and not yet cleaned up**: the installers still expect the agents in `agents/`,
> which moved into the template, so they no longer work. The measured OpenCode v2 behaviour
> documented below still holds.

A seven-agent pipeline for [OpenCode](https://opencode.ai), built for a single
local/self-hosted model (Qwen3.8-27B) serving **one request at a time**. The
orchestrator delegates to exactly one subagent at a time via the Task tool.

OpenCode is opened in a **ticket workspace** - a folder per ticket, outside the
repository - and the code is only referenced from there. The repository ends up
containing the change and nothing else: no plan, no notes, no agent files, and no
tests, docs or helpers of a kind it did not already have.

```
Documents/opencode/PROJ-1234-short-title/   <- `opencode` runs HERE        C:/repos/orders/  <- the code
  TICKET.md  notes/  PLAN.md  REVIEW.md  REFACTOR.md  PROGRESS.md             (only the coder writes here)

user -> orchestrator --Task--> intake      notes/ -> TICKET.md + open questions   /intake, optional
                     --Task--> planner     writes PLAN.md                  then STOPS for your OK
                     --Task--> researcher  writes RESEARCH.md              only if the planner asks
                     --Task--> coder       implements the plan in the code roots <-+  max 4
                     --Task--> reviewer    writes REVIEW.md, VERDICT: APPROVE | CHANGES --+  rounds
                     --Task--> refactorer  writes REFACTOR.md
                     --Task--> coder -> reviewer                           max 2 rounds
                     -> final report (never commits or pushes)
   after every step: PROGRESS.md - a new session reads it and carries on
```

| agent | mode | can write | runs commands | job |
|---|---|---|---|---|
| `orchestrator` | primary | only `PROGRESS.md` | `git -C <root> status` only | runs the loop, counts rounds, talks to you, keeps the ticket's memory |
| `intake` | subagent | only `TICKET.md` | yes (no git writes, no deletes) | Jira text + meeting notes -> one structured ticket, names anchored to code paths, contradictions listed |
| `researcher` | subagent | only `RESEARCH.md` | yes (no git writes, no deletes) | facts the plan needs - web where the environment allows it, the code otherwise |
| `planner` | subagent | only `PLAN.md` | yes (no git writes, no deletes) | file-level plan, **what the repository already has** (`Tests: none`), the list of new files |
| `coder` | subagent | **the code roots**, `scratch/` | yes (no add/commit/push/stash) | implements, fixes review findings, leaves no footprint |
| `reviewer` | subagent | only `REVIEW.md` | yes (runs the checks that exist) | adversarial review, footprint check first, structured verdict |
| `refactorer` | subagent | only `REFACTOR.md` | yes (no git writes, no deletes) | behaviour-preserving simplifications |

"Can write" is a permission rule, not a request: OpenCode v2 matches `edit` rules against
the path relative to the opened folder, so `"PLAN.md": allow` means the workspace's
`PLAN.md` and refuses one inside the repository (measured on v2.0.10).

## Designed for a ~130K context window

- Every subagent starts with a **fresh context**; nothing accumulates across roles.
- State is handed over through **files** in the workspace, not through the
  orchestrator's conversation - including the reviewer's findings (`REVIEW.md`).
- Subagent reports are capped (80-200 words), so the orchestrator stays small
  across many rounds.
- Agents are told to grep first, read line ranges, and `tail` noisy output.
- Loops are hard-capped (4 build rounds, 2 refactor rounds, `steps:` per agent) so
  a confused model cannot spin forever.
- `PROGRESS.md` makes the conversation disposable: start a new session in the
  ticket folder, type `/ticket`, and it continues from the recorded next step.

## Install

Agents carry **no `model:` field** - they use whatever model your OpenCode is
configured with, so the same files work at home and at work. They are installed
**globally**, because OpenCode is opened in ticket folders, not in projects.

Windows (home or work):

```powershell
.\install.ps1 -BaseUrl http://<llm-host>:<port>/v1 -ModelId <id from /v1/models> -TeamRepo C:\repos\agent_and_skills
```

macOS / Linux:

```bash
./install.sh --global                    # agents + commands -> ~/.config/opencode/
./install.sh --global home               # + opencode.json for the local vLLM server (never overwrites)
```

[WORK-SETUP.md](WORK-SETUP.md) is the guide: the workspace layout, how to write the
ticket, how to pick one up again, and what v2 silently ignores. The `work` provider
file (`opencode.work.example.json`) is the older v1 shape and relies on `{env:...}`
variables, which v2's background service does not inherit from your terminal;
`install.ps1` writes `providers/opencode.work.v2.example.jsonc` instead.

Agents go in **`agents/`, plural** - that is what OpenCode's docs say, and on a
name clash it is the copy that wins. OpenCode actually globs both spellings
(`{agent,agents}/**/*.md`, measured on v2.0.10), so a hand-made `agent/` copy
beside an installed `agents/` one is silently dead weight; the installers print
`SHADOWED:` for every such file rather than leaving you to wonder why an edit
did nothing.

`limit.context` is set to 130000 for work, 160000 for home and 126000 for windows
(that box serves `--ctx-size 131072`); OpenCode uses it to decide when to compact.

## Use

```powershell
cd $HOME\Documents\opencode
.\new-ticket.ps1 PROJ-1234 "Order export times out" -Repo C:\repos\orders -Open
```

Fill in `TICKET.md` - or drop the Jira text and your meeting notes into `notes\` and
run `/intake` - then `/ticket`. The orchestrator **stops after the plan** and waits
for your approval: correcting a plan costs one planner run, correcting code costs
coder and reviewer rounds. Watch the change arrive in the repository's
source-control view; no agent stages, commits or pushes - that stays with you.

Coming back later: open `opencode` in the same folder and type `/ticket` again.

You can also call one role directly: `@reviewer review the uncommitted changes in
C:/repos/orders against PLAN.md`.

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
  truth** - the reviewer must run the tests itself. A repository without tests gets
  no tests written for it (that is the point) and therefore a weaker review: the
  reviewer traces the acceptance criteria through the code by hand instead.
- `permission` rules are guard rails, not a sandbox.
- OpenCode's `/undo` does not cover files outside the opened folder. Git is the undo
  for the code.
- The workspace layout was tested end-to-end with OpenCode 2.0.10 against llama.cpp
  (2026-09-20); the earlier in-repository `.pipeline/` layout with OpenCode 1.18.31
  against vLLM 0.29.0 (2026-09-19).
