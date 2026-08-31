# Data Contracts — Deep Research Diamond

Machine-checkable contracts for every artifact crossing a handoff. The runner enforces these structurally; the SOULs enforce them behaviorally.

---

## 1. Scout findings — `findings-<bot>.json`

Each scout writes exactly one file per run:

```json
{
  "run_id": "dr-20260227-101533-example-run",
  "agent": "scout-deepseek",
  "model": "deepseek-v4-flash",
  "question": "<verbatim research question>",
  "claims": [
    {
      "claim_id": "c1",
      "statement": "<one factual claim, falsifiable, no hedging bundled>",
      "confidence": "high | medium | low",
      "citations": ["s7"],
      "quotes": [{ "citation_id": "s7", "quote": "<verbatim ≤40 words from source>" }]
    }
  ],
  "citations": [
    {
      "citation_id": "s7",
      "url": "https://...",
      "title": "<page title>",
      "publisher": "<domain or org>",
      "accessed_at": "2026-02-27",
      "source_type": "primary | official | press | analysis | community"
    }
  ],
  "open_questions": [
    { "question": "<what could not be established with a citation>", "why": "<what was tried / what's missing>" }
  ],
  "gaps": ["<topics within scope that yielded no citable sources>"]
}
```

**Hard rules**
- Every `claims[].citations[]` entry MUST resolve to a `citations[].citation_id`. Unresolvable → move claim to `open_questions`.
- **A claim with zero citations is invalid** — no exceptions, no "well-known facts".
- Citation IDs are scoped per-scout (`s1, s2...`); global uniqueness comes from the `agent:` prefix at fusion.
- `findings-<bot>.md` (human-readable rendering) is a courtesy; `.json` is the contract.

## 2. Fusion — `fusion.json`

Written by `lead-researcher` ONLY from the three findings files. No fetching.

```json
{
  "run_id": "dr-20260227-101533-example-run",
  "agents": ["scout-deepseek", "scout-glm", "scout-minimax"],
  "agreements": [
    {
      "topic": "<shared conclusion>",
      "agents": ["scout-deepseek", "scout-glm"],
      "statement": "<fused statement>",
      "citations": ["scout-deepseek:s7", "scout-glm:s2"]
    }
  ],
  "disagreements": [
    {
      "topic": "<point of conflict>",
      "positions": [
        { "agent": "scout-deepseek", "claim_id": "c1", "position": "<VERBATIM from that scout's findings>", "citations": ["scout-deepseek:s7"] },
        { "agent": "scout-glm", "claim_id": "c3", "position": "<VERBATIM>", "citations": ["scout-glm:s5"] }
      ],
      "what_would_resolve": "<the single piece of evidence or check that would settle it>"
    }
  ],
  "unique_contributions": [
    { "agent": "scout-minimax", "claim_id": "c4", "contribution": "<finding only this scout surfaced>", "citations": ["scout-minimax:s1"] }
    }
  ],
  "synthesis": "<the deliverable narrative: agreements as the spine, disagreements surfaced inline with attribution, unique contributions woven in>",
  "confidence": {
    "level": "high | medium | low",
    "note": "<what drives the level: agreement breadth, source quality, unresolved disagreements>"
  }
}
```

**Hard rules**
- Runner requires all four keys: `agreements`, `disagreements`, `synthesis`, `confidence`. Missing `disagreements` key = hard reject (it may be an empty array ONLY if no claims conflict; the key must exist).
- Disagreement positions are **verbatim quotes** from the scout findings, each attributed. Never paraphrase a position into agreement. **Never average, vote away, or silently drop a position.**
- Cross-scout citation refs carry the `agent:citation_id` prefix — this is what makes citations traceable end-to-end (claim → scout → source URL in `research.citations`).
- A disagreement with a resolvable factual answer may be annotated in `what_would_resolve`, but both positions still persist.

## 3. Supabase schema — `research` schema

Applied by `supabase-bot` (it holds the credentials). Idempotent via `create schema if not exists` + `on conflict do nothing/update`.

```sql
create schema if not exists research;

-- One row per run (status ledger mirrors on-disk status.json)
create table if not exists research.runs (
  run_id      text primary key,
  question    text not null,
  status      text not null default 'running',  -- running|fusion|persisting|complete|failed
  created_at  timestamptz not null default now(),
  completed_at timestamptz
);

-- Raw findings, one row per scout per run (payload = findings JSON verbatim)
create table if not exists research.findings (
  run_id      text not null references research.runs(run_id),
  agent       text not null,
  model       text not null,
  payload     jsonb not null,
  updated_at  timestamptz not null default now(),
  primary key (run_id, agent)
);

-- Normalized citations, traceable to the scout that produced them
create table if not exists research.citations (
  run_id      text not null references research.runs(run_id),
  agent       text not null,
  citation_id text not null,          -- scout-local id (s1, s2...)
  url         text not null,
  title       text,
  publisher   text,
  source_type text,
  accessed_at date,
  primary key (run_id, agent, citation_id)
);

-- One synthesis per run (disagreements live inside the JSONB and are never flattened away)
create table if not exists research.syntheses (
  run_id      text primary key references research.runs(run_id),
  agreements  jsonb not null,
  disagreements jsonb not null,       -- MUST preserve every attributed position
  unique_contributions jsonb not null,
  synthesis   text not null,
  confidence  jsonb not null,
  updated_at  timestamptz not null default now()
);

create index if not exists idx_findings_run on research.findings(run_id);
create index if not exists idx_citations_run on research.citations(run_id);
```

**Upsert semantics** (why re-persisting is safe):
- `findings` — `insert ... on conflict (run_id, agent) do update set payload = excluded.payload, updated_at = now()`
- `citations` — `on conflict (run_id, agent, citation_id) do update set url = excluded.url, ...`
- `syntheses` — `on conflict (run_id) do update set ...`
- `runs.status` transitions `running → complete`; `completed_at` set once.

**Query-back verification** (the runner/PM runs this after persist):
```sql
select agent, jsonb_array_length(payload->'claims') as claims from research.findings where run_id = '<run_id>';
select status from research.runs where run_id = '<run_id>';
```
Expect 3 findings rows and `status = 'complete'`.

### Airtable variant
Same natural keys as field groups: base "Deep Research" → tables `Runs` (key: run_id), `Findings` (key: run_id+agent), `Citations` (key: run_id+agent+citation_id), `Syntheses` (key: run_id). JSON columns become long-text fields holding the JSON. Confirmation keyword unchanged (`PERSISTED`).

## 4. SOUL templates

### Scout SOUL (write per scout; only Role/Model lines differ)

```markdown
You are **scout-deepseek**, an independent research scout in a deep-research diamond.

## Mission
Research the question you are given — alone. Produce findings where every claim is cited.

## Rules
- You are INDEPENDENT. You cannot see other scouts and must not try. No assumptions about what others found.
- Research deeply: multiple searches, extract primary sources, follow citations. Budget ~15-30 tool calls.
- EVERY claim in `claims[]` must cite ≥1 source in `citations[]`, with a verbatim quote (≤40 words).
- Cannot verify something? It goes to `open_questions` — never into `claims`.
- Cite what sources SAY, not your summary of them. Dates, numbers, article numbers verbatim.
- Write output to the exact Windows paths given in the prompt, as valid JSON (then .md rendering).

## Output contract
End your reply with: `DONE <run_id>`. Your deliverable is `findings-scout-deepseek.json` matching the schema in the prompt.

## Boundary
You are a leaf scout. Do not persist to any database, do not message other agents, do not synthesize across scouts — fusion is another agent's job.
```

### Fusion SOUL (for `lead-researcher` — append if its SOUL lacks these)

```markdown
## Deep-research fusion duty
When given a fusion request for run `<run_id>`:
- Read ONLY the three findings files at the given paths. DO NOT web-search, fetch, or browse — fusion adds no new facts.
- Produce `fusion.json` per the schema: agreements (≥2 scouts), disagreements (VERBATIM positions, each attributed), unique_contributions, synthesis, confidence.
- Disagreements are never averaged, voted away, or dropped. Both positions persist verbatim with citations; add `what_would_resolve`.
- Synthesis leads with the strongest agreed finding, surfaces disagreements inline with attribution ("scout-glm found X (s5); scout-deepseek found Y (s7)"), ends with the confidence note.
- Every citation ref you emit must be `agent:citation_id`.
- End your reply with: `FUSED <run_id>`.
```

### Persistence instruction (sent to `supabase-bot` per run)

```markdown
Persist deep-research run <run_id>:
1. Upsert findings: read findings-<bot>.json for each of the 3 scouts → research.findings (run_id, agent, model, payload).
2. Normalize citations: for each scout, explode citations[] → research.citations (run_id, agent, citation_id, url, title, publisher, source_type, accessed_at).
3. Upsert fusion.json → research.syntheses (run_id, agreements, disagreements, unique_contributions, synthesis, confidence). Preserve disagreements verbatim.
4. Update research.runs: status='complete', completed_at=now().
All writes are upserts on natural keys. Reply with `PERSISTED findings=<n> citations=<n> syntheses=<n>` and nothing else.
```

## 5. Prompt templates (runner → bot)

### Scout prompt (`--query-file`, one per scout)

```
Message from 🤖 art (@art): deep-research scout task.

Run: <run_id>
Question: <question verbatim>

Research this question independently and deeply (primary sources > press > blogs; 15-30 tool calls).
Write TWO files (use these EXACT Windows paths):
  C:/Users/<you>/deep-research-runs/<run_id>/findings-<bot>.json
  C:/Users/<you>/deep-research-runs/<run_id>/findings-<bot>.md

The .json must match this schema exactly: <inline scout schema from §1>.

Rules: every claim cited (verbatim quote ≤40 words); unverifiable → open_questions; citation ids s1,s2,...
End your reply with exactly: DONE <run_id>
```

### Fusion prompt

```
Message from 🤖 art (@art): fusion task for run <run_id>.

Read these three files (do NOT fetch anything new):
  C:/Users/<you>/deep-research-runs/<run_id>/findings-scout-deepseek.json
  C:/Users/<you>/deep-research-runs/<run_id>/findings-scout-glm.json
  C:/Users/<you>/deep-research-runs/<run_id>/findings-scout-minimax.json

Fuse them into C:/Users/<you>/deep-research-runs/<run_id>/fusion.json matching: <inline fusion schema from §2>.

Rules: disagreements keep every position VERBATIM with attribution; citation refs prefixed agent:citation_id; all four top-level keys required.
End your reply with exactly: FUSED <run_id>
```

### Persistence prompt

```
Message from 🤖 art (@art): persist task for run <run_id>.

<persistence instruction from §4, with paths filled in>
Artifacts:
  C:/Users/<you>/deep-research-runs/<run_id>/findings-scout-deepseek.json
  C:/Users/<you>/deep-research-runs/<run_id>/findings-scout-glm.json
  C:/Users/<you>/deep-research-runs/<run_id>/findings-scout-minimax.json
  C:/Users/<you>/deep-research-runs/<run_id>/fusion.json
End your reply with exactly: PERSISTED findings=<n> citations=<n> syntheses=<n>
```
