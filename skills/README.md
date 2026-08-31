# Hermes Agent Skills

Reusable [Hermes Agent](https://github.com/NousResearch/hermes-agent) skills. Drop a skill directory into your profile's `skills/` folder (or copy it into a repo and run `hermes skills trust`).

## Available

| Skill | Description |
|---|---|
| [`deep-research-diamond`](./deep-research-diamond/) | Multi-model deep research: 3 model-diverse scout bots research independently in parallel → fusion agent reconciles with attribution → Supabase persistence by `run_id`. Idempotent and resumable at every phase. |

## Installing

```bash
# Copy into your Hermes profile's skills directory, e.g.:
cp -r skills/deep-research-diamond \
   "$HOME/AppData/Local/hermes/profiles/<your-profile>/skills/research/"

# Or on Linux/macOS:
cp -r skills/deep-research-diamond ~/.hermes/profiles/<your-profile>/skills/research/
```

Then verify with `hermes skills list`.
