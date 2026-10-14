#!/usr/bin/env python3
"""Run only the signed Hana fixture entry point; create a unique local fixture."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid

binary = Path(sys.argv[1]).resolve()
parent = Path(sys.argv[2]).resolve()
parent.mkdir(parents=True, exist_ok=False)
root = parent / 'root'


def run(action, *args, text=''):
    result = subprocess.run([str(binary), '--collection-fixture', action, str(root), *map(str, args)],
                            input=text, capture_output=True, text=True, check=True)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    print(json.dumps({'action': action, 'events': events}, ensure_ascii=False), flush=True)
    return events


print(json.dumps({'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest()}))
run('create-root')
note = run('create-note', '--operation', uuid.uuid4(), text='# บันทึก\r\nExact e\u0301 🌸  \n')[-1]
run('pin-note', '--id', note['id'], '--revision', '1', '--pinned', 'true')
task = run('create-task', '--operation', uuid.uuid4(), '--placement', 'today', text='Saved task')[-1]
run('complete-task', '--id', task['id'], '--revision', '1')
run('archive-task', '--id', task['id'], '--revision', '2')
expected = run('read', '--query', 'all')
run('runtime-report')
snapshot = run('snapshot-create')[-1]
run('snapshot-list')
run('snapshot-inspect', '--id', snapshot['snapshotID'])
reopened = run('snapshot-reopen', '--id', snapshot['snapshotID'], '--destination', parent / 'verification')
assert reopened[:-1] == expected
print(json.dumps({'ordinaryFreshProcessReopenEquality': True, 'snapshotID': snapshot['snapshotID']}))
