#!/usr/bin/env python3
"""Apply two reviewed diffs to an already-created disposable base worktree."""
from pathlib import Path
import subprocess
import sys

BASE = '210e9f34de86d751de6eb80a584cc41cde560ee3'
EXPORT = '0592aab17803b2f1a0e5978af2f51aa4494a1bd8'
SNAPSHOT = '9dc752d07be3496f2c4f65d246a25990c15f3473'
root = Path(sys.argv[1]).resolve()


def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args])


assert git('rev-parse', 'HEAD').decode().strip() == BASE
assert not git('status', '--porcelain')
subprocess.run(['git', '-C', str(root), 'apply', '-'], input=git('diff', BASE, EXPORT), check=True)
skipped = ['Sources/Hana/CollectionRecovery.swift', 'Sources/Hana/CollectionFixtureHarness.swift', 'docs/technical-design.md']
assert git('show', EXPORT + ':' + skipped[0]) == git('show', SNAPSHOT + ':' + skipped[0])
patch = git('diff', BASE, SNAPSHOT, '--', '.', *[':(exclude)' + p for p in skipped])
subprocess.run(['git', '-C', str(root), 'apply', '-'], input=patch, check=True)

# Retain the snapshot harness with its read/emit access; insert the reviewed
# export-only additions from the export harness, without changing either flow.
path = skipped[1]
snapshot = git('show', SNAPSHOT + ':' + path).decode()
export = git('show', EXPORT + ':' + path).decode()
for first, end in [
    ('/// - `export <root>', '/// - `runtime-report <root>'),
    ('            case "export", "validate-export":', '            case "runtime-report":'),
    ('        case let error as CollectionRecovery.ExportError:', '        case is InjectedFailure:')
]:
    addition = export[export.index(first):export.index(end, export.index(first))]
    assert addition not in snapshot
    snapshot = snapshot.replace(end, addition + end, 1)
(root / path).write_text(snapshot)
path = skipped[2]
base = git('show', BASE + ':' + path).decode()
ours = git('show', SNAPSHOT + ':' + path).decode()
assert ours.startswith(base)
with (root / path).open('a') as output:
    output.write(ours[len(base):])
subprocess.run(['git', '-C', str(root), 'diff', '--check'], check=True)
print('Applied reviewed diffs without merging:', EXPORT, SNAPSHOT)
