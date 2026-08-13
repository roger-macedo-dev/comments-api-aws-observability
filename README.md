# Comments API — AWS + Observability

API REST de comentários com infraestrutura como código, containerização e stack de
observabilidade completa. Comentários são associados a um `content_id` (matéria/conteúdo);
a API permite inserção e listagem cronológica por conteúdo.

## Arquitetura

```
GitHub ─┐
         │  (pipeline de deploy — em construção)
         ▼
AWS · VPC (subnet pública única)
  EC2 (Amazon Linux 2023, sem SSH — acesso via IAM/SSM Session Manager)
  │
  ├── nginx (porta 80, único componente exposto)
  │     └── proxy → comments-api
  ├── comments-api (Node/Express) ── postgres (container, ou RDS via toggle)
  └── observabilidade
        prometheus ── alertmanager
        loki ── alloy
        grafana (datasources e dashboards provisionados via código)

Segredos: AWS SSM Parameter Store (SecureString), escopados por ambiente via IAM
State da infraestrutura: S3 + lock nativo
```

Só a porta 80 é exposta publicamente. API, banco e stack de observabilidade existem
apenas na rede interna do Docker. Não há chave SSH nem porta 22 em nenhum ambiente —
acesso administrativo à instância é feito via AWS Systems Manager Session Manager,
auditado por IAM.

## Stack técnica

| Camada | Tecnologia |
|---|---|
| API | Node.js 20 / Express, driver `pg` |
| Banco de dados | PostgreSQL 16 |
| Containerização | Docker (multi-stage, non-root) + Docker Compose |
| Infraestrutura | Terraform (VPC, EC2, IAM, Security Group, SSM) |
| Observabilidade | Prometheus, Grafana, Loki, Grafana Alloy, Alertmanager |
| Testes | Jest + Supertest |

## API

| Método | Rota | Descrição |
|---|---|---|
| `POST` | `/api/comment/new` | Cria um comentário (`email`, `comment`, `content_id`) |
| `GET` | `/api/comment/list/:content_id` | Lista comentários de um conteúdo, em ordem cronológica |
| `GET` | `/health` | Health check (valida conexão com o banco) |
| `GET` | `/metrics` | Métricas Prometheus (rate, errors, duration) |

```bash
curl -X POST http://localhost/api/comment/new \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","comment":"first post!","content_id":1}'

curl http://localhost/api/comment/list/1
```

## Executando localmente

Requisitos: Docker e Docker Compose.

```bash
cd compose
cp .env.example .env   # ajustar credenciais
docker compose up -d
```

Serviços disponíveis:

| Serviço | URL |
|---|---|
| API (via nginx) | http://localhost |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9091 |
| Alertmanager | http://localhost:9093 |

## Testes

```bash
cd app
npm install
npm test
```

## Observabilidade

Dashboard próprio da API segue o método **RED** (Rate, Errors, Duration) mais um painel
de disponibilidade/error budget. Datasources e dashboard são provisionados automaticamente
via código (`observability/grafana/provisioning/`) — nenhuma configuração manual na UI.

Alertas ativos: indisponibilidade de nodo (`NodeExporterDown`), memória alta
(`MemoriaAlta`), API fora do ar (`APIDown`) e taxa de erro elevada (`TaxaErroAlta`,
baseada nas métricas HTTP da própria API).

## Infraestrutura

Provisionamento via Terraform, com ambientes isolados por workspace:

```bash
cd terraform
terraform init
terraform workspace new dev
terraform apply -var-file=envs/dev.tfvars
```

Segredos (credenciais de banco, senha do Grafana) são gerados automaticamente pelo
Terraform e armazenados como `SecureString` no SSM Parameter Store — nunca em texto
plano no código ou no host.

## Documentação

- [Decisões de arquitetura](docs/DECISOES.md) — resumo executivo das escolhas técnicas
- [Design detalhado](docs/2026-08-12-comments-api-design.md) — arquitetura completa e alternativas avaliadas
- [Log de engenharia](docs/LOG_DE_ENGENHARIA.md) — registro de implementação, problemas reais encontrados e soluções

## Roadmap

- [x] API REST com testes automatizados e métricas
- [x] Containerização (Docker multi-stage, non-root)
- [x] Stack de observabilidade provisionada como código
- [x] Infraestrutura AWS via Terraform (rede, EC2, IAM, SSM)
- [x] Configuração automatizada do host via Ansible (aws_ssm, zero SSH)
- [ ] Pipeline de CI/CD (build, testes, segurança, deploy)
- [ ] Deploy automatizado com smoke test e rollback
