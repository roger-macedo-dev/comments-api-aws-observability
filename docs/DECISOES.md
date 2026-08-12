# Decisões de Arquitetura — Comments API + Infra AWS

Resumo executivo das decisões técnicas do projeto. Detalhamento completo em
[`docs/2026-08-12-comments-api-design.md`](2026-08-12-comments-api-design.md);
rastro de execução em [`docs/LOG_DE_ENGENHARIA.md`](LOG_DE_ENGENHARIA.md).

## Contexto do problema

API REST de comentários (inserção e listagem por matéria), com infraestrutura e
pipeline de deploy automatizados, em três ambientes (dev/test/prod), na AWS.

## Decisões

| # | Decisão | Alternativas descartadas | Justificativa |
|---|---|---|---|
| 1 | Cloud: **AWS** | GCP, Azure | Domínio prévio do time; ecossistema conhecido |
| 2 | Compute: **EC2 + Ansible + Docker Compose** | ECS Fargate, EKS | Automação de ponta a ponta (IaaS+IaaC) com custo controlado; EKS é overkill de custo/complexidade pro escopo |
| 3 | API: **Node/Express + Postgres** | Flask, Go | Stack web moderna, ecossistema maduro de testes e observabilidade |
| 4 | Ambientes: **Terraform workspaces sob demanda** | 3 instâncias fixas 24/7 | Isolamento real de IaC multi-ambiente sem custo de infraestrutura ociosa |
| 5 | CI/CD: **GitHub Actions + GHCR** | GitLab CI self-hosted | Integração nativa com o repositório do projeto |
| 6 | Deploy: **automático em dev, gate manual em prod** | automático em ambos | Segurança operacional — falha de deploy não derruba produção sem revisão |
| 7 | Acesso ao host: **SSM Session Manager** | SSH + chave + porta 22 | Elimina porta exposta; acesso auditado via IAM, sem gestão de chaves distribuídas |
| 8 | Secrets: **SSM Parameter Store** | `.env` no host / segredos no Git | Segredos nunca residem no host nem no controle de versão; least privilege via IAM |
| 9 | Banco em prod: **toggle RDS** (`use_rds`) | sempre container / sempre RDS | Ambientes de baixo custo usam container; produção usa serviço gerenciado (backup, Multi-AZ) via flag de configuração — 12-factor |
| 10 | State do Terraform: **S3 com lock nativo** (`use_lockfile`) | state local, lock via DynamoDB | Colaboração segura, lock contra execução concorrente sem depender de tabela separada; método atual recomendado pelo Terraform (DynamoDB lock foi depreciado) |
| 11 | Coleta de logs: **Grafana Alloy** | Promtail | Promtail atingiu EOL em 03/2026 (sem mais suporte oficial); Alloy é o coletor atual recomendado pelo Grafana Labs |

## Caminho de evolução (fora do escopo desta entrega)

Documentado e defendido, não construído — decisão consciente de escopo:

```
1 EC2 + Docker Compose   →  Auto Scaling Group + ALB  →  ECS Fargate
Postgres em container    →  RDS Multi-AZ (toggle já implementado no código)
nginx em HTTP             →  ALB + ACM (TLS)
```

## Requisitos avaliados × status da entrega

| Requisito | Status |
|---|---|
| Automação de infraestrutura (IaaS) | ✅ Terraform — provisionamento completo, validado end-to-end na AWS |
| Automação de configuração (IaaC) | 🔜 Ansible — em desenvolvimento |
| Pipeline de deploy | 🔜 GitHub Actions — em desenvolvimento |
| Monitoramento e métricas | ✅ Prometheus + Grafana + Loki + Alloy + Alertmanager, métricas RED da API, dashboard com painel de SLO |
| Desenvolvimento da API | ✅ Node/Express + Postgres, testado (7 testes automatizados) |
