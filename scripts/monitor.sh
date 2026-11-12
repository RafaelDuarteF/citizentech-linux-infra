#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas pela lib/common.sh e pelos templates
# =============================================================================
#  monitor.sh - Monitoramento de CPU, memória RAM e disco (CitizenTech)
# -----------------------------------------------------------------------------
#  Coleta:
#    CPU    -> % de uso (amostragem de /proc/stat), load average
#    RAM    -> % em uso, total, disponível e swap (/proc/meminfo)
#    Disco  -> % de uso de cada ponto de montagem em DISK_MOUNTS (df)
#    App    -> saúde HTTP da aplicação (endpoint APP_HEALTH_PATH)
#
#  Compara com os limites (config/citizentech.conf) e classifica OK/WARN/CRIT.
#  Em WARN/CRIT gera ALERTA (alerts.log + journald) com os processos que mais
#  consomem o recurso. Quando o recurso volta ao normal registra RESOLVIDO.
#
#  Registros:
#    /var/log/citizentech/monitor.log  -> cada verificação
#    /var/log/citizentech/alerts.log   -> somente alertas e resoluções
#    /var/log/citizentech/metrics.csv  -> série histórica (planilha/gráfico)
#
#  Uso:
#    monitor.sh                 uma verificação com painel no terminal
#    monitor.sh --json          uma verificação em JSON
#    monitor.sh --daemon        execução contínua (usado pelo systemd)
#    monitor.sh --interval 5    altera o intervalo do modo daemon
#    CPU_WARN=10 monitor.sh     sobrescreve limites para testes
# =============================================================================
set -uo pipefail   # sem -e: o monitor nunca deve morrer por uma falha pontual
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CT_SCRIPT_NAME="monitor"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
CT_LOG_FILE="$CT_LOG_DIR/monitor.log"
ALERT_LOG="$CT_LOG_DIR/alerts.log"
METRICS_CSV="$CT_LOG_DIR/metrics.csv"

MODE="once"
OUTPUT="table"
CHECK_NO=0
STOP=0
CAN_WRITE=0
[[ -w "$CT_LOG_DIR" ]] && CAN_WRITE=1

usage() { sed -n '/^#  Uso:/,/^# =====/p' "$0" | sed 's/^# \{0,2\}//; /^=====/d'; }

while (( $# )); do
  case "$1" in
    --daemon)   MODE="daemon" ;;
    --once)     MODE="once" ;;
    --json)     OUTPUT="json" ;;
    --interval) MONITOR_INTERVAL="${2:?informe os segundos}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Opção inválida: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# ---- Validação da configuração ---------------------------------------------
validate_config() {
  local ok=1 n
  for n in CPU_WARN CPU_CRIT MEM_WARN MEM_CRIT DISK_WARN DISK_CRIT; do
    if ! [[ "${!n}" =~ ^[0-9]+$ ]] || (( ${!n} < 1 || ${!n} > 100 )); then
      log_error "Configuração inválida: $n='${!n}' (esperado inteiro entre 1 e 100)"; ok=0
    fi
  done
  if (( ok )); then
    for n in CPU MEM DISK; do
      local w="${n}_WARN" c="${n}_CRIT"
      if (( ${!w} >= ${!c} )); then log_error "Configuração inválida: $w (${!w}) deve ser menor que $c (${!c})"; ok=0; fi
    done
  fi
  if ! [[ "$MONITOR_INTERVAL" =~ ^[0-9]+$ ]] || (( MONITOR_INTERVAL < 1 )); then
    log_error "Configuração inválida: MONITOR_INTERVAL='$MONITOR_INTERVAL'"; ok=0
  fi
  (( ok )) || audit "monitor-config" "FAIL" "configuração inválida em $CT_CONF_FILE"
  (( ok ))
}

# ---- Coletores ---------------------------------------------------------------
read_cpu() {   # imprime: total idle
  local _cpu user nice system idle iowait irq softirq steal _rest
  read -r _cpu user nice system idle iowait irq softirq steal _rest </proc/stat
  echo "$((user + nice + system + idle + iowait + irq + softirq + steal)) $((idle + iowait))"
}

cpu_usage() {  # % de CPU ocupada no intervalo de amostragem
  local t1 i1 t2 i2 dt di
  read -r t1 i1 < <(read_cpu)
  sleep "$CPU_SAMPLE_SECONDS"
  read -r t2 i2 < <(read_cpu)
  dt=$((t2 - t1)); di=$((i2 - i1))
  (( dt > 0 )) || { echo 0; return; }
  echo $(( (100 * (dt - di) + dt / 2) / dt ))
}

read_mem() {   # imprime: pct_usado total_mb disponivel_mb swap_pct
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
       END { pct = (t > 0) ? int(((t - a) * 100 / t) + 0.5) : 0
             sp  = (st > 0) ? int(((st - sf) * 100 / st) + 0.5) : 0
             printf "%d %d %d %d\n", pct, t/1024, a/1024, sp }' /proc/meminfo
}

read_disk() {  # read_disk <mount> -> pct_usado tamanho_gb livre_gb
  df -P -k "$1" 2>/dev/null | awk 'NR==2 { gsub("%","",$5); printf "%d %.1f %.1f\n", $5, $2/1048576, $4/1048576 }'
}

app_status() {
  [[ -n "${CT_SVC_IP:-}" && -n "${APP_PORT:-}" ]] || { echo "N/A"; return; }
  if curl -fsS -o /dev/null -m 3 "http://$CT_SVC_IP:$APP_PORT${APP_HEALTH_PATH:-/}" 2>/dev/null; then
    echo "UP"
  else
    echo "DOWN"
  fi
}

top_procs() {  # top_procs cpu|mem -> 3 processos que mais consomem
  local sort="-%cpu" field="%cpu"
  [[ "$1" == "mem" ]] && { sort="-rss"; field="%mem"; }
  ps -eo pid=,comm=,"$field"= --sort="$sort" 2>/dev/null | awk '$2 != "ps"' | head -3 |
    awk '{ printf "%s%s(pid %s, %s%%)", (NR>1?", ":""), $2, $1, $3 }'
}

level() {  # level <valor> <aviso> <critico> -> OK | WARN | CRIT
  if   (( $1 >= $3 )); then echo "CRIT"
  elif (( $1 >= $2 )); then echo "WARN"
  else echo "OK"
  fi
}

worst() {  # maior severidade entre os argumentos
  local r="OK" l
  for l in "$@"; do
    [[ "$l" == "CRIT" ]] && { echo CRIT; return; }
    [[ "$l" == "WARN" ]] && r="WARN"
  done
  echo "$r"
}

# ---- Alertas -----------------------------------------------------------------
alert() {  # alert <recurso> <nível> <valor> <aviso> <crítico> <detalhe>
  local res="$1" lvl="$2" val="$3" warn="$4" crit="$5" detail="$6"
  local key state prev line ts
  key="$(echo "$res" | tr -c 'a-zA-Z0-9' '_')"
  state="$CT_STATE_DIR/alert_${key}"
  prev="$(cat "$state" 2>/dev/null || echo OK)"
  ts="$(_ct_ts)"
  if [[ "$lvl" != "OK" ]]; then
    line="$ts [$lvl] host=$(hostname) recurso=$res valor=${val} limite_aviso=${warn} limite_critico=${crit} detalhe=\"$detail\""
    _ct_append "$ALERT_LOG" "$line"
    _ct_journal "$([[ $lvl == CRIT ]] && echo crit || echo warning)" citizentech-alert \
      "ALERTA $lvl: $res em $val (limite $warn/$crit) - $detail"
    if [[ "$lvl" == "CRIT" ]]; then
      printf '%s[ALERTA CRITICO]%s %s = %s (limite crítico %s) %s\n' "$C_RED$C_BOLD" "$C_RESET" "$res" "$val" "$crit" "$detail" >&3
    else
      printf '%s[ALERTA AVISO]%s %s = %s (limite de aviso %s) %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$res" "$val" "$warn" "$detail" >&3
    fi
  elif [[ "$prev" != "OK" ]]; then
    line="$ts [RESOLVIDO] host=$(hostname) recurso=$res valor=${val} anterior=$prev"
    _ct_append "$ALERT_LOG" "$line"
    _ct_journal notice citizentech-alert "RESOLVIDO: $res voltou ao normal ($val)"
    printf '%s[RESOLVIDO]%s %s voltou ao normal (%s)\n' "$C_GREEN$C_BOLD" "$C_RESET" "$res" "$val" >&3
  fi
  (( CAN_WRITE )) && echo "$lvl" >"$state" 2>/dev/null
  return 0
}

# ---- Saídas ------------------------------------------------------------------
bar() {  # bar <pct> <nivel> -> barra colorida de 30 posições
  local pct="$1" lvl="$2" n color
  n=$(( pct * 30 / 100 )); (( n > 30 )) && n=30
  case "$lvl" in CRIT) color="$C_RED" ;; WARN) color="$C_YELLOW" ;; *) color="$C_GREEN" ;; esac
  printf '%s%s%s%s' "$color" "$(printf '%*s' "$n" '' | tr ' ' '#')" "$C_DIM$(printf '%*s' $((30 - n)) '' | tr ' ' '.')" "$C_RESET"
}

lvl_color() { case "$1" in CRIT) printf '%s' "$C_RED$C_BOLD" ;; WARN) printf '%s' "$C_YELLOW$C_BOLD" ;; DOWN) printf '%s' "$C_RED$C_BOLD" ;; *) printf '%s' "$C_GREEN" ;; esac; }

print_table() {
  printf '\n%s CitizenTech Monitor%s  host=%s  %s\n' "$C_BOLD$C_CYAN" "$C_RESET" "$(hostname)" "$(date '+%d/%m/%Y %H:%M:%S')"
  printf ' %-12s %6s  %-30s  %-12s %s\n' "RECURSO" "USO" "" "LIMITES" "STATUS"
  printf ' %-12s %5s%%  %s  %-12s %s%s%s   %s\n' "CPU" "$cpu" "$(bar "$cpu" "$cpu_l")" "$CPU_WARN/$CPU_CRIT%" "$(lvl_color "$cpu_l")" "$cpu_l" "$C_RESET" "load=$load1 (${ncpu} CPUs)"
  printf ' %s %5s%%  %s  %-12s %s%s%s   %s\n' "$(pad 'Memória RAM' 12)" "$mem" "$(bar "$mem" "$mem_l")" "$MEM_WARN/$MEM_CRIT%" "$(lvl_color "$mem_l")" "$mem_l" "$C_RESET" "livre=${mem_avail}MB de ${mem_total}MB, swap=${swap}%"
  local i
  for i in "${!disk_mounts[@]}"; do
    printf ' %-12s %5s%%  %s  %-12s %s%s%s   %s\n' "Disco ${disk_mounts[i]}" "${disk_pct[i]}" "$(bar "${disk_pct[i]}" "${disk_lvl[i]}")" "$DISK_WARN/$DISK_CRIT%" "$(lvl_color "${disk_lvl[i]}")" "${disk_lvl[i]}" "$C_RESET" "livre=${disk_free[i]}GB de ${disk_size[i]}GB"
  done
  printf ' %s %6s  %-30s  %-12s %s%s%s\n' "$(pad 'Aplicação' 12)" "" "http://$CT_SVC_IP:$APP_PORT$APP_HEALTH_PATH" "" "$(lvl_color "$app")" "$app" "$C_RESET"
  printf ' Status geral: %s%s%s\n\n' "$(lvl_color "$overall")" "$overall" "$C_RESET"
}

print_json() {
  local i disks=""
  for i in "${!disk_mounts[@]}"; do
    disks+="${disks:+,}{\"mount\":\"${disk_mounts[i]}\",\"pct\":${disk_pct[i]},\"size_gb\":${disk_size[i]},\"free_gb\":${disk_free[i]},\"status\":\"${disk_lvl[i]}\"}"
  done
  printf '{"timestamp":"%s","host":"%s","cpu":{"pct":%s,"load1":%s,"cpus":%s,"status":"%s"},"memory":{"pct":%s,"total_mb":%s,"available_mb":%s,"swap_pct":%s,"status":"%s"},"disks":[%s],"app":"%s","status":"%s"}\n' \
    "$(_ct_ts)" "$(hostname)" "$cpu" "$load1" "$ncpu" "$cpu_l" "$mem" "$mem_total" "$mem_avail" "$swap" "$mem_l" "$disks" "$app" "$overall"
}

# ---- Uma verificação -----------------------------------------------------------
run_check() {
  CHECK_NO=$((CHECK_NO + 1))
  cpu="$(cpu_usage)"
  read -r load1 _ </proc/loadavg
  ncpu="$(nproc)"
  read -r mem mem_total mem_avail swap < <(read_mem)

  disk_mounts=(); disk_pct=(); disk_size=(); disk_free=(); disk_lvl=()
  local m p s f
  for m in $DISK_MOUNTS; do
    read -r p s f < <(read_disk "$m") || continue
    [[ -n "${p:-}" ]] || { log_warn "Não foi possível ler o disco $m"; continue; }
    disk_mounts+=("$m"); disk_pct+=("$p"); disk_size+=("$s"); disk_free+=("$f")
    disk_lvl+=("$(level "$p" "$DISK_WARN" "$DISK_CRIT")")
  done

  cpu_l="$(level "$cpu" "$CPU_WARN" "$CPU_CRIT")"
  mem_l="$(level "$mem" "$MEM_WARN" "$MEM_CRIT")"
  app="$(app_status)"
  local app_l="OK"; [[ "$app" == "DOWN" ]] && app_l="CRIT"
  overall="$(worst "$cpu_l" "$mem_l" "${disk_lvl[@]}" "$app_l")"

  # Saída no terminal (modo interativo)
  if [[ "$MODE" == "once" ]]; then
    if [[ "$OUTPUT" == "json" ]]; then print_json; else print_table; fi
  fi

  # Alertas (antes do registro para aparecerem junto no terminal)
  alert "cpu"  "$cpu_l" "${cpu}%" "${CPU_WARN}%" "${CPU_CRIT}%" "load=$load1 top: $(top_procs cpu)"
  alert "memoria" "$mem_l" "${mem}%" "${MEM_WARN}%" "${MEM_CRIT}%" "disponivel=${mem_avail}MB top: $(top_procs mem)"
  local i
  for i in "${!disk_mounts[@]}"; do
    alert "disco:${disk_mounts[i]}" "${disk_lvl[i]}" "${disk_pct[i]}%" "${DISK_WARN}%" "${DISK_CRIT}%" "livre=${disk_free[i]}GB"
  done
  alert "aplicacao" "$app_l" "$app" "-" "DOWN" "health=http://$CT_SVC_IP:$APP_PORT$APP_HEALTH_PATH"

  # Registro da verificação
  local disks_txt=""
  for i in "${!disk_mounts[@]}"; do disks_txt+=" disco[${disk_mounts[i]}]=${disk_pct[i]}%"; done
  local msg="check=#$CHECK_NO status=$overall cpu=${cpu}% mem=${mem}% (${mem_avail}MB livres)${disks_txt} load=$load1 app=$app"
  local lvl_log=INFO; [[ "$overall" == "WARN" ]] && lvl_log=WARN; [[ "$overall" == "CRIT" ]] && lvl_log=ALERT
  _ct_append "$CT_LOG_FILE" "$(_ct_ts) [$lvl_log] [monitor] $msg"
  if [[ "$MODE" == "daemon" ]]; then
    echo "$msg"    # vai para o journal (journalctl -u citizentech-monitor)
  fi

  # Série histórica CSV
  if (( CAN_WRITE )); then
    if [[ ! -s "$METRICS_CSV" ]]; then
      _ct_append "$METRICS_CSV" "timestamp,host,cpu_pct,load1,mem_pct,mem_disponivel_mb,swap_pct,disco_raiz_pct,app,status"
    fi
    _ct_append "$METRICS_CSV" "$(_ct_ts),$(hostname),$cpu,$load1,$mem,$mem_avail,$swap,${disk_pct[0]:-},$app,$overall"
    touch "$CT_STATE_DIR/monitor.heartbeat" 2>/dev/null   # usado pelo watchdog
  fi
  return 0
}

# ---- Detecção de reinicialização ------------------------------------------------
detect_boot() {
  local boot_key saved started
  started="$(ps -o lstart= -p 1 2>/dev/null | xargs)"
  # chave estável: boot_id do kernel + instante de início do PID 1 em ticks (campo 22 de /proc/1/stat)
  boot_key="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)|$(awk '{print $22}' /proc/1/stat 2>/dev/null)"
  saved="$(cat "$CT_STATE_DIR/boot_key" 2>/dev/null || true)"
  if [[ "$boot_key" != "$saved" ]]; then
    log_info "BOOT: nova inicialização do sistema detectada (systemd iniciado em: $started) - monitor iniciado automaticamente"
    audit "boot-detectado" "OK" "inicio_sistema=$started"
    echo "$boot_key" >"$CT_STATE_DIR/boot_key" 2>/dev/null
  fi
  return 0
}

# ---- Modo serviço ---------------------------------------------------------------
daemon_loop() {
  trap 'STOP=1' TERM INT
  log_info "Monitor iniciado em modo serviço (pid=$$, intervalo=${MONITOR_INTERVAL}s, limites CPU=${CPU_WARN}/${CPU_CRIT}% MEM=${MEM_WARN}/${MEM_CRIT}% DISCO=${DISK_WARN}/${DISK_CRIT}%)"
  audit "monitor-inicio" "OK" "pid=$$ intervalo=${MONITOR_INTERVAL}s"
  detect_boot
  while (( ! STOP )); do
    run_check || log_error "Verificação #$CHECK_NO falhou - o monitor continua em execução"
    (( STOP )) && break
    sleep "$MONITOR_INTERVAL" &
    wait $! 2>/dev/null || true
  done
  log_info "Monitor encerrado por sinal (verificações realizadas: $CHECK_NO)"
  audit "monitor-fim" "OK" "verificacoes=$CHECK_NO"
  exit 0
}

# ---- Principal ------------------------------------------------------------------
if ! validate_config; then
  exit 2
fi
if (( ! CAN_WRITE )); then
  echo "${C_YELLOW}[aviso] sem permissão de escrita em $CT_LOG_DIR - executando só leitura (use sudo para registrar)${C_RESET}" >&2
fi

if [[ "$MODE" == "daemon" ]]; then
  daemon_loop
else
  run_check
  [[ "$overall" == "OK" ]] && exit 0
  [[ "$overall" == "WARN" ]] && exit 1
  exit 2
fi
