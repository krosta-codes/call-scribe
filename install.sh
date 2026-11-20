#!/bin/zsh
# One-shot setup on a new Mac: checks the machine, installs dependencies, downloads the whisper model,
# checks vault path and signing identity, then builds and starts CallScribe. Safe to run again.
set -e
cd "$(dirname "$0")"
ok()   { print -P "%F{green}ok%f    $1"; }
warn() { print -P "%F{yellow}warn%f  $1"; }
fail() { print -P "%F{red}fail%f  $1"; exit 1; }

# 1. Machine
[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon required (build targets arm64)."
OSV="$(sw_vers -productVersion)"
autoload is-at-least
is-at-least 14.2 "$OSV" || fail "macOS 14.2+ required (Core Audio process tap), this Mac has $OSV."
ok "Apple Silicon, macOS $OSV"

# 2. Xcode Command Line Tools (swiftc, codesign)
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  fail "Command Line Tools installer opened. Finish it, then run install.sh again."
fi
ok "Command Line Tools"

# 3. Homebrew + ffmpeg + whisper-cpp
command -v brew >/dev/null || fail "Homebrew missing: https://brew.sh, then run install.sh again."
for pkg in ffmpeg whisper-cpp; do
  brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
ok "ffmpeg, whisper-cpp"

# 4. Whisper model (~1.6 GB)
MODEL="$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
if [[ ! -s "$MODEL" ]]; then
  mkdir -p "${MODEL:h}"
  curl -L --fail --connect-timeout 20 -o "$MODEL.part" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
  mv "$MODEL.part" "$MODEL"
fi
ok "whisper model $MODEL"

# 5. Claude CLI (summary step; without it the note has the transcript plus an ERROR line)
if command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; then
  ok "claude CLI (log in once with: claude)"
else
  warn "claude CLI missing: install Claude Code and log in, otherwise notes have no summary."
fi

# 6. Notes folder (Markdown notes land in <folder>/Projects/<Project>/calls/)
VAULT="$(defaults read com.jurekkrosta.callscribe vaultPath 2>/dev/null || echo "$HOME/Documents/CallScribe")"
mkdir -p "$VAULT/Projects" 2>/dev/null || true
if [[ -d "$VAULT/Projects" ]]; then
  ok "notes folder $VAULT (change: defaults write com.jurekkrosta.callscribe vaultPath \"/path\")"
else
  warn "notes folder not reachable: $VAULT (iCloud not synced yet?)"
fi

# 7. Signing identity (keeps permission grants across rebuilds)
SIGN_NAME="${CALLSCRIBE_SIGN_IDENTITY:-Local Code Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_NAME\""; then
  ok "signing identity found ($SIGN_NAME)"
else
  warn "no code signing certificate named '... $SIGN_NAME': the app gets signed ad hoc and macOS"
  warn "  asks for microphone and audio permissions again after every rebuild. Fix (2 minutes): README, Install, step 3."
fi

# 8. Build + start
./build.sh
ok "CallScribe built to ~/Applications/CallScribe.app and started. Grant the permissions on first use (README)."
