#!/usr/bin/env bash
# =============================================================================
#  install.sh - Provisiona TODO o ambiente CitizenTech com um único comando
# -----------------------------------------------------------------------------
#  Executa em ordem:
#    1. scripts/01-provision-infra.sh       hostname, rede/IP, DNS, usuários, logs
#    2. scripts/02-provision-app.sh         dependências, variáveis, serviço, Nginx
#    3. scripts/03-provision-monitoring.sh  monitor + watchdog (systemd)
#    4. scripts/04-validate.sh              validação automática PASS/FAIL
#
#  Uso:
#    sudo ./install.sh              tudo
#    sudo ./install.sh infra        somente a etapa 1 (também: app, monitoring, validate)
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo ./install.sh" >&2
  exit 1
fi

# Mesmo identificador de execução em todos os scripts -> auditoria correlacionada
CT_RUN_ID="install-$(date +%Y%m%d-%H%M%S)"
export CT_RUN_ID

declare -A STAGES=(
  [infra]="scripts/01-provision-infra.sh"
  [app]="scripts/02-provision-app.sh"
  [monitoring]="scripts/03-provision-monitoring.sh"
  [validate]="scripts/04-validate.sh"
)
ORDER=(infra app monitoring validate)
[[ $# -gt 0 ]] && ORDER=("$@")

if [[ -t 1 ]]; then M=$'\e[1;35m'; R=$'\e[1;31m'; G=$'\e[1;32m'; N=$'\e[0m'; else M=""; R=""; G=""; N=""; fi

START=$SECONDS
for stage in "${ORDER[@]}"; do
  script="${STAGES[$stage]:-}"
  if [[ -z "$script" ]]; then
    echo "Etapa desconhecida: $stage (use: infra, app, monitoring, validate)" >&2
    exit 2
  fi
  printf '\n%s################  %s  ################%s\n' "$M" "$script" "$N"
  if ! bash "$script"; then
    printf '\n%sFalha em %s. Consulte /var/log/citizentech/errors.log%s\n' "$R" "$script" "$N" >&2
    exit 1
  fi
done

printf '\n%sAmbiente CitizenTech provisionado em %ss (run=%s).%s\n' "$G" "$((SECONDS - START))" "$CT_RUN_ID" "$N"
printf 'Acesse: http://citizentech.local/ (no servidor)  |  Testes de falha: sudo ./scripts/fault-tests.sh all\n'
