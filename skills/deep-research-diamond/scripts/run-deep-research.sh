#!/usr/bin/env bash
# run-deep-research.sh — diamond runner for the deep-research-diamond skill.
# Usage:
#   ./run-deep-research.sh new "<question>"     # start a new run
#   ./run-deep-research.sh resume <run_id>      # resume, skipping validated phases
#   ./run-deep-research.sh dryrun "<question>"  # intake + plan only (no bot calls)
#
# Phases: intake -> wave1 (3 scouts, parallel) -> fusion -> persist -> done
# Launch with the terminal tool: background=true, notify_on_complete=true
# (the fan-out uses bash & + wait, which foreground terminal commands reject).

set -uo pipefail

RUNS_ROOT="$HOME/deep-research-runs"
SCOUTS=(scout-deepseek scout-glm scout-minimax)
FUSION_BOT="lead-researcher"
PERSIST_BOT="supabase-bot"
BOT_TIMEOUT="${BOT_TIMEOUT:-1800}"   # seconds per bot invocation (research runs are long; override via env)

# Native Windows path for prompts (bots' file tools need C:/... not /c/...)
WINHOME="$(cd ~ && pwd -W 2>/dev/null || echo "$HOME")"
WIN_RUNS_ROOT="${WINHOME}/deep-research-runs"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1 (install it first)"; }
need hermes
# JSON helper: prefer python3, then python (Hermes hosts always have one)
PY="$(command -v python3 || command -v python)" || die "missing dependency: python"
PY="${PY/cpython3.exe/python}"   # MSYS shim safety

wpath() { # msys path -> windows form for native python ( /c/x -> C:/x )
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$p"
  else printf '%s' "${p/\/c\//C:\/}"; fi
}

slugify() { # first 40 chars, lowercase, alnum->hyphen
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 \
    | sed -E 's/-$//'
}

set_status() { # set_status <run_dir> <key> <value>  (updates <run_dir>/status.json)
  local dir="$1"; shift
  "$PY" - "$(wpath "$dir/status.json")" "$@" <<'PYEOF'
import json, sys, os
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as f: d = json.load(f)
except Exception:
    d = {}
d[key] = val
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f: json.dump(d, f, indent=2)
os.replace(tmp, path)
PYEOF
}

findings_ok() { # json parses + claims/citations arrays present?
  "$PY" - "$(wpath "$1")" <<'PYEOF' >/dev/null 2>&1
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: d = json.load(f)
assert isinstance(d.get("claims"), list) and isinstance(d.get("citations"), list)
PYEOF
}

fusion_ok() { # all four contract keys present?
  "$PY" - "$(wpath "$1")" <<'PYEOF' >/dev/null 2>&1
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: d = json.load(f)
for k in ("agreements", "disagreements", "synthesis", "confidence"): assert k in d
PYEOF
}

invoke_bot() { # invoke_bot <profile> <query_file> <log_file>
  local profile="$1" qfile="$2" log="$3"
  # hermes CLI is a native program — it needs the C:/ Windows path, not /c/...
  local win_qfile; win_qfile="$(wpath "$qfile")"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$BOT_TIMEOUT" hermes -p "$profile" chat -Q --query-file "$win_qfile" >"$log" 2>&1
  else
    hermes -p "$profile" chat -Q --query-file "$win_qfile" >"$log" 2>&1
  fi
}

scout_prompt() { # scout_prompt <run_id> <bot> <question> -> stdout
  cat <<EOF
Deep-research scout task (run $1).

Question: $3

Research this question independently and deeply. Primary sources over press over blogs; 15-30 tool calls. You cannot see other scouts — do not try.

Write TWO files to these EXACT Windows paths:
  $WIN_RUNS_ROOT/$1/findings-$2.json
  $WIN_RUNS_ROOT/$1/findings-$2.md

The .json must match this schema:
{
  "run_id": "$1", "agent": "$2", "model": "<your model>", "question": "<verbatim>",
  "claims": [ { "claim_id": "c1", "statement": "...", "confidence": "high|medium|low",
                "citations": ["s1"], "quotes": [ { "citation_id": "s1", "quote": "<verbatim <=40 words>" } ] } ],
  "citations": [ { "citation_id": "s1", "url": "...", "title": "...", "publisher": "...",
                   "accessed_at": "YYYY-MM-DD", "source_type": "primary|official|press|analysis|community" } ],
  "open_questions": [ { "question": "...", "why": "..." } ],
  "gaps": ["..."]
}

Rules: every claim needs >=1 resolvable citation with a verbatim quote (<=40 words); unverifiable -> open_questions, never claims; citation ids s1, s2, ... ; the .md renders the same content for humans.

START IMMEDIATELY with your first web_search call — do not reply with a plan or narration first. If you catch yourself writing text before any tool call, stop and call the tool instead.

End your reply with exactly: DONE $1
EOF
}

fusion_prompt() { # fusion_prompt <run_id> -> stdout
  local rid="$1"
  cat <<EOF
Deep-research fusion task (run $rid). You are the fusion node. Read ONLY these three files — do NOT search, fetch, or browse anything new:
  $WIN_RUNS_ROOT/$rid/findings-scout-deepseek.json
  $WIN_RUNS_ROOT/$rid/findings-scout-glm.json
  $WIN_RUNS_ROOT/$rid/findings-scout-minimax.json

Fuse them into $WIN_RUNS_ROOT/$rid/fusion.json matching this schema:
{
  "run_id": "$rid", "agents": ["scout-deepseek","scout-glm","scout-minimax"],
  "agreements": [ { "topic": "...", "agents": ["...","..."], "statement": "...", "citations": ["agent:sN"] } ],
  "disagreements": [ { "topic": "...",
      "positions": [ { "agent": "...", "claim_id": "...", "position": "<VERBATIM from findings>", "citations": ["agent:sN"] } ],
      "what_would_resolve": "..." } ],
  "unique_contributions": [ { "agent": "...", "claim_id": "...", "contribution": "...", "citations": ["agent:sN"] } ],
  "synthesis": "<narrative: agreements as spine, disagreements inline with attribution, contributions woven in>",
  "confidence": { "level": "high|medium|low", "note": "..." }
}

Rules: disagreements keep EVERY position verbatim, attributed, with citations — never average, vote away, or drop a position; all four top-level keys required even if an array is empty; citation refs prefixed agent:sN so they trace back to research.citations.

Also write the human-readable rendering to $WIN_RUNS_ROOT/$rid/fusion.md.

End your reply with exactly: FUSED $rid
EOF
}

persist_prompt() { # persist_prompt <run_id> -> stdout
  local rid="$1"
  cat <<EOF
Persist deep-research run $rid to Supabase (schema: research.*). If the tables do not exist yet, apply this idempotent migration first:

create schema if not exists research;
create table if not exists research.runs (run_id text primary key, question text not null, status text not null default 'running', created_at timestamptz not null default now(), completed_at timestamptz);
create table if not exists research.findings (run_id text not null references research.runs(run_id), agent text not null, model text not null, payload jsonb not null, updated_at timestamptz not null default now(), primary key (run_id, agent));
create table if not exists research.citations (run_id text not null references research.runs(run_id), agent text not null, citation_id text not null, url text not null, title text, publisher text, source_type text, accessed_at date, primary key (run_id, agent, citation_id));
create table if not exists research.syntheses (run_id text primary key references research.runs(run_id), agreements jsonb not null, disagreements jsonb not null, unique_contributions jsonb not null, synthesis text not null, confidence jsonb not null, updated_at timestamptz not null default now());
create index if not exists idx_findings_run on research.findings(run_id);
create index if not exists idx_citations_run on research.citations(run_id);

Artifacts (read from disk):
  $WIN_RUNS_ROOT/$rid/findings-scout-deepseek.json
  $WIN_RUNS_ROOT/$rid/findings-scout-glm.json
  $WIN_RUNS_ROOT/$rid/findings-scout-minimax.json
  $WIN_RUNS_ROOT/$rid/fusion.json

Steps:
1. Upsert research.runs (run_id='$rid', question from any findings file, status stays 'running' until step 4).
2. Per scout: upsert research.findings (run_id, agent, model, payload=verbatim JSON) on conflict (run_id,agent) do update; explode citations[] -> research.citations (run_id, agent, citation_id, url, title, publisher, source_type, accessed_at) on conflict (run_id,agent,citation_id) do update.
3. Upsert research.syntheses from fusion.json on conflict (run_id) do update — preserve disagreements verbatim.
4. Update research.runs set status='complete', completed_at=now().
All writes are upserts on natural keys — re-persisting must not duplicate.

Reply with exactly: PERSISTED findings=<n> citations=<n> syntheses=<n>
EOF
}

run_wave1() { # run_wave1 <dir> <run_id> <question>
  local dir="$1" rid="$2" q="$3" bot attempt
  echo "--- Wave 1: fanning out ${#SCOUTS[@]} scouts in parallel ---"
  for bot in "${SCOUTS[@]}"; do
    if [[ -f "$dir/findings-$bot.json" ]] && findings_ok "$dir/findings-$bot.json"; then
      echo "  $bot: findings already valid — skipping"
      set_status "$dir" "wave1_$bot" "complete"
      continue
    fi
    scout_prompt "$rid" "$bot" "$q" > "$dir/prompt-$bot.txt"
    echo "  $bot: dispatching..."
    (
      # NOTE: no set_status here — parallel read-modify-write on status.json
      # loses updates. Per-bot truth = log + artifact check below; the ledger
      # is written only by the serial main process.
      for attempt in 1 2; do
        invoke_bot "$bot" "$dir/prompt-$bot.txt" "$dir/log-$bot.txt"
        if [[ -f "$dir/findings-$bot.json" ]] && findings_ok "$dir/findings-$bot.json"; then
          break
        fi
        [[ $attempt -eq 1 ]] && cp "$dir/log-$bot.txt" "$dir/log-$bot-attempt1.txt"
      done
    ) &
  done
  wait
  local ok=1
  for bot in "${SCOUTS[@]}"; do
    if findings_ok "$dir/findings-$bot.json" 2>/dev/null; then
      set_status "$dir" "wave1_$bot" "complete"
    else
      set_status "$dir" "wave1_$bot" "failed"
      echo "  $bot: FAILED (see $dir/log-$bot.txt)"
      ok=0
    fi
  done
  [[ $ok -eq 1 ]] || return 1
  set_status "$dir" "wave1" "complete"
  echo "--- Wave 1 complete ---"
}

run_fusion() { # run_fusion <dir> <run_id>
  local dir="$1" rid="$2"
  if [[ -f "$dir/fusion.json" ]] && fusion_ok "$dir/fusion.json"; then
    echo "--- Fusion already valid — skipping ---"
    set_status "$dir" "fusion" "complete"
    return 0
  fi
  echo "--- Fusion: dispatching $FUSION_BOT ---"
  fusion_prompt "$rid" > "$dir/prompt-fusion.txt"
  invoke_bot "$FUSION_BOT" "$dir/prompt-fusion.txt" "$dir/log-fusion.txt"
  if [[ -f "$dir/fusion.json" ]] && fusion_ok "$dir/fusion.json"; then
    set_status "$dir" "fusion" "complete"
    echo "--- Fusion complete ---"
    return 0
  fi
  echo "Fusion FAILED (see $dir/log-fusion.txt)"
  set_status "$dir" "fusion" "failed"
  return 1
}

run_persist() { # run_persist <dir> <run_id>
  local dir="$1" rid="$2"
  # NOTE: check the log TAIL only — the log opens with the query echo, and the
  # prompt itself contains the word PERSISTED (false-positive if grepped whole).
  if tail -c 2000 "$dir/log-persist.txt" 2>/dev/null | grep -q "PERSISTED"; then
    echo "--- Persistence already confirmed — skipping ---"
    set_status "$dir" "persist" "complete"
    return 0
  fi
  echo "--- Persistence: dispatching $PERSIST_BOT ---"
  persist_prompt "$rid" > "$dir/prompt-persist.txt"
  invoke_bot "$PERSIST_BOT" "$dir/prompt-persist.txt" "$dir/log-persist.txt"
  if tail -c 2000 "$dir/log-persist.txt" 2>/dev/null | grep -q "PERSISTED"; then
    set_status "$dir" "persist" "complete"
    echo "--- Persistence confirmed: $(tail -c 2000 "$dir/log-persist.txt" | grep PERSISTED | tail -1) ---"
    return 0
  fi
  echo "Persistence FAILED (see $dir/log-persist.txt)"
  set_status "$dir" "persist" "failed"
  return 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new|dryrun)
    [[ $# -ge 1 ]] || die "usage: $0 {new|dryrun} \"<question>\""
    QUESTION="$*"
    RID="dr-$(date +%Y%m%d-%H%M%S)-$(slugify "$QUESTION")"
    DIR="$RUNS_ROOT/$RID"
    mkdir -p "$DIR" || die "cannot create $DIR"
    printf '%s' "$QUESTION" > "$DIR/question.txt"
    echo '{"intake":"complete"}' > "$DIR/status.json"
    echo "RUN_ID=$RID"
    echo "RUN_DIR=$DIR"
    [[ "$cmd" == "dryrun" ]] && { echo "DRYRUN: would fan out to [${SCOUTS[*]}] -> $FUSION_BOT -> $PERSIST_BOT"; echo "DRYRUN: prompts would reference $WIN_RUNS_ROOT/$RID"; exit 0; }
    ;;
  resume)
    [[ $# -ge 1 ]] || die "usage: $0 resume <run_id>"
    RID="$1"
    DIR="$RUNS_ROOT/$RID"
    [[ -d "$DIR" ]] || die "no such run: $RID (looked in $RUNS_ROOT)"
    QUESTION="$(cat "$DIR/question.txt")"
    echo "RESUME run $RID"
    ;;
  *) die "usage: $0 {new|dryrun|resume} ...";;
esac

set_status "$DIR" "run" "running"
run_wave1 "$DIR" "$RID" "$QUESTION"   || { set_status "$DIR" "run" "failed";  die "wave1 incomplete — fix scouts, then: $0 resume $RID"; }
run_fusion "$DIR" "$RID"              || { set_status "$DIR" "run" "failed";  die "fusion failed — then: $0 resume $RID"; }
run_persist "$DIR" "$RID"             || { set_status "$DIR" "run" "failed";  die "persist failed — then: $0 resume $RID"; }
set_status "$DIR" "run" "complete"

echo ""
echo "SUMMARY: run=$RID status=complete"
echo "Synthesis: $DIR/fusion.md"
echo "Query back: select agent, jsonb_array_length(payload->'claims') from research.findings where run_id='$RID';"
