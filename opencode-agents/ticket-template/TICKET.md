# <TICKET-KEY> <one-line title>

<!-- This file is the specification. You fill in the title and the Code section - the
     agents cannot start without a repository path. The rest is yours too, or /intake
     writes it from the files in notes/.
     Delete the sections you have nothing for - an empty heading is noise. -->

## Code
<!-- One line per repository this change may touch: FULL path, then what lives there.
     Forward slashes are safest (C:/repos/orders); the agents convert backslashes.
     The agents work in these folders; this folder only holds the paperwork.
     Commit or stash your own unfinished changes there first - otherwise the planner
     has to list them so that the reviewer can tell them from the coder's. -->
- <C:/repos/example> - <what lives there>

Check command: <the exact command that proves the change, and the folder to run it in - or: none>
Tests: <yes - where / none / unknown>
<!-- "none" is a fact the agents respect: a repository without tests gets no tests. -->

## What and why
<!-- Paste the ticket / wiki text. Keep the WHY: a 27B model fills a missing reason
     with a guess, and the guess becomes the design. -->

## Decisions from meetings
<!-- One line each: date - what was agreed - (who, if it matters). Decisions, not
     transcripts; the raw notes belong in notes/. A later decision beats an earlier one. -->

## Vocabulary
<!-- The words people use -> the names in the code.
     "the export job" = C:/repos/orders/export/ExportJob.java -->

## My notes
<!-- What you already know: where the code lives, the approach you want, the approach
     you do NOT want, similar code to copy the style from. One path saves the planner
     ten searches. -->

## Constraints
<!-- Must not change (public API, schema, config), libraries allowed or forbidden,
     performance or security requirements. -->

## Done when
<!-- Checkable statements. If there is a check command, the reviewer runs it and
     believes the result, not the coder. If there is none, say what to look at by hand. -->

## Out of scope
<!-- What someone might reasonably do here and must not. -->

## Open questions
<!-- /intake writes these. Answer them in place (or in the chat), then delete them. -->
