#!/bin/bash
# Drive the installed app with synthetic Claude Code hooks, through the real helper and
# socket, so paint timing can be compared before and after a change. Nothing is read back
# from the pad: the numbers come from the app's own "paint stats" log line, which lands
# within a minute of the run ending.
#
#   tools/led-load.sh [sessions] [rounds]
#
# Sessions are named obtest-* and always end themselves, even on Ctrl-C.
set -u
HOOK=/Applications/OpenBoard.app/Contents/MacOS/openboard-hook
SESSIONS=${1:-3}
ROUNDS=${2:-3}
LOG="$HOME/Library/Logs/OpenBoard/app.log"

send() { # event session
    printf '{"hook_event_name":"%s","session_id":"%s","cwd":"/tmp/%s"}' "$1" "$2" "$2" \
        | CLAUDE_CODE_ENTRYPOINT=cli "$HOOK" --event "$1"
}

ids=()
for n in $(seq 1 "$SESSIONS"); do ids+=("obtest-$$-$n"); done
cleanup() { for id in "${ids[@]}"; do send SessionEnd "$id"; done; }
trap cleanup EXIT

session() { # id
    send SessionStart "$1"
    for _ in $(seq 1 "$ROUNDS"); do
        send UserPromptSubmit "$1"
        for _ in 1 2 3; do sleep 0.3; send PostToolUse "$1"; done
        sleep 1
        send Stop "$1"
        sleep 3
    done
}

start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "load: $SESSIONS sessions x $ROUNDS rounds, from $start"
for id in "${ids[@]}"; do session "$id" & sleep 0.2; done
wait
echo "load: done at $(date -u +%Y-%m-%dT%H:%M:%SZ) — paint stats follow in $LOG within ~70s"
