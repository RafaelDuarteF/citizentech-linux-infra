#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas pela lib/common.sh e pelos templates
# =============================================================================
#  ct-network.sh - Rede interna de serviços CitizenTech
# -----------------------------------------------------------------------------
#  Cria a interface virtual dedicada (padrão: ct0, tipo dummy) e atribui o IP
#  fixo de serviço (padrão: 10.77.0.10/24). A aplicação escuta neste IP e o
#  Nginx a publica na porta 80. Executado pelo citizentech-network.service
#  a cada inicialização, garantindo que a configuração seja persistente.
#
#  Uso: ct-network.sh up | down | status
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
CT_LOG_FILE="$CT_LOG_DIR/network.log"

up() {
  if ! ip link show "$CT_SVC_IFACE" &>/dev/null; then
    if ! ip link add "$CT_SVC_IFACE" type dummy 2>/dev/null; then
      modprobe dummy 2>/dev/null || true
      ip link add "$CT_SVC_IFACE" type dummy
    fi
    log_info "Interface $CT_SVC_IFACE (dummy) criada"
  fi
  ip addr replace "$CT_SVC_IP/$CT_SVC_PREFIX" dev "$CT_SVC_IFACE"
  ip link set "$CT_SVC_IFACE" up
  log_ok "Interface $CT_SVC_IFACE ativa com IP $CT_SVC_IP/$CT_SVC_PREFIX"
  audit "rede-servico-up" "OK" "iface=$CT_SVC_IFACE ip=$CT_SVC_IP/$CT_SVC_PREFIX"
}

down() {
  if ip link show "$CT_SVC_IFACE" &>/dev/null; then
    ip link del "$CT_SVC_IFACE"
    log_info "Interface $CT_SVC_IFACE removida"
    audit "rede-servico-down" "OK" "iface=$CT_SVC_IFACE"
  fi
}

case "${1:-up}" in
  up)     up ;;
  down)   down ;;
  status) ip -br addr show dev "$CT_SVC_IFACE" ;;
  *)      echo "Uso: $0 up|down|status" >&2; exit 2 ;;
esac
