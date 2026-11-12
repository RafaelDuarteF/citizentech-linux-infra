#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas pela lib/common.sh e pelos templates
# =============================================================================
#  service-event.sh - Registro do ciclo de vida dos serviços systemd
# -----------------------------------------------------------------------------
#  Chamado pelo próprio systemd nas units CitizenTech:
#     ExecStartPre=-+/opt/citizentech/bin/service-event.sh start %n
#     ExecStopPost=-+/opt/citizentech/bin/service-event.sh stop  %n
#
#  - Na PARADA lê as variáveis que o systemd fornece ($SERVICE_RESULT,
#    $EXIT_CODE, $EXIT_STATUS) e classifica: parada normal x FALHA.
#  - Na PARTIDA verifica como foi a última parada: se foi falha, registra
#    "RECUPERAÇÃO" (evidência de tolerância a falhas) e o nº de reinícios.
#
#  Nunca retorna erro: o registro não pode impedir o serviço de funcionar.
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CT_SCRIPT_NAME="systemd"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || exit 0
CT_LOG_FILE="$CT_LOG_DIR/service-events.log"

event="${1:-}"
unit="${2:-desconhecido}"
state_file="$CT_STATE_DIR/${unit}.last-stop"
mkdir -p "$CT_STATE_DIR" 2>/dev/null || true

boot_epoch() {   # instante (epoch) em que o systemd (PID 1) iniciou
  local s
  s="$(ps -o etimes= -p 1 2>/dev/null | tr -d ' ')"
  echo $(( $(date +%s) - ${s:-0} ))
}

case "$event" in
  start)
    restarts="$(systemctl show -p NRestarts --value "$unit" 2>/dev/null || echo "?")"
    last="$(cat "$state_file" 2>/dev/null || echo "none")"
    last_mtime="$(stat -c %Y "$state_file" 2>/dev/null || echo 0)"
    boot="$(boot_epoch)"
    if { [[ -f "$state_file" ]] && (( last_mtime < boot )); } ||
       { [[ ! -f "$state_file" ]] && (( $(date +%s) - boot < 120 )); }; then
      # primeira partida desde a inicialização do sistema
      log_info "BOOT: $unit iniciado automaticamente na inicialização do sistema (última parada antes do boot: ${last})"
      audit "servico-boot" "OK" "unit=$unit ultima_parada=${last}"
    elif [[ "$last" == failure* ]]; then
      log_warn "RECUPERACAO: $unit sendo reiniciado após falha (${last#failure }) | reinícios automáticos: $restarts"
      audit "servico-recuperacao" "OK" "unit=$unit causa=${last#failure } nrestarts=$restarts"
    else
      log_info "INICIO: $unit iniciando (reinícios automáticos até agora: $restarts)"
      audit "servico-start" "OK" "unit=$unit"
    fi
    ;;
  stop)
    result="${SERVICE_RESULT:-desconhecido}"
    code="${EXIT_CODE:-?}"
    status="${EXIT_STATUS:-?}"
    if [[ "$result" == "success" ]]; then
      log_info "PARADA: $unit encerrado normalmente (code=$code status=$status)"
      audit "servico-stop" "OK" "unit=$unit result=$result code=$code status=$status"
      echo "success" >"$state_file" 2>/dev/null || true
    else
      log_error "FALHA: $unit terminou de forma anormal (result=$result code=$code status=$status)"
      audit "servico-falha" "FAIL" "unit=$unit result=$result code=$code status=$status"
      echo "failure result=$result status=$status" >"$state_file" 2>/dev/null || true
    fi
    ;;
  *)
    echo "Uso: $0 start|stop <unit>" >&2
    ;;
esac
exit 0
