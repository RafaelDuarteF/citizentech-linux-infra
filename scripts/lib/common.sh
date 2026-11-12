#!/usr/bin/env bash
# shellcheck disable=SC2034
# =============================================================================
#  lib/common.sh - Biblioteca compartilhada pelos scripts CitizenTech
# -----------------------------------------------------------------------------
#  - carrega a configuração central (config/citizentech.conf)
#  - logging padronizado: console colorido + arquivo + journald
#  - trilha de AUDITORIA: quem executou, o quê, quando e qual o resultado
#  - tratamento de erros: registra script, linha, comando e código de saída
#  - utilitários: apt idempotente, templates, blocos gerenciados, backups
# =============================================================================

[[ -n "${_CT_COMMON_LOADED:-}" ]] && return 0
_CT_COMMON_LOADED=1

# Bash 5.2: impede que '&' na substituição de strings seja interpretado
shopt -u patsub_replacement 2>/dev/null || true
# Locale UTF-8 (acentos corretos também quando executado pelo systemd)
export LANG="${LANG:-C.UTF-8}"

# ---- Localização e configuração ---------------------------------------------
CT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT_REPO_DIR="$(cd "$CT_LIB_DIR/../.." && pwd)"

# Executando a partir do repositório -> usa config/ do repositório.
# Executando a cópia instalada (/opt/citizentech/bin) -> usa /etc/citizentech.
if [[ -z "${CT_CONF_FILE:-}" ]]; then
  if [[ -f "$CT_REPO_DIR/config/citizentech.conf" ]]; then
    CT_CONF_FILE="$CT_REPO_DIR/config/citizentech.conf"
  else
    CT_CONF_FILE="/etc/citizentech/citizentech.conf"
  fi
fi
if [[ ! -r "$CT_CONF_FILE" ]]; then
  echo "ERRO: configuração não encontrada ou sem permissão de leitura: $CT_CONF_FILE" >&2
  exit 2
fi
# shellcheck source=../../config/citizentech.conf
source "$CT_CONF_FILE"

# ---- Identificação da execução ----------------------------------------------
CT_SCRIPT="${CT_SCRIPT_NAME:-$(basename "$0")}"
CT_RUN_ID="${CT_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"   # correlaciona linhas de log
CT_LOG_FILE="${CT_LOG_FILE:-$CT_LOG_DIR/provision.log}"
CT_AUDIT_LOG="$CT_LOG_DIR/audit.log"
CT_ERROR_LOG="$CT_LOG_DIR/errors.log"
CT_CMD_LOG="${CT_CMD_LOG:-$CT_LOG_DIR/commands.log}"   # saída bruta (apt, pip...)
CT_CURRENT_STEP="inicio"
CT_STEP_NO=0
CT_STEP_TOTAL="${CT_STEP_TOTAL:-0}"

# Descritor 3 = console. Permite redirecionar a saída de comandos para o log
# sem esconder as mensagens de progresso.
if ! { true >&3; } 2>/dev/null; then exec 3>&1; fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

# ---- Logging ----------------------------------------------------------------
_ct_ts() { printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1; }

# Acrescenta uma linha a um arquivo de log, se houver permissão.
# Arquivos novos nascem com permissão 640 (umask 027).
_ct_append() {
  local file="$1" line="$2" dir
  dir="$(dirname "$file")"
  if [[ -e "$file" ]]; then
    [[ -w "$file" ]] || return 0
  else
    [[ -d "$dir" && -w "$dir" ]] || return 0
  fi
  ( umask 027; printf '%s\n' "$line" >>"$file" ) 2>/dev/null || true
}

_ct_journal() {  # _ct_journal <prioridade> <tag> <mensagem>
  command -v logger >/dev/null 2>&1 || return 0
  logger -t "$2" -p "user.$1" -- "$3" 2>/dev/null || true
}

_ct_log() {  # _ct_log <NIVEL> <rótulo-console> <cor> <mensagem...>
  local level="$1" label="$2" color="$3"; shift 3
  local msg="$*" ts
  ts="$(_ct_ts)"
  printf '%s%s%s %s\n' "$color" "$label" "$C_RESET" "$msg" >&3
  _ct_append "$CT_LOG_FILE" "$ts [$level] [$CT_SCRIPT] [run=$CT_RUN_ID] $msg"
  case "$level" in
    ERROR) _ct_append "$CT_ERROR_LOG" "$ts [ERROR] [$CT_SCRIPT] [run=$CT_RUN_ID] $msg"
           _ct_journal err citizentech "[$CT_SCRIPT] $msg" ;;
    WARN)  _ct_journal warning citizentech "[$CT_SCRIPT] $msg" ;;
  esac
}

log_info()  { _ct_log INFO  "[INFO]" "$C_BLUE"   "$@"; }
log_ok()    { _ct_log OK    "[ OK ]" "$C_GREEN"  "$@"; }
log_warn()  { _ct_log WARN  "[WARN]" "$C_YELLOW" "$@"; }
log_error() { _ct_log ERROR "[ERRO]" "$C_RED"    "$@"; }
log_step()  {
  local n=""
  (( CT_STEP_TOTAL > 0 )) && n="[$CT_STEP_NO/$CT_STEP_TOTAL] "
  printf '\n%s==> %s%s%s\n' "$C_BOLD$C_CYAN" "$n" "$*" "$C_RESET" >&3
  _ct_append "$CT_LOG_FILE" "$(_ct_ts) [STEP ] [$CT_SCRIPT] [run=$CT_RUN_ID] $n$*"
}

# pad <texto> <largura> -> texto alinhado à esquerda contando CARACTERES
# (o printf do bash conta bytes e desalinha palavras acentuadas)
pad() {
  local s="$1" n
  n=$(( $2 - ${#s} )); (( n < 0 )) && n=0
  printf '%s%*s' "$s" "$n" ''
}

# kv <largura> rótulo valor [rótulo valor...] -> tabela de duas colunas
kv() {
  local w="$1"; shift
  while (( $# >= 2 )); do
    printf '  %s %s\n' "$(pad "$1" "$w")" "$2" >&3
    shift 2
  done
}

banner() {
  local title="$1" sub="${2:-}"
  printf '\n%s+------------------------------------------------------------------+%s\n' "$C_MAGENTA" "$C_RESET" >&3
  printf '%s|%s %s %s|%s\n' "$C_MAGENTA" "$C_BOLD" "$(pad "$title" 64)" "$C_RESET$C_MAGENTA" "$C_RESET" >&3
  [[ -n "$sub" ]] && printf '%s|%s %s %s|%s\n' "$C_MAGENTA" "$C_DIM" "$(pad "$sub" 64)" "$C_RESET$C_MAGENTA" "$C_RESET" >&3
  printf '%s+------------------------------------------------------------------+%s\n' "$C_MAGENTA" "$C_RESET" >&3
}

# ---- Auditoria --------------------------------------------------------------
# Formato (uma linha por evento, separado por " | "):
# data | run=ID | host= | user= | script= | acao= | resultado=OK/FAIL | detalhe=
audit() {
  local action="$1" result="$2" detail="${3:-}" who line
  who="$(id -un 2>/dev/null || echo "uid$EUID")"
  [[ -n "${SUDO_USER:-}" ]] && who="${SUDO_USER}(sudo)"
  line="$(_ct_ts) | run=$CT_RUN_ID | host=$(hostname) | user=$who | script=$CT_SCRIPT | acao=$action | resultado=$result | detalhe=$detail"
  _ct_append "$CT_AUDIT_LOG" "$line"
  if [[ "$result" == "FAIL" ]]; then
    _ct_journal err citizentech-audit "${line#* | }"
  else
    _ct_journal notice citizentech-audit "${line#* | }"
  fi
}

# ---- Tratamento de erros ----------------------------------------------------
_ct_on_error() {
  local rc=$? where="$1" cmd="$2"
  [[ -n "${_CT_ERR_HANDLED:-}" ]] && return "$rc"
  _CT_ERR_HANDLED=1
  log_error "Falha na etapa '$CT_CURRENT_STEP' ($where, exit=$rc): $cmd"
  audit "$CT_CURRENT_STEP" "FAIL" "local=$where exit=$rc comando=$cmd"
  return "$rc"
}

_ct_on_exit() {
  local rc=$?
  if (( rc == 0 )); then
    audit "fim" "OK" "duracao=${SECONDS}s"
  else
    audit "fim" "FAIL" "exit=$rc duracao=${SECONDS}s"
    printf '\n%s[ERRO] %s terminou com erro (exit=%s). Detalhes: %s e %s%s\n' \
      "$C_RED" "$CT_SCRIPT" "$rc" "$CT_ERROR_LOG" "$CT_CMD_LOG" "$C_RESET" >&3
  fi
}

# ct_init "descrição" -> modo estrito, traps de erro/saída, registro de início
ct_init() {
  set -Eeuo pipefail
  trap '_ct_on_error "${BASH_SOURCE[0]##*/}:$LINENO" "$BASH_COMMAND"' ERR
  trap '_ct_on_exit' EXIT
  if [[ $EUID -eq 0 ]]; then
    install -d -m 2751 "$CT_LOG_DIR"
    getent group "$CT_OPS_GROUP" >/dev/null 2>&1 && chgrp "$CT_OPS_GROUP" "$CT_LOG_DIR"
  fi
  audit "inicio" "OK" "$1"
}

# step "descrição" função [args] -> executa uma etapa com log e auditoria.
# Em caso de erro, o trap ERR registra a falha da etapa e o script é abortado.
step() {
  local desc="$1"; shift
  local t0=$SECONDS
  CT_STEP_NO=$((CT_STEP_NO + 1))
  CT_CURRENT_STEP="$desc"
  log_step "$desc"
  "$@"
  audit "$desc" "OK" "duracao=$((SECONDS - t0))s"
}

# quiet comando... -> executa comando enviando a saída para commands.log.
# Se falhar, mostra as últimas linhas no console e devolve o código de erro.
quiet() {
  local rc=0
  _ct_append "$CT_CMD_LOG" "$(_ct_ts) [run=$CT_RUN_ID] \$ $*"
  if [[ -w "$CT_LOG_DIR" ]]; then
    "$@" >>"$CT_CMD_LOG" 2>&1 || rc=$?
  else
    "$@" >/dev/null 2>&1 || rc=$?
  fi
  if (( rc != 0 )); then
    log_error "Comando falhou (exit=$rc): $*"
    [[ -r "$CT_CMD_LOG" ]] && tail -n 12 "$CT_CMD_LOG" | sed 's/^/        | /' >&3
    return "$rc"
  fi
}

# ---- Verificações de ambiente -----------------------------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${C_RED}Este script precisa de privilégios de root. Use: sudo $0 ${*}${C_RESET}" >&2
    exit 1
  fi
}

is_wsl() { grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; }

env_kind() {
  if is_wsl; then echo "wsl"
  elif [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "7783-7084-3265-9085-8269-3286-77" ]]; then echo "azure"
  else echo "vm"
  fi
}

env_label() {
  case "$(env_kind)" in
    wsl)   echo "WSL2 (Windows Subsystem for Linux)" ;;
    azure) echo "Máquina virtual Azure" ;;
    *)     echo "Máquina virtual ($(systemd-detect-virt 2>/dev/null || echo desconhecida))" ;;
  esac
}

default_iface() { ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

primary_ip() {
  local ifc; ifc="$(default_iface)"
  [[ -n "$ifc" ]] && ip -o -4 addr show dev "$ifc" | awk '{print $4; exit}'
}

# wait_until <segundos> comando... -> repete até o comando ter sucesso
wait_until() {
  local timeout="$1"; shift
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= end )) && return 1
    sleep 1
  done
}

# ---- Pacotes ----------------------------------------------------------------
_CT_APT_UPDATED=""
apt_update_once() {
  [[ -n "$_CT_APT_UPDATED" ]] && return 0
  log_info "Atualizando índice de pacotes (apt-get update)"
  quiet env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
  _CT_APT_UPDATED=1
}

# apt_install pacote... -> instala apenas o que falta e registra versões
apt_install() {
  local p missing=()
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    log_info "Já instalados: $*"
    return 0
  fi
  apt_update_once
  log_info "Instalando: ${missing[*]}"
  quiet env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${missing[@]}"
  local line
  while read -r line; do
    _ct_append "$CT_LOG_FILE" "$(_ct_ts) [INFO ] [$CT_SCRIPT] [run=$CT_RUN_ID] pacote instalado: $line"
  done < <(dpkg-query -W -f='${Package} ${Version}\n' "${missing[@]}" 2>/dev/null)
  audit "apt-install" "OK" "pacotes=${missing[*]}"
  log_ok "Instalados: ${missing[*]}"
}

# ---- Arquivos ---------------------------------------------------------------
# backup_file <arquivo> -> guarda cópia em CT_BACKUP_DIR (mantém o original .orig)
backup_file() {
  local f="$1" name
  [[ -e "$f" || -L "$f" ]] || return 0
  install -d -m 0700 "$CT_BACKUP_DIR"
  name="$(echo "${f#/}" | tr '/' '_')"
  [[ -e "$CT_BACKUP_DIR/$name.orig" ]] || cp -aL "$f" "$CT_BACKUP_DIR/$name.orig" 2>/dev/null || true
  cp -aL "$f" "$CT_BACKUP_DIR/$name.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
}

# render_template <origem> <destino> -> substitui @VARIAVEL@ pelo valor da variável
render_template() {
  local src="$1" dst="$2" content var val
  content="$(<"$src")"
  while [[ "$content" =~ @([A-Z][A-Z0-9_]*)@ ]]; do
    var="${BASH_REMATCH[1]}"
    if [[ ! -v "$var" ]]; then
      log_error "Template $src usa @$var@, mas a variável não está definida"
      return 1
    fi
    val="${!var}"
    content="${content//"@$var@"/"$val"}"
  done
  printf '%s\n' "$content" >"$dst"
}

# set_managed_block <arquivo> <conteúdo> -> mantém um bloco delimitado no arquivo
# (re-execuções substituem o bloco, nunca duplicam)
set_managed_block() {
  local file="$1" content="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk '/^# BEGIN CITIZENTECH/{skip=1} !skip{print} /^# END CITIZENTECH/{skip=0}' "$file" >"$tmp"
  fi
  {
    cat "$tmp"
    printf '# BEGIN CITIZENTECH (gerenciado por citizentech-linux-infra - não editar)\n'
    printf '%s\n' "$content"
    printf '# END CITIZENTECH\n'
  } >"$tmp.new"
  cat "$tmp.new" >"$file"   # 'cat >' preserva dono e permissões do arquivo
  rm -f "$tmp" "$tmp.new"
}

remove_managed_block() {
  local file="$1" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp)"
  awk '/^# BEGIN CITIZENTECH/{skip=1} !skip{print} /^# END CITIZENTECH/{skip=0}' "$file" >"$tmp"
  cat "$tmp" >"$file"; rm -f "$tmp"
}

# ini_set <arquivo> <seção> <chave> <valor> -> edita arquivos .ini (ex.: /etc/wsl.conf)
ini_set() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  [[ -f "$file" ]] || touch "$file"
  tmp="$(mktemp)"
  awk -v s="[$section]" -v k="$key" -v v="$value" '
    function emit() { if (insec && !done) { print k " = " v; done = 1 } }
    {
      t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (substr(t, 1, 1) == "[") {
        emit(); insec = (t == s); if (insec) found = 1; print; next
      }
      if (insec) {
        split(t, kv, "="); kk = kv[1]; gsub(/[ \t]+$/, "", kk)
        if (kk == k) { if (!done) { print k " = " v; done = 1 }; next }
      }
      print
    }
    END { emit(); if (!found) { print ""; print s; print k " = " v } }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"; rm -f "$tmp"
}

# install_runtime <arquivo>... -> instala scripts de runtime em CT_HOME/bin
install_runtime() {
  local src_dir="$CT_REPO_DIR/scripts" f
  install -d -m 0755 -o root -g root "$CT_HOME/bin" "$CT_HOME/bin/lib"
  install -m 0644 -o root -g root "$src_dir/lib/common.sh" "$CT_HOME/bin/lib/common.sh"
  for f in "$@"; do
    install -m 0755 -o root -g root "$src_dir/$f" "$CT_HOME/bin/$f"
  done
}

# ---- Leitura de métricas (compartilhado entre monitor e validação) ----------
unit_active() { systemctl is-active --quiet "$1"; }
