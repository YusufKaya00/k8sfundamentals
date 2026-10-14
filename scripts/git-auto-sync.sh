#!/usr/bin/env bash
# ==============================================================================
# Git Auto-Sync Daemon (Automatic Add, Commit, and Push on File Changes)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PID_FILE="${REPO_ROOT}/.git/git-auto-sync.pid"
LOG_FILE="${REPO_ROOT}/.git/git-auto-sync.log"
POLL_INTERVAL=3      # Saniye cinsinden değişiklik kontrol sıklığı
DEBOUNCE_WAIT=5      # Değişiklikler durduktan sonra beklenilecek saniye

log() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] $*" | tee -a "${LOG_FILE}"
}

get_remote_target() {
  cd "${REPO_ROOT}"
  if git remote | grep -qw "all"; then
    echo "all"
  else
    echo "origin"
  fi
}

get_current_branch() {
  cd "${REPO_ROOT}"
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"
}

run_daemon() {
  cd "${REPO_ROOT}"
  local remote_name
  local branch_name
  remote_name="$(get_remote_target)"
  branch_name="$(get_current_branch)"

  log "🚀 Git Auto-Sync başlatıldı. Repo: ${REPO_ROOT}"
  log "📡 Hedef Uzak Depo: ${remote_name} | Dal: ${branch_name}"
  log "⏱️  Kontrol aralığı: ${POLL_INTERVAL}s | Debounce bekleme: ${DEBOUNCE_WAIT}s"

  while true; do
    # Git durumunu kontrol et (.gitignore kurallarına uyar)
    if [[ -n "$(git status --porcelain)" ]]; then
      log "📝 Değişiklik algılandı. Dosya yazımlarının bitmesi için ${DEBOUNCE_WAIT}s bekleniyor..."
      sleep "${DEBOUNCE_WAIT}"

      # Debounce süresi sonrasında hala değişiklik var mı kontrol et
      local changes
      changes="$(git status --porcelain)"
      if [[ -n "${changes}" ]]; then
        # Değişen ilk 2 dosyanın adını özet mesajı için al
        local summary
        summary="$(git status --porcelain | awk '{print $2}' | head -n 2 | paste -sd ", " -)"
        local count
        count="$(git status --porcelain | wc -l)"
        if [[ "${count}" -gt 2 ]]; then
          summary="${summary} (+ $((count - 2)) dosya)"
        fi

        local commit_msg="auto: ${summary} ($(date '+%H:%M:%S'))"
        
        log "📦 Değişiklikler paketleniyor (${count} dosya): ${summary}"
        git add -A

        # Eğer stage edilmiş değişiklik varsa commit et
        if ! git diff --cached --quiet; then
          git commit -m "${commit_msg}" >> "${LOG_FILE}" 2>&1 || true
          log "✅ Commit oluşturuldu: ${commit_msg}"

          log "📤 Uzak depoya gönderiliyor (git push ${remote_name} ${branch_name})..."
          if git push "${remote_name}" "${branch_name}" >> "${LOG_FILE}" 2>&1; then
            log "🎉 Başarıyla pushlandı!"
          else
            log "⚠️ Push işlemi başarısız oldu. Log detayları için: ${LOG_FILE}"
          fi
        fi
      fi
    fi
    sleep "${POLL_INTERVAL}"
  done
}

start() {
  if is_running; then
    local pid
    pid="$(cat "${PID_FILE}")"
    echo "⚠️  Git Auto-Sync zaten çalışıyor (PID: ${pid})."
    return 0
  fi

  mkdir -p "$(dirname "${LOG_FILE}")"
  nohup "${BASH_SOURCE[0]}" run >/dev/null 2>&1 &
  local new_pid=$!
  echo "${new_pid}" > "${PID_FILE}"

  sleep 1
  if is_running; then
    echo "✅ Git Auto-Sync arka planda başarıyla başlatıldı (PID: ${new_pid})."
    echo "📋 Logları canlı izlemek için:  ${BASH_SOURCE[0]} logs"
    echo "🛑 Durdurmak için:               ${BASH_SOURCE[0]} stop"
  else
    echo "❌ Başlatılamadı. Hata detayları için '${LOG_FILE}' dosyasını inceleyin."
    return 1
  fi
}

stop() {
  if ! is_running; then
    echo "ℹ️  Git Auto-Sync şu anda çalışmıyor."
    rm -f "${PID_FILE}"
    return 0
  fi

  local pid
  pid="$(cat "${PID_FILE}")"
  echo "🛑 Git Auto-Sync durduruluyor (PID: ${pid})..."
  kill "${pid}" 2>/dev/null || true
  sleep 1

  if kill -0 "${pid}" 2>/dev/null; then
    kill -9 "${pid}" 2>/dev/null || true
  fi

  rm -f "${PID_FILE}"
  echo "✅ Git Auto-Sync durduruldu."
}

is_running() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

status() {
  if is_running; then
    local pid
    pid="$(cat "${PID_FILE}")"
    echo "🟢 Git Auto-Sync ÇALIŞIYOR (PID: ${pid})"
    local remote_name
    local branch_name
    remote_name="$(get_remote_target)"
    branch_name="$(get_current_branch)"
    echo "   Hedef: ${remote_name}/${branch_name}"
    echo "   Log Dosyası: ${LOG_FILE}"
    echo ""
    echo "--- Son 10 Log Satırı ---"
    if [[ -f "${LOG_FILE}" ]]; then
      tail -n 10 "${LOG_FILE}"
    fi
  else
    echo "🔴 Git Auto-Sync ÇALIŞMIYOR."
    if [[ -f "${LOG_FILE}" ]]; then
      echo ""
      echo "--- Son Log Kayıtları ---"
      tail -n 5 "${LOG_FILE}"
    fi
  fi
}

logs() {
  if [[ ! -f "${LOG_FILE}" ]]; then
    touch "${LOG_FILE}"
  fi
  echo "📋 Loglar canlı izleniyor (Çıkmak için Ctrl+C)..."
  tail -f "${LOG_FILE}"
}

case "${1:-}" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  status)
    status
    ;;
  logs|log)
    logs
    ;;
  run)
    run_daemon
    ;;
  *)
    echo "Kullanım: $0 {start|stop|status|logs|run}"
    echo ""
    echo "Komutlar:"
    echo "  start   : Arka planda otomatik senkronizasyon servisini başlatır"
    echo "  stop    : Çalışan servisi durdurur"
    echo "  status  : Servisin durumunu ve son logları gösterir"
    echo "  logs    : Canlı log akışını terminale basar"
    echo "  run     : Ön planda (foreground) çalıştırır"
    exit 1
    ;;
esac
