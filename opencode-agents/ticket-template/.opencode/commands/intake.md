---
description: Turn the raw material in notes/ (Jira text, meeting notes, mails) into a structured TICKET.md and list what is missing. Arguments - optional notes of your own. Run /ticket afterwards.
agent: orchestrator
---
Run INTAKE for this workspace, and nothing after it.

My notes (may be empty): $ARGUMENTS

Task -> `intake`: "Build `TICKET.md` from the material in `notes/`." followed by my
notes verbatim. Then show me its summary and its open questions and STOP. Do not
start the planner.
