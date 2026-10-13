#!/usr/bin/env bash
# Adapted from diagnosing-bugs/scripts/hitl-loop.template.sh.
# User observes the animation; automated state flags cannot locate its endpoint.
set -euo pipefail
scenario="${1:-single}"
case "$scenario" in
 single) instruction='Open Main using WF, then click its yellow minimize button. Watch where the animation ends.' ;;
 bulk) instruction='Open Main, Note A and Note B using WF, then choose WF > Minimize all working windows. Watch where the animations end.' ;;
 *) instruction="$scenario" ;;
esac
printf '\n>>> %s\n' "$instruction"
printf 'Report endpoint: top-left, dock, or unclear\n> '
read -r endpoint
case "$endpoint" in top-left|dock|unclear) ;; *) printf 'Invalid observation\n'; exit 2;; esac
printf 'SCENARIO=%s\nENDPOINT=%s\n' "$scenario" "$endpoint"
if [[ "$endpoint" == top-left ]]; then printf 'FAIL: reported top-left animation reproduced\n'; exit 1; fi
if [[ "$endpoint" == unclear ]]; then printf 'UNRESOLVED: no reliable endpoint observation\n'; exit 2; fi
printf 'PASS: observer saw animation to Dock\n'
