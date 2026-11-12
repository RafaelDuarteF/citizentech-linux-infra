# Roteiro do vídeo (máximo 7 minutos)

Dica: grave a tela do terminal com fonte grande (zoom 130%+). Deixe o ambiente
**já instalado uma vez** (para o `apt` não consumir tempo do vídeo) e rode o
`install.sh` de novo na gravação: os scripts são idempotentes e mostram cada etapa.
Se quiser mostrar a instalação do zero, rode antes `sudo ./scripts/uninstall.sh --yes --purge`
(os pacotes continuam instalados, então a reinstalação é rápida).

| Tempo | O que mostrar | Comandos |
|---|---|---|
| 0:00 – 0:30 | Apresentação: equipe, CitizenTech (Zeladoria Cidadã), objetivo da infraestrutura | `cat README.md \| head -40` ou slide |
| 0:30 – 1:00 | Ambiente Linux e estrutura do repositório | `hostnamectl` · `cat /etc/os-release \| head -2` · `tree -L 2` (ou `ls -R scripts systemd`) · `cat config/citizentech.conf` |
| 1:00 – 2:30 | **Provisionamento automatizado** (infra + app + monitoramento) | `sudo ./install.sh` — comentar: hostname, IP fixo `ct0`, DNS com rollback, usuários/sudoers, diretórios/permissões, variáveis de ambiente, venv/pip, unit systemd, Nginx |
| 2:30 – 3:00 | Resultado da validação automática (PASS/FAIL) | final do `install.sh` ou `sudo ./scripts/04-validate.sh` |
| 3:00 – 3:40 | **Aplicação funcionando**: navegador em `http://localhost/` (WSL) ou `http://IP-da-VM/`; registrar uma ocorrência | `curl -s http://citizentech.local/health` · `curl -s http://citizentech.local/api/info \| jq` |
| 3:40 – 4:20 | **Monitoramento** e **serviços systemd** | `sudo ct-monitor` · `systemctl status citizentech-monitor --no-pager` · `systemctl list-timers citizentech-*` · `journalctl -u citizentech-monitor -n 5` |
| 4:20 – 5:40 | **Simulação de falha e recuperação** | `sudo ./scripts/fault-tests.sh kill-monitor` · `sudo ./scripts/fault-tests.sh stop-monitor` · `sudo ./scripts/fault-tests.sh kill-app` |
| 5:40 – 6:20 | **Consumo elevado** gerando alertas | `sudo ./scripts/fault-tests.sh cpu-stress` (encurtar com `STRESS_SECONDS=25`) |
| 6:20 – 6:50 | **Logs e auditoria** | `sudo tail -n 8 /var/log/citizentech/{audit,alerts,errors,service-events}.log` · `journalctl -t citizentech-audit -n 5` |
| 6:50 – 7:00 | Reboot: mostrar que tudo sobe sozinho (gravar à parte e encaixar) | VM: `sudo reboot` · WSL: `wsl --terminate CitizenTech` → reabrir → `sudo ./scripts/fault-tests.sh reboot-check` |

## Falas sugeridas (resumo)

- "Toda a infraestrutura é criada por scripts Bash idempotentes, a partir de um único arquivo de configuração."
- "A aplicação roda com um usuário de sistema sem login, escutando só no IP interno 10.77.0.10; o Nginx publica na porta 80."
- "O monitoramento roda como serviço systemd com Restart=always. Se ele cair em loop, o systemd desiste e o nosso watchdog, agendado por timer, recupera."
- "Cada execução registra quem executou, o quê, quando e o resultado no audit.log, e também no journald."
