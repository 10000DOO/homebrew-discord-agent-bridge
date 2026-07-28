#!/bin/bash
# homebrew-self-update.sh — runs detached from a running `dab` process (see
# DAB_HOMEBREW_UPDATE_SCRIPT / triggerHomebrewSelfUpdateIfConfigured in the main repo's
# swift/Sources/DiscordAgentBridge/Update/Installer.swift) to own the full
# upgrade -> restart -> verify -> rollback sequence that the process being replaced cannot
# safely do to itself.
#
# Args: $1 = Discord application id, $2 = interaction token (for the followup webhook).
#
# set -e is deliberately NOT used: a step failing must still reach its own notify() call,
# not kill the script before Discord hears about it. Each step is checked explicitly instead.
set -uo pipefail

APP_ID="${1:-}"
TOKEN="${2:-}"

# brew services launches dab under launchd's minimal PATH (no /opt/homebrew/bin) — same root
# cause swift/scripts/install.sh's generated run.sh works around for the dab process itself.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:$PATH"

DAB_HOME="$HOME/.dab"
LOG_DIR="$DAB_HOME/logs"
LOG_FILE="$LOG_DIR/homebrew-update.log"
MARKER="$DAB_HOME/homebrew-ready-marker"
READY_TIMEOUT=90
POLL_INTERVAL=3

mkdir -p "$LOG_DIR"

log() {
  printf '%s [homebrew-self-update] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Discord interaction followup — retry on transient failures / token propagation lag.
# wait=true so we get a real HTTP body and avoid silent 204-only fire-and-forget misses.
notify() {
  local msg="$1"
  log "notify: $msg"
  if [ -z "$APP_ID" ] || [ -z "$TOKEN" ]; then
    log "webhook skipped (missing application id/token)"
    return 0
  fi
  local try code body
  for try in 1 2 3 4 5; do
    body="$(mktemp)"
    # --globoff: interaction tokens can contain characters curl would treat as globs.
    code="$(curl -sS --globoff -o "$body" -w '%{http_code}' -X POST \
      "https://discord.com/api/v10/webhooks/${APP_ID}/${TOKEN}?wait=true" \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"$(json_escape "$msg")\"}" 2>>"$LOG_FILE")" || code="curl-fail"
    log "webhook try=${try} HTTP=${code} body=$(head -c 200 "$body" 2>/dev/null | tr '\n' ' ')"
    rm -f "$body"
    case "$code" in
      200|204) return 0 ;;
    esac
    sleep $((try * 2))
  done
  log "webhook FAILED after retries"
  return 1
}

brew_dab_started() {
  brew services list 2>/dev/null | awk '$1=="dab" && $2=="started" {found=1} END{exit !found}'
}

# Full stop then start with retries (more reliable than a single `restart` under launchd).
restart_dab_service() {
  local label="${1:-restart}"
  local attempt i
  for attempt in 1 2 3; do
    log "brew services stop+start dab (${label} attempt ${attempt})"
    brew services stop dab >>"$LOG_FILE" 2>&1 || true
    sleep 1
    if ! brew services start dab >>"$LOG_FILE" 2>&1; then
      brew services restart dab >>"$LOG_FILE" 2>&1 || true
    fi
    for i in $(seq 1 30); do
      if brew_dab_started; then
        log "brew service started (${label} attempt ${attempt}, after ${i}s)"
        return 0
      fi
      sleep 1
    done
    log "brew service not started after attempt ${attempt} (${label})"
    sleep 2
  done
  return 1
}

log "=== update start pid=$$ ==="
log "APP_ID set=$([ -n "$APP_ID" ] && echo yes || echo no) TOKEN set=$([ -n "$TOKEN" ] && echo yes || echo no)"

prev_version="$(brew list --versions dab 2>/dev/null | awk '{print $NF}')"
log "previous version: ${prev_version:-<unknown>}"

rm -f "$MARKER"
log "cleared marker: $MARKER"

log "brew update"
if ! brew update >> "$LOG_FILE" 2>&1; then
  log "FAILED: brew update"
  notify "❌ dab 업데이트 실패: brew update 단계에서 오류가 발생했어요. 설치된 버전은 그대로예요."
  exit 1
fi

# ponytail: HOMEBREW_NO_INSTALL_CLEANUP keeps the previous keg on disk so a failed upgrade
# can still be rolled back to it; a healthy upgrade prunes it back down via brew cleanup below.
log "brew upgrade dab"
if ! HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade dab >> "$LOG_FILE" 2>&1; then
  log "FAILED: brew upgrade dab"
  notify "❌ dab 업데이트 실패: brew upgrade 단계에서 오류가 발생했어요. 설치된 버전은 그대로예요."
  exit 1
fi

if ! restart_dab_service "post-upgrade"; then
  log "FAILED: brew services restart dab after upgrade"
  notify "❌ dab 업데이트 실패: 새 버전 설치는 됐지만 서비스 재시작에 실패했어요. 수동 확인이 필요해요. 로그: \`~/.dab/logs/homebrew-update.log\`"
  exit 1
fi

log "waiting up to ${READY_TIMEOUT}s for marker (poll every ${POLL_INTERVAL}s)"
elapsed=0
while [ "$elapsed" -lt "$READY_TIMEOUT" ]; do
  if [ -f "$MARKER" ]; then
    log "marker detected after ${elapsed}s -> success"
    brew cleanup dab >> "$LOG_FILE" 2>&1 || log "note: brew cleanup dab failed (non-fatal)"
    notify "✅ dab 업데이트 완료! 새 버전으로 정상적으로 다시 접속했어요."
    exit 0
  fi
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

log "marker not detected within ${READY_TIMEOUT}s -> attempting rollback"

if [ -z "$prev_version" ]; then
  log "no previous version recorded -> cannot roll back"
  notify "⚠️ dab 업데이트 후 정상 기동을 확인하지 못했고, 이전 버전 정보가 없어 자동 롤백도 못 했어요. 수동으로 확인해주세요. 로그: \`~/.dab/logs/homebrew-update.log\`"
  exit 1
fi

cellar_dir="$(brew --cellar)/dab/${prev_version}"
if [ ! -d "$cellar_dir" ]; then
  log "FAILED: previous keg missing at $cellar_dir"
  notify "⚠️ dab 업데이트 후 정상 기동을 확인하지 못했지만, 이전 버전(${prev_version}) 설치본을 찾지 못해 자동 롤백도 못 했어요. 수동으로 확인해주세요. 로그: \`~/.dab/logs/homebrew-update.log\`"
  exit 1
fi

# brew's old `brew switch` command was removed; relinking a specific (non-latest) Cellar
# keg has no plain CLI equivalent, so this reaches for the same Keg#link Homebrew itself
# used to call, via `brew ruby` (Homebrew's own Ruby + library load, no PATH/gem guessing).
# The currently-linked keg (whichever version) must be unlinked first — Keg#link refuses
# with AlreadyLinkedError while linked_keg_record still points at the other version.
log "relinking previous keg: $cellar_dir"
if ! brew ruby -e '
  target = Keg.new(Pathname.new(ARGV[0]))
  Keg.new(target.linked_keg_record.resolved_path).unlink if target.linked_keg_record.symlink?
  target.link(overwrite: true)
' -- "$cellar_dir" >> "$LOG_FILE" 2>&1; then
  log "FAILED: relink previous keg"
  notify "⚠️ dab 업데이트 실패 후 롤백 중 오류가 발생했어요(이전 버전: ${prev_version}). 수동 확인이 필요해요. 로그: \`~/.dab/logs/homebrew-update.log\`"
  exit 1
fi

rm -f "$MARKER"
if ! restart_dab_service "post-rollback"; then
  log "FAILED: brew services restart dab (post-rollback)"
  notify "⚠️ 이전 버전(${prev_version})으로 되돌렸지만 서비스 재시작에 실패했어요. 수동 확인이 필요해요. 로그: \`~/.dab/logs/homebrew-update.log\`"
  exit 1
fi

log "rollback complete -> previous version ${prev_version} restored"
notify "⚠️ dab 새 버전이 정상 기동하지 않아 이전 버전(${prev_version})으로 되돌렸어요."
exit 0
