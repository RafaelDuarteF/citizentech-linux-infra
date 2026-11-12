#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas pela lib/common.sh e pelos templates
# =============================================================================
#  01-provision-infra.sh - Provisionamento da INFRAESTRUTURA Linux (CitizenTech)
# -----------------------------------------------------------------------------
#  O que este script faz (idempotente: pode ser executado várias vezes):
#    1. Verifica pré-requisitos (root, Ubuntu/Debian, systemd, ambiente)
#    2. Instala pacotes base de administração
#    3. Cria usuários, grupos e regras sudo
#    4. Cria diretórios com dono e permissões corretos
#    5. Configura resolução local de nomes (/etc/hosts)
#    6. Configura hostname e fuso horário
#    7. Configura rede: interface de serviço com IP fixo (+ IP estático na VM)
#    8. Configura DNS (com teste e rollback automático)
#    9. Configura logs: diretórios, logrotate e journald persistente
#   10. Configura firewall (ufw)
#
#  Uso: sudo ./scripts/01-provision-infra.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
CT_STEP_TOTAL=10
ct_init "Provisionamento da infraestrutura (hostname, rede, DNS, usuários, logs)"

ENV_KIND="$(env_kind)"
NEED_WSL_RESTART=0

# -----------------------------------------------------------------------------
preflight() {
  # shellcheck disable=SC1091
  source /etc/os-release
  log_info "Sistema operacional: ${PRETTY_NAME:-desconhecido}"
  log_info "Ambiente detectado:  $(env_label)"
  log_info "Kernel:              $(uname -r)"
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* && "${ID:-}" != "debian" ]]; then
    log_error "Distribuição não suportada (${ID:-?}). Use Ubuntu 22.04/24.04 ou Debian 12."
    return 1
  fi
  if [[ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]]; then
    if [[ "$ENV_KIND" == "wsl" ]]; then
      ini_set /etc/wsl.conf boot systemd true
      log_error "O systemd não está ativo no WSL. Habilitei [boot] systemd=true em /etc/wsl.conf."
      log_error "No PowerShell execute: wsl --shutdown   e depois rode este script novamente."
    else
      log_error "Este ambiente não utiliza systemd como PID 1."
    fi
    return 1
  fi
  log_ok "systemd ativo (PID 1)"
  if wait_until 5 getent ahosts deb.debian.org || wait_until 5 ping -c1 -W2 1.1.1.1; then
    log_ok "Conectividade com a internet OK"
  else
    log_warn "Sem conectividade aparente com a internet - a instalação de pacotes pode falhar"
  fi
}

# -----------------------------------------------------------------------------
install_base_packages() {
  local pkgs=(ca-certificates curl wget git jq rsync acl sudo openssl tzdata
              iproute2 iputils-ping bind9-dnsutils net-tools lsof procps
              htop sysstat stress-ng logrotate)
  [[ "$(firewall_enabled)" == "yes" ]] && pkgs+=(ufw)
  apt_install "${pkgs[@]}"
}

# -----------------------------------------------------------------------------
setup_users() {
  # Grupo de operadores: lê logs e gerencia os serviços do projeto via sudo
  if ! getent group "$CT_OPS_GROUP" >/dev/null; then
    groupadd --system "$CT_OPS_GROUP"
    log_ok "Grupo criado: $CT_OPS_GROUP"
    audit "grupo-criado" "OK" "$CT_OPS_GROUP"
  else
    log_info "Grupo já existe: $CT_OPS_GROUP"
  fi

  # Usuário de sistema da aplicação: sem shell e sem login (princípio do menor privilégio)
  if ! id "$CT_APP_USER" &>/dev/null; then
    useradd --system --user-group --home-dir "$CT_DATA/home" --no-create-home \
            --shell /usr/sbin/nologin --comment "CitizenTech - servico da aplicacao" "$CT_APP_USER"
    log_ok "Usuário de serviço criado: $CT_APP_USER (sem login)"
    audit "usuario-criado" "OK" "$CT_APP_USER tipo=sistema shell=nologin"
  else
    log_info "Usuário de serviço já existe: $CT_APP_USER"
  fi

  # Usuário operador da equipe (senha bloqueada: acesso via 'sudo -iu ctops')
  if ! id "$CT_OPS_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash --groups "$CT_OPS_GROUP" \
            --comment "CitizenTech - operador" "$CT_OPS_USER"
    passwd -l "$CT_OPS_USER" >/dev/null
    log_ok "Usuário operador criado: $CT_OPS_USER (grupo $CT_OPS_GROUP)"
    audit "usuario-criado" "OK" "$CT_OPS_USER tipo=operador grupos=$CT_OPS_GROUP"
  else
    usermod -aG "$CT_OPS_GROUP" "$CT_OPS_USER"
    log_info "Usuário operador já existe: $CT_OPS_USER"
  fi

  # O administrador que executou o script também entra no grupo de operadores
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && id "$SUDO_USER" &>/dev/null; then
    usermod -aG "$CT_OPS_GROUP" "$SUDO_USER"
    log_info "Usuário $SUDO_USER adicionado ao grupo $CT_OPS_GROUP"
  fi

  # Regras sudo: operadores gerenciam SOMENTE os serviços do projeto
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# CitizenTech - gerado por 01-provision-infra.sh em $(_ct_ts)
# Operadores podem administrar somente os serviços do projeto, sem senha.
Cmnd_Alias CT_SERVICES = /usr/bin/systemctl start citizentech-*, \\
                         /usr/bin/systemctl stop citizentech-*, \\
                         /usr/bin/systemctl restart citizentech-*, \\
                         /usr/bin/systemctl status citizentech-*, \\
                         /usr/bin/systemctl restart nginx, \\
                         /usr/bin/journalctl -u citizentech-*, \\
                         $CT_HOME/bin/monitor.sh, $CT_HOME/bin/healthcheck.sh
%$CT_OPS_GROUP ALL=(root) NOPASSWD: CT_SERVICES
EOF
  if visudo -cqf "$tmp"; then
    install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/citizentech
    log_ok "Regras sudo instaladas em /etc/sudoers.d/citizentech (validadas com visudo)"
  else
    rm -f "$tmp"
    log_error "Arquivo sudoers inválido - não instalado"
    return 1
  fi
  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
setup_directories() {
  #           caminho                      modo  dono               grupo
  local dirs=(
    "$CT_HOME"                   0755 root              root
    "$CT_HOME/bin"               0755 root              root
    "$CT_HOME/app"               0750 root              "$CT_APP_USER"
    "$CT_ETC"                    0750 root              "$CT_OPS_GROUP"
    "$CT_DATA"                   0755 root              root
    "$CT_DATA/db"                0750 "$CT_APP_USER"    "$CT_APP_USER"
    "$CT_DATA/home"              0750 "$CT_APP_USER"    "$CT_APP_USER"
    "$CT_STATE_DIR"              0750 root              "$CT_OPS_GROUP"
    "$CT_LOG_DIR"                2751 root              "$CT_OPS_GROUP"
    "$CT_LOG_DIR/app"            2750 "$CT_APP_USER"    "$CT_OPS_GROUP"
    "$CT_BACKUP_DIR"             0700 root              root
  )
  local i
  for ((i = 0; i < ${#dirs[@]}; i += 4)); do
    install -d -m "${dirs[i+1]}" -o "${dirs[i+2]}" -g "${dirs[i+3]}" "${dirs[i]}"
    chmod "${dirs[i+1]}" "${dirs[i]}"
    printf '        %-32s %s %s:%s\n' "${dirs[i]}" "${dirs[i+1]}" "${dirs[i+2]}" "${dirs[i+3]}" >&3
  done
  # Arquivos de log principais já nascem com dono/permissão corretos
  local f
  for f in audit provision commands errors monitor alerts healthcheck service-events network fault-tests; do
    [[ -e "$CT_LOG_DIR/$f.log" ]] || install -m 0640 -o root -g "$CT_OPS_GROUP" /dev/null "$CT_LOG_DIR/$f.log"
  done
  chgrp "$CT_OPS_GROUP" "$CT_LOG_DIR"/*.log 2>/dev/null || true

  # Configuração central instalada para uso dos serviços
  install -m 0640 -o root -g "$CT_OPS_GROUP" "$CT_CONF_FILE" "$CT_ETC/citizentech.conf"
  log_ok "Configuração instalada em $CT_ETC/citizentech.conf"

  # Scripts de runtime usados pelo systemd
  install_runtime service-event.sh ct-network.sh
  log_ok "Scripts de runtime instalados em $CT_HOME/bin"

  # Variáveis de ambiente para sessões de shell
  cat >/etc/profile.d/citizentech.sh <<EOF
# CitizenTech - variáveis de ambiente (gerado por 01-provision-infra.sh)
export CITIZENTECH_HOME="$CT_HOME"
export CITIZENTECH_ETC="$CT_ETC"
export CITIZENTECH_LOGS="$CT_LOG_DIR"
export CITIZENTECH_URL="http://$CT_DOMAIN"
case ":\$PATH:" in *":$CT_HOME/bin:"*) ;; *) export PATH="\$PATH:$CT_HOME/bin" ;; esac
alias ct-logs='sudo tail -n 20 -F $CT_LOG_DIR/{audit,alerts,errors,monitor,healthcheck,service-events}.log'
EOF
  chmod 0644 /etc/profile.d/citizentech.sh
  log_ok "Variáveis de ambiente de shell em /etc/profile.d/citizentech.sh"
}

# -----------------------------------------------------------------------------
setup_hosts() {
  backup_file /etc/hosts
  set_managed_block /etc/hosts "127.0.1.1    $CT_HOSTNAME $CT_HOSTNAME.$CT_DOMAIN
127.0.0.1    $CT_DOMAIN www.$CT_DOMAIN
$CT_SVC_IP   app.$CT_DOMAIN api.$CT_DOMAIN"
  log_ok "/etc/hosts atualizado:"
  sed -n '/^# BEGIN CITIZENTECH/,/^# END CITIZENTECH/p' /etc/hosts | sed 's/^/        /' >&3
  if [[ "$ENV_KIND" == "wsl" ]]; then
    # Impede o WSL de sobrescrever o /etc/hosts a cada inicialização
    ini_set /etc/wsl.conf network generateHosts false
    log_info "WSL: generateHosts=false em /etc/wsl.conf (mantém /etc/hosts entre reinícios)"
  fi
}

# -----------------------------------------------------------------------------
setup_hostname_timezone() {
  local current; current="$(hostname)"
  if [[ "$ENV_KIND" == "wsl" ]]; then
    ini_set /etc/wsl.conf network hostname "$CT_HOSTNAME"
    echo "$CT_HOSTNAME" >/etc/hostname
    hostname "$CT_HOSTNAME" 2>/dev/null || NEED_WSL_RESTART=1
    log_info "WSL: hostname persistido em /etc/wsl.conf ([network] hostname)"
  else
    hostnamectl set-hostname "$CT_HOSTNAME"
    # cloud-init (Azure) não deve sobrescrever o hostname nem o /etc/hosts no boot
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      printf 'preserve_hostname: true\nmanage_etc_hosts: false\n' >/etc/cloud/cloud.cfg.d/99-citizentech.cfg
    fi
  fi
  log_ok "Hostname: $current -> $(hostname)"
  audit "hostname" "OK" "anterior=$current novo=$CT_HOSTNAME"

  if timedatectl set-timezone "$CT_TIMEZONE" 2>/dev/null; then :; else
    ln -sf "/usr/share/zoneinfo/$CT_TIMEZONE" /etc/localtime
    echo "$CT_TIMEZONE" >/etc/timezone
  fi
  log_ok "Fuso horário: $CT_TIMEZONE ($(date '+%d/%m/%Y %H:%M:%S %Z'))"
}

# -----------------------------------------------------------------------------
setup_network() {
  # 1) Interface de serviço ct0 com IP fixo, recriada a cada boot pelo systemd
  render_template "$CT_REPO_DIR/systemd/citizentech-network.service" /etc/systemd/system/citizentech-network.service
  systemctl daemon-reload
  systemctl enable citizentech-network.service >/dev/null 2>&1
  systemctl restart citizentech-network.service
  if ip -4 addr show dev "$CT_SVC_IFACE" 2>/dev/null | grep -q "inet $CT_SVC_IP/"; then
    log_ok "Interface de serviço $CT_SVC_IFACE: $CT_SVC_IP/$CT_SVC_PREFIX (citizentech-network.service habilitado no boot)"
  else
    log_error "Interface $CT_SVC_IFACE sem o IP $CT_SVC_IP"
    return 1
  fi

  # 2) IP estático da interface principal (somente VM, quando NET_MODE=static)
  if [[ "$ENV_KIND" == "wsl" ]]; then
    log_info "WSL: IP principal ($(primary_ip)) é atribuído pelo Windows (NAT) - mantido"
  elif [[ "$NET_MODE" == "static" ]]; then
    configure_static_ip
  else
    log_info "NET_MODE=dhcp: interface principal $(default_iface) mantida em DHCP ($(primary_ip))"
  fi

  log_info "Endereços atuais:"
  ip -br -4 addr | sed 's/^/        /' >&3
  log_info "Rota padrão: $(ip route show default | head -1)"
}

configure_static_ip() {
  local iface="${NET_IFACE:-$(default_iface)}" file=/etc/netplan/60-citizentech.yaml
  if ! ip link show "$iface" &>/dev/null; then
    log_error "Interface '$iface' não existe (ajuste NET_IFACE em config/citizentech.conf)"
    return 1
  fi
  command -v netplan >/dev/null || { log_error "netplan não encontrado"; return 1; }
  backup_file "$file"
  {
    echo "# CitizenTech - IP estático (gerado por 01-provision-infra.sh)"
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    $iface:"
    echo "      dhcp4: false"
    echo "      addresses: [$NET_ADDRESS]"
    if [[ -n "$NET_GATEWAY" ]]; then
      echo "      routes:"
      echo "        - to: default"
      echo "          via: $NET_GATEWAY"
    fi
    echo "      nameservers:"
    echo "        addresses: [${DNS_SERVERS// /, }]"
  } >"$file"
  chmod 600 "$file"
  quiet netplan generate
  quiet netplan apply
  sleep 3
  # Validação com rollback automático para não perder acesso à máquina
  local ok=1
  ip -4 addr show dev "$iface" | grep -q "inet ${NET_ADDRESS%/*}/" || ok=0
  if [[ -n "$NET_GATEWAY" ]] && ! wait_until 10 ping -c1 -W1 "$NET_GATEWAY"; then ok=0; fi
  if (( ok )); then
    log_ok "IP estático aplicado: $iface = $NET_ADDRESS ${NET_GATEWAY:+(gateway $NET_GATEWAY)}"
    audit "ip-estatico" "OK" "iface=$iface ip=$NET_ADDRESS gw=${NET_GATEWAY:-nenhum}"
  else
    log_error "Validação do IP estático falhou - executando ROLLBACK"
    rm -f "$file"; quiet netplan apply || true
    audit "ip-estatico" "FAIL" "rollback executado iface=$iface"
    return 1
  fi
}

# -----------------------------------------------------------------------------
dns_works() { getent ahosts "$DNS_TEST_NAME" >/dev/null 2>&1; }

setup_dns() {
  local s
  if [[ "$ENV_KIND" == "wsl" ]]; then
    backup_file /etc/resolv.conf
    local old_link=""; [[ -L /etc/resolv.conf ]] && old_link="$(readlink /etc/resolv.conf)"
    ini_set /etc/wsl.conf network generateResolvConf false
    rm -f /etc/resolv.conf
    {
      echo "# CitizenTech - DNS gerenciado por 01-provision-infra.sh (WSL generateResolvConf=false)"
      for s in $DNS_SERVERS; do echo "nameserver $s"; done
      echo "search $CT_DOMAIN"
      echo "options timeout:2 attempts:2"
    } >/etc/resolv.conf
    chmod 0644 /etc/resolv.conf
    if ! wait_until 8 dns_works; then
      log_warn "Resolução externa falhou com $DNS_SERVERS - ROLLBACK para o DNS do WSL"
      rm -f /etc/resolv.conf
      [[ -n "$old_link" ]] && ln -s "$old_link" /etc/resolv.conf
      ini_set /etc/wsl.conf network generateResolvConf true
      audit "dns" "FAIL" "rollback para DNS automático do WSL"
      return 0
    fi
  elif systemctl is-active --quiet systemd-resolved; then
    install -d /etc/systemd/resolved.conf.d
    backup_file /etc/systemd/resolved.conf.d/citizentech.conf
    cat >/etc/systemd/resolved.conf.d/citizentech.conf <<EOF
# CitizenTech - DNS (gerado por 01-provision-infra.sh)
[Resolve]
DNS=$DNS_SERVERS
FallbackDNS=$DNS_FALLBACK
Domains=$CT_DOMAIN
EOF
    systemctl restart systemd-resolved
    if ! wait_until 8 dns_works; then
      log_warn "Resolução externa falhou - ROLLBACK da configuração de DNS"
      rm -f /etc/systemd/resolved.conf.d/citizentech.conf
      systemctl restart systemd-resolved
      audit "dns" "FAIL" "rollback systemd-resolved"
      return 0
    fi
  else
    backup_file /etc/resolv.conf
    { for s in $DNS_SERVERS; do echo "nameserver $s"; done; echo "search $CT_DOMAIN"; } >/etc/resolv.conf
  fi

  log_ok "Servidores DNS configurados: $DNS_SERVERS"
  for s in $DNS_SERVERS; do
    if dig +time=2 +tries=1 +short "@$s" "$DNS_TEST_NAME" A 2>/dev/null | grep -qE '^[0-9.]+$'; then
      log_ok "  DNS $s respondeu para $DNS_TEST_NAME"
    else
      log_warn "  DNS $s não respondeu (rede pode bloquear DNS externo)"
    fi
  done
  log_ok "Resolução externa:  $DNS_TEST_NAME -> $(getent ahostsv4 "$DNS_TEST_NAME" | awk 'NR==1{print $1}')"
  log_ok "Resolução local:    $CT_DOMAIN -> $(getent hosts "$CT_DOMAIN" | awk '{print $1}'),  app.$CT_DOMAIN -> $(getent hosts "app.$CT_DOMAIN" | awk '{print $1}')"
  audit "dns" "OK" "servidores=$DNS_SERVERS dominio=$CT_DOMAIN"
}

# -----------------------------------------------------------------------------
setup_logging() {
  cat >/etc/logrotate.d/citizentech <<EOF
# CitizenTech - rotação de logs (gerado por 01-provision-infra.sh)
$CT_LOG_DIR/*.log $CT_LOG_DIR/*.csv $CT_LOG_DIR/app/*.log {
    daily
    rotate $LOG_RETENTION_DAYS
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    dateext
}
EOF
  if logrotate -d /etc/logrotate.d/citizentech >/dev/null 2>&1; then
    log_ok "logrotate: rotação diária, retenção de $LOG_RETENTION_DAYS dias"
  else
    log_warn "logrotate reportou avisos na validação da configuração"
  fi

  # journald persistente: os registros sobrevivem à reinicialização (evidência de recuperação)
  install -d /etc/systemd/journald.conf.d /var/log/journal
  cat >/etc/systemd/journald.conf.d/citizentech.conf <<EOF
# CitizenTech - journal persistente (gerado por 01-provision-infra.sh)
[Journal]
Storage=persistent
SystemMaxUse=200M
EOF
  systemctl restart systemd-journald
  log_ok "journald persistente (/var/log/journal) - logs sobrevivem ao reboot"
  log_ok "Logs do projeto em $CT_LOG_DIR:"
  ls -l "$CT_LOG_DIR" | sed 's/^/        /' >&3
}

# -----------------------------------------------------------------------------
firewall_enabled() {
  case "$FIREWALL" in
    yes) echo yes ;;
    no)  echo no ;;
    *)   [[ "$ENV_KIND" == "wsl" ]] && echo no || echo yes ;;
  esac
}

setup_firewall() {
  if [[ "$(firewall_enabled)" != "yes" ]]; then
    log_info "Firewall não alterado neste ambiente (FIREWALL=$FIREWALL, ambiente=$ENV_KIND)"
    return 0
  fi
  quiet ufw default deny incoming
  quiet ufw default allow outgoing
  quiet ufw allow OpenSSH
  quiet ufw allow 80/tcp comment "CitizenTech HTTP"
  quiet ufw --force enable
  log_ok "ufw ativo: entrada bloqueada, liberado SSH (22) e HTTP (80)"
  ufw status | sed 's/^/        /' >&3
}

# -----------------------------------------------------------------------------
summary() {
  banner "Infraestrutura provisionada" "$(env_label)"
  kv 22 \
    "Hostname"            "$(hostname)" \
    "Domínio"             "$CT_DOMAIN" \
    "IP principal"        "$(primary_ip) ($(default_iface))" \
    "IP de serviço"       "$CT_SVC_IP/$CT_SVC_PREFIX ($CT_SVC_IFACE)" \
    "DNS"                 "$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)" \
    "Fuso horário"        "$CT_TIMEZONE" \
    "Usuário da app"      "$CT_APP_USER" \
    "Operador"            "$CT_OPS_USER (grupo $CT_OPS_GROUP)" \
    "Logs"                "$CT_LOG_DIR"
  if (( NEED_WSL_RESTART )); then
    log_warn "Para aplicar o hostname no WSL execute no PowerShell: wsl --terminate <distro>"
  fi
  echo >&3
  log_ok "Próximo passo: sudo ./scripts/02-provision-app.sh"
}

step "Verificando pré-requisitos"                     preflight
step "Instalando pacotes base"                        install_base_packages
step "Usuários, grupos e permissões sudo"             setup_users
step "Diretórios, permissões e variáveis de ambiente" setup_directories
step "Resolução local de nomes (/etc/hosts)"          setup_hosts
step "Hostname e fuso horário"                        setup_hostname_timezone
step "Rede e endereçamento IP"                        setup_network
step "DNS"                                            setup_dns
step "Logs e auditoria (logrotate, journald)"         setup_logging
step "Firewall"                                       setup_firewall
summary
