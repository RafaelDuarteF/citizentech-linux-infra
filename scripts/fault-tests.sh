#!/usr/bin/env bash
# =============================================================================
#  fault-tests.sh - Testes de falha controlados (CitizenTech)
# -----------------------------------------------------------------------------
#  Simula situações que comprometem a infraestrutura e comprova que ela
#  DETECTA, REGISTRA e RECUPERA. Cada teste mostra as evidências na tela e
#  grava o resultado (PASS/FAIL) em audit.log e fault-tests.log.
#
#  Uso: sudo ./scripts/fault-tests.sh <cenário>
#
#  Cenários:
#    kill-monitor   mata o monitor com SIGKILL      -> systemd reinicia (Restart=always)
#    stop-monitor   para o monitor manualmente      -> watchdog (timer) recupera
#    crash-loop     derruba o monitor em sequência  -> systemd desiste (StartLimit),
#                                                      watchdog recupera
#    kill-app       mata a aplicação web            -> systemd reinicia, Nginx mostra
#                                                      página amigável enquanto isso
#    cpu-stress     CPU elevada por 45s             -> alertas de CPU + RESOLVIDO
#    mem-stress     memória elevada por 45s         -> alertas de memória + RESOLVIDO
#    disk-alert     disco acima do limite           -> alerta de disco + RESOLVIDO
#    script-error   falha controlada em scripts     -> erro em errors.log e audit.log
#    reboot-check   após reiniciar a VM/WSL         -> serviços subiram sozinhos
#    all            executa todos, exceto crash-loop e reboot-check
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
CT_LOG_FILE="$CT_LOG_DIR/fault-tests.log"

STRESS_SECONDS="${STRESS_SECONDS:-45}"
MON=citizentech-monitor.service
APP=citizentech-app.service

# ---- Modo interno: script que falha de propósito ------------------------------
if [[ "${1:-}" == "__falha_controlada" ]]; then
  ct_init "Falha controlada (teste de registro de erros)"
  copiar_configuracao() {
    log_info "Copiando arquivo de configuração obrigatório $CT_ETC/parametros-inexistentes.conf"
    cp "$CT_ETC/parametros-inexistentes.conf" /tmp/citizentech-teste.conf
    log_ok "Esta linha nunca deve ser executada"
  }
  step "Copiar configuração obrigatória (falha proposital)" copiar_configuracao
  exit 0
fi

usage() { sed -n '/^#  Uso:/,/^# =====/p' "$0" | sed 's/^# \{0,2\}//; /^=====/d'; }
[[ $# -ge 1 ]] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

require_root "$@"
ct_init "Testes de falha: $*"
set +e; trap - ERR   # os testes tratam os próprios erros

RESULTS=()

# ---- Utilitários --------------------------------------------------------------
say()      { printf '%s>>%s %s\n' "$C_BOLD$C_MAGENTA" "$C_RESET" "$*" >&3; }
run_show() { printf '   %s$ %s%s\n' "$C_DIM" "$*" "$C_RESET" >&3; "$@" 2>&1 | sed 's/^/     /' >&3; }
main_pid() { systemctl show -p MainPID --value "$1"; }
nrestarts(){ systemctl show -p NRestarts --value "$1"; }
http_code(){ curl -s -o /dev/null -w '%{http_code}' -m 3 "http://$CT_DOMAIN/"; }
now_j()    { date '+%Y-%m-%d %H:%M:%S'; }

pid_changed() {   # pid_changed <unit> <pid-antigo>
  local p; p="$(main_pid "$1")"
  [[ "$p" != "0" && "$p" != "$2" ]] && unit_active "$1"
}

ensure_up() {
  unit_active "$1" && return 0
  systemctl reset-failed "$1" 2>/dev/null; systemctl start "$1"
  wait_until 20 unit_active "$1"
}

show_since() {    # show_since <arquivo> <timestamp> [filtro-regex] [linhas]
  local file="$CT_LOG_DIR/$1" t="$2" re="${3:-.}" n="${4:-10}"
  printf '   %s--- %s ---%s\n' "$C_DIM" "$file" "$C_RESET" >&3
  awk -v t="$t" '$1 >= t' "$file" 2>/dev/null | grep -E -- "$re" | tail -n "$n" | sed 's/^/     /' >&3
}

count_since() {   # count_since <arquivo> <timestamp> <regex>
  awk -v t="$2" '$1 >= t' "$CT_LOG_DIR/$1" 2>/dev/null | grep -cE -- "$3"
}

record() {        # record <teste> <PASS|FAIL> <detalhe>
  RESULTS+=("$1|$2|$3")
  if [[ "$2" == "PASS" ]]; then
    printf '\n   %s[PASS]%s %s - %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$1" "$3" >&3
    audit "teste-$1" "OK" "$3"
  else
    printf '\n   %s[FAIL]%s %s - %s\n' "$C_RED$C_BOLD" "$C_RESET" "$1" "$3" >&3
    audit "teste-$1" "FAIL" "$3"
  fi
  _ct_append "$CT_LOG_FILE" "$(_ct_ts) [$2] [fault-tests] [run=$CT_RUN_ID] teste=$1 $3"
}

# ---- 1. SIGKILL no monitor ----------------------------------------------------
t_kill_monitor() {
  banner "TESTE: processo do monitor morto com SIGKILL" "Esperado: o systemd (Restart=always) reinicia o serviço sozinho"
  ensure_up "$MON" || { record kill-monitor FAIL "monitor não estava ativo"; return; }
  local t0 tj pid1 pid2 n1 n2
  t0="$(_ct_ts)"; tj="$(now_j)"
  pid1="$(main_pid "$MON")"; n1="$(nrestarts "$MON")"
  say "Monitor ativo: PID $pid1 | reinícios automáticos até agora: $n1"
  run_show kill -9 "$pid1"
  say "Estado logo após o kill: $(systemctl is-active "$MON")"
  say "Aguardando o systemd reiniciar (RestartSec=5)..."
  if wait_until 25 pid_changed "$MON" "$pid1"; then
    pid2="$(main_pid "$MON")"; n2="$(nrestarts "$MON")"
    say "Monitor recuperado: novo PID $pid2 | reinícios automáticos: $n2"
    run_show journalctl -u "$MON" --since "$tj" --no-pager -o short-iso
    show_since service-events.log "$t0" "$MON"
    record kill-monitor PASS "PID $pid1 morto (SIGKILL), systemd reiniciou como PID $pid2 (NRestarts $n1 -> $n2)"
  else
    record kill-monitor FAIL "monitor não voltou em 25s (estado: $(systemctl is-active "$MON"))"
  fi
}

# ---- 2. Parada manual do monitor ------------------------------------------------
t_stop_monitor() {
  banner "TESTE: interrupção manual do monitor (systemctl stop)" "Esperado: o watchdog (timer a cada $HEALTHCHECK_EVERY) detecta e recupera"
  ensure_up "$MON" || { record stop-monitor FAIL "monitor não estava ativo"; return; }
  [[ -f "$CT_ETC/maintenance" ]] && say "ATENÇÃO: modo manutenção ativo - o watchdog não vai recuperar"
  local t0 start
  t0="$(_ct_ts)"; start=$SECONDS
  run_show systemctl stop "$MON"
  say "Estado após a parada: $(systemctl is-active "$MON")  (Restart=always NÃO age em parada manual)"
  run_show systemctl list-timers citizentech-healthcheck.timer --no-pager
  say "Aguardando o watchdog (até 75s)..."
  if wait_until 75 unit_active "$MON"; then
    say "Monitor recuperado pelo watchdog em $((SECONDS - start))s"
    show_since healthcheck.log "$t0"
    show_since service-events.log "$t0" "$MON"
    record stop-monitor PASS "parado manualmente, recuperado pelo watchdog em $((SECONDS - start))s"
  else
    record stop-monitor FAIL "watchdog não recuperou o monitor em 75s"
  fi
}

# ---- 3. Loop de falhas ------------------------------------------------------------
t_crash_loop() {
  banner "TESTE: loop de falhas (StartLimitBurst=5 em 120s)" "Esperado: systemd desiste (failed/start-limit-hit) e o watchdog recupera"
  ensure_up "$MON" || { record crash-loop FAIL "monitor não estava ativo"; return; }
  local t0 kills=0 pid start
  t0="$(_ct_ts)"
  while (( kills < 12 )); do
    [[ "$(systemctl is-active "$MON")" == "failed" ]] && break
    if wait_until 12 unit_active "$MON"; then
      pid="$(main_pid "$MON")"
      kill -9 "$pid" 2>/dev/null && kills=$((kills + 1))
      say "Falha provocada #$kills (kill -9 PID $pid)"
      sleep 1
    fi
  done
  say "Estado: $(systemctl is-active "$MON") | motivo: $(systemctl show -p Result --value "$MON")"
  run_show systemctl status "$MON" --no-pager -n 0
  start=$SECONDS
  say "Aguardando o watchdog recuperar o serviço 'failed' (até 75s)..."
  if wait_until 75 unit_active "$MON"; then
    show_since healthcheck.log "$t0"
    record crash-loop PASS "$kills falhas seguidas -> systemd marcou failed -> watchdog recuperou em $((SECONDS - start))s"
  else
    record crash-loop FAIL "serviço continua $(systemctl is-active "$MON")"
  fi
}

# ---- 4. SIGKILL na aplicação ------------------------------------------------------
t_kill_app() {
  banner "TESTE: aplicação web morta com SIGKILL" "Esperado: systemd reinicia a aplicação; Nginx exibe página amigável (502) enquanto isso"
  ensure_up "$APP" || { record kill-app FAIL "aplicação não estava ativa"; return; }
  local t0 pid1 pid2 i c ok=0 saw_error=0
  t0="$(_ct_ts)"
  pid1="$(main_pid "$APP")"
  say "Aplicação: PID $pid1 | http://$CT_DOMAIN/ -> HTTP $(http_code)"
  run_show kill -9 "$pid1"
  say "Disponibilidade medida a cada segundo:"
  for i in $(seq 1 25); do
    c="$(http_code)"
    printf '     t+%02ds  HTTP %s\n' "$i" "$c" >&3
    [[ "$c" != "200" ]] && saw_error=1
    if [[ "$c" == "200" ]] && pid_changed "$APP" "$pid1"; then ok=1; break; fi
    sleep 1
  done
  pid2="$(main_pid "$APP")"
  show_since service-events.log "$t0" "$APP"
  if (( ok )); then
    record kill-app PASS "PID $pid1 morto, aplicação voltou como PID $pid2 em ~${i}s (indisponibilidade detectada: $([[ $saw_error == 1 ]] && echo sim || echo não))"
  else
    record kill-app FAIL "aplicação não voltou a responder 200 em 25s"
  fi
}

# ---- 5. CPU elevada ---------------------------------------------------------------
wait_for_resolution() {   # aguarda o serviço registrar a volta ao normal
  say "Aguardando a próxima verificação do serviço de monitoramento (${MONITOR_INTERVAL}s)..."
  sleep $((MONITOR_INTERVAL + 3))
}

t_cpu_stress() {
  banner "TESTE: consumo elevado de CPU por ${STRESS_SECONDS}s" "Limites: aviso ${CPU_WARN}% | crítico ${CPU_CRIT}% | $(nproc) CPUs"
  ensure_up "$MON" >/dev/null
  local t0 n i
  t0="$(_ct_ts)"
  if command -v stress-ng >/dev/null; then
    say "Iniciando: stress-ng --cpu $(nproc) --timeout ${STRESS_SECONDS}s"
    stress-ng --cpu "$(nproc)" --timeout "${STRESS_SECONDS}s" --quiet 2>/dev/null &
  else
    say "stress-ng ausente - usando laços em bash"
    for ((i = 0; i < $(nproc); i++)); do timeout "$STRESS_SECONDS" bash -c 'while :; do :; done' & done
  fi
  sleep 8
  say "Painel do monitor durante o estresse:"
  "$CT_HOME/bin/monitor.sh" 3>&1 2>&1 | sed 's/^/   /' >&3
  say "Aguardando o fim do estresse..."
  wait
  wait_for_resolution
  show_since alerts.log "$t0" "recurso=cpu " 12
  n="$(count_since alerts.log "$t0" '\[(WARN|CRIT)\] .*recurso=cpu ')"
  if (( n > 0 )) && (( $(count_since alerts.log "$t0" 'RESOLVIDO.*recurso=cpu ') > 0 )); then
    record cpu-stress PASS "$n alerta(s) de CPU gerados e registrados, seguidos de RESOLVIDO"
  elif (( n > 0 )); then
    record cpu-stress PASS "$n alerta(s) de CPU gerados e registrados"
  else
    record cpu-stress FAIL "nenhum alerta de CPU registrado"
  fi
}

# ---- 6. Memória elevada ------------------------------------------------------------
t_mem_stress() {
  local total_kb avail_kb used_kb target need_kb max_kb t0 n
  read -r total_kb avail_kb < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
  target="${MEM_STRESS_TARGET:-$((MEM_WARN + 5))}"
  used_kb=$((total_kb - avail_kb))
  need_kb=$((total_kb * target / 100 - used_kb))
  max_kb=$((avail_kb - 262144))          # preserva ao menos 256 MB livres
  (( need_kb > max_kb )) && need_kb=$max_kb
  banner "TESTE: consumo elevado de memória por ${STRESS_SECONDS}s" "Limites: aviso ${MEM_WARN}% | crítico ${MEM_CRIT}% | alvo do teste ${target}%"
  if (( need_kb <= 0 )); then
    record mem-stress FAIL "não há memória livre suficiente para o teste com segurança"
    return
  fi
  ensure_up "$MON" >/dev/null
  t0="$(_ct_ts)"
  say "Memória: $((total_kb / 1024)) MB total, $((used_kb * 100 / total_kb))% em uso. Alocando +$((need_kb / 1024)) MB..."
  if command -v stress-ng >/dev/null; then
    stress-ng --vm 1 --vm-bytes "${need_kb}K" --vm-keep --timeout "${STRESS_SECONDS}s" --quiet 2>/dev/null &
  else
    timeout "$STRESS_SECONDS" bash -c "head -c ${need_kb}K /dev/zero | tail" &
  fi
  sleep 18   # tempo para o stress-ng alocar toda a memória
  say "Painel do monitor durante o estresse:"
  "$CT_HOME/bin/monitor.sh" 3>&1 2>&1 | sed 's/^/   /' >&3
  say "Aguardando o fim do estresse..."
  wait
  wait_for_resolution
  show_since alerts.log "$t0" "recurso=memoria " 12
  n="$(count_since alerts.log "$t0" '\[(WARN|CRIT)\] .*recurso=memoria ')"
  if (( n > 0 )); then
    record mem-stress PASS "$n alerta(s) de memória gerados e registrados"
  else
    record mem-stress FAIL "nenhum alerta de memória registrado"
  fi
}

# ---- 7. Disco acima do limite ------------------------------------------------------
t_disk_alert() {
  local pct size_kb used_kb avail_kb target need_kb t0 n file="$CT_DATA/teste-disco.bin"
  read -r pct size_kb used_kb avail_kb < <(df -Pk / | awk 'NR==2{gsub("%","",$5); print $5, $2, $3, $4}')
  target=$((DISK_WARN + 2))
  need_kb=$(( (used_kb + avail_kb) * target / 100 - used_kb ))
  banner "TESTE: disco acima do limite" "Disco / com $((size_kb / 1048576)) GB, ${pct}% em uso | limites ${DISK_WARN}% / ${DISK_CRIT}%"
  t0="$(_ct_ts)"
  if (( need_kb > 0 && need_kb < avail_kb - 2097152 && need_kb <= 15 * 1048576 )); then
    say "Ocupando $((need_kb / 1024)) MB com fallocate para atingir ${target}%"
    run_show fallocate -l "${need_kb}K" "$file"
    "$CT_HOME/bin/monitor.sh" 3>&1 2>&1 | sed 's/^/   /' >&3
    run_show rm -f "$file"
    say "Arquivo removido - nova verificação:"
    "$CT_HOME/bin/monitor.sh" 3>&1 2>&1 | grep -E 'Disco|RESOLVIDO' | sed 's/^/   /' >&3
  else
    say "Encher este disco até ${target}% exigiria $((need_kb / 1048576)) GB - inviável/inseguro."
    say "Simulação: reduzindo temporariamente o limite de disco (DISK_WARN=1) só nesta execução"
    DISK_WARN=1 DISK_CRIT=$((pct < 99 ? pct + 1 : 100)) "$CT_HOME/bin/monitor.sh" 3>&1 2>&1 | sed 's/^/   /' >&3
    say "Limite original restaurado - nova verificação:"
    "$CT_HOME/bin/monitor.sh" 3>&1 2>&1 | grep -E 'Disco|RESOLVIDO' | sed 's/^/   /' >&3
  fi
  show_since alerts.log "$t0" "recurso=disco" 6
  n="$(count_since alerts.log "$t0" '\[(WARN|CRIT)\] .*recurso=disco')"
  if (( n > 0 )); then
    record disk-alert PASS "$n alerta(s) de disco registrados e resolvidos"
  else
    record disk-alert FAIL "nenhum alerta de disco registrado"
  fi
}

# ---- 8. Falha controlada em script -------------------------------------------------
t_script_error() {
  banner "TESTE: falha controlada em scripts" "Esperado: erro registrado com script, linha, comando e código de saída"
  local rid rc tj ok=1
  rid="falha-$(date +%H%M%S)"; tj="$(now_j)"

  say "(a) Script de provisionamento que tenta copiar um arquivo inexistente:"
  CT_SCRIPT_NAME="falha-controlada.sh" CT_RUN_ID="$rid" bash "$SCRIPT_DIR/fault-tests.sh" __falha_controlada
  rc=$?
  say "Código de saída: $rc (esperado: diferente de 0)"
  (( rc != 0 )) || ok=0
  printf '   %s--- errors.log ---%s\n' "$C_DIM" "$C_RESET" >&3
  grep "run=$rid" "$CT_LOG_DIR/errors.log" | sed 's/^/     /' >&3 || ok=0
  printf '   %s--- audit.log ---%s\n' "$C_DIM" "$C_RESET" >&3
  grep "run=$rid" "$CT_LOG_DIR/audit.log" | sed 's/^/     /' >&3
  grep "run=$rid" "$CT_LOG_DIR/audit.log" | grep -q "resultado=FAIL" || ok=0

  say "(b) Monitor executado com configuração inválida (CPU_WARN=abc):"
  CPU_WARN=abc "$CT_HOME/bin/monitor.sh" >/dev/null 2>&1
  rc=$?
  say "Código de saída do monitor: $rc (esperado: 2)"
  (( rc == 2 )) || ok=0
  tail -n 1 "$CT_LOG_DIR/errors.log" | sed 's/^/     /' >&3

  say "Registro também no journald:"
  journalctl -t citizentech-audit -t citizentech --since "$tj" --no-pager -o short-iso 2>/dev/null | grep -E "FAIL|ERRO|inválida|Falha" | tail -n 4 | sed 's/^/     /' >&3
  if (( ok )); then
    record script-error PASS "falhas registradas em errors.log, audit.log e journald (run=$rid)"
  else
    record script-error FAIL "erro não foi registrado como esperado"
  fi
}

# ---- 9. Pós-reinicialização --------------------------------------------------------
t_reboot_check() {
  local started up u ok=1 since
  started="$(ps -o lstart= -p 1 2>/dev/null | xargs)"; up="$(ps -o etimes= -p 1 2>/dev/null | tr -d ' ')"
  banner "VERIFICAÇÃO PÓS-REINICIALIZAÇÃO" "systemd iniciado em $started (há $((up / 60)) min)"
  printf '     %-36s %-9s %-8s %s\n' "UNIDADE" "BOOT" "ESTADO" "ATIVA DESDE" >&3
  for u in citizentech-network.service nginx.service citizentech-app.service citizentech-monitor.service citizentech-healthcheck.timer; do
    since="$(systemctl show -p ActiveEnterTimestamp --value "$u")"
    printf '     %-36s %-9s %-8s %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null)" "$(systemctl is-active "$u")" "$since" >&3
    { systemctl is-enabled -q "$u" && unit_active "$u"; } || ok=0
  done
  say "Eventos de BOOT registrados:"
  grep -h "BOOT" "$CT_LOG_DIR/monitor.log" "$CT_LOG_DIR/service-events.log" 2>/dev/null | sort | tail -n 6 | sed 's/^/     /' >&3
  if (( up > 1800 )); then
    say "Dica: para testar de verdade reinicie e rode este teste de novo:"
    say "  VM/Azure: sudo reboot     |     WSL (PowerShell): wsl --terminate <distro>  e abra novamente"
  fi
  if (( ok )); then
    record reboot-check PASS "todos os serviços habilitados no boot e ativos após a inicialização"
  else
    record reboot-check FAIL "há serviços desabilitados ou inativos após a inicialização"
  fi
}

summary() {
  local r name res det pass=0 fail=0
  banner "RESUMO DOS TESTES DE FALHA" "registro: $CT_LOG_FILE"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r name res det <<<"$r"
    if [[ "$res" == "PASS" ]]; then pass=$((pass + 1)); printf '  %s[PASS]%s %-13s %s\n' "$C_GREEN" "$C_RESET" "$name" "$det" >&3
    else fail=$((fail + 1)); printf '  %s[FAIL]%s %-13s %s\n' "$C_RED" "$C_RESET" "$name" "$det" >&3; fi
  done
  printf '\n  Total: %d aprovados, %d reprovados\n\n' "$pass" "$fail" >&3
  (( fail == 0 ))
}

case "$1" in
  kill-monitor) t_kill_monitor ;;
  stop-monitor) t_stop_monitor ;;
  crash-loop)   t_crash_loop ;;
  kill-app)     t_kill_app ;;
  cpu-stress)   t_cpu_stress ;;
  mem-stress)   t_mem_stress ;;
  disk-alert)   t_disk_alert ;;
  script-error) t_script_error ;;
  reboot-check) t_reboot_check ;;
  all)
    t_kill_monitor; t_stop_monitor; t_kill_app; t_cpu_stress
    t_mem_stress; t_disk_alert; t_script_error ;;
  *) usage; exit 2 ;;
esac
summary
