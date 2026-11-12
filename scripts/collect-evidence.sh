#!/usr/bin/env bash
# =============================================================================
#  collect-evidence.sh - Coleta automática de evidências técnicas
# -----------------------------------------------------------------------------
#  Gera arquivos de texto com a saída real dos comandos que comprovam o
#  funcionamento do ambiente, em evidencias/coleta-<data>/ dentro do repositório.
#  Os arquivos podem ser versionados no GitHub junto com as capturas de tela.
#
#  Uso: sudo ./scripts/collect-evidence.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root "$@"
ct_init "Coleta de evidências"
set +e; trap - ERR
export NO_COLOR=1 COLUMNS=200 LINES=50   # evita aviso do procps em sessões sem terminal

OUT="$CT_REPO_DIR/evidencias/coleta-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# section <arquivo> <título> <comando...> -> registra comando e saída
section() {
  local file="$OUT/$1" title="$2"; shift 2
  {
    printf '\n### %s\n$ %s\n' "$title" "$*"
    bash -c "$*" 3>&1 2>&1
  } >>"$file"
}

log_info "Gerando evidências em $OUT"

F=01-sistema.txt
section $F "Data da coleta"                 "date '+%d/%m/%Y %H:%M:%S %Z'"
section $F "Hostname"                       "hostname; hostnamectl 2>/dev/null | head -12"
section $F "Sistema operacional"            "cat /etc/os-release | head -4; uname -a"
section $F "Ambiente"                       "systemd-detect-virt; echo '$(env_label)'"
section $F "Tempo ligado / boot do systemd" "uptime; ps -o lstart= -p 1"
section $F "Recursos"                       "nproc; free -h; df -h /"

F=02-rede-dns.txt
section $F "Interfaces e IPs"               "ip -br addr"
section $F "Interface de serviço"           "ip addr show dev $CT_SVC_IFACE"
section $F "Rotas"                          "ip route"
section $F "/etc/hosts (bloco gerenciado)"  "sed -n '/BEGIN CITIZENTECH/,/END CITIZENTECH/p' /etc/hosts"
section $F "DNS configurado"                "cat /etc/resolv.conf; ls -l /etc/resolv.conf"
section $F "wsl.conf (somente WSL)"         "cat /etc/wsl.conf 2>/dev/null || echo 'não é WSL'"
section $F "Resolução de nomes local"       "getent hosts $CT_DOMAIN app.$CT_DOMAIN $CT_HOSTNAME"
section $F "Resolução externa"              "getent ahostsv4 $DNS_TEST_NAME | head -3; dig +short @${DNS_SERVERS%% *} $DNS_TEST_NAME"
section $F "Portas em escuta"               "ss -ltnp | grep -E ':80 |:$APP_PORT '"
section $F "Firewall"                       "ufw status verbose 2>/dev/null || echo 'ufw não utilizado neste ambiente'"

F=03-usuarios-permissoes.txt
section $F "Usuários do projeto"            "id $CT_APP_USER; id $CT_OPS_USER; getent passwd $CT_APP_USER $CT_OPS_USER"
section $F "Grupo de operadores"            "getent group $CT_OPS_GROUP"
section $F "Regras sudo"                    "cat /etc/sudoers.d/citizentech; sudo -l -U $CT_OPS_USER"
section $F "Permissões dos diretórios"      "stat -c '%A %U:%G %n' $CT_HOME $CT_HOME/app $CT_HOME/bin $CT_ETC $CT_ETC/* $CT_DATA $CT_DATA/db $CT_LOG_DIR $CT_LOG_DIR/app"
section $F "Variáveis de ambiente da app"   "sed -E 's/^(SECRET_KEY=).*/\\1********/' $CT_ETC/app.env"
section $F "Variáveis de shell"             "cat /etc/profile.d/citizentech.sh"

F=04-servicos-systemd.txt
for u in citizentech-network.service citizentech-app.service nginx.service citizentech-monitor.service citizentech-healthcheck.timer citizentech-healthcheck.service; do
  section $F "systemctl status $u"          "systemctl status $u --no-pager -n 5"
done
section $F "Habilitados no boot"            "systemctl is-enabled citizentech-network citizentech-app nginx citizentech-monitor citizentech-healthcheck.timer"
section $F "Timers"                         "systemctl list-timers citizentech-* --no-pager"
section $F "Unit do monitor"                "systemctl cat citizentech-monitor.service"
section $F "Unit da aplicação"              "systemctl cat citizentech-app.service"

F=05-aplicacao.txt
section $F "Health check via Nginx"         "curl -s -i http://$CT_DOMAIN$APP_HEALTH_PATH"
section $F "Informações da aplicação"       "curl -s http://$CT_DOMAIN/api/info | jq . 2>/dev/null || curl -s http://$CT_DOMAIN/api/info"
section $F "Ocorrências (API)"              "curl -s http://$CT_DOMAIN/api/ocorrencias | jq '.[0:3]' 2>/dev/null"
section $F "Página inicial (cabeçalhos)"    "curl -s -I http://$CT_DOMAIN/"
section $F "Processos da aplicação"         "ps -o user,pid,ppid,%cpu,%mem,cmd -u $CT_APP_USER"
section $F "Log de acesso"                  "tail -n 10 $CT_LOG_DIR/app/access.log"

F=06-monitoramento.txt
section $F "Verificação manual"             "$CT_HOME/bin/monitor.sh"
section $F "Verificação em JSON"            "$CT_HOME/bin/monitor.sh --json | jq ."
section $F "Últimas verificações do serviço" "tail -n 15 $CT_LOG_DIR/monitor.log"
section $F "Histórico de métricas (CSV)"    "head -1 $CT_LOG_DIR/metrics.csv; tail -n 10 $CT_LOG_DIR/metrics.csv"
section $F "Journal do monitor"             "journalctl -u citizentech-monitor -n 15 --no-pager -o short-iso"

F=07-logs-auditoria.txt
for f in audit alerts errors service-events healthcheck fault-tests; do
  section $F "$f.log (últimas linhas)"      "tail -n 25 $CT_LOG_DIR/$f.log"
done
section $F "Instalações registradas"        "grep -h 'pacote instalado' $CT_LOG_DIR/provision.log | tail -n 40"
section $F "Auditoria no journald"          "journalctl -t citizentech-audit -n 20 --no-pager -o short-iso"
section $F "Arquivos de log"                "ls -la $CT_LOG_DIR $CT_LOG_DIR/app"
section $F "Rotação de logs"                "cat /etc/logrotate.d/citizentech"

F=08-validacao.txt
section $F "Validação automática"           "$SCRIPT_DIR/04-validate.sh"

[[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER": "$CT_REPO_DIR/evidencias" 2>/dev/null
log_ok "Evidências geradas:"
ls -1 "$OUT" | sed 's/^/        /' >&3
audit "evidencias" "OK" "destino=$OUT"
