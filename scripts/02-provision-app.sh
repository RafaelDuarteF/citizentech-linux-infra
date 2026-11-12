#!/usr/bin/env bash
# shellcheck disable=SC2034  # variáveis lidas pela lib/common.sh e pelos templates
# =============================================================================
#  02-provision-app.sh - Provisionamento da APLICAÇÃO Web CitizenTech
# -----------------------------------------------------------------------------
#  O que este script faz (idempotente):
#    1. Verifica se a infraestrutura (01) foi provisionada
#    2. Instala o runtime da aplicação (python | node | dotnet) e o Nginx
#    3. Publica o código (pasta app/ do repositório ou repositório git)
#    4. Gera as variáveis de ambiente (/etc/citizentech/app.env)
#    5. Instala as dependências / compila a aplicação
#    6. Define dono e permissões de arquivos e diretórios
#    7. Cria o serviço systemd da aplicação (início automático no boot)
#    8. Configura o Nginx como proxy reverso
#    9. Inicia tudo e executa testes de fumaça (HTTP)
#
#  Uso: sudo ./scripts/02-provision-app.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
CT_STEP_TOTAL=9
ct_init "Provisionamento da aplicação (runtime=$APP_RUNTIME origem=$APP_SOURCE)"

APP_DIR="$CT_HOME/app"
VENV_DIR="$CT_HOME/venv"
APP_WORKDIR="$APP_DIR"
APP_EXEC=""
DOTNET_DLL=""

# -----------------------------------------------------------------------------
check_infra() {
  local missing=0
  id "$CT_APP_USER" &>/dev/null            || { log_error "Usuário $CT_APP_USER não existe"; missing=1; }
  [[ -d "$CT_ETC" && -d "$CT_LOG_DIR" ]]   || { log_error "Diretórios do projeto não existem"; missing=1; }
  unit_active citizentech-network.service  || { log_error "citizentech-network.service inativo"; missing=1; }
  if (( missing )); then
    log_error "Execute primeiro: sudo ./scripts/01-provision-infra.sh"
    return 1
  fi
  log_ok "Infraestrutura base encontrada (usuário, diretórios e rede de serviço)"
  log_info "Aplicação: $APP_NAME | runtime: $APP_RUNTIME | origem: $APP_SOURCE"
}

# -----------------------------------------------------------------------------
install_runtime_deps() {
  case "$APP_RUNTIME" in
    python) apt_install python3 python3-venv python3-pip sqlite3 ;;
    node)   apt_install nodejs npm ;;
    dotnet) apt_install dotnet-sdk-8.0 ;;
    *)      log_error "APP_RUNTIME inválido: '$APP_RUNTIME' (use python, node ou dotnet)"; return 1 ;;
  esac
  apt_install nginx
  case "$APP_RUNTIME" in
    python) log_info "Versão: $(python3 --version 2>&1)" ;;
    node)   log_info "Versão: node $(node --version 2>&1), npm $(npm --version 2>&1)" ;;
    dotnet) log_info "Versão: dotnet $(dotnet --version 2>&1)" ;;
  esac
  log_info "Versão: $(nginx -v 2>&1)"
}

# -----------------------------------------------------------------------------
deploy_code() {
  local src detail
  if [[ "$APP_SOURCE" == "git" ]]; then
    [[ -n "$APP_GIT_URL" ]] || { log_error "APP_SOURCE=git, mas APP_GIT_URL está vazio"; return 1; }
    if [[ -d "$CT_HOME/src/.git" ]]; then
      log_info "Atualizando repositório $APP_GIT_URL ($APP_GIT_BRANCH)"
      quiet git -C "$CT_HOME/src" fetch --depth 1 origin "$APP_GIT_BRANCH"
      quiet git -C "$CT_HOME/src" reset --hard FETCH_HEAD
    else
      log_info "Clonando $APP_GIT_URL ($APP_GIT_BRANCH)"
      rm -rf "$CT_HOME/src"
      quiet git clone --depth 1 --branch "$APP_GIT_BRANCH" "$APP_GIT_URL" "$CT_HOME/src"
    fi
    src="$CT_HOME/src/${APP_SUBDIR}"
    detail="git=$APP_GIT_URL commit=$(git -C "$CT_HOME/src" log -1 --format=%h)"
  else
    src="$CT_REPO_DIR/app"
    detail="local=$src"
  fi
  [[ -d "$src" ]] || { log_error "Código da aplicação não encontrado em $src"; return 1; }

  quiet rsync -a --delete \
    --exclude '.git' --exclude '__pycache__' --exclude '*.db' --exclude '*.db-*' \
    --exclude 'node_modules' --exclude 'bin/' --exclude 'obj/' --exclude 'publish/' \
    "$src/" "$APP_DIR/"
  cat >"$APP_DIR/.deploy-info" <<EOF
data=$(_ct_ts)
origem=$APP_SOURCE
$detail
executado_por=${SUDO_USER:-root}
EOF
  log_ok "Código publicado em $APP_DIR ($(find "$APP_DIR" -type f | wc -l) arquivos)"
  audit "deploy" "OK" "$detail destino=$APP_DIR"
}

# -----------------------------------------------------------------------------
write_env_file() {
  local env_file="$CT_ETC/app.env" secret="" tmp kv
  if [[ -f "$env_file" ]]; then
    secret="$(grep -E '^SECRET_KEY=' "$env_file" | head -1 | cut -d= -f2- || true)"
  fi
  if [[ -z "$secret" ]]; then
    secret="$(openssl rand -hex 32)"
    log_info "SECRET_KEY gerada aleatoriamente (openssl rand)"
  else
    log_info "SECRET_KEY existente preservada"
  fi
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# CitizenTech - variáveis de ambiente da aplicação
# Gerado por 02-provision-app.sh em $(_ct_ts). Contém segredo: permissão 600 (root).
APP_NAME=$APP_NAME
APP_ENV=$APP_ENV
APP_HOST=$CT_SVC_IP
APP_PORT=$APP_PORT
HOST=$CT_SVC_IP
PORT=$APP_PORT
DATABASE_PATH=$CT_DATA/db/citizentech.db
LOG_DIR=$CT_LOG_DIR/app
SECRET_KEY=$secret
TZ=$CT_TIMEZONE
HOME=$CT_DATA/home
PYTHONUNBUFFERED=1
NODE_ENV=production
ASPNETCORE_URLS=http://$CT_SVC_IP:$APP_PORT
ASPNETCORE_ENVIRONMENT=Production
DOTNET_CLI_TELEMETRY_OPTOUT=1
DOTNET_NOLOGO=1
EOF
  for kv in ${APP_EXTRA_ENV[@]+"${APP_EXTRA_ENV[@]}"}; do
    printf '%s\n' "$kv" >>"$tmp"
  done
  install -m 0600 -o root -g root "$tmp" "$env_file"
  rm -f "$tmp"
  log_ok "Variáveis de ambiente em $env_file (600 root:root):"
  grep -vE '^#' "$env_file" | sed -E 's/^(SECRET_KEY=).*/\1********/' | sed 's/^/        /' >&3
  audit "variaveis-ambiente" "OK" "arquivo=$env_file vars=$(grep -cvE '^#' "$env_file")"
}

# -----------------------------------------------------------------------------
build_app() {
  case "$APP_RUNTIME" in
    python)
      if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        quiet python3 -m venv "$VENV_DIR"
        log_ok "Ambiente virtual Python criado em $VENV_DIR"
      fi
      quiet "$VENV_DIR/bin/pip" install --disable-pip-version-check --upgrade pip
      if [[ -f "$APP_DIR/requirements.txt" ]]; then
        quiet "$VENV_DIR/bin/pip" install --disable-pip-version-check -r "$APP_DIR/requirements.txt"
      fi
      "$VENV_DIR/bin/pip" show gunicorn >/dev/null 2>&1 || quiet "$VENV_DIR/bin/pip" install gunicorn
      log_ok "Dependências Python instaladas:"
      "$VENV_DIR/bin/pip" freeze --disable-pip-version-check | sed 's/^/        /' >&3
      audit "dependencias-app" "OK" "pip: $("$VENV_DIR/bin/pip" freeze | tr '\n' ' ')"
      APP_EXEC="$VENV_DIR/bin/gunicorn --workers 2 --bind $CT_SVC_IP:$APP_PORT --timeout 30 --access-logfile $CT_LOG_DIR/app/access.log --error-logfile - --capture-output $APP_WSGI"
      ;;
    node)
      if [[ -f "$APP_DIR/package-lock.json" ]]; then
        quiet bash -c "cd '$APP_DIR' && npm ci --omit=dev"
      else
        quiet bash -c "cd '$APP_DIR' && npm install --omit=dev"
      fi
      quiet bash -c "cd '$APP_DIR' && npm run build --if-present"
      log_ok "Dependências Node instaladas"
      APP_EXEC="/usr/bin/npm start"
      ;;
    dotnet)
      local proj="${APP_DOTNET_PROJECT:-}" name
      [[ -z "$proj" ]] || proj="$APP_DIR/$proj"
      [[ -n "$proj" ]] || proj="$(find "$APP_DIR" -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' -not -iname '*test*' | head -1)"
      [[ -f "$proj" ]] || { log_error "Nenhum projeto .csproj encontrado em $APP_DIR"; return 1; }
      log_info "Compilando $proj (dotnet publish -c Release)"
      quiet env HOME=/root DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
        dotnet publish "$proj" -c Release -o "$APP_DIR/publish"
      name="$(sed -n 's:.*<AssemblyName>\(.*\)</AssemblyName>.*:\1:p' "$proj" | head -1)"
      [[ -n "$name" ]] || name="$(basename "$proj" .csproj)"
      DOTNET_DLL="$APP_DIR/publish/$name.dll"
      [[ -f "$DOTNET_DLL" ]] || { log_error "Artefato não encontrado: $DOTNET_DLL"; return 1; }
      APP_WORKDIR="$APP_DIR/publish"
      APP_EXEC="/usr/bin/dotnet $DOTNET_DLL"
      log_ok "Aplicação .NET publicada: $DOTNET_DLL"
      ;;
  esac
  [[ -n "$APP_START_CMD" ]] && APP_EXEC="$APP_START_CMD"
  log_info "Comando de execução: $APP_EXEC"
}

# -----------------------------------------------------------------------------
set_permissions() {
  # Código: root é dono (a aplicação NÃO pode alterar o próprio código);
  # o grupo da aplicação só lê. Outros usuários não têm acesso.
  chown -R root:"$CT_APP_USER" "$APP_DIR"
  chmod -R u=rwX,g=rX,o= "$APP_DIR"
  if [[ -d "$VENV_DIR" ]]; then
    chown -R root:"$CT_APP_USER" "$VENV_DIR"
    chmod -R u=rwX,g=rX,o= "$VENV_DIR"
    chmod 0755 "$VENV_DIR"
  fi
  # Dados: somente o usuário da aplicação escreve
  chown -R "$CT_APP_USER:$CT_APP_USER" "$CT_DATA/db" "$CT_DATA/home"
  chmod 0750 "$CT_DATA/db" "$CT_DATA/home"
  chown "$CT_APP_USER:$CT_OPS_GROUP" "$CT_LOG_DIR/app"
  chmod 2750 "$CT_LOG_DIR/app"
  local shown=("$APP_DIR" "$CT_ETC/app.env" "$CT_DATA/db" "$CT_LOG_DIR" "$CT_LOG_DIR/app")
  [[ -d "$VENV_DIR" ]] && shown+=("$VENV_DIR")
  log_ok "Permissões aplicadas:"
  stat -c '        %A %U:%G %n' "${shown[@]}" >&3
  audit "permissoes" "OK" "app=root:$CT_APP_USER(750) dados=$CT_APP_USER(750) env=600"
}

# -----------------------------------------------------------------------------
setup_service() {
  render_template "$CT_REPO_DIR/systemd/citizentech-app.service" /etc/systemd/system/citizentech-app.service
  chmod 0644 /etc/systemd/system/citizentech-app.service
  systemctl daemon-reload
  systemctl enable citizentech-app.service >/dev/null 2>&1
  log_ok "Unit instalada: /etc/systemd/system/citizentech-app.service (enabled - inicia no boot)"
  log_info "Restart=always, RestartSec=3, usuário $CT_APP_USER, sandbox ProtectSystem=strict"
}

# -----------------------------------------------------------------------------
setup_nginx() {
  NGINX_LISTEN_V6=""
  [[ -f /proc/net/if_inet6 ]] && NGINX_LISTEN_V6="listen [::]:80 default_server;"
  render_template "$CT_REPO_DIR/nginx/citizentech.conf" /etc/nginx/sites-available/citizentech
  ln -sfn ../sites-available/citizentech /etc/nginx/sites-enabled/citizentech
  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    log_info "Site padrão do Nginx desabilitado"
  fi
  install -d -m 0755 /var/www/citizentech
  install -m 0644 "$CT_REPO_DIR/nginx/50x.html" /var/www/citizentech/50x.html

  install -d /etc/systemd/system/nginx.service.d
  install -m 0644 "$CT_REPO_DIR/systemd/nginx-override.conf" /etc/systemd/system/nginx.service.d/10-citizentech.conf
  systemctl daemon-reload

  if ! nginx -t >>"$CT_CMD_LOG" 2>&1; then
    log_error "Configuração do Nginx inválida (nginx -t):"
    nginx -t 2>&1 | sed 's/^/        | /' >&3
    return 1
  fi
  log_ok "nginx -t: configuração válida"
  systemctl enable nginx >/dev/null 2>&1
  systemctl reload-or-restart nginx
  log_ok "Nginx: proxy reverso :80 -> $CT_SVC_IP:$APP_PORT (Restart=on-failure via drop-in)"
}

# -----------------------------------------------------------------------------
start_and_test() {
  systemctl restart citizentech-app.service
  local url_direct="http://$CT_SVC_IP:$APP_PORT$APP_HEALTH_PATH"
  if wait_until 45 curl -fsS -m 3 "$url_direct"; then
    log_ok "Aplicação respondendo diretamente: $url_direct"
  else
    log_error "A aplicação não respondeu em 45s. Últimos registros:"
    journalctl -u citizentech-app.service -n 25 --no-pager | sed 's/^/        | /' >&3
    return 1
  fi

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$CT_DOMAIN/")"
  if [[ "$code" != "200" ]]; then
    log_error "Acesso via Nginx retornou HTTP $code (http://$CT_DOMAIN/)"
    return 1
  fi
  log_ok "Acesso via Nginx + nome local: http://$CT_DOMAIN/  (HTTP $code)"
  log_info "Resposta de $APP_HEALTH_PATH: $(curl -s -m 5 "http://$CT_DOMAIN$APP_HEALTH_PATH")"
  audit "smoke-test" "OK" "url=http://$CT_DOMAIN/ http=$code"
}

summary() {
  banner "Aplicação CitizenTech no ar" "$(env_label)"
  kv 26 \
    "No servidor (DNS local)"   "http://$CT_DOMAIN/" \
    "IP principal"              "http://$(primary_ip | cut -d/ -f1)/" \
    "IP de serviço (interno)"   "http://$CT_SVC_IP:$APP_PORT/" \
    "Serviço"                   "systemctl status citizentech-app" \
    "Logs da aplicação"         "$CT_LOG_DIR/app/  |  journalctl -u citizentech-app"
  if [[ "$(env_kind)" == "wsl" ]]; then
    kv 26 "No navegador do Windows" "http://localhost/"
  fi
  echo >&3
  log_ok "Próximo passo: sudo ./scripts/03-provision-monitoring.sh"
}

step "Verificando infraestrutura"                 check_infra
step "Instalando runtime e dependências"          install_runtime_deps
step "Publicando o código da aplicação"           deploy_code
step "Configurando variáveis de ambiente"         write_env_file
step "Instalando dependências da aplicação"       build_app
step "Aplicando dono e permissões"                set_permissions
step "Criando serviço systemd da aplicação"       setup_service
step "Configurando Nginx (proxy reverso)"         setup_nginx
step "Iniciando e testando a aplicação"           start_and_test
summary
