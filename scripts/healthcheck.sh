#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas pela lib/common.sh e pelos templates
# =============================================================================
#  healthcheck.sh - Watchdog dos serviços CitizenTech (auto-recuperação)
# -----------------------------------------------------------------------------
#  Executado periodicamente pelo citizentech-healthcheck.timer (padrão: 30s).
#  Para cada serviço crítico:
#    - se estiver parado ou 'failed' (inclusive após atingir o limite de
#      reinícios do systemd), registra o ALERTA e tenta RECUPERAR
#    - verifica se o monitor está travado (heartbeat antigo) e o reinicia
#    - verifica a saúde HTTP da aplicação; 2 falhas seguidas -> reinicia
#
#  Modo manutenção: enquanto o arquivo /etc/citizentech/maintenance existir,
#  nenhuma recuperação automática é feita (para paradas planejadas).
#    sudo touch /etc/citizentech/maintenance   # liga
#    sudo rm /etc/citizentech/maintenance      # desliga
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CT_SCRIPT_NAME="healthcheck"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
CT_LOG_FILE="$CT_LOG_DIR/healthcheck.log"

SERVICES=(citizentech-network.service nginx.service citizentech-app.service citizentech-monitor.service)
MAINT_FILE="$CT_ETC/maintenance"

recover() {
  local svc="$1" state
  state="$(systemctl is-active "$svc" 2>/dev/null)"
  log_error "ALERTA: $svc está '$state' - iniciando recuperação automática"
  audit "falha-detectada" "FAIL" "servico=$svc estado=$state"
  local attempt
  for attempt in 1 2 3; do
    # 'failed' (ex.: limite de reinícios atingido) exige reset-failed antes do start
    if [[ "$(systemctl is-active "$svc" 2>/dev/null)" == "failed" ]] || (( attempt > 1 )); then
      systemctl reset-failed "$svc" 2>/dev/null
      log_info "reset-failed aplicado em $svc (limite de reinícios do systemd zerado) - tentativa $attempt"
    fi
    systemctl start "$svc" 2>/dev/null
    if wait_until 15 unit_active "$svc"; then
      log_ok "RECUPERADO: $svc ativo novamente (PID $(systemctl show -p MainPID --value "$svc"), tentativa $attempt)"
      audit "recuperacao" "OK" "servico=$svc estado_anterior=$state tentativas=$attempt"
      return 0
    fi
  done
  log_error "FALHA NA RECUPERAÇÃO: $svc continua '$(systemctl is-active "$svc")'"
  audit "recuperacao" "FAIL" "servico=$svc"
  return 1
}

main() {
  if [[ -f "$MAINT_FILE" ]]; then
    log_warn "Modo manutenção ativo ($MAINT_FILE) - recuperação automática suspensa"
    return 0
  fi

  local svc problems=0 recovered=0 failed=0
  for svc in "${SERVICES[@]}"; do
    systemctl cat "$svc" &>/dev/null || continue      # serviço ainda não instalado
    if ! unit_active "$svc"; then
      # 'activating' = o próprio systemd já está reiniciando (Restart=always): aguarda
      if [[ "$(systemctl is-active "$svc" 2>/dev/null)" == "activating" ]] && wait_until 15 unit_active "$svc"; then
        log_info "$svc estava sendo reiniciado pelo systemd e voltou sozinho"
        continue
      fi
      problems=$((problems + 1))
      if recover "$svc"; then recovered=$((recovered + 1)); else failed=$((failed + 1)); fi
    fi
  done

  # Monitor travado? (processo vivo mas sem registrar verificações)
  local hb="$CT_STATE_DIR/monitor.heartbeat" max_age=$((MONITOR_INTERVAL * 3 + 15)) age
  if unit_active citizentech-monitor.service && [[ -f "$hb" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$hb") ))
    if (( age > max_age )); then
      problems=$((problems + 1))
      log_error "ALERTA: monitor sem registrar há ${age}s (limite ${max_age}s) - reiniciando"
      audit "monitor-travado" "FAIL" "heartbeat=${age}s"
      systemctl restart citizentech-monitor.service && recovered=$((recovered + 1))
    fi
  fi

  # Saúde HTTP da aplicação (processo pode estar ativo porém sem responder)
  local fails_file="$CT_STATE_DIR/app_http_fails" fails=0
  if unit_active citizentech-app.service; then
    if curl -fsS -o /dev/null -m 5 "http://$CT_SVC_IP:$APP_PORT$APP_HEALTH_PATH" 2>/dev/null; then
      echo 0 >"$fails_file"
    else
      fails=$(( $(cat "$fails_file" 2>/dev/null || echo 0) + 1 ))
      echo "$fails" >"$fails_file"
      log_warn "Aplicação não respondeu ao health check ($fails falha(s) seguida(s))"
      if (( fails >= 2 )); then
        problems=$((problems + 1))
        log_error "ALERTA: aplicação sem responder - reiniciando citizentech-app"
        audit "app-sem-resposta" "FAIL" "falhas_consecutivas=$fails"
        systemctl restart citizentech-app.service && recovered=$((recovered + 1))
        echo 0 >"$fails_file"
      fi
    fi
  fi

  if (( problems == 0 )); then
    _ct_append "$CT_LOG_FILE" "$(_ct_ts) [INFO ] [healthcheck] OK: ${#SERVICES[@]} serviços ativos, monitor e aplicação respondendo"
  else
    log_warn "Verificação concluída: problemas=$problems recuperados=$recovered falhas=$failed"
  fi
  (( failed == 0 ))
}

main "$@"
