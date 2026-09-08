# Comments API — AWS + Observability

[![CI](https://github.com/roger-macedo-dev/comments-api-aws-observability/actions/workflows/ci.yml/badge.svg)](https://github.com/roger-macedo-dev/comments-api-aws-observability/actions/workflows/ci.yml)
[![CD](https://github.com/roger-macedo-dev/comments-api-aws-observability/actions/workflows/cd.yml/badge.svg)](https://github.com/roger-macedo-dev/comments-api-aws-observability/actions/workflows/cd.yml)
[![Docs](https://github.com/roger-macedo-dev/comments-api-aws-observability/actions/workflows/docs.yml/badge.svg)](https://roger-macedo-dev.github.io/comments-api-aws-observability/)

API REST de comentários com infraestrutura como código, containerização e stack de
observabilidade completa. Comentários são associados a um `content_id` (matéria/conteúdo);
a API permite inserção e listagem cronológica por conteúdo.

## Arquitetura

```
GitHub ─┐
         │  CI: testes + segurança (npm audit, Trivy no código e na imagem)
         │      + build/push (GHCR)
         │  CD: Ansible (aws_ssm) → smoke test → rollback automático se falhar
         │      dev automático · prod com aprovação · autenticação por OIDC
         ▼
AWS · VPC (subnet pública única)
  EC2 (Amazon Linux 2023, sem SSH — acesso via IAM/SSM Session Manager)
  │
  ├── nginx (porta 80, único componente exposto)
  │     └── proxy → comments-api
  ├── comments-api (Node/Express) ── postgres (container, ou RDS via toggle)
  │                                    └── postgres_exporter
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
| Configuração | Ansible (`aws_ssm`, zero SSH) |
| CI/CD | GitHub Actions (testes, segurança, build/push GHCR, deploy, OIDC) |
| Observabilidade | Prometheus, Grafana, Loki, Grafana Alloy, Alertmanager, node/postgres exporter |
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

Datasources e dashboard são provisionados automaticamente via código
(`observability/grafana/provisioning/`) — nenhuma configuração manual na interface.
Destruir e recriar o ambiente devolve tudo, e mudança de painel passa por revisão de
código como qualquer outra alteração.

O dashboard cobre quatro camadas:

| Seção | Conteúdo |
|---|---|
| Aplicação | método **RED** (Rate, Errors, Duration) e painel de SLO/error budget |
| Infraestrutura | CPU, memória, disco, carga e rede da instância |
| Logs | log da aplicação e filtro de erros em qualquer serviço, via Loki |
| Banco de dados | conexões, transações, eficiência de cache, deadlocks, tamanho e volume de linhas |

Alertas ativos: indisponibilidade de nodo (`NodeExporterDown`), memória alta
(`MemoriaAlta`), API fora do ar (`APIDown`) e taxa de erro elevada (`TaxaErroAlta`,
baseada nas métricas HTTP da própria API) — todos **reativos** (disparam quando o
problema já está acontecendo).

Além desses, um alerta **preditivo** (`MemoriaVaiEstourarPrevisao`) usa `predict_linear`
para extrapolar a tendência de uso de memória dos últimos 30min e avisar com ~1h de
antecedência se o consumo vai ultrapassar 90%, antes do problema se manifestar —
mesmo princípio usado por ferramentas comerciais de análise preditiva de capacidade
(ex: VMware Aria Operations), aqui implementado só com Prometheus nativo.

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

**Ordem de criação.** O provedor OIDC é único por conta AWS e é criado pelo workspace
que tiver `criar_provedor_oidc = true` — hoje, `dev`. Portanto: suba `dev` antes de
`prod`. Se for subir apenas `prod`, ligue a flag no `envs/prod.tfvars`, senão a role
apontará para um provedor inexistente e o pipeline falhará com `AccessDenied` em
`sts:AssumeRoleWithWebIdentity` — erro que não menciona o provedor.

Vale como regra: **dev sobe primeiro, prod é destruído primeiro.** A dependência é a
mesma nos dois sentidos, e a ordem se inverte.

## Configuração e deploy

Configuração do host e deploy da stack via Ansible, usando o plugin de conexão `aws_ssm`
(sem SSH em nenhum momento — mesmo caminho de acesso do provisionamento):

```bash
cd ansible
ansible-playbook -i inventory/dev.aws_ec2.yml site.yml
```

Em desenvolvimento esse mesmo playbook roda automaticamente via GitHub Actions
(`cd.yml`) a cada CI verde na `main`, puxando a imagem recém-publicada no GHCR. Em
produção, o deploy é sempre explícito e depende de aprovação — ver a seguir.

### Ambientes

Dev e prod usam o mesmo workflow reutilizável de deploy — uma cópia só, para que
produção não divirja do caminho já exercitado em dev. O que muda é a configuração:

| | dev | prod |
|---|---|---|
| Disparo | automático, a cada CI verde na `main` | manual, com ambiente escolhido |
| Aprovação | não exige | revisor obrigatório no Environment |
| Credencial do pipeline | role assumida via OIDC, restrita a `dev` | role assumida via OIDC, restrita a `prod` |
| Segredos | `/comments-api/dev/*` | `/comments-api/prod/*` |

O gate não está no YAML — está na regra de proteção do Environment, na configuração
do repositório. YAML qualquer um altera num pull request; a regra de proteção, não.

```bash
gh workflow run cd.yml -f ambiente=prod -f image_tag=<sha>
```

O job fica pendente até alguém aprovar. Em um time, a configuração adequada é
`prevent_self_review`: quem dispara o deploy não deveria ser quem aprova.

### Verificação e rollback

Depois de implantar, o pipeline exercita o caminho completo — nginx, aplicação e
banco — antes de considerar o deploy bem-sucedido. `docker compose up` retornar zero
não significa que a aplicação subiu: container que inicia e morre em seguida passaria
como sucesso.

Se a verificação falhar, ou se o próprio deploy falhar, a versão anterior é
reimplantada automaticamente e o job termina em erro — deploy revertido não é deploy
bem-sucedido. A imagem em produção fica registrada no Parameter Store, fora do host,
de modo que a informação sobrevive à instância ser recriada.

O deploy manual aceita uma tag específica, o que permite reimplantar qualquer versão
já publicada:

```bash
gh workflow run cd.yml -f ambiente=dev -f image_tag=<sha>
```

### Ordem de destruição

Destrua **produção antes de desenvolvimento**:

| passo | comando |
|---|---|
| 1 | `terraform workspace select prod && terraform destroy -var-file=envs/prod.tfvars` |
| 2 | `terraform workspace select dev && terraform destroy -var-file=envs/dev.tfvars` |

O provedor OIDC é único por conta AWS e pertence ao estado de `dev`; a role de
`prod` depende dele. Destruir `dev` primeiro deixa produção de pé mas sem
conseguir autenticar o pipeline — e o erro (`AccessDenied` em
`sts:AssumeRoleWithWebIdentity`) não menciona o provedor.

Para manter apenas produção no ar, ligue `criar_provedor_oidc` no tfvars de
`prod` e desligue no de `dev` antes de destruir `dev`.

Depois de destruir, confira que nada ficou cobrando — apagar a instância nem
sempre apaga os volumes:

```bash
aws ec2 describe-instances --region us-east-2 \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text

aws ec2 describe-volumes --region us-east-2 \
  --query "Volumes[].[VolumeId,State,Size]" --output text
```

### Segurança do pipeline

A verificação acontece em três pontos, e cada um cobre o que os outros não veem:

| ponto | cobre |
|---|---|
| `npm audit --audit-level=moderate --omit=dev` | dependências de produção declaradas |
| Trivy no filesystem | código e dependências do diretório da aplicação |
| Trivy na **imagem**, antes da publicação | tudo acima, mais o sistema operacional da base e o ferramental que vem com ela |

O terceiro é o que impede uma imagem com vulnerabilidade alta corrigível de
chegar ao registry — e foi acrescentado depois de uma revisão constatar que a
varredura existente olhava o diretório, não o artefato entregue. Na estreia,
reprovou o build com seis vulnerabilidades altas, nenhuma delas no código do
projeto.

A imagem final não carrega npm, npx, corepack nem yarn: a aplicação executa
`node src/server.js`, e o ferramental serve apenas ao estágio de construção. O
build **verifica** essa ausência e falha se ela deixar de valer.

## Documentação

Também publicada como site navegável, com busca:
**[roger-macedo-dev.github.io/comments-api-aws-observability](https://roger-macedo-dev.github.io/comments-api-aws-observability/)**

O site é gerado destes mesmos arquivos a cada push — não existe conteúdo que
viva apenas lá, então não há segunda fonte para divergir do código.

- [Decisões de arquitetura](docs/DECISOES.md) — resumo executivo das escolhas técnicas
- [Design detalhado](docs/2026-08-12-comments-api-design.md) — arquitetura completa e alternativas avaliadas
- [Log de engenharia](docs/LOG_DE_ENGENHARIA.md) — registro de implementação, problemas reais encontrados e soluções

## Roadmap

- [x] API REST com testes automatizados e métricas
- [x] Containerização (Docker multi-stage, non-root)
- [x] Stack de observabilidade provisionada como código
- [x] Infraestrutura AWS via Terraform (rede, EC2, IAM, SSM)
- [x] Configuração automatizada do host via Ansible (aws_ssm, zero SSH)
- [x] Pipeline de CI (build, testes, segurança, publicação da imagem)
- [x] Deploy automático em dev via CI/CD (Ansible/aws_ssm, pull do GHCR)
- [x] Smoke test end-to-end com rollback automático para a versão anterior
- [x] Gate manual de aprovação para produção (Environment com revisor obrigatório)
- [x] OIDC no lugar de chave de acesso estática no pipeline
