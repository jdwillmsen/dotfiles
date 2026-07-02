#!/usr/bin/env bash
# Stop hook: emit a compact session summary to the status bar.
# Receives session JSON on stdin; outputs {"systemMessage": "..."} for Claude Code.

INPUT="$(cat)"
COST=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
cost = d.get('cost', {}).get('total_cost_usd', 0)
dur_ms = d.get('cost', {}).get('total_duration_ms', 0)
added = d.get('cost', {}).get('total_lines_added', 0)
removed = d.get('cost', {}).get('total_lines_removed', 0)
dur = int(dur_ms / 1000)
h, rem = divmod(dur, 3600)
m, s = divmod(rem, 60)
dur_str = f'{h}h{m}m' if h else (f'{m}m{s}s' if m else f'{s}s')
parts = []
if cost: parts.append(f'\${cost:.2f}')
if dur_str: parts.append(dur_str)
if added or removed: parts.append(f'+{added}/-{removed} lines')
print('  '.join(parts))
" 2>/dev/null || true)

[ -z "$COST" ] && exit 0

python3 -c "import json; print(json.dumps({'systemMessage': 'Session: $COST'}))"
