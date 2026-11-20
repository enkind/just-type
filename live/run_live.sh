#!/bin/zsh
# usage: ./run_live.sh <none|justtype|rekey|unfumble> [n_episodes] [minMs] [maxMs] [resume_from]
# Runs the typing harness with exactly one tool active, then scores it.
set -e
cd "$(dirname $0)"
TOOL=$1; N=${2:-100}; MIN=${3:-40}; MAX=${4:-90}; FROM=${5:-0}
OUT=$PWD/../results/live; mkdir -p $OUT
APP=$PWD/build/JustType.app
quit_all() {
  pkill -f "MacOS/JustType tool" 2>/dev/null || true
  osascript -e 'quit app "Rekey"' 2>/dev/null || true
  osascript -e 'quit app "Unfumble"' 2>/dev/null || true
  sleep 2
}
if ioreg -l -w 0 | grep -q '"SecureInput"'; then echo "Secure input is ON somewhere (password field / Terminal secure entry); turn it off first"; exit 1; fi
quit_all
trap quit_all EXIT INT TERM   # never leave a tool running, even if the harness fails
case $TOOL in
  none) ;;
  justtype) ($APP/Contents/MacOS/JustType tool $OUT/justtype_tool.log ${TE:-0.8} ${TM:-0.995} ${NMIN:-4} &); sleep 3 ;;
  rekey) open -a Rekey; sleep 6 ;;
  unfumble) open -a Unfumble; sleep 6 ;;
  *) echo "unknown tool"; exit 1 ;;
esac
[[ $FROM == 0 ]] && rm -f $OUT/$TOOL.jsonl $OUT/$TOOL.jsonl.log
$APP/Contents/MacOS/JustType bench $PWD/Resources/episodes.jsonl $OUT/$TOOL.jsonl $TOOL $MIN $MAX $N $FROM || echo "harness exited with error"
quit_all
cat $OUT/$TOOL.jsonl.log
cd ../bench && ../.venv/bin/python live_score.py $OUT/$TOOL.jsonl
