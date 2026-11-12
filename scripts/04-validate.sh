#!/usr/bin/env bash
# =============================================================================
#  04-validate.sh - Validação completa do ambiente CitizenTech
# -----------------------------------------------------------------------------
#  Executa verificações automáticas de tudo o que foi provisionado e imprime
#  um relatório PASS/FAIL. Código de saída 0 somente se tudo passar.
#
#  Uso: sudo ./scripts/04-validate.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root "$@"
ct_init "Validação do ambiente"
set +e; trap - ERR   # cada verificação trata seu próprio resultado

PASS=0; FAIL=0; FAILED_ITEMS=()

check() {  # check "descrição" comando...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$desc" >&3
    PASS=$((PASS + 1))
  else
    printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$desc" >&3
    FAIL=$((FAIL + 1)); FAILED_ITEMS+=("$desc")
  fi
}
section() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET" >&3; }

perm_is() {  # perm_is <caminho> <modo> <dono:grupo>
  [[ "$(stat -c '%a %U:%G' "$1" 2>/dev/null)" == "$2 $3" ]]
}
http_code_is() { [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$1")" == "$2" ]]; }
log_recent() {   # log_recent <arquivo> <segundos>
  [[ -f "$1" ]] && (( $(date +%s) - $(stat -c %Y "$1") < $2 ))
}

banner "Validação do ambiente CitizenTech" "$(hostname) | $(env_label)"

section "1. Sistema e identificação"
check "Hostname é '$CT_HOSTNAME' (atual: $(hostname))"            test "$(hostname)" = "$CT_HOSTNAME"
check "Fuso horário $CT_TIMEZONE"                                  bash -c "timedatectl show -p Timezone --value 2>/dev/null | grep -qx '$CT_TIMEZONE' || readlink /etc/localtime | grep -q '$CT_TIMEZONE'"
check "systemd é o PID 1"                                          test "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd"
check "journald persistente (/var/log/journal)"                    test -d /var/log/journal

section "2. Rede, IP e DNS"
check "Interface $CT_SVC_IFACE com IP $CT_SVC_IP/$CT_SVC_PREFIX"   bash -c "ip -4 addr show dev $CT_SVC_IFACE | grep -q 'inet $CT_SVC_IP/$CT_SVC_PREFIX'"
check "Rota padrão configurada ($(default_iface))"                 test -n "$(default_iface)"
check "Nome local $CT_DOMAIN resolve para 127.0.0.1"               bash -c "getent hosts $CT_DOMAIN | grep -q '^127.0.0.1'"
check "Nome app.$CT_DOMAIN resolve para $CT_SVC_IP"                bash -c "getent hosts app.$CT_DOMAIN | grep -q '^$CT_SVC_IP'"
check "Hostname $CT_HOSTNAME resolve localmente"                   getent hosts "$CT_HOSTNAME"
check "DNS externo resolve $DNS_TEST_NAME"                         getent ahosts "$DNS_TEST_NAME"
check "Servidores DNS do projeto em uso ($DNS_SERVERS)"            bash -c "grep -q '${DNS_SERVERS%% *}' /etc/resolv.conf || resolvectl dns 2>/dev/null | grep -q '${DNS_SERVERS%% *}'"
check "Serviço de rede citizentech-network ativo e habilitado"     bash -c "systemctl is-active -q citizentech-network && systemctl is-enabled -q citizentech-network"

section "3. Usuários, grupos e permissões"
check "Usuário de serviço $CT_APP_USER sem shell de login"         bash -c "getent passwd $CT_APP_USER | grep -q nologin"
check "Grupo $CT_OPS_GROUP existe"                                 getent group "$CT_OPS_GROUP"
check "Operador $CT_OPS_USER pertence a $CT_OPS_GROUP"             bash -c "id -nG $CT_OPS_USER | grep -qw $CT_OPS_GROUP"
check "Regras sudo válidas (/etc/sudoers.d/citizentech)"           visudo -cf /etc/sudoers.d/citizentech
check "Operador pode reiniciar serviços via sudo"                  bash -c "sudo -l -U $CT_OPS_USER | grep -q 'systemctl restart citizentech-'"
check "$CT_HOME/app = 750 root:$CT_APP_USER"                       perm_is "$CT_HOME/app" 750 "root:$CT_APP_USER"
check "$CT_ETC/app.env = 600 root:root (segredos)"                 perm_is "$CT_ETC/app.env" 600 "root:root"
check "$CT_DATA/db = 750 $CT_APP_USER:$CT_APP_USER"                perm_is "$CT_DATA/db" 750 "$CT_APP_USER:$CT_APP_USER"
check "$CT_LOG_DIR = 2751 root:$CT_OPS_GROUP"                      perm_is "$CT_LOG_DIR" 2751 "root:$CT_OPS_GROUP"
check "Usuário $CT_APP_USER lê mas NÃO altera o código"           bash -c "sudo -u $CT_APP_USER test -r $CT_HOME/app && ! sudo -u $CT_APP_USER test -w $CT_HOME/app"

section "4. Aplicação"
check "Pacote nginx instalado"                                     bash -c "dpkg -s nginx | grep -q 'Status: install ok'"
check "Variáveis de ambiente carregadas no processo da aplicação"  bash -c "tr '\\0' '\\n' < /proc/\$(systemctl show -p MainPID --value citizentech-app)/environ | grep -q '^APP_ENV=$APP_ENV'"
check "citizentech-app ativo e habilitado no boot"                 bash -c "systemctl is-active -q citizentech-app && systemctl is-enabled -q citizentech-app"
check "Aplicação roda como usuário $CT_APP_USER"                   bash -c "ps -o user= -p \$(systemctl show -p MainPID --value citizentech-app) | grep -qx $CT_APP_USER"
check "nginx ativo e habilitado no boot"                           bash -c "systemctl is-active -q nginx && systemctl is-enabled -q nginx"
check "Health direto http://$CT_SVC_IP:$APP_PORT$APP_HEALTH_PATH" http_code_is "http://$CT_SVC_IP:$APP_PORT$APP_HEALTH_PATH" 200
check "Página via Nginx http://$CT_DOMAIN/ (HTTP 200)"            http_code_is "http://$CT_DOMAIN/" 200
check "Página via IP principal http://$(primary_ip | cut -d/ -f1)/" http_code_is "http://$(primary_ip | cut -d/ -f1)/" 200

section "5. Monitoramento e serviços systemd"
check "citizentech-monitor ativo e habilitado no boot"             bash -c "systemctl is-active -q citizentech-monitor && systemctl is-enabled -q citizentech-monitor"
check "citizentech-monitor com Restart=always"                     bash -c "systemctl show -p Restart --value citizentech-monitor | grep -qx always"
check "Watchdog citizentech-healthcheck.timer ativo"               bash -c "systemctl is-active -q citizentech-healthcheck.timer && systemctl is-enabled -q citizentech-healthcheck.timer"
check "monitor.sh executa verificação manual"                      bash -c "$CT_HOME/bin/monitor.sh --json | jq -e .cpu.pct"
check "Monitor registrou verificação nos últimos $((MONITOR_INTERVAL * 3))s" log_recent "$CT_LOG_DIR/monitor.log" $((MONITOR_INTERVAL * 3))
check "Watchdog executou nos últimos 120s"                         log_recent "$CT_LOG_DIR/healthcheck.log" 120

section "6. Logs e auditoria"
for f in audit provision monitor alerts healthcheck service-events errors; do
  check "Log $CT_LOG_DIR/$f.log existe"                            test -f "$CT_LOG_DIR/$f.log"
done
check "Auditoria registra provisionamento (01, 02 e 03)"           bash -c "grep -q 'script=01-provision-infra.sh' $CT_LOG_DIR/audit.log && grep -q 'script=02-provision-app.sh' $CT_LOG_DIR/audit.log && grep -q 'script=03-provision-monitoring.sh' $CT_LOG_DIR/audit.log"
check "Histórico de métricas (metrics.csv) com dados"              bash -c "[ \$(wc -l < $CT_LOG_DIR/metrics.csv) -gt 1 ]"
check "Rotação de logs configurada (logrotate)"                    test -f /etc/logrotate.d/citizentech
check "Auditoria também no journald (citizentech-audit)"           bash -c "journalctl -t citizentech-audit -n 1 --no-pager | grep -q citizentech"

TOTAL=$((PASS + FAIL))
echo >&3
if (( FAIL == 0 )); then
  printf '%s  RESULTADO: %d/%d verificações aprovadas - ambiente 100%% operacional%s\n\n' "$C_GREEN$C_BOLD" "$PASS" "$TOTAL" "$C_RESET" >&3
  audit "validacao" "OK" "aprovadas=$PASS/$TOTAL"
  exit 0
else
  printf '%s  RESULTADO: %d/%d aprovadas, %d falharam:%s\n' "$C_RED$C_BOLD" "$PASS" "$TOTAL" "$FAIL" "$C_RESET" >&3
  printf '    - %s\n' "${FAILED_ITEMS[@]}" >&3
  audit "validacao" "FAIL" "aprovadas=$PASS/$TOTAL falhas=${FAILED_ITEMS[*]}"
  exit 1
fi
