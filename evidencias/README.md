# Evidências técnicas

## Saídas reais dos comandos

Geradas automaticamente com:

```bash
sudo ./scripts/collect-evidence.sh
```

Cada execução cria `evidencias/coleta-<data>/` com:

| Arquivo | Conteúdo |
|---|---|
| `01-sistema.txt` | hostname, SO, ambiente, uptime, recursos |
| `02-rede-dns.txt` | interfaces e IPs, rotas, `/etc/hosts`, DNS, resolução local/externa, portas, firewall |
| `03-usuarios-permissoes.txt` | usuários, grupos, sudoers, permissões dos diretórios, variáveis de ambiente |
| `04-servicos-systemd.txt` | `systemctl status` de todas as units, timers, units completas |
| `05-aplicacao.txt` | `/health`, `/api/info`, API de ocorrências, processos, log de acesso |
| `06-monitoramento.txt` | painel do monitor, JSON, `monitor.log`, `metrics.csv`, journal |
| `07-logs-auditoria.txt` | `audit`, `alerts`, `errors`, `service-events`, `healthcheck`, `fault-tests`, journald |
| `08-validacao.txt` | resultado das 47 verificações automáticas |

Também incluídos (execução de referência em WSL2 / Ubuntu 24.04, provisionamento do zero):

- `execucao-uninstall.txt` – remoção completa (`uninstall.sh --yes --purge`), provando que o ambiente é recriado do zero
- `execucao-install.txt` – saída completa de `sudo ./install.sh` (47/47 verificações aprovadas)
- `testes-de-falha.txt` – saída completa de `fault-tests.sh all` + `crash-loop` (8/8 aprovados)
- `prints/03-app-navegador.png` – aplicação aberta no navegador do Windows (`http://localhost/`)

## Capturas de tela (`evidencias/prints/`)

Capturadas da gravação do [vídeo de demonstração](https://youtu.be/RKiHxaTRDfY), na distribuição
WSL `CitizenTech` (Ubuntu 24.04), em resolução original.

| Arquivo | O que comprova |
|---|---|
| [`00-ambiente-configuracao.png`](prints/00-ambiente-configuracao.png) | Ubuntu 24.04 e a configuração central (`config/citizentech.conf`): hostname, IP de serviço, DNS, runtime e limites |
| [`01-install-execucao.png`](prints/01-install-execucao.png) | `sudo ./install.sh` em execução: pré-requisitos, pacotes, usuários, sudoers e diretórios |
| [`01-install-validacao-47-47.png`](prints/01-install-validacao-47-47.png) | Validação automática: **47/47 verificações aprovadas** |
| [`02-rede-ip-dns.png`](prints/02-rede-ip-dns.png) | Hostname `citizentech-srv`, interface `ct0` com `10.77.0.10/24`, resolução local e servidores DNS |
| [`03-app-navegador.png`](prints/03-app-navegador.png) | Aplicação Zeladoria Cidadã aberta no navegador do Windows (`http://localhost/`) |
| [`04-app-api-variaveis.png`](prints/04-app-api-variaveis.png) | `/api/info`: variáveis de ambiente carregadas pelo systemd (segredo não exposto) |
| [`05-monitor-recursos.png`](prints/05-monitor-recursos.png) | Painel `sudo ct-monitor`: CPU, memória, disco e saúde da aplicação |
| [`06-servicos-systemd-timer.png`](prints/06-servicos-systemd-timer.png) | `citizentech-monitor.service` ativo/habilitado e o timer do watchdog |
| [`07-teste-kill-monitor.png`](prints/07-teste-kill-monitor.png) | Monitor morto com `kill -9` e reiniciado pelo systemd (FALHA → RECUPERAÇÃO no log) |
| [`08-teste-stop-monitor-watchdog.png`](prints/08-teste-stop-monitor-watchdog.png) | Parada manual detectada e recuperada pelo watchdog |
| [`09-teste-kill-app.png`](prints/09-teste-kill-app.png) | Aplicação derrubada: HTTP 502 por ~4s e volta ao HTTP 200 |
| [`10-cpu-stress-alerta-critico.png`](prints/10-cpu-stress-alerta-critico.png) | CPU a 100%: alerta **CRIT** com os processos responsáveis |
| [`10-cpu-stress-resolvido.png`](prints/10-cpu-stress-resolvido.png) | Alertas registrados em `alerts.log` e o **RESOLVIDO** após o estresse |
| [`12-logs-auditoria.png`](prints/12-logs-auditoria.png) | `audit.log`, `alerts.log` e `service-events.log` |
| [`13-reboot-check.png`](prints/13-reboot-check.png) | Após reiniciar a distro: todas as units habilitadas e ativas, eventos de BOOT registrados |
