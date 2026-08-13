# Comments API + Infra AWS: Design

**Data:** 2026-08-12
**Autor:** Roger Macedo
**Status:** Implementado

## 1. Contexto e objetivo

Objetivo do projeto: uma API de comentários simples servindo de carga de trabalho de
referência para validar uma esteira completa de infraestrutura como código — provisionamento,
configuração, observabilidade e deploy automatizados, com ambientes isolados (dev/test/prod).
A prioridade é a infraestrutura e a automação; a API é o serviço real usado para exercitar
tudo isso de ponta a ponta.

A API permite inserir um comentário associado a um conteúdo (`content_id`) e listar os
comentários de um conteúdo em ordem cronológica. Duas rotas essenciais: inserção e listagem.

### Objetivos técnicos

| Objetivo | Como a solução atende |
|---|---|
| Automação da infraestrutura (IaaS) | Terraform provisiona VPC/EC2/SG do zero |
| Automação de configuração (IaaC) | Ansible idempotente via `aws_ssm`, nada manual no host |
| Pipeline de deploy | GitHub Actions (CI + CD) end-to-end |
| Monitoramento e métricas | Prometheus/Grafana/Loki/Alloy/Alertmanager + RED/SLO |
| API | Express + Postgres, testada e instrumentada |

## 2. Decisões de arquitetura (ADRs resumidos)

| # | Decisão | Alternativas descartadas | Porquê |
|---|---|---|---|
| 1 | Cloud: **AWS** | GCP, Azure | Ecossistema conhecido |
| 2 | Compute: **EC2 + Ansible + Docker Compose** | ECS Fargate, EKS | Automação de ponta a ponta (IaaS+IaaC) com custo controlado. EKS é overkill de custo/complexidade pro escopo |
| 3 | API: **Node/Express + Postgres** | Flask, Go | Stack web moderna, ecossistema maduro de testes e observabilidade |
| 4 | Ambientes: **Terraform workspaces sob demanda** | 3 EC2 24/7; 1 host/3 stacks | Isolamento real de IaC multi-ambiente sem custo de infraestrutura ociosa |
| 5 | CI/CD: **GitHub Actions + GHCR** | GitLab CI self-hosted | Integração nativa com o repositório do projeto; registry grátis |
| 6 | Deploy: **automático em dev, gate manual em prod** | automático em ambos | Segurança operacional — falha de deploy não derruba produção sem revisão |
| 7 | Acesso ao host: **SSM Session Manager** | SSH + chave + porta 22 | Elimina porta exposta; acesso auditado via IAM, sem gestão de chaves distribuídas |
| 8 | Secrets: **SSM Parameter Store** | `.env` no host / segredos no Git | Segredos nunca residem no host nem no controle de versão; least privilege via IAM |
| 9 | Banco em prod: **toggle RDS** (`use_rds`) | sempre container; sempre RDS | Ambientes de baixo custo usam container; produção usa serviço gerenciado (backup, Multi-AZ) via flag de configuração — 12-factor |
| 10 | State do Terraform: **S3 com lock nativo** (`use_lockfile`) | state local; lock via DynamoDB | Colaboração segura, lock contra execução concorrente, sem tabela separada — método atual recomendado pelo Terraform |
| 11 | Coleta de logs: **Grafana Alloy** | Promtail | Promtail atingiu EOL; Alloy é o coletor atual recomendado pelo Grafana Labs |

## 3. Arquitetura

### 3.1 Fluxo de deploy

```
Dev → git push (main)
   │
GitHub Actions
   ├─ CI:  npm ci + jest (com Postgres de serviço)
   │       npm audit + Trivy (scan de filesystem)
   │       docker build → push ghcr.io/<user>/comments-api:<sha> e :latest
   └─ CD:  disparado após CI verde (workflow_run) ou manualmente (workflow_dispatch)
             ansible-playbook via aws_ssm → configura host + docker pull da imagem + compose up
             validação: health check + round-trip real de comentário
```

Gate manual de produção e rollback automático estão desenhados (decisão #6) mas não
construídos — ver seção 9 (fora de escopo).

### 3.2 Topologia AWS (estado da entrega)

```
VPC
└── subnet pública
      EC2 (Amazon Linux 2023, sem SSH — acesso via SSM Session Manager)
      │
      ├── nginx (porta 80, único componente exposto)
      ├── comments-api (Node, expõe /metrics) ── postgres (container+volume) | RDS (toggle)
      └── observabilidade
            prometheus + alertmanager
            loki + alloy
            grafana (provisionado via YAML: datasources + dashboard RED/SLO)
            node_exporter

Acesso ao host: SSM Session Manager (IAM; sem porta 22 aberta)
Secrets:        SSM Parameter Store (senha DB, chaves) lidos no deploy via lookup do Ansible
State remoto:   S3 (backend) + lock nativo (use_lockfile)
```

### 3.3 Caminho de evolução (documentado, não construído)

```
ATUAL                        →   EVOLUÇÃO
1 EC2 + Docker Compose        →   ASG + ALB + N hosts     →   ECS Fargate
Postgres container            →   RDS Multi-AZ (toggle já implementado)
nginx (porta 80)              →   ALB + ACM (HTTPS/TLS)
observabilidade no host       →   Amazon Managed Prometheus/Grafana (opcional)
```

## 4. Estrutura do repositório

```
comments-api-aws-observability/
├── terraform/
│   ├── network.tf security.tf iam.tf secrets.tf ec2.tf
│   ├── versions.tf          # backend S3 + lock nativo
│   ├── variables.tf outputs.tf
│   └── envs/{dev,test,prod}.tfvars
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/dev.aws_ec2.yml  # dinâmico via amazon.aws.aws_ec2
│   ├── site.yml
│   └── roles/
│       ├── docker/          # Docker CE + Compose plugin
│       └── deploy/          # copia compose/observability, renderiza .env, sobe a stack
├── app/
│   ├── src/
│   │   ├── server.js        # Express bootstrap
│   │   ├── routes/          # POST /api/comment/new, GET /api/comment/list/:id, /health
│   │   ├── db/pool.js, db/migrate.js
│   │   └── metrics.js       # prom-client: RED (rate/errors/duration)
│   ├── tests/                # jest + supertest
│   └── Dockerfile          # multi-stage, imagem mínima, non-root
├── observability/
│   ├── prometheus/{prometheus.yml,alert-rules.yml}
│   ├── alertmanager/alertmanager.yml
│   ├── alloy/config.alloy
│   └── grafana/provisioning/{datasources,dashboards}/
├── compose/
│   ├── docker-compose.yml   # api + postgres + nginx + observabilidade
│   └── .env.example
├── .github/workflows/
│   ├── ci.yml                # testes, segurança, build/push
│   └── cd.yml                # deploy automático em dev via Ansible/aws_ssm
└── docs/
    ├── 2026-08-12-comments-api-design.md
    ├── DECISOES.md
    └── LOG_DE_ENGENHARIA.md
```

## 5. Componentes

### 5.1 API de Comentários (Node/Express)

**Rotas:**

| Método | Rota | Corpo / Resposta |
|---|---|---|
| POST | `/api/comment/new` | `{email, comment, content_id}` → 201 `{id,...}` |
| GET | `/api/comment/list/:content_id` | → 200 `[{id,email,comment,content_id,created_at}]` |
| GET | `/health` | → 200 `{status:"ok", db:"up"}` |
| GET | `/metrics` | → Prometheus (RED) |

**Modelo de dados** (`comments`):

| coluna | tipo | nota |
|---|---|---|
| id | serial PK | |
| email | text not null | |
| comment | text not null | |
| content_id | integer not null | indexado (listagem por conteúdo) |
| created_at | timestamptz default now() | |

**Validação:** email com formato válido, `comment` não vazio, `content_id` inteiro > 0.
Erros retornam 400 com mensagem. 12-factor: config 100% via env (`DATABASE_URL`, `PORT`,
`LOG_LEVEL`). Stateless (escala horizontal no futuro sem sessão local).

**Migrations:** aplicadas por um container `migrate` que roda antes da API subir, com
script idempotente (`CREATE TABLE IF NOT EXISTS`).

### 5.2 Terraform (IaaS)

- Workspaces = ambientes (`dev`, `test`, `prod`); só `dev` está provisionado hoje.
- Recursos: VPC, subnet pública única, IGW, route table, SG least privilege (só porta 80
  pública; API/DB/observabilidade só na rede interna do Docker), EC2 com IAM instance
  profile (permissões SSM + leitura escopada de Parameter Store), sem `key_name`.
- `secrets.tf` gera credenciais via `random_password`, armazenadas como `SecureString`.
- Backend S3 com lock nativo (`use_lockfile`) para state e concorrência.

### 5.3 Ansible (IaaC)

- Duas roles: `docker` (instala engine + Compose plugin) e `deploy` (copia `compose/` e
  `observability/`, renderiza `.env` com segredos lidos do SSM via lookup, sobe a stack).
- Inventário dinâmico via plugin `amazon.aws.aws_ec2`, conexão `aws_ssm` — zero SSH também
  na etapa de configuração.
- Suporta dois modos de origem de imagem: build local + transferência (uso manual) ou
  `docker pull` de uma imagem já publicada no GHCR (uso via CD).

### 5.4 Observabilidade

- **Prometheus:** scrape de `node_exporter` (host) e `comments-api /metrics` (RED).
- **Grafana:** provisionado via YAML (datasources Prometheus+Loki, dashboard RED + painel
  de SLO/error budget). Sem clique manual na UI.
- **Loki + Grafana Alloy:** logs do host e dos containers.
- **Alertmanager:** regras `NodeExporterDown`, `MemoriaAlta`, `TaxaErroAlta` (RED),
  `APIDown`.

### 5.5 CI/CD (GitHub Actions)

- **ci.yml:** roda em todo push/PR que toque `app/` — job `test` (Postgres de serviço,
  migration, `jest`), job `security` (`npm audit` + Trivy scan de filesystem), job
  `build-and-push` (build multi-stage e push pro GHCR com tag `<sha>` e `latest`, só em
  push na `main`, dependente dos dois jobs anteriores).
- **cd.yml:** disparado automaticamente via `workflow_run` quando o CI termina com sucesso
  na `main` (ou manualmente via `workflow_dispatch`). Roda o playbook Ansible do próprio
  runner do GitHub Actions contra o host, via `aws_ssm`, puxando a imagem publicada pelo CI.
- Credenciais AWS via GitHub Secrets (mesmo usuário IAM do Terraform) — trade-off aceito
  documentado em `DECISOES.md`.

## 6. Diferenças por ambiente

| | dev | test | prod |
|---|---|---|---|
| instância | t3.micro | t3.micro (planejado) | t3.small (planejado) |
| gatilho | push `main` (auto) | manual | push `main` (gate manual — não construído) |
| log level | debug | info | warn |
| banco | Postgres container | container + volume | `use_rds=true` (RDS) |
| status | provisionado e validado | não provisionado | não provisionado |

## 7. Segurança

- SSM Session Manager (sem SSH, sem porta 22, sem chave distribuída) tanto no
  provisionamento quanto na configuração/deploy.
- Secrets em SSM Parameter Store, IAM least privilege (a instância só lê seus próprios
  parâmetros, escopados por ambiente).
- Rede: só nginx exposto; API, banco e observabilidade só na rede interna do Docker.
- Imagem Docker: multi-stage, non-root, mínima; scan Trivy no CI.
- Credenciais AWS do pipeline via GitHub Secrets (usuário IAM dedicado do Terraform) —
  OIDC é evolução natural, não implementada nesta entrega.

## 8. Estratégia de testes

- **Unit/integração da API:** jest + supertest — rotas, validação, erros, round-trip DB
  (Postgres efêmero via service container no CI).
- **Segurança:** `npm audit` (dependências) + Trivy (filesystem) no CI.
- **Validação pós-deploy:** health check e round-trip real de comentário via `curl` no
  ambiente alvo (manual hoje; automatizar como smoke-test de pipeline é evolução).
- **Alertas:** ciclo `inactive → pending → firing → resolved` validado provocando uma falha
  real na API (queda proposital do Postgres) e observando o Alertmanager reagir.

## 9. Fora de escopo (decisão consciente)

- ASG/ALB/ECS/EKS — descritos como evolução, não construídos.
- HTTPS/ACM — nginx em HTTP; TLS citado na evolução.
- Autenticação de usuários da API — fora do escopo do serviço de referência.
- Amazon Managed Prometheus/Grafana — evolução opcional.
- Ambientes `test`/`prod` provisionados na AWS — só `dev` está no ar (disciplina de custo).
- Gate manual de aprovação em prod e rollback automático — desenhados, não construídos.
- Scan de IaC (Checkov) e OIDC no pipeline — evolução natural do CI/CD atual.

## 10. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Custo esquecido ligado | disciplina manual de `terraform destroy` ao fim de cada sessão de trabalho |
| SPOF (1 host) | aceito nesta entrega; evolução ASG+ALB diagramada e defendida |
| Perda de dados (container DB) | volume nomeado; prod via RDS toggle |
| Deploy quebra o ambiente | validação pós-deploy manual; gate + rollback automático ficam na evolução |
| Falha de conexão do banco derruba a API | tratada em código (listener de erro no pool + timeout de conexão), validada provocando a falha de propósito |
