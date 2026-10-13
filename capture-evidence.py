#!/usr/bin/env python3
"""Copy this run's diagnostic state (never editor text) and summarize it."""
import collections
import datetime
import json
import pathlib
import re
import tempfile

root = pathlib.Path(__file__).resolve().parent
source = pathlib.Path(tempfile.gettempdir()) / 'window-focus-prototype.jsonl'
rows = [json.loads(line) for line in source.read_text().splitlines()]
# Earlier diagnostic builds included key codes; preserve only whether the key was Escape.
for row in rows:
    row['event'] = re.sub(r'keyDown code=(\d+)', lambda m: 'keyDown escape=' + str(m[1] == '53').lower(), row['event'])
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
destination = root / 'evidence' / f'{stamp}-runtime.jsonl'
destination.write_text('\n'.join(json.dumps(row, sort_keys=True) for row in rows) + '\n')
print(destination)
print('Events:', len(rows))
print('Invocation sessions:', sorted({r['session'] for r in rows if r['event'] == 'invoke.new'}))
print('Policies:', dict(collections.Counter(r['policy'] for r in rows)))
print('Native marked-text events:', sum('setMarkedText' in r['event'] for r in rows))
for r in rows:
    if r['event'].startswith(('invoke.', 'dismiss.', 'policy.', 'working.', 'space.')):
        print(r['time'], r['event'], 'session', r['session'], r['policy'],
              'front', r['frontBundle'], 'bar-key', r['barKey'],
              'length', r['editorUTF16'], 'working', len(r['working']))
