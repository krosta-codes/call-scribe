#!/bin/zsh
# Usage: process_call.sh <session-dir> <with> <project>
# session-dir holds me.caf (you) and them.caf (other side), optionally meta.json.
# Writes <vault>/Projects/<project>/calls/<contact>/<stem>.md; <contact> = parent folder of session-dir.
# Env: CALLSCRIBE_VAULT (vault root override), CALLSCRIBE_NO_NOTIFY=1, CALLSCRIBE_FROM_APP=1 (app posts the notification),
#      CALLSCRIBE_CLAUDE_MODEL (default sonnet), CALLSCRIBE_SKIP_CLAUDE=1, CALLSCRIBE_ME (your name, default Me).
# Last stdout line: NOTE: <path>
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SESSION="${1:A}"; WITH="${2:-Unknown}"; PROJECT="${3:-Calls}"
ME="${CALLSCRIBE_ME:-Me}"
[[ -d "$SESSION" ]] || { echo "no such session dir: $SESSION" >&2; exit 2; }
VAULT="${CALLSCRIBE_VAULT:-$HOME/Documents/CallScribe}"
STEM="${SESSION:t}"
OUTDIR="$VAULT/Projects/$PROJECT/calls"
# layout since 2026-11-16: <archive>/<Project>/calls/<Contact>/<stem>; the note mirrors the contact folder
[[ "${SESSION:h:t}" != "calls" ]] && OUTDIR="$OUTDIR/${SESSION:h:t}"
NOTE="$OUTDIR/$STEM.md"
MODEL="$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
CLAUDE_MODEL="${CALLSCRIBE_CLAUDE_MODEL:-sonnet}"
LOG="$SESSION/process.log"
ERRORS=()
mkdir -p "$OUTDIR"
exec > >(tee -a "$LOG") 2>&1
echo "== process_call $(date '+%F %T') session=$SESSION with=$WITH project=$PROJECT"

# timeout fallback (perl alarm) if `timeout` is missing
if command -v timeout >/dev/null; then TO() { timeout "$@"; }
else TO() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }; fi

# 1. wav + whisper per track
for T in me them; do
  SRC="$SESSION/$T.caf"; [[ -s "$SRC" ]] || SRC="$SESSION/$T.m4a"   # m4a after compression (re-runs)
  [[ -s "$SRC" ]] || { echo "track $T missing"; continue }
  ffmpeg -nostdin -loglevel error -y -i "$SRC" -ar 16000 -ac 1 "$SESSION/$T.wav" || { ERRORS+=("ffmpeg failed for $T"); continue }
  if [[ ! -s "$SESSION/$T.json" ]]; then
    TO 1800 whisper-cli -m "$MODEL" -f "$SESSION/$T.wav" -l auto -oj -of "$SESSION/$T" -np >/dev/null 2>>"$LOG" \
      || ERRORS+=("whisper-cli failed for $T")
  fi
done

# 2. merge transcripts, compute duration + date
TRANSCRIPT="$SESSION/transcript.txt"
python3 -I - "$SESSION" "$WITH" "$ME" >"$TRANSCRIPT" 2>>"$LOG" <<'PY' || ERRORS+=("transcript merge failed")
import json, os, re, subprocess, sys
sess, other, me = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for track, name in (("me", me), ("them", other)):
    p = os.path.join(sess, track + ".json")
    if not os.path.isfile(p): continue
    with open(p, encoding="utf-8", errors="replace") as f:
        data = json.load(f)
    # whisper often stamps a segment after leading silence with start 0: snap starts to the end of silence
    sil = []
    wav = os.path.join(sess, track + ".wav")
    if os.path.isfile(wav):
        out = subprocess.run(["ffmpeg", "-nostdin", "-i", wav, "-af", "silencedetect=noise=-38dB:d=0.4", "-f", "null", "-"],
                             capture_output=True, text=True).stderr
        starts = [float(x) for x in re.findall(r"silence_start: (-?[\d.]+)", out)]
        ends = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", out)]
        sil = list(zip(starts, ends))
    for seg in data.get("transcription", []):
        t = seg.get("text", "").strip()
        if not t or re.fullmatch(r"[\[\(\*♪ ].*[\]\)\*♪]", t) and len(t) < 40:  # [BLANK_AUDIO], (music) ...
            continue
        ms = seg.get("offsets", {}).get("from", 0)
        to = seg.get("offsets", {}).get("to", ms)
        for a, b in sil:
            if a * 1000 - 300 <= ms < b * 1000 and b * 1000 < to:
                ms = int(b * 1000)
        rows.append((ms, name, t))
rows.sort(key=lambda r: r[0])
# Echo filter (2026-11-16): on laptop speakers the mic also hears the other side, so whisper writes the
# same sentence twice. Drop a line of mine when the other side said nearly the same within 5 s.
import difflib
norm = lambda s: " ".join(re.findall(r"[a-z0-9']+", s.lower()))
them = [(ms, norm(t)) for ms, n, t in rows if n != me]
def echo(ms, t):
    a = norm(t)
    return bool(a) and any(abs(ms - m2) <= 5000 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.6 for m2, b in them)
dropped = [r for r in rows if r[1] == me and echo(r[0], r[2])]
rows = [r for r in rows if not (r[1] == me and echo(r[0], r[2]))]
print(f"echo filter dropped {len(dropped)} of my lines", file=sys.stderr)
# whisper sometimes repeats a line: drop a repeat of the same speaker's previous line within 10 s
out, last = [], {}
for ms, name, t in rows:
    p = last.get(name)
    if p and ms - p[0] <= 10000 and norm(t) == norm(p[1]):
        continue
    last[name] = (ms, t); out.append((ms, name, t))
rows = out
for ms, name, t in rows:
    s = ms // 1000
    print(f"[{s//60:02d}:{s%60:02d}] {name}: {t}")
PY
DUR=$(for f in "$SESSION/me.wav" "$SESSION/them.wav"; do [[ -f $f ]] && ffprobe -v error -show_entries format=duration -of csv=p=0 "$f"; done | sort -n | tail -1)
DUR=${DUR:-0}; DURTXT=$(printf '%d min %02d s' $((${DUR%.*} / 60)) $((${DUR%.*} % 60)))
START=$(jq -r '.start // empty' "$SESSION/meta.json" 2>/dev/null)
DATE_H="${START:+${START[1,10]}}"; [[ -z "$DATE_H" ]] && DATE_H="${STEM[1,10]}"
TIME_H="${START:+${START[12,16]}}"; [[ -z "$TIME_H" ]] && TIME_H="${STEM[12,13]}:${STEM[14,15]}"

# 3. summary via claude (subscription, no API key)
SUMMARY="$SESSION/summary.md"; : >"$SUMMARY"
if [[ ! -s "$TRANSCRIPT" ]]; then
  ERRORS+=("transcript is empty (no speech detected or whisper failed)")
elif [[ -n "${CALLSCRIBE_SKIP_CLAUDE:-}" ]]; then
  ERRORS+=("claude skipped (CALLSCRIBE_SKIP_CLAUDE)")
else
  PROMPT="You get the transcript of a phone call between $ME and $WITH (project: $PROJECT). Lines look like [mm:ss] Speaker: text. Speech recognition can contain errors; fix obvious name or term mistakes silently. Answer in the language of the call. Output ONLY these markdown sections, with exactly these headings, no preamble and no closing remarks:
## Summary
(3 to 5 lines)
## Decisions
## To-dos $ME
## To-dos $WITH
## Open questions
## Facts that change the project state
Use bullet lists in all sections except Summary. Write '- none' if a section is empty. Rules: never use em dashes or en dashes (U+2014, U+2013); use a comma, a colon or a new sentence instead. Do not invent anything that is not in the transcript."
  ( cd "$(mktemp -d)" && TO 300 claude -p --model "$CLAUDE_MODEL" --no-session-persistence "$PROMPT" <"$TRANSCRIPT" ) >"$SUMMARY" 2>>"$LOG" \
    || { ERRORS+=("claude summary failed or timed out (exit $?)"); }
  [[ -s "$SUMMARY" ]] || ERRORS+=("claude returned no summary")
fi

# 4. write note
{
  echo "# Call with $WITH, $DATE_H $TIME_H"
  echo
  echo "- Date: $DATE_H $TIME_H"
  echo "- Duration: $DURTXT"
  echo "- Participants: $ME, $WITH"
  echo "- Project: $PROJECT"
  echo "- Audio: ${SESSION/#$HOME/~}"
  if (( ${#ERRORS} )); then echo; for e in "${ERRORS[@]}"; do echo "> ERROR: $e (see $SESSION/process.log; re-run: process_call.sh)"; done; fi
  # recording problems from the app (other side not recorded, gaps): shown so a half transcript is never mistaken for the call
  PROBS=$(jq -r '.problems // [] | .[]' "$SESSION/meta.json" 2>/dev/null)
  if [[ -n "$PROBS" ]]; then echo; echo "> **Recording problems:**"; while IFS= read -r p; do echo "> - $p"; done <<<"$PROBS"; fi
  echo
  if [[ -s "$SUMMARY" ]]; then cat "$SUMMARY"; echo; fi
  echo "## Transcript"
  echo
  if [[ -s "$TRANSCRIPT" ]]; then cat "$TRANSCRIPT"; else echo "(no transcript)"; fi
} >"$NOTE.tmp"
# no em/en dashes in generated text
python3 -I - "$NOTE.tmp" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r"(?<=\d)–(?=\d)", "-", s)
s = re.sub(r"\s*[—–]\s*", ", ", s)
open(p, "w", encoding="utf-8").write(s)
PY
mv "$NOTE.tmp" "$NOTE"

# 4b. shrink the audio (raw CAF is ~30 MB/min): AAC 64 kbit mono, ~0.5 MB/min. Only after a clean run, and the
#     raw files are deleted only when the AAC copy has the same duration (+-1 s).
if (( ${#ERRORS} == 0 )); then
  for T in me them; do
    [[ -s "$SESSION/$T.caf" ]] || continue
    ffmpeg -nostdin -loglevel error -y -i "$SESSION/$T.caf" -ac 1 -c:a aac -b:a 64k "$SESSION/$T.m4a" >>"$LOG" 2>&1 || continue
    A=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SESSION/$T.caf"); B=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SESSION/$T.m4a")
    if python3 -c "import sys; sys.exit(0 if abs(float('${A:-0}')-float('${B:-0}'))<=1 and float('${B:-0}')>0 else 1)"; then
      rm -f "$SESSION/$T.caf" "$SESSION/$T.wav"; echo "compressed $T to m4a" >>"$LOG"
    else echo "compress check failed for $T, raw kept" >>"$LOG"; fi
  done
fi
echo "NOTE: $NOTE"

# 5. notification (the app posts its own, clickable one)
if [[ -z "${CALLSCRIBE_NO_NOTIFY:-}" && -z "${CALLSCRIBE_FROM_APP:-}" ]]; then
  osascript -e "display notification \"$STEM\" with title \"Call note ready\"" >/dev/null 2>&1
fi
exit 0
