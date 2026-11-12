#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas pela lib/common.sh e pelos templates
# =============================================================================
#  03-provision-monitoring.sh - Provisionamento do MONITORAMENTO (systemd)
# -----------------------------------------------------------------------------
#  O que este script faz (idempotente):
#    1. Instala monitor.sh e healthcheck.sh em /opt/citizentech/bin
#       (+ atalhos ct-monitor e ct-healthcheck em /usr/local/bin)
#    2. Instala as units systemd:
#         citizentech-monitor.service     -> monitoramento contínuo (daemon)
#         citizentech-healthcheck.service -> watchdog (verifica e recupera)
#         citizentech-healthcheck.timer   -> agenda o watchdog
#    3. Valida as units (systemd-analyze verify)
#    4. Habilita no boot e inicia
#    5. Confirma que o monitor já está registrando verificações
#
#  Uso: sudo ./scripts/03-provision-monitoring.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
CT_STEP_TOTAL=5
ct_init "Provisionamento do monitoramento (monitor + watchdog via systemd)"

UNITS=(citizentech-monitor.service citizentech-healthcheck.service citizentech-healthcheck.timer)

install_scripts() {
  install -m 0640 -o root -g "$CT_OPS_GROUP" "$CT_CONF_FILE" "$CT_ETC/citizentech.conf"
  install_runtime monitor.sh healthcheck.sh service-event.sh ct-network.sh
  ln -sfn "$CT_HOME/bin/monitor.sh"     /usr/local/bin/ct-monitor
  ln -sfn "$CT_HOME/bin/healthcheck.sh" /usr/local/bin/ct-healthcheck
  install -d -m 0750 -o root -g "$CT_OPS_GROUP" "$CT_STATE_DIR"
  log_ok "Scripts instalados:"
  ls -l "$CT_HOME/bin" | sed 's/^/        /' >&3
  log_ok "Atalhos: ct-monitor, ct-healthcheck (em /usr/local/bin)"
}

install_units() {
  local u
  for u in "${UNITS[@]}"; do
    render_template "$CT_REPO_DIR/systemd/$u" "/etc/systemd/system/$u"
    chmod 0644 "/etc/systemd/system/$u"
    log_ok "Unit instalada: /etc/systemd/system/$u"
  done
  systemctl daemon-reload
}

verify_units() {
  local u out
  for u in "${UNITS[@]}"; do
    out="$(systemd-analyze verify "/etc/systemd/system/$u" 2>&1 | grep -i "citizentech" || true)"
    if [[ -n "$out" ]]; then
      log_warn "systemd-analyze verify $u:"; echo "$out" | sed 's/^/        | /' >&3
    else
      log_ok "systemd-analyze verify $u: sem erros"
    fi
  done
}

enable_and_start() {
  systemctl enable citizentech-monitor.service citizentech-healthcheck.timer >/dev/null 2>&1
  systemctl restart citizentech-monitor.service
  systemctl restart citizentech-healthcheck.timer
  log_ok "Habilitados no boot: citizentech-monitor.service, citizentech-healthcheck.timer"
  systemctl list-timers citizentech-healthcheck.timer --no-pager | sed 's/^/        /' >&3
}

confirm_running() {
  local before after
  before="$(wc -l <"$CT_LOG_DIR/monitor.log" 2>/dev/null || echo 0)"
  if ! wait_until 20 unit_active citizentech-monitor.service; then
    log_error "citizentech-monitor.service não ficou ativo"
    journalctl -u citizentech-monitor.service -n 20 --no-pager | sed 's/^/        | /' >&3
    return 1
  fi
  wait_until 20 bash -c "[ \$(wc -l <'$CT_LOG_DIR/monitor.log') -gt $before ]" || true
  after="$(wc -l <"$CT_LOG_DIR/monitor.log")"
  if (( after > before )); then
    log_ok "Monitor ativo e registrando. Última verificação:"
    tail -n 1 "$CT_LOG_DIR/monitor.log" | sed 's/^/        /' >&3
  else
    log_warn "Monitor ativo, mas ainda sem registros novos em monitor.log"
  fi
  log_info "Status do serviço:"
  systemctl status citizentech-monitor.service --no-pager -n 0 | sed 's/^/        /' >&3 || true
}

summary() {
  banner "Monitoramento ativo" "intervalo ${MONITOR_INTERVAL}s | watchdog a cada $HEALTHCHECK_EVERY"
  kv 30 \
    "Painel no terminal"            "sudo ct-monitor" \
    "Logs de verificação"           "$CT_LOG_DIR/monitor.log" \
    "Alertas"                       "$CT_LOG_DIR/alerts.log" \
    "Histórico (CSV)"               "$CT_LOG_DIR/metrics.csv" \
    "Watchdog"                      "$CT_LOG_DIR/healthcheck.log" \
    "Ciclo de vida dos serviços"    "$CT_LOG_DIR/service-events.log" \
    "Journal"                       "journalctl -u citizentech-monitor -f"
  echo >&3
  log_ok "Próximo passo: sudo ./scripts/04-validate.sh"
}

step "Instalando scripts de monitoramento"   install_scripts
step "Instalando units systemd"              install_units
step "Validando units"                       verify_units
step "Habilitando e iniciando serviços"      enable_and_start
step "Confirmando funcionamento"             confirm_running
summary
