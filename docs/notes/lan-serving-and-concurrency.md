---
name: lan-serving-and-concurrency
description: qwen38 serves the whole home LAN (ufw scoped to the subnet, linger + boot autostart); max-num-seqs 2 costs 2,797 tokens and does NOT allow two large contexts at once -- measured, they serialise cleanly with zero preemption
metadata:
  node_type: memory
  type: project
  modified: 2026-09-19T12:30:00.000Z
---

**Opened to the home LAN 2026-09-19.** The launcher always bound `0.0.0.0`, so
nothing about serving changed; the blockers were `ufw` (active) and `Linger=no`.

```bash
sudo ufw allow from 192.168.178.0/24 to any port 8000 proto tcp comment 'qwen38 vLLM LAN'
sudo loginctl enable-linger bezol      # --user unit must outlive the session
systemctl --user enable qwen38         # [Install] added to the unit for this
```

Clients use `http://omarchy.local:8000/v1` (avahi is active) or
`http://192.168.178.75:8000/v1`.

**`--host 0.0.0.0` was IPv4-only and half-broke the hostname.** avahi advertises
the box's IPv6 addresses, so `omarchy.local` resolved to IPv6 FIRST and was
refused (`000`); it only worked at all because Happy Eyeballs fell back to IPv4.
Now `--host ::` (`bindv6only=0`, one socket serves both) -> `ss -tln` shows
`*:8000`, IPv6 returns `200`, by-name connects in 0.10 s. NOTE this box has a
globally routable IPv6 and IPv6 has no NAT, so the v6 ufw rule is scoped to the
**ULA** `fd34::/64` (unroutable from outside), never the global `2a00:` prefix. No auth -- the ufw rule scoped to the subnet is
the only thing keeping it private, so do NOT widen it to `0.0.0.0/0`. If auth is
ever needed: `--api-key` on the server, `OPENAI_API_KEY` on the clients.

**`--max-num-seqs` 1 -> 2 costs 2,797 tokens** (pool 6.46 -> 6.34 GiB,
173,391 -> 170,594), which still clears `--max-model-len 166400`.

**It does not buy two big contexts, and cannot.** `max-num-seqs` caps SCHEDULED
sequences; the KV pool is one shared budget. Two ~150K requests want ~300K tokens
against a 170,594-token pool. vLLM says so itself at startup: *"Maximum
concurrency for 166,400 tokens per request: 1.03x"*.

**MEASURED, two clients firing ~149K prompts simultaneously:**

```
clientA:  46.4s  148,949 tokens  correct
clientB:  92.3s  148,921 tokens  correct
wall:     92.3s      preemption/recompute log lines: 0
```

They **serialise cleanly** -- both correct, wall = 2x one request, scheduler never
preempted. This is the good case: V1 preemption is recompute-only, so a preempted
150K prefill would have to redo ~46 s of work. Nothing to fix; just do not expect
seqs=2 to parallelise jumbo prompts. It helps the ordinary agentic mix of short
turns.

Going to 4 costs ~456 MiB and needs `--max-model-len` lowered ~12,800 tokens.
Re-run the gates if so ([[gpu-memory-utilization-locked]],
[[qwen38-context-ceiling-measured]]).
