# Registro de uso de IA (prompts.md)

Conforme o combinado da Global Solution: *"IA como copiloto: permitida para aprender e revisar.
Registrem os prompts em um arquivo prompts.md e saibam explicar cada linha."*

- **Ferramenta:** Claude (Claude Code, aplicativo desktop) com acesso ao terminal do Windows e ao WSL.
- **Como foi usada:** a IA gerou a primeira versão dos scripts, da aplicação de exemplo e da
  documentação a partir do enunciado; os testes foram executados em uma distribuição WSL dedicada
  (`CitizenTech`) e os problemas encontrados foram corrigidos em ciclos de teste → correção → novo teste.
  As decisões de entrega (publicação, integrantes, vídeo) foram da equipe.

## 1. Linha do tempo das interações

| # | Pedido da equipe (resumo fiel) | O que a IA fez | Resultado |
|---|---|---|---|
| 1 | Enviamos o enunciado de Operating Systems e o PDF da GS CitizenTech e pedimos o desenvolvimento da infraestrutura | Leu o PDF (incluindo a rubrica de 10 pontos), propôs a arquitetura (Nginx → app em IP interno, monitor como serviço + watchdog por timer, auditoria centralizada) e gerou scripts, units systemd, app de exemplo e README | Repositório com `install.sh` e scripts 01–04 |
| 2 | (validação) Execução em uma distro WSL nova, sem nada instalado | Rodou `install.sh` do zero, os testes de falha e um reboot real (`wsl --terminate`) | 47/47 verificações e 8/8 testes de falha aprovados após as correções da seção 2 |
| 3 | "Publica o repositório no GitHub" → depois "deixa público" | Criou o repositório, conferiu bits de execução e fim de linha LF; antes de abrir, varreu o conteúdo procurando senhas, tokens e dados pessoais | Repositório público |
| 4 | Enviamos nomes e RMs para o README | Preencheu a tabela de integrantes | README atualizado |
| 5 | "Me dá o roteiro do vídeo com as falas" | Montou o roteiro por blocos, com tempo, comandos e falas, alinhado aos critérios de avaliação | `docs/roteiro-video.md` |
| 6 | "Por que o `sudo` pediu senha e recusou no usuário `ctops`?" | Explicou que o `ctops` tem **sudo restrito por design** (`/etc/sudoers.d/citizentech` só libera `systemctl` dos serviços `citizentech-*`) e que a distro sem usuário inicial adotou o `ctops` (UID 1000) como padrão; orientou entrar com `wsl -d CitizenTech -u root` | Entendemos na prática o controle de permissões do sudoers |
| 7 | Edição do vídeo gravado (cortes de erros/silêncios, trilha livre de direitos) | Transcreveu o áudio para localizar repetições, cortou, sincronizou e adicionou cartelas e trilha da Mixkit | Vídeo final |
| 8 | "O prompts.md está genérico, melhora" | Reescreveu este registro com a linha do tempo real e os problemas corrigidos | Este arquivo |

## 2. Problemas encontrados nos testes e como foram corrigidos

Cada item abaixo apareceu ao executar os scripts de verdade e foi corrigido e testado de novo:

| Problema observado | Causa | Correção |
|---|---|---|
| `01-provision-infra.sh` falhou ao gerar a unit de rede | O comentário do template continha um marcador no formato `@NOME@`, que a função `render_template` tentou substituir | Comentários dos templates reescritos sem esse padrão |
| Tabelas do terminal desalinhadas em palavras com acento | O `printf` do bash conta **bytes**, não caracteres (UTF-8) | Função `pad()` em `lib/common.sh` usando `${#texto}` |
| Monitor registrava "novo boot" sem ter reiniciado | `ps -o lstart` do PID 1 variava 1 segundo entre leituras | Chave de boot = `boot_id` do kernel + campo 22 de `/proc/1/stat` (ticks, estável) |
| Reinício após parada manual aparecia como "BOOT" em `service-events.log` | Critério baseado só no tempo desde o boot | Compara a data do último registro de parada com o início do PID 1 |
| No teste `crash-loop`, o watchdog registrava uma recuperação com falha | Watchdog e auto-restart do systemd agiam ao mesmo tempo; o `start` batia no `StartLimitBurst` | Watchdog aguarda o estado `activating` e faz `reset-failed` com até 3 tentativas |
| O próprio `ps` aparecia entre os "processos que mais consomem CPU" | O `ps` mede a si mesmo durante a coleta | Filtro do processo `ps` no `monitor.sh` |
| Serviços "sumiam" ao fechar o terminal no WSL | O WSL desliga a distro segundos após o último terminal fechar | Comportamento documentado no README; `reboot-check` comprova a volta automática |
| Risco no Azure: `/etc/hosts` reescrito a cada boot | `cloud-init` com `manage_etc_hosts` | `/etc/cloud/cloud.cfg.d/99-citizentech.cfg` com `manage_etc_hosts: false` |

## 3. Conceitos que cada integrante deve saber explicar

Checklist de estudo (marcar quando o integrante conseguir explicar sem consultar):

- [ ] `set -Eeuo pipefail` + `trap ... ERR` / `EXIT`: como o erro vira registro com script, linha e comando
- [ ] Idempotência: por que rodar `install.sh` duas vezes não duplica nada (blocos gerenciados, `install -d`, checagem antes de criar)
- [ ] Interface `dummy` (`ct0`) com IP fixo e por que a aplicação escuta só nele
- [ ] DNS no WSL (`generateResolvConf=false`) × systemd-resolved na VM, e o rollback quando a resolução falha
- [ ] `Cmnd_Alias` no sudoers e por que validar com `visudo -c` antes de instalar
- [ ] Permissões: por que o código é `root:citizentech 750` e o `app.env` é `600 root`
- [ ] `Restart=always` × watchdog por timer × `StartLimitBurst` (as três camadas de tolerância a falhas)
- [ ] `ExecStartPre=-+` e as variáveis `SERVICE_RESULT` / `EXIT_CODE` / `EXIT_STATUS` no `ExecStopPost`
- [ ] Sandbox do systemd: `ProtectSystem=strict`, `ReadWritePaths`, `NoNewPrivileges`
- [ ] Cálculo de CPU por amostragem de `/proc/stat` e de memória por `MemAvailable`
- [ ] `logrotate` com `copytruncate` e journald persistente

## 4. Como o resultado foi validado

- `sudo ./install.sh` em distribuição WSL limpa (Ubuntu 24.04): **47/47 verificações aprovadas**.
- `sudo ./scripts/uninstall.sh --yes --purge` seguido de nova instalação do zero (reprodutibilidade).
- `sudo ./scripts/fault-tests.sh all` + `crash-loop` + `reboot-check`: **todos aprovados**
  (saídas completas em `evidencias/`).
- `shellcheck -S warning` sem avisos em todos os scripts.
