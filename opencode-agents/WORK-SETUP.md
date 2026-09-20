# Work setup: OpenCode v2, one local model, a separate team `agent_and_skills` repo

> **Current way of working (2026-09-20): no scripts, nothing installed.** Copy the folder
> [`ticket-template/`](ticket-template/) once per ticket, open `opencode` in the copy, and
> follow [`ticket-template/HOW-TO.md`](ticket-template/HOW-TO.md). The folder carries its own
> `opencode.jsonc`, agents, commands and skills.
> The script-based flow described below (`install.ps1`, `install.sh`, `new-ticket.ps1`) is
> **superseded and not yet cleaned up**: the installers still expect the agents in `agents/`,
> which moved into the template, so they no longer work. The measured OpenCode v2 behaviour
> documented below still holds.

For this situation: production code, **only** a local ~27B model with a ~130K window,
**only** OpenCode, Windows 11, code repositories that must not contain a single agent,
skill, config, plan, note or `.gitignore` change - nor a test, a document or a helper script
of a kind they did not already have -, and a team repository of Copilot-style agents and
skills cloned somewhere else on the disk.

The shape of the answer: OpenCode is never opened inside a repository. It is opened in a
**ticket workspace** - one folder per Jira ticket under `Documents\opencode` - that holds
the specification, your notes, every file the agents hand to each other, and the record of
where the work stands. The repositories are only referenced, only one agent can write to
them, and what it writes there is the change and nothing else.

Everything below marked *measured* was checked on OpenCode **v2.0.10**, Windows 11,
Windows PowerShell 5.1. v2 differs from the v1 documentation most search results show;
where they disagree, this file follows what v2 actually did.

## Install

```powershell
git clone <this repo> ; cd qwen-vllm\opencode-agents
.\install.ps1 -BaseUrl http://<llm-host>:<port>/v1 -ModelId <id from /v1/models> -TeamRepo C:\repos\agent_and_skills
opencode reload              # ONLY when no session is working - it aborts tool calls in flight
opencode debug agents        # expect orchestrator, intake, researcher, planner, coder, reviewer, refactorer + team agents
```

`-WhatIf` shows what it would do. It is safe to re-run: an existing `opencode.json(c)`
is never touched, and an installed agent that differs from the kit is backed up first.

What lands where - under `%USERPROFILE%\.config\opencode` (not `%APPDATA%`;
`opencode debug paths` prints the real location) and in your workspace root; nothing in
any code repository, and no git setting:

| Path | What |
|---|---|
| `opencode.jsonc` | provider, model, `default_agent`, the link to the team skills |
| `agents\*.md` | the seven pipeline agents + converted team agents |
| `commands\*.md` | `/ticket`, `/intake` |
| `Documents\opencode\` (`-WorkspaceRoot`) | `new-ticket.ps1`, `TICKET.template.md` - and, later, one folder per ticket. `Documents` is resolved through Windows, so a OneDrive-redirected folder is found |

After a `git pull` in the team repo: skills are live immediately; for agents re-run
`.\sync-team-agents.ps1 -TeamRepo C:\repos\agent_and_skills`.

## The ticket workspace: OpenCode is opened next to the code, never in it

One folder per ticket, outside every repository. You open OpenCode **there**; the code
is only referenced. Everything the agents need, write and hand to each other lives in that
folder, so the repositories contain exactly one thing afterwards: the change.

```
Documents\opencode\                          <- -WorkspaceRoot of install.ps1
  new-ticket.ps1   TICKET.template.md
  PROJ-1234-order-export-timeout\            <- one ticket; `opencode` is started HERE
    TICKET.md      the specification: yours, or written by /intake from notes\
    notes\         raw material: Jira export, meeting notes, mails, logs
    PROJ-1234.code-workspace   VS Code: this folder + the repositories in one window
    RESEARCH.md    researcher   (only when the planner asks for it)
    PLAN.md        planner      <- you approve this
    REVIEW.md      reviewer     the latest verdict and findings
    REFACTOR.md    refactorer
    PROGRESS.md    orchestrator where the ticket stands; what a new session reads first
    scratch\       coder        throwaway scripts and captured output

C:\repos\orders\                             <- a CODE ROOT, named in TICKET.md "## Code"
  ...                                           only the coder can write here; you watch it
                                                in VS Code's source-control view
```

```powershell
cd $HOME\Documents\opencode
.\new-ticket.ps1 PROJ-1234 "Order export times out" -Repo C:\repos\orders -Open
```

`-Repo` takes several paths for a change that spans repositories. The script writes them
into `TICKET.md` with forward slashes, warns when a repository already has uncommitted
changes (the reviewer reads `git diff HEAD` and would take them for part of the ticket),
and never touches an existing workspace - run it again with the same key and title and
`-Open` (no `-Repo` needed) to get back to a ticket.

It also writes `<KEY>.code-workspace`, a VS Code multi-root workspace with the ticket folder
and every repository. `code .\PROJ-1234.code-workspace` gives you one window with the plan
and the review on one side and the repository's source-control view - the change, as the
coder makes it - on the other.

**Who can write where** - enforced by permission rules, not by asking nicely (*measured*):

| Agent | Can write | Everything else |
|---|---|---|
| `orchestrator` | `PROGRESS.md` | `Permission denied: edit` |
| `intake` | `TICKET.md` | refused |
| `researcher` | `RESEARCH.md` | refused |
| `planner` | `PLAN.md` | refused |
| `reviewer` | `REVIEW.md` | refused - it cannot "just fix" what it finds |
| `refactorer` | `REFACTOR.md` | refused |
| `coder` | the code roots, and `scratch\` | - |

This works because v2 matches an `edit` rule against the path **relative to the folder
OpenCode was opened in**: `"PLAN.md": allow` after `"*": deny` lets the planner write the
workspace's `PLAN.md` and refuses `C:\repos\orders\PLAN.md` (*measured*). It is the reason
the workspace has to be the opened folder: open OpenCode inside the repository instead and
the same rule would allow a `PLAN.md` there.

**Reaching the code.** Everything outside the opened folder is an `external_directory` to
v2, and the default is `ask`. In the TUI that is a prompt per folder; in a subagent nobody
can answer it; under `opencode run` it is auto-rejected and *ends the session*
(*measured*). Every pipeline agent therefore carries `external_directory: allow`, and
`sync-team-agents.ps1` gives it to the converted team agents. With it, `read`, `grep`,
`glob`, `edit` and the shell's working-directory parameter all work on the code roots
(*measured*). The built-in `build` and `plan` agents keep the default and will ask.

**What git sees:** the change, and nothing else. No `.pipeline` folder, no ignore rule, no
global git setting - the earlier version of this kit added `.pipeline/` to your machine-wide
excludes file; that line is harmless and no longer needed. One consequence: OpenCode's own
`/undo` snapshots belong to the opened folder and do not cover files in the code roots.
Your undo for the code is git - which is also why the agents can neither stage nor stash.

## How the team repo is connected

**Skills - linked live, no copy.** `"skills": ["C:\\repos\\agent_and_skills\\skills"]`
in `opencode.jsonc`. v2 loads flat `skills\<name>.md` files and `<name>\SKILL.md`
folders alike. Only each skill's `description` sits in the context; the body is loaded
on demand. That makes skills the right home for team knowledge: twenty conventions cost
twenty sentences, not twenty documents.

**Agents - converted, because they cannot be linked.** `sync-team-agents.ps1` writes a
cleaned copy of each team agent into `agents\` (keeps `description` and the prompt; drops
`name`, `tools`, `model`, `handoffs`; adds `mode: subagent`, a step limit,
`external_directory: allow` (the code is outside the opened folder) and conservative
permissions - `edit: deny` when the Copilot `tools` list contained nothing that edits).
Call them with `@name`. They are deliberately **not** added to the orchestrator's
allow-list: every subagent the orchestrator may call costs it context on every turn.

**Rules that must always apply** go in `%USERPROFILE%\.config\opencode\AGENTS.md`. Keep it
to a few lines - unlike a skill, all of it is sent on every single request.

### Traps, all measured

| What you do | What v2.0.10 does |
|---|---|
| Link skills as `C:/repos/.../skills` (forward slashes) | Every flat `skills\<name>.md` collapses into **one** skill named `skills`; the rest vanish. `<name>\SKILL.md` folders survive. **Use doubled backslashes.** |
| Skill file without `description:` | Loaded, but never advertised - the model does not know it exists. The sync reports these. |
| Copilot agent file dropped into `agents\` as is (`tools: [...]`, `model: GPT-5 (copilot)`) | The agent silently does not exist. No error, no log line. Hence the conversion. |
| A typo makes `opencode.jsonc` invalid JSON | The whole file is ignored. The only trace is `configuration normalization diagnostic ... rejected malformed JSON` in `%USERPROFILE%\.local\share\opencode\log\opencode.log`. |
| v1-style keys (`provider`, `npm`, `autoupdate`, `compaction.prune`, model `reasoning`/`attachment` flags) | Translated on load where possible, **dropped** where not - also only visible in that log. The shipped config is v2-native so nothing is dropped. |
| `"instructions": [...]` | Accepted, never loaded (v2 docs say so too). Use `AGENTS.md`. |
| `OPENCODE_CONFIG_DIR` | Not in the v2 docs and had no effect in a probe here. Not used. |
| `{env:VAR}` in the config | Resolved by the shared **background service**, which does not inherit the environment of the terminal you start `opencode` in. Hardcode the URL. |
| The same agent file name in two config folders (global `agents\` and a project's `.opencode\agents\`) | The two are **merged**, rules concatenated - not replaced. An old global `planner.md` with `webfetch: deny` kept denying it for a newer project copy. Keep one copy. |
| `opencode debug agents` right after the service (re)started | Prints `[]`. Not an error - ask again until the built-ins (`build`, `plan`, ...) appear. |
| `~\.claude\skills` exists (Claude desktop/Code installed) | v2 advertises every skill in it to your local model too. Hide them: `{ "action": "skill", "resource": "docx", "effect": "deny" }` per skill under `permissions`. |
| A Windows path in **double** quotes in an agent's frontmatter (`"C:\\code\\*": allow`) | The agent's **entire** `permission:` block is dropped: it ends up allowing everything, `question` and `task` included. No error, no log line. Single quotes (`'C:\code\*'`) and forward slashes both work. Check with `opencode debug agents`. |
| An agent touches a path outside the opened folder without `external_directory: allow` | `ask`. Under `opencode run`: `permission requested: external_directory (...); auto-rejecting`, and the session ends. |
| `edit:` rules with file patterns | Matched against the path **relative to the opened folder**. `"**/REVIEW.md"` does **not** match `REVIEW.md` - write the plain name. |
| An agent runs `git -C C:\repos\orders status` | Where v2 picked Git Bash as the agents' shell, bash eats the backslashes: `cannot change to 'C:reposorders'`. A forward-slash path in double quotes works in both shells; `new-ticket.ps1` writes the code roots that way. |

## Your own agent

One markdown file; the file name is the agent's id. Put it in
`%USERPROFILE%\.config\opencode\agents\` and check with `opencode debug agents`.
*Measured* on v2.0.10: new and edited agent files are served without a reload - the next
subagent that starts already gets the new text, even in a folder that was open before.
Only if yours does not show up: `opencode reload`, when nothing is running.

```markdown
---
description: Explains what a piece of legacy code does and why, without changing it. Use before touching unfamiliar modules.
mode: subagent
steps: 40
permission:
  edit: deny
  external_directory: allow
  question: deny
  task: deny
---
You are the EXPLAINER. You are read-only. ...
Finish with a report of at most 200 words.
```

- `description` is what the calling model reads to decide **when** to use the agent -
  write "use when ...", not "this is ...".
- `mode: subagent` = called by another agent or by `@name`; `primary` = selectable with Tab.
- **No `model:` line.** The agent then follows the configured model, and the same file
  works at home and at work.
- `steps` is the hard stop for a confused model. Always set it.
- `question: deny` for subagents: a subagent cannot reach you, and one that asks anyway
  stalls the pipeline inside a child session you are not looking at.
- `external_directory: allow`, or the agent cannot see the code from a ticket workspace.
  To let an agent write one workspace file and nothing else:
  `edit:` / `"*": deny` / `"NOTES.md": allow` (the pipeline agents do exactly this).
- Leave the web tools out. The machine's config decides (see "The web" below).
- End every subagent prompt with a **word limit for its report**. The report lands in
  the caller's context; an unbounded one is how a 130K window dies.
- This v1-style `permission:` block is what the pipeline agents use; v2.0.10 translates
  it (`bash` -> `shell`, `task` -> `subagent`) - `opencode debug agents` shows the result.
- Do not assume PowerShell. *Measured* here: with no `"shell"` key set, v2.0.10 ran the
  agents' commands in **Git Bash** (`$0` = `/usr/bin/bash`). Allow/deny lists need both
  spellings (`rm -rf *` and `Remove-Item*-Recurse*`), and prompts should show paths with
  forward slashes in double quotes - the one form both shells take.

A skill is even less: `skills\<name>.md` in the team repo with `name:` and `description:`
in the frontmatter and the convention in the body.

## The daily loop

1. `.\new-ticket.ps1 PROJ-1234 "short title" -Repo C:\repos\orders -Open` (see above).
2. Give it the material - one of two ways:
   - **You write `TICKET.md`** (the template's comments say what goes where), or
   - you drop the raw text into `notes\` - the Jira export, your meeting notes, the mail
     thread - and run **`/intake`**. The intake agent distils it into `TICKET.md`, resolves
     the names people used to real paths in the code, and comes back with the open
     questions. Answer them in the chat (it works the answers in) or edit the file.
     Read `TICKET.md` before you go on - it is the one document everything else trusts.
3. **`/ticket`** - optionally with a remark: `/ticket the batch job also calls this`.
   The planner writes `PLAN.md`; the orchestrator shows its summary - approach, the
   `Tests:` line, the new files, open questions - and **stops**. Read the plan. This is
   the cheapest moment to be right: correcting a plan costs one planner run, correcting
   code costs coder + reviewer rounds. Answer, ask for changes, or approve.
4. coder -> reviewer, at most 4 rounds; then refactorer -> coder -> reviewer, at most 2.
   One subagent at a time, each in a fresh context; the findings travel in `REVIEW.md`,
   not through the orchestrator. Child sessions are browsable from the session tree.
   Meanwhile the change grows in VS Code's source-control view of the repository.
5. Read the diff (`git diff HEAD`). **You** stage, commit and push. No agent can.

## Picking a ticket up again

Tomorrow, or when the pull request comes back with comments: `cd` into the ticket folder
(or run `new-ticket.ps1` with the same key and title and `-Open` - it leaves an existing
workspace alone), start `opencode`, type **`/ticket`**.

The orchestrator's first action in every conversation is to read `PROGRESS.md` - phase,
round, whether the plan was approved, your decisions, one line per finished step, and the
exact next step. It rewrites that file after every subagent result. So a **new** session
continues where the last one stopped, without the old conversation (*measured*: intake in
one session, `/ticket` with the answer to its open question in a fresh one). Prefer that
over `opencode --continue` for anything but a short break - a day-old orchestrator context
is long, and re-sending it buys nothing that is not in the files.

- Waiting at the plan gate: `/ticket approved` (or `/ticket change step 3: ...`).
- Follow-up on a finished ticket: put the review comments into `notes\`, then
  `/ticket follow-up: address the PR comments in notes\pr-review.txt`. The planner reads
  the old plan for context and replaces it with a plan for the follow-up only.
- OpenCode keys sessions by folder, so the session list inside a ticket folder is that
  ticket's history and nothing else.

## Nothing the repository does not already have

Production code must come out of this looking as if a careful colleague had typed it: no
tests where there are none, no README, no helper scripts, no "added for PROJ-1234"
comments. A small model's instinct is the opposite - it has been rewarded for tests and
docstrings its whole life - so this is not left to one sentence in one prompt:

1. **The planner establishes facts, with evidence.** `PLAN.md` has a `Repo facts` section:
   `Tests:` (where, framework, exact command - or `none - do not add any`), `Build/lint:`,
   `Maintained alongside:` (changelog, migrations, ...), `Comment style:`. It also has a
   `New files` list: every file the change may create, each with a reason. Both are in the
   summary you approve, so you see "Tests: none" and "New files: none" *before* any code.
2. **The coder is bound by them.** It adds only kinds of things the repository has, creates
   no file outside `New files`, mirrors the comment density of the neighbouring code, puts
   its own experiments into the workspace's `scratch\`, and ends by checking
   `git status --short` of every code root against the plan.
3. **The reviewer checks the footprint first, mechanically.** A new file that is not in
   `New files`, a changed file no step names, a test although `Tests: none`, anything of
   the pipeline inside a code root, a new dependency or config key, narrating comments, a
   diff that shows a whole file as changed (line endings or formatting damaged) - each is
   a blocker. And it is told the converse too: **never request tests, docs or config the
   repository does not have** - otherwise the reviewer talks the coder into them in round 2.
4. **The other agents cannot write into a code root at all** (table above).

If a ticket really is "introduce tests for module X", say so in `TICKET.md` in so many
words - the planner's rule has exactly that exception.

Where there are no tests the review is weaker, and the kit does not pretend otherwise: the
reviewer runs whatever check exists (build, compile, lint) and otherwise traces each
acceptance criterion through the changed code by hand, writing down in `REVIEW.md` what it
traced. Put a manual check under "Done when" and do it yourself before you commit.

By-products of running things: the coder and the reviewer run the checks inside the
repository, and a repository whose `.gitignore` does not cover its own caches or build
output then shows them as untracked (*measured*: a `__pycache__\` in a Python repository
without an ignore rule - the reviewer had looked at `git status` *before* running its
checks and reported a clean tree). So the reviewer looks again *after* the checks and ends
its verdict with `LEFT BEHIND: <paths>`; that is never a finding against the coder, and the
orchestrator's last step before the report is to have the coder delete exactly those paths.
The planner and the intake agent are told to read and never run, for the same reason.

Line endings: the `edit` tool keeps a file's CRLF (*measured*: a one-line change in a CRLF
file is a one-line diff). Files the `write` tool **creates** get LF; with Git for Windows'
default `core.autocrlf=true` that is normalised on commit.

## Only the human commits and pushes

This is enforced in four layers, because any single one leaks:

1. **Global rules** in `opencode.jsonc` deny `git commit*`, `git push*`, `git * commit*`
   and `git * push*` (the last two catch `git -C <path> commit`). They cover every agent
   without shell rules of its own - above all OpenCode's built-in `build` and `general`,
   which otherwise allow everything and are one Tab press away.
2. **Each agent's own deny list** repeats them. It has to: an agent that declares
   `"*": allow` for its shell is evaluated *after* the global rules and overrides them
   (*measured* - `opencode debug agents` prints the final order; the last match wins).
   Every agent is also denied `git add` - in the plain form and as `git -C <path> add ...`,
   which with the code outside the opened folder is the normal way to call git.
3. **The planner never plans a commit**, even when a team skill describes commit
   messages. *Measured* before this rule existed: the planner added a "Commit" step, the
   coder ran `git add` and then `git commit`, and the permission system blocked the commit -
   no commit was made, but the files were left staged.
4. **The reviewer diffs against `HEAD`**, so staged changes cannot slip past the review.

These are guard rails, not a sandbox: an agent could still write a script that calls git.
Protected branches and required reviews on the server remain the real control.

## From Jira and meetings to TICKET.md: what, and how deep

The test for depth: **whatever a new colleague would have to ask you on their first day
with this ticket belongs in it; whatever they would find with a search does not.** The
model can grep. It cannot know what was said in a meeting.

- **Keep the why.** A missing reason gets replaced by a guess, and the guess becomes the design.
- **Decisions, not transcripts.** One line each: date, what was agreed. Meetings produce
  proposals, objections and reversals; a 27B model given the transcript will happily
  implement the proposal that was rejected ten minutes later. The transcript goes into
  `notes\`; the outcome goes into `TICKET.md`. A later decision beats an earlier one - and
  say so when it overturns the Jira text.
- **Vocabulary.** People say "the export job"; the code says `TenantExportTask`. Three to
  ten such pairs save more planner searches than anything else you can write.
- **Name one path.** "Like `OrderValidator` in `orders/validation/`" anchors the style.
- **Give the exact check command, or write `none`.** The reviewer runs it and believes the
  result, not the coder - it is the same model as the coder and shares its blind spots;
  a test suite is the only independent judge here. `Tests: none` is equally valuable: it
  is what keeps tests out of a repository that has none.
- **Say what is out of scope.** Small models are eager.
- **One ticket, one concern.** Two features in one ticket is two plans fighting for one
  context. Make two workspaces and run the pipeline twice.
- **Size.** Aim for one to three screens. Beyond ~250 lines the planner starts to lose
  the early parts; move detail into `notes\` and point to it (`see notes\api-contract.txt`).
  The planner opens a note only when the ticket points to it.

`/intake` applies the same rules on your behalf: it never invents a requirement, marks its
own inferences `ASSUMPTION:`, records a decision that a later one overturned as superseded,
and puts a contradiction it cannot settle by date under "Open questions" instead of
choosing (*measured* on a Jira text plus two meeting notes that disagreed: 1.5 minutes,
one open question, the right one). It is a first draft by a 27B model - read it.

## Why this shape, and not a bigger "agent factory"

The well-known OpenCode orchestration packs (oh-my-opencode and its forks, FlowDeck,
Ensemble, Mission Control) assume frontier models, several providers with per-role
routing, and parallel agents. On one 27B model behind one endpoint that is the wrong
trade: their agent rosters and tool schemas eat a large slice of 130K before work starts,
and parallel subagents do not run faster on a single server slot - they queue, and
thrash its prefix cache (see `../docs/notes/lan-serving-and-concurrency.md`).

What carries a small local model is structure, not headcount:

- **Strictly sequential, fresh context per job.** The orchestrator is always on and tiny;
  exactly one subagent works at a time and starts empty.
- **State in files, not in conversation.** `TICKET.md` -> `PLAN.md` -> the diff ->
  `REVIEW.md` -> `REFACTOR.md`, and `PROGRESS.md` for the run itself. Agents pass file
  names, never contents - not even the reviewer's findings go through the orchestrator.
- **Capped reports and capped loops.** 100-300 words back; 4 build rounds, 2 refactor
  rounds, a `steps` limit per agent. A confused model stops; it cannot spin.
- **A human gate where it is cheap** - after the plan.
- **Tests as ground truth**, run by the reviewer itself.
- **Knowledge on demand** - skills, not always-on instructions.

## See what OpenCode really loaded

v2 fails silently, so ask it instead of guessing. `debug agents` / `debug config` exist as
commands; skills and commands are only reachable through the API. The header makes the
service answer **for that folder** - without it you get the answer for your home folder.

```powershell
opencode debug config                                                  # which config files were read
opencode debug agents                                                  # every agent, with its FINAL rule order
opencode api --header "x-opencode-directory:$PWD" GET /api/skill       # skills: id, description, path
opencode api --header "x-opencode-directory:$PWD" GET /api/command     # /commands
.\show-denials.ps1                                                     # what was refused, per agent
```

**Reloading is not harmless.** `opencode reload` - and equally
`opencode api ... POST /api/location/reload`, *even with the directory header* - restarts
locations under every running session. *Measured, the hard way:* reloads issued against a
scratch folder aborted eight tool calls in a live planner session in a different project
("Interaction cancelled because the location shut down") and made it regenerate its plan.
Reload only when no session is working. That is why `install.ps1` does not reload unless
you pass `-Reload`.

Two more things that are easy to get wrong (both *measured*): the header is `x-opencode-directory` (the
`--param location[directory]=...` form is accepted and ignored), and a server that has
just started answers `[]` for agents and skills until it has finished loading - so
`--standalone`, which starts a fresh server per call, always shows empty lists.

## "Permission denied: shell" - is that normal?

In itself, yes: a deny rule did its job and the agent carries on. What matters is *which*
command was refused - `.\show-denials.ps1` lists them per agent. It should only ever be
one of these:

| Refused | Why |
|---|---|
| `git add`, `git commit`, `git push`, `git reset`, `git checkout`, `git stash`, `git clean` - also as `git -C <path> ...` | Only the human changes history. |
| `rm`, `mv`, `Remove-Item`, `Move-Item`, `Set-Content`, `Out-File`, `sed -i` (every agent except the coder) | These agents write exactly one file, through the edit tool. |
| anything at all, for the **orchestrator** | It delegates; it does not work. A refusal here means it tried to do a subagent's job. |
| `Permission denied: edit`, for anyone but the coder | It tried to write something other than its one workspace file - typically a plan or a note aimed at a code root. That is the rule doing its job. |

**If a harmless command is refused, that is a bug in the kit, not normal.** It was one:
the planner, researcher and refactorer used to run on "deny everything except a list".
*Measured* in real sessions, that list refused `Get-ChildItem ... | Select-Object Name`
(a compound command is refused as a whole when any part is not listed), a one-line
`powershell -Command` that checked the title lengths the planner had just written into
its own plan, and even `echo ok`. No list can anticipate an ad-hoc check, and every
refusal costs one of a capped number of steps. The list also protected nothing - those
agents can already write files through the edit tool. So all five working agents now
share one policy: **allow by default, deny the few commands above.**

The agents are also told to use `;` and not `&&` (Windows PowerShell 5.1 has no `&&`), to
write paths with forward slashes in double quotes (Git Bash eats bare backslashes), and the
refactorer not to run tests - that is the coder's and the reviewer's job.

## The web: open by default, one agent excepted, lockdown on request

Agents need information like a developer does: documentation while planning, the meaning
of an error while coding, best practices, competitors. So **the web is open by default**.
The researcher, planner, coder, reviewer and refactorer do not mention `webfetch`,
`websearch`, `execute` or `browser` in their files at all; they inherit whatever the
machine's `opencode.json(c)` says. (Agent rules are appended after the global ones, so an
agent that stays silent can neither loosen nor tighten them. *Measured* with identical
agent files: `allow` on a machine whose config has no web rules, `deny` for every agent
once the config carries them.)

**The one exception is the orchestrator, and the reason is context, not security.** It is
the only context that must survive the whole run. *Measured:* an orchestrator that did its
own research - 7 searches, 4 page scrapes - stood at 92 KB of conversation before the
planner had written a line, then had to push all of it through a prompt to hand it over.
It still gets the information: when the planner reports `RESEARCH NEEDED:`, it sends the
**researcher**, which works in a fresh context of its own, writes `RESEARCH.md` for the
planner, and reports back in 200 words.

**Lockdown is a switch, not the default:** `.\install.ps1 -NoWeb`. Reasons to use it are
yours or your employer's - a policy against sending anything from a machine with production
code to arbitrary hosts, or a network with no way out, where a model that keeps trying
burns its steps on timeouts. If you lock, lock all four. `execute` is v2's Code Mode (the
model writes JavaScript, OpenCode runs it); the documentation says that runtime has no
`fetch()`. *Measured on v2.0.10:* it does - an agent with only `webfetch: deny` fetched four
websites through `execute`, HTTP 200, page contents returned. Denying `webfetch` alone
locks nothing.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Starts as `build`, not `orchestrator` | `default_agent` dangles: `agents\orchestrator.md` missing, or an older copy in a singular `agent\` folder is being shadowed (the installer warns). |
| Config edits change nothing | Invalid JSON, or you edited `opencode.json` while an `opencode.jsonc` exists - check the log line above. Then `opencode reload`. |
| "Model not found" / instant failure | The id under `model` and `models` must equal `GET <baseURL>/models` exactly. `install.ps1` checks this when the server is reachable. |
| Planner works, coder dies on its first turn, every time | Server-side tool-call parsing, not OpenCode: vLLM needs `--enable-auto-tool-choice` and a Qwen tool parser (>= 0.29 for `qwen3_xml` streaming); llama.cpp needs `--jinja`. See `README.md`. |
| Tool calls come out as prose | Same - the chat template / parser is not active on the server. |
| Cannot connect to a local server | Use `127.0.0.1`, not `localhost` (resolves to `::1` first on Windows). |
| Slower and slower in a long session | Context near the limit; prefix caching stops paying. Start a new session in the ticket folder and type `/ticket` - the state is in `PROGRESS.md` and the other workspace files, not in the chat. |
| The planner cannot write its own `PLAN.md` (`Permission denied: edit`) | OpenCode was opened somewhere other than the ticket folder. Edit rules are relative to the opened folder. |
| A permission prompt for every folder of the repository, or `auto-rejecting` under `opencode run` | The agent in use has no `external_directory: allow`: a built-in agent (Tab back to `orchestrator`), or a stale pipeline agent from before the workspace layout - re-run `install.ps1`. |
| The reviewer sees no changes | The path under `## Code` is not the repository (or not a git repository), or the change is already committed. |
| The reviewer flags files you changed yourself | They were uncommitted when the ticket started, and `git diff HEAD` cannot tell yours from the coder's. Commit or stash first - `new-ticket.ps1` warns about it. |

## Limits

`permission` rules are guard rails, not a sandbox. The reviewer and the coder are the
same model. Nothing here commits, pushes or opens a pull request - on production code
that last step stays with you.
