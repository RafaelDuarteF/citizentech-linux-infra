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

## Capturas de tela (a equipe deve adicionar em `evidencias/prints/`)

| # | Arquivo sugerido | O que capturar |
|---|---|---|
| 1 | `01-install.png` | final do `sudo ./install.sh` com "47/47 verificações aprovadas" |
| 2 | `02-rede-dns.png` | `hostname`, `ip -br addr`, `getent hosts citizentech.local app.citizentech.local` |
| 3 | `03-app-navegador.png` | aplicação aberta no navegador (`http://localhost/` ou IP da VM) |
| 4 | `04-app-api.png` | `curl -s http://citizentech.local/api/info \| jq` |
| 5 | `05-monitor.png` | `sudo ct-monitor` |
| 6 | `06-servicos.png` | `systemctl status citizentech-monitor citizentech-app --no-pager` e `systemctl list-timers 'citizentech-*'` |
| 7 | `07-kill-monitor.png` | `sudo ./scripts/fault-tests.sh kill-monitor` |
| 8 | `08-stop-monitor.png` | `sudo ./scripts/fault-tests.sh stop-monitor` |
| 9 | `09-kill-app.png` | `sudo ./scripts/fault-tests.sh kill-app` (+ página "Estamos voltando em instantes" no navegador) |
| 10 | `10-cpu-stress.png` | `sudo ./scripts/fault-tests.sh cpu-stress` com os alertas |
| 11 | `11-mem-stress.png` | `sudo ./scripts/fault-tests.sh mem-stress` |
| 12 | `12-script-error.png` | `sudo ./scripts/fault-tests.sh script-error` |
| 13 | `13-reboot.png` | `sudo ./scripts/fault-tests.sh reboot-check` após reiniciar |
| 14 | `14-logs.png` | `sudo tail -n 8 /var/log/citizentech/{audit,alerts,errors,service-events}.log` |
