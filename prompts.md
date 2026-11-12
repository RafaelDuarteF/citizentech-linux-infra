# Registro de uso de IA (prompts.md)

Conforme o combinado da Global Solution ("IA como copiloto: permitida para aprender e revisar;
registrem os prompts em um arquivo prompts.md e saibam explicar cada linha").

| # | Ferramenta | Objetivo | Prompt (resumo) |
|---|---|---|---|
| 1 | Claude (Claude Code) | Gerar a estrutura inicial da solução a partir do enunciado | "Leia o enunciado da GS de Operating Systems (CitizenTech) e desenvolva a infraestrutura Linux: scripts Bash de provisionamento (hostname, IP, DNS, usuários, permissões, dependências, variáveis de ambiente, serviço systemd), script de monitoramento de CPU/RAM/disco com alertas, monitoramento como serviço systemd tolerante a falhas, logs de auditoria, testes de falha, README e roteiro do vídeo." |
| 2 | _preencher_ | _ex.: entender a diferença entre Restart=always e o watchdog por timer_ | _..._ |
| 3 | _preencher_ | _ex.: revisar o script de DNS no WSL_ | _..._ |

## Como a equipe validou o que a IA produziu

- Execução completa em uma distribuição WSL limpa (Ubuntu 24.04): `sudo ./install.sh` → 47/47 verificações aprovadas.
- Execução de todos os cenários de `scripts/fault-tests.sh`.
- `shellcheck` sem avisos em todos os scripts.
- [ ] Revisão linha a linha em grupo (sugestão: cada integrante apresenta um dos scripts para os demais).

> Atualizem esta tabela com os prompts que cada integrante usar daqui em diante.
