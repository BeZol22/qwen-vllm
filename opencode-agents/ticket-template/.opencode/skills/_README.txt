Skills for this ticket folder. OpenCode finds them here without any setting:

    <name>.md               one file per skill, or
    <name>\SKILL.md         one folder per skill

Each needs a frontmatter with  name:  and  description:  - a skill without a description is
loaded but never advertised to the model. Only the descriptions cost context; a body is
loaded when an agent decides it applies.

Copy the team skills you want in here (in your SAMPLE folder, so every ticket copy has them),
or link the team repository live in opencode.jsonc ("skills": [...]).
This .txt file is ignored by OpenCode.
