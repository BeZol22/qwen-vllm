---
description: Run the ticket in this folder through plan -> code -> review -> refactor, or pick it up where PROGRESS.md says it stopped. Arguments - optional notes of your own.
agent: orchestrator
---
This is the `/ticket` command: work on the ticket in this workspace. The
specification is `TICKET.md`.

My notes (may be empty): $ARGUMENTS

Read `PROGRESS.md` first.
- It does not exist, or its Phase is INTAKE: intake is over. Start Phase 1 (PLAN)
  now and pass my notes to the planner verbatim.
- Any other Phase: continue from its `Next` line, and treat my notes as my answer
  or decision for that step.
Do not read `TICKET.md` yourself; the planner does.
