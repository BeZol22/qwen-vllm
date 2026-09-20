---
name: api-error-handling
description: How the team maps exceptions to HTTP responses - problem+json body, stable error codes, no stack traces to clients.
---
# API error handling

- Every error response is `application/problem+json` with `type`, `title`, `status`, `code`.
- `code` is a stable, documented string; clients branch on it, never on `title`.
- Never return a stack trace or an internal exception message to the client.
