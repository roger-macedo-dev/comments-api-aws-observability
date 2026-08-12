# Comments API + Infra AWS: Design

**Data:** 2026-08-12
**Autor:** Roger Macedo
**Status:** Aprovado (pré-implementação)

## 1. Contexto e objetivo

Projeto: implantar a **infraestrutura (obrigatório)** e a
**API REST de Comentários (opcional/diferencial)** com o máximo de automação possível,
incluindo a esteira de deploy, e implementar ambientes distintos (dev/test/prod) com
configurações apropriadas. A solução deve ser tecnicamente defensável: cada escolha
tem um porquê explícito e um caminho de evolução articulado.

A API permite que internautas enviem comentários em texto de uma matéria e listem o que
outras pessoas comentaram. Duas rotas essenciais: inserção e listagem por matéria.

### Critérios de avaliação (do enunciado)

| Critério | Peso | Como a solução atende |
|---|---|---|
| Automação da infra (IaaS/PaaS) | Obrigatório | Terraform provisiona VPC/EC2/SG do zero |
| Automação de setup/config (IaaC) | Obrigatório | Ansible idempotente, nada manual no host |
| Pipeline de deploy | Desejável | GitHub Actions end-to-end |
| Monitoramento de serviços e métricas | Desejável | Prometheus/Grafana/Loki/Alertmanager + RED/SLO |
| Desenvolvimento da API | Diferencial | Express + Postgres com testes e métricas |

## 2. Decisões de arquitetura (ADRs resumidos)

| # | Decisão | Alternativas descartadas | Porquê |
|---|---|---|---|
| 1 | Cloud: **AWS** | GCP, Azure | Domínio do candidato; ecossistema conhecido |
| 2 | Compute: **EC2 + Ansible + Docker Compose** | ECS Fargate, EKS | Ponto forte do candidato (IaaC), custo baixo, defende IaaS+IaaC de ponta a ponta. EKS = caro/overkill; contradiz disciplina de custo |
| 3 | API: **Node/Express + Postgres** | Flask, Go | Stack web moderna comum; demonstra amplitude |
| 4 | Ambientes: **Terraform workspaces sob demanda** | 3 EC2 24/7; 1 host/3 stacks | Isolamento real de IaC multi-ambiente sem custo permanente |
| 5 | CI/CD: **GitHub Actions + ghcr.io** | GitLab CI self-hosted | Integra com o portfólio no GitHub; ghcr grátis |
| 6 | Deploy: **auto em dev, gate manual em prod** | auto em prod; tudo manual | GitOps com trava; evita derrubar prod sozinho |
| 7 | Acesso host: **SSM Session Manager** | SSH + key + porta 22 | Zero superfície de ataque; sem IP fixo; auditado por IAM |
| 8 | Secrets: **SSM Parameter Store** | .env no host; secrets no Git | Least privilege via IAM; segredo fora do host e do Git |
| 9 | DB prod: **toggle RDS** (`use_rds`) | sempre container; sempre RDS | dev/test barato em container; prod com backup/multi-AZ gerenciado por flip de variável (12-factor) |
| 10 | State Terraform: **S3 + DynamoDB lock** | state local | Colaboração, lock, durabilidade |

## 3. Arquitetura

### 3.1 Fluxo de deploy

```
Dev → git push
   │
GitHub Actions
   ├─ CI:  npm lint + test
   │       Trivy (scan imagem) + Checkov (scan IaC)
   │       docker build → push ghcr.io/<user>/comments-api:<sha>
   └─ CD:  branch develop → workspace dev  (deploy automático)
           branch main    → workspace prod (gate de aprovação manual)
             terraform apply   → cria/atualiza VPC/EC2/SG/IAM/SSM
             ansible-playbook   → configura host + sobe stack via compose
             smoke-test         → curl /health + round-trip real de comment
             falhou? → rollback para tag de imagem anterior
```

### 3.2 Topologia AWS (estado da entrega)

```
VPC
├── subnet pública
│     nginx (reverse proxy — único componente exposto, porta 80)
│     SSM endpoints (acesso administrativo, sem SSH)
└── subnet privada
      comments-api (Node, expõe /metrics)  ── postgres (container+volume) | RDS (toggle)
      observabilidade:
        prometheus + alertmanager
        loki + promtail
        grafana (provisionado via YAML: datasources + dashboard RED/SLO)
        node_exporter
Acesso ao host: SSM Session Manager (IAM; sem porta 22 aberta)
Secrets:        SSM Parameter Store (senha DB, chaves) puxados no deploy
State remoto:   S3 (backend) + DynamoDB (lock)
```

### 3.3 Evolução (diagramada em `docs/`, NÃO construída — peça de defesa)

```
ENTREGA (challenge)          →   EVOLUÇÃO (defendida)
1 EC2 + Docker Compose       →   ASG + ALB + N hosts     →   ECS Fargate
Postgres container           →   RDS Multi-AZ (toggle já implementado)
nginx (porta 80)             →   ALB + ACM (HTTPS/TLS)
observabilidade no host      →   Amazon Managed Prometheus/Grafana (opcional)
```

## 4. Estrutura do repositório

```
comments-api-aws-observability/
├── terraform/
│   ├── main.tf              # VPC, subnets, SG, EC2, IAM role (SSM), SSM params
│   ├── rds.tf               # RDS condicional (count = var.use_rds ? 1 : 0)
│   ├── backend.tf           # S3 + DynamoDB
│   ├── variables.tf outputs.tf
│   └── envs/{dev,test,prod}.tfvars
├── ansible/
│   ├── inventory/           # dinâmico a partir de output do Terraform
│   ├── site.yml             # tags: infra / app / observability
│   └── roles/{docker,firewall,swap,app,postgres,nginx,observability}/
├── app/
│   ├── src/
│   │   ├── server.js        # Express bootstrap
│   │   ├── routes/comments.js  # POST /api/comment/new, GET /api/comment/list/:id
│   │   ├── routes/health.js    # GET /health
│   │   ├── db/pool.js migrations/
│   │   └── metrics.js       # prom-client: RED (rate/errors/duration)
│   ├── tests/               # jest + supertest
│   └── Dockerfile           # multi-stage, imagem mínima, non-root
├── observability/
│   ├── prometheus/{prometheus.yml,alert-rules.yml}
│   ├── alertmanager/alertmanager.yml
│   ├── promtail/promtail-config.yml
│   └── grafana/provisioning/{datasources,dashboards}/   # fecha o gap manual do lab
├── compose/
│   ├── docker-compose.yml   # api + postgres + nginx + observabilidade
│   └── .env.j2              # template Ansible por ambiente
├── .github/workflows/
│   ├── ci.yml               # lint, test, scan, build, push
│   ├── deploy.yml           # terraform + ansible + smoke-test + rollback
│   └── destroy.yml          # guardrail de custo (destroy manual)
└── docs/
    ├── architecture.md      # diagramas atual + evolução
    └── adr/                 # decisões detalhadas
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
| email | text not null | validado (formato) |
| comment | text not null | |
| content_id | integer not null | indexado (listagem por matéria) |
| created_at | timestamptz default now() | |

**Validação:** email com formato válido, `comment` não vazio, `content_id` inteiro > 0.
Erros retornam 400 com mensagem. 12-factor: config 100% via env (`DATABASE_URL`, `PORT`,
`LOG_LEVEL`). Stateless (escala horizontal no futuro sem sessão local).

**Migrations:** aplicadas na subida do container (script idempotente `CREATE TABLE IF NOT EXISTS`).

### 5.2 Terraform (IaaS)

- Workspaces = ambientes (`dev`, `test`, `prod`). `terraform workspace select` no pipeline.
- Recursos: VPC, 2 subnets (pública/privada), IGW, route tables, SG least privilege
  (só 80 público; API/DB/observabilidade internos), EC2 com IAM instance profile
  (permissões SSM + leitura de Parameter Store), key-less.
- `rds.tf` condicional por `var.use_rds`. Output: IP/DNS, endpoint DB, id da instância.
- Backend S3 + DynamoDB para state e lock.

### 5.3 Ansible (IaaC)

- Roles idempotentes: `docker` (instala engine), `swap` (1GB, herdado do lab), `firewall`,
  `postgres` (container, quando não-RDS), `app` (pull imagem + compose up), `nginx`
  (reverse proxy), `observability` (stack completa + provisioning Grafana).
- Inventário dinâmico a partir dos outputs do Terraform.
- Secrets lidos do SSM Parameter Store no momento do deploy, injetados no `.env` gerado
  (nunca versionado).
- Tags `infra` / `app` / `observability` para execução seletiva.

### 5.4 Observabilidade

- **Prometheus:** scrape de `node_exporter` (host) e `comments-api /metrics` (RED).
- **Grafana:** provisionado via YAML (datasources Prometheus+Loki, dashboard RED + painel
  de SLO/error budget). Sem clique manual — fecha o gap identificado no lab anterior.
- **Loki + Promtail:** logs do host e dos containers (lista explícita de arquivos, sem glob
  binário — lição do lab).
- **Alertmanager:** regras `NodeExporterDown`, `MemoriaAlta`, `TaxaErroAlta` (RED),
  `APIDown`. Receiver de webhook (Discord/Slack) com `send_resolved`.

### 5.5 CI/CD (GitHub Actions)

- **ci.yml:** roda em todo push/PR — `npm ci`, lint, `jest`, Checkov (Terraform), Trivy
  (imagem buildada), build e push para ghcr.io com tag `<sha>` e `latest` do ambiente.
- **deploy.yml:** disparado por push em `develop` (→dev, auto) ou `main` (→prod, com
  `environment: prod` protegido por aprovação). Passos: configura credenciais AWS (OIDC,
  sem chave estática), `terraform apply` no workspace, `ansible-playbook`, smoke-test,
  rollback automático em falha (redeploy da tag anterior registrada).
- **destroy.yml:** `workflow_dispatch` manual para `terraform destroy` — guardrail de custo.
- Guardrail extra: job agendado de auto-stop noturno das instâncias dev/test.

## 6. Diferenças por ambiente

| | dev | test | prod |
|---|---|---|---|
| instância | t3.micro | t3.micro | t3.small |
| gatilho | push `develop` (auto) | manual/tag | push `main` (gate manual) |
| log level | debug | info | warn |
| banco | Postgres container | container + volume | `use_rds=true` (RDS) |
| smoke-test | sim | sim | sim + rollback obrigatório |

## 7. Segurança

- SSM Session Manager (sem SSH, sem porta 22, sem key distribuída).
- Secrets em SSM Parameter Store, IAM least privilege (instância só lê seus próprios params).
- OIDC GitHub↔AWS no pipeline (sem access key estática em secret).
- Rede: só nginx exposto; API e DB em subnet privada; SG mínimo.
- Imagem Docker: multi-stage, non-root, mínima; scan Trivy no CI.
- IaC scan Checkov no CI.
- Container/API scan também disponível via Snyk (uso alinhado à política de segurança).

## 8. Estratégia de testes

- **Unit/integração da API:** jest + supertest — rotas, validação, erros, round-trip DB
  (Postgres efêmero via service container no CI).
- **IaC:** `terraform validate` + `checkov`.
- **Config:** `ansible-lint` + `--check` (dry-run) no CI.
- **Smoke (pós-deploy):** `curl /health` + criar e listar um comentário real no ambiente alvo.
- **Alertas:** ciclo Inactive→Pending→Firing validado gerando erro na API (herdado do método do lab).

## 9. Fora de escopo (YAGNI para o challenge)

- ASG/ALB/ECS/EKS — descritos como evolução, não construídos.
- HTTPS/ACM — nginx em HTTP; TLS citado na evolução.
- Autenticação de usuários da API — o enunciado não pede.
- Amazon Managed Prometheus/Grafana — evolução opcional.

## 10. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Custo esquecido ligado | destroy.yml + auto-stop agendado + disciplina Stop |
| SPOF (1 host) | aceito no challenge; evolução ASG+ALB diagramada e defendida |
| Perda de dados (container DB) | volume nomeado; prod via RDS toggle |
| Deploy quebra prod | gate manual + smoke-test + rollback automático |
| Créditos burst t3.micro | swap idempotente (lição do lab) |
