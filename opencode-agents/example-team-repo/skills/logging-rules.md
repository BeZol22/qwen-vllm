---
name: logging-rules
description: Team logging rules - structured fields, no personal data, which level to use when.
---
# Logging rules

- Log structured key/value fields, never string-concatenated messages.
- Never log personal data, tokens or full request bodies.
- ERROR = someone must act; WARN = degraded but working; INFO = state changes.
