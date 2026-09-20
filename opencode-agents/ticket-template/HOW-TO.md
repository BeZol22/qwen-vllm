# One folder per ticket - copy, fill in, `opencode`

Everything OpenCode needs is inside this folder. Nothing is installed, no script is run,
and the code repositories never receive anything but the change itself.

```
PROJ-1234-short-title\        <- a COPY of the sample folder; `opencode` is started HERE
  opencode.jsonc              model + server + guard rails        (filled in once, in the sample)
  .opencode\agents\           orchestrator, intake, researcher, planner, coder, reviewer, refactorer
  .opencode\commands\         /ticket, /intake
  .opencode\skills\           team conventions, loaded on demand
  TICKET.md                   the specification - you name the repository here
  notes\                      raw material: Jira text, meeting notes, mails, logs
  -- written by the agents as the work proceeds --
  PLAN.md  REVIEW.md  REFACTOR.md  RESEARCH.md  PROGRESS.md  scratch\
```

## Once: prepare the sample folder

1. Keep one pristine copy of this folder, e.g. `Documents\opencode\_sample`. **Never start
   OpenCode inside the sample** - it would collect a ticket's files and pass them on to
   every copy.
2. In the sample's `opencode.jsonc`, replace `REPLACE-WITH-SERVED-MODEL-NAME` (three
   places; the exact id from `<server>/v1/models`) and `REPLACE-WITH-BASE-URL`.
3. Team skills: copy the ones you want into `.opencode\skills\`, or link the team
   repository live in `opencode.jsonc` (the commented `"skills"` line).
4. If the pipeline agents were ever installed globally
   (`%USERPROFILE%\.config\opencode\agents\orchestrator.md`, `planner.md`, ... and
   `commands\ticket.md`), delete them there. OpenCode MERGES a global agent with a folder
   agent of the same name - every rule twice, and an old global copy keeps overriding the
   new one.

## Per ticket

1. Copy the sample folder, rename the copy: `PROJ-1234-order-export-timeout`.
2. `TICKET.md`: put the ticket key and title in the first line, and the repository path(s)
   under `## Code` - full path, e.g. `C:/repos/orders`. Without a path the agents stop.
3. Either write the rest of `TICKET.md` yourself, or drop the Jira text and your meeting
   notes into `notes\` as text files.
4. Open a terminal in the folder, run `opencode`.
   - `/intake` (optional) - turns `notes\` into a structured `TICKET.md` and comes back with
     the open questions. Answer in the chat or edit the file. Read the result.
   - `/ticket` - the planner writes `PLAN.md`; you get a summary (approach, `Tests:` line,
     new files, open questions) and the run **stops**. Approve with `/ticket approved`, or
     say what to change.
   - Then: coder -> reviewer (max 4 rounds) -> refactorer -> coder -> reviewer (max 2),
     one agent at a time.
5. The change appears in the repository, uncommitted. Read it in VS Code's source-control
   view. **You** stage, commit and push - no agent can.

## Coming back to a ticket

Open a terminal in that ticket's folder, run `opencode`, type `/ticket` - with a remark if
you have one: `/ticket follow-up: address the PR comments in notes\pr-review.txt`.
The orchestrator reads `PROGRESS.md` first (phase, round, your decisions, the next step)
and carries on from there; it does not need the old conversation. A finished ticket gets a
new plan for the follow-up only.

## What the agents may and may not do

| Agent | Can write | |
|---|---|---|
| `orchestrator` | `PROGRESS.md` | delegates, one subagent at a time; no web, no shell |
| `intake` | `TICKET.md` | reads `notes\`, anchors names to real paths in the code |
| `researcher` | `RESEARCH.md` | only when the planner reports `RESEARCH NEEDED:` |
| `planner` | `PLAN.md` | records what the repository HAS (`Tests: none` ...) and every new file |
| `coder` | the repositories, `scratch\` | adds nothing of a kind the repository does not have |
| `reviewer` | `REVIEW.md` | footprint check first; never asks for tests or docs that do not exist |
| `refactorer` | `REFACTOR.md` | behaviour-preserving simplifications of the new code only |

These are permission rules, not requests: an `edit` rule is matched against the path
relative to the folder OpenCode was opened in, so `"PLAN.md": allow` means *this folder's*
`PLAN.md` and refuses one inside the repository. No agent can `git add`, commit, push,
reset, stash or clean.

## If something is off

| Symptom | Cause |
|---|---|
| Starts as `build`, not `orchestrator` | OpenCode was not started in the ticket folder, or `.opencode\agents\orchestrator.md` is missing from the copy (hidden/dot folders not copied?). |
| "Model not found", instant failure | The model id in `opencode.jsonc` differs from what `<server>/v1/models` reports, or one of the three places was missed. |
| Config seems ignored | Invalid JSON after an edit - the whole file is dropped. See `%USERPROFILE%\.local\share\opencode\log\opencode.log`, "configuration normalization diagnostic". |
| The planner stops: "no code root" | `## Code` in `TICKET.md` still holds the placeholder, or the path does not exist. |
| Every rule of an agent appears twice in `opencode debug agents` | A global copy of the same agent exists - see "Once", step 4. |
| A permission prompt for every folder of the repository | You are in a built-in agent (`build`, `plan`). Tab back to `orchestrator`. |
| The reviewer sees no changes | The path under `## Code` is not the git repository, or the change is already committed. |
