#!/usr/bin/env bash
# boot-test.sh — parallel identity check for the scout fleet
H="$HOME/AppData/Local/hermes/profiles/art/skills/research/deep-research-diamond"
mkdir -p /tmp/bootlogs
for b in scout-deepseek scout-glm scout-minimax lead-researcher; do
  ( hermes -p "$b" chat -Q -q "Boot test. Reply with exactly: ${b}-OK and nothing else." >/tmp/bootlogs/$b.log 2>&1 ) &
done
wait
for b in scout-deepseek scout-glm scout-minimax lead-researcher; do
  echo "=== $b ==="; tail -3 /tmp/bootlogs/$b.log
done
