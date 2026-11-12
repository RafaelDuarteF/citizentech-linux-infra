#!/usr/bin/env bash
# =============================================================================
#  uninstall.sh - Remove o ambiente CitizenTech (para reprovisionar do zero)
# -----------------------------------------------------------------------------
#  Uso: sudo ./scripts/uninstall.sh [--yes] [--purge]
#    --yes    não pede confirmação
#    --purge  remove também dados (banco), logs e usuários do projeto
#
#  Mantém: pacotes instalados, hostname, DNS e /etc/wsl.conf (backups dos
#  arquivos originais ficam em /var/backups/citizentech).
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root "$@"

YES=0; PURGE=0
for a in "$@"; do
  case "$a" in --yes) YES=1 ;; --purge) PURGE=1 ;; *) echo "Opção inválida: $a" >&2; exit 2 ;; esac
done

if (( ! YES )); then
  printf 'Isto remove serviços, configuração e código do CitizenTech%s. Continuar? [s/N] ' "$( ((PURGE)) && echo ', DADOS, LOGS e USUÁRIOS')"
  read -r ans
  [[ "$ans" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 0; }
fi

ct_init "Remoção do ambiente (purge=$PURGE)"
set +e; trap - ERR

UNITS=(citizentech-healthcheck.timer citizentech-healthcheck.service citizentech-monitor.service
       citizentech-app.service citizentech-network.service)

log_step "Parando e removendo serviços"
for u in "${UNITS[@]}"; do
  systemctl disable --now "$u" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$u"
  log_info "removido: $u"
done
rm -rf /etc/systemd/system/nginx.service.d/10-citizentech.conf
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1

log_step "Removendo Nginx site, sudoers, atalhos e configuração"
rm -f /etc/nginx/sites-enabled/citizentech /etc/nginx/sites-available/citizentech
[[ -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]] && \
  ln -s ../sites-available/default /etc/nginx/sites-enabled/default
rm -rf /var/www/citizentech
systemctl reload-or-restart nginx >/dev/null 2>&1
rm -f /etc/sudoers.d/citizentech /etc/profile.d/citizentech.sh /etc/logrotate.d/citizentech
rm -f /usr/local/bin/ct-monitor /usr/local/bin/ct-healthcheck
rm -rf "$CT_HOME" "$CT_ETC"
remove_managed_block /etc/hosts
ip link del "$CT_SVC_IFACE" 2>/dev/null

if (( PURGE )); then
  log_step "Removendo dados, logs e usuários"
  audit "remocao" "OK" "purge: dados, logs e usuarios"
  rm -rf "$CT_DATA" "$CT_LOG_DIR"
  userdel -r "$CT_OPS_USER" 2>/dev/null
  userdel "$CT_APP_USER" 2>/dev/null
  groupdel "$CT_OPS_GROUP" 2>/dev/null
  trap - EXIT
fi

log_ok "Ambiente CitizenTech removido. Para recriar: sudo ./install.sh"
