# Roadmap / Future Plan

This document records **future ideas** for evolving the memory system.

It is intentionally conservative: we only adopt changes after observing the current L1-L3 pipeline in real usage.

## Repos (source of truth)

- Our pipeline repo: https://github.com/dztabel-happy/openclaw-memory-fusion
- Reference architecture (knowledge organization + lookup protocol):
  https://github.com/blessonism/openclaw-memory-architecture
- Discussion thread (Linux.do):
  https://linux.do/t/topic/1642100

## Current status (now)

L1-L3 is already production-usable:

- L1 (hourly): incremental session scan (byte-offset cursors) + de-noise + anti-recursion (no self-ingestion)
- L2 (daily): canonical daily summary + A' rolling 7-day section in `MEMORY.md`
- L3 (weekly): gated (at-least-once-per-ISO-week) consolidation + promotion + cleanup

Decision: **do not introduce new layers immediately**. Observe and iterate L1-L3 first.

## Key observation (important)

OpenClaw injects a fixed set of workspace bootstrap files into the system prompt on every turn
(e.g. `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `IDENTITY.md`, `HEARTBEAT.md`, `MEMORY.md`).

Therefore:

- Moving content from `MEMORY.md` into other bootstrap files does **NOT** reduce context usage.
- To reduce context pressure, keep bootstrap files concise and move bulk content into deep storage
  under `memory/` (loaded only on demand via recall tools).

## L4 candidate: Knowledge organization & lookup governance (future)

We may add a longer-interval job (monthly/quarterly) to improve **knowledge organization**
without destabilizing the extraction pipeline.

### Goals

- Keep `MEMORY.md` as a true hot cache: compact, easy to decode, stable categories.
- Move durable knowledge into more structured deep storage under `memory/`:
  - `memory/glossary.md`
  - `memory/people/`
  - `memory/projects/`
  - `memory/knowledge/`
  - `memory/context/`
  - `memory/post-mortems.md`
- Introduce a deterministic lookup protocol (Path A) + semantic recall (Path B) guidance.
- Avoid automated "silent" rewrites of persona/user identity files; prefer proposals + human review.

### Non-goals

- Do not replace L1-L3 (file-scan extraction remains the truth source).
- Do not auto-edit `SOUL.md` / `USER.md` at high frequency.

### Suggested implementation approach

1) Start with a **static protocol doc** (no automation):
   - Add a short "Tiered Lookup Protocol" section to `AGENTS.md` (keep it small).
2) Add deep-storage directory conventions (only for NEW knowledge; no migration).
3) Only after 1-2 weeks of stable usage, consider L4 as a cron job.

### L4 output mode (recommended)

To keep risk low, L4 should not directly edit many bootstrap files.

Instead, L4 generates proposals:

- `memory/proposals/YYYY-MM/*.md`

Then a human reviews and applies the proposal.

## When to adopt (triggers)

Adopt L4 ideas when at least 2 of these happen:

- `MEMORY.md` starts bloating or is frequently truncated in `/context`.
- Frequent "decode" questions: who/what is X, project status, terminology.
- Semantic recall becomes noisy (high search-miss / high snippet churn).
- Entity count grows (people/projects/terms) and needs stable file layout.
- Facts evolve often (configs/status/roles) and we need a supersede-style fact chain.

## Research workflow (for future revisits)

For research tasks:

- Prefer grok-search (when configured) for up-to-date web research.
- Fallback to built-in web_search.
- Do not rely on web_fetch if it is blocked/unreliable in the current environment.

