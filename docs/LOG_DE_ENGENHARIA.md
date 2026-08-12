# Log de Engenharia — Comments API + Infra AWS

> Registro cronológico de execução: comandos rodados, decisões tomadas no momento,
> problemas reais encontrados e como foram resolvidos. Complementa o spec de design
> (`docs/superpowers/specs/`) com o rastro de implementação — prova de processo,
> não só de resultado.

## Fase 0 — Preparando a estação de controle (VM)

### 0.1 — Por que uma VM dedicada?

Decisão: criar `Control Node Desafio` separado do lab antigo.

**Por quê:**
- Isolamento — nada deste projeto mistura com o lab de observabilidade anterior.
- Reprodutibilidade — se quebrar, recria do zero, não carrega lixo de outro projeto.
- Defesa na entrevista — "montei o ambiente do zero" é argumento mais forte que "reaproveitei uma VM velha".

**Specs escolhidas:** AlmaLinux 9, 2 vCPU, 4GB RAM, 30GB disco.
- AlmaLinux = mesma família do RHEL, terreno que você já domina (RHCE), e combina com Amazon Linux (RHEL-like) que será o alvo na AWS — menos atrito de sintaxe entre estação de controle e servidor remoto.
- 4GB RAM porque a stack de observabilidade completa (Prometheus+Grafana+Loki+Alertmanager) roda local antes de ir pra nuvem.
- 30GB disco — lição aprendida no lab anterior: build de imagens Docker esgota disco pequeno rápido.

### 0.2 — Instalação mínima (Server minimal)

Escolhida "Instalações Mínimas" — só o essencial, sem GUI, sem serviços de rede desnecessários.
**Por quê:** menor superfície de ataque, mais rápido, você instala exatamente o que precisa e sabe o que tem na máquina (nada de surpresa).

### 0.3 — Usuário `rmacedo`

Convenção corporativa: primeira letra do nome + sobrenome.
**Por quê:** contas nomeadas por pessoa permitem auditoria real ("quem fez o quê"). Contas genéricas tipo `deployer`/`ansible` virão depois, só pra automação, sem login interativo — separando claramente humano de robô.

### 0.4 — Rede: NAT + Host-only (dois adaptadores)

Problema: uma rede só não resolve as duas necessidades.

| Rede | Dá internet? | SSH do Windows? |
|---|---|---|
| NAT sozinho | sim | não (VM fica atrás do NAT) |
| Host-only sozinho | **não** (sem gateway pra internet) | sim, IP fixo |
| NAT + Host-only | sim (via adaptador 1) | sim (via adaptador 2) |

Resultado: Adaptador 1 = NAT (saída internet — dnf, npm, git, AWS). Adaptador 2 = Host-only (`vboxnet0`), IP fixo `192.168.56.20`, pra SSH estável do Windows.

**Comando de fixação do IP:**
```bash
nmcli con show                                              # lista conexões, acha o nome certo
sudo nmcli con mod "Conexão cabeada 1" ipv4.addresses 192.168.56.20/24
sudo nmcli con mod "Conexão cabeada 1" ipv4.method manual    # de DHCP pra manual
sudo nmcli con up "Conexão cabeada 1"                        # aplica sem reiniciar
```
`nmcli` é a ferramenta oficial do NetworkManager em RHEL/AlmaLinux/Amazon Linux — editar `ifcfg-*` na mão é jeito antigo, `nmcli` é o padrão atual.

### 0.5 — Bug do driver de rede (e1000 Tx Unit Hang)

Sintoma: boot com spam infinito `e1000 ... Detected Tx Unit Hang` na interface `enp0s8`.
**Causa:** bug conhecido de emulação da placa Intel PRO/1000 (e1000) no VirtualBox — não é erro seu, é a placa virtual.
**Fix:** trocar tipo de placa pra **virtio-net** (Configurações → Rede → Avançado → Tipo de placa → Paravirtualized Network) em cada adaptador.
**Por quê funciona:** virtio-net é paravirtualizado — o guest sabe que roda em VM e fala direto com o hypervisor, sem emular hardware físico. Mais estável, mais rápido, sem esse bug.

### 0.6 — Ferramentas base

```bash
sudo dnf update -y
sudo dnf install -y git vim curl wget unzip tar dnf-plugins-core
```
- `dnf update -y` — atualiza pacotes do sistema, `-y` confirma automático.
- `dnf-plugins-core` — traz o `dnf config-manager`, necessário pra adicionar repositórios de terceiros (Docker, Terraform) nos próximos passos.

### 0.7 — Docker CE

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker rmacedo
```
- AlmaLinux usa o repo "centos" do Docker (compatibilidade binária RHEL-family).
- `docker-ce` = engine; `containerd.io` = runtime de containers por baixo; `docker-compose-plugin` = `docker compose` (v2, integrado ao CLI, substitui o antigo `docker-compose` standalone).
- `systemctl enable --now` = habilita no boot **e** inicia agora, num comando só.
- `usermod -aG docker rmacedo` — adiciona o usuário ao grupo `docker`, pra rodar `docker` sem `sudo` toda vez. Exige relogar pra grupo valer (grupos são lidos na criação da sessão).

**Validado:** `docker run hello-world` — puxou imagem do Docker Hub, rodou container, imprimiu mensagem. Confirma engine + acesso sem sudo + rede funcionando.

### 0.8 — Node.js 20 LTS

```bash
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo dnf install -y nodejs
```
- Repo padrão do AlmaLinux tem Node desatualizado; script da NodeSource adiciona repo com Node 20 (LTS — suportado até 2026, versão certa pra produção).
- `curl | sudo bash` = confiar no instalador oficial do fornecedor; prática comum mas vale saber que é isso que acontece.
- Resultado: `node v20.20.2`, `npm 10.8.2`.

### 0.9 — Terraform (repo oficial HashiCorp)

```bash
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform
```
- Mesmo padrão do Docker: repo oficial → `dnf install` → atualiza depois via `dnf update`, sem binário solto sem gerenciamento.
- Resultado: `Terraform v1.15.8`.

### 0.10 — Ansible (ansible-core, enxuto)

```bash
sudo dnf install -y ansible-core
```
- `ansible-core` (não o pacote `ansible` completo) = motor + módulos essenciais, sem centenas de coleções de terceiros que raramente usamos. Coleções específicas (`community.docker`, `amazon.aws`) instalamos depois via `ansible-galaxy`, sob demanda.
- Resultado: `ansible-core 2.14.18`, Python 3.9, `libyaml=True` (parser YAML em C — mais rápido em playbooks grandes).

### 0.11 — AWS CLI v2 (instalador oficial, sem repo dnf)

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip
sudo ./aws/install
```
- AWS não distribui CLI v2 via repositório `dnf` — só via `.zip` com instalador próprio, diferente de Docker/Terraform.
- Baixado em `/tmp` (não polui `$HOME`, some no reboot).
- Credenciais **ainda não configuradas** — fica pra Fase 4 (Terraform), quando criarmos o usuário IAM dedicado.
- Resultado: `aws-cli/2.36.21`.

## Fase 0 — CONCLUÍDA ✅

- [x] git, vim, ferramentas base
- [x] Docker CE
- [x] Node.js 20 LTS + npm
- [x] Terraform 1.15.8
- [x] Ansible core 2.14
- [x] AWS CLI v2

Estação de controle `ControlNode` (192.168.56.20) pronta. Próxima fase: API Node/Express + Postgres rodando local (Fase 1).

## Fase 1 — API Node/Express + Postgres (local)

### 1.1 — Estrutura do repo

Repo movido pra dentro da VM: `~/desafio` (não mais no Windows — as ferramentas de infra rodam aqui).

```bash
mkdir -p ~/desafio/app/src/{routes,db}
git init
git branch -m master main    # alinha com o pipeline: main→prod, develop→dev
```

`app/src/routes/` — cada rota HTTP em arquivo próprio (isolamento de responsabilidade).
`app/src/db/` — conexão e migration do Postgres, isolados (trocar de banco = mexer só aqui).

### 1.2 — package.json e dependências

```bash
npm init -y
npm install express pg dotenv prom-client
npm install --save-dev jest supertest nodemon
```

| Pacote | Papel |
|---|---|
| `express` | framework HTTP |
| `pg` | driver PostgreSQL (pool de conexões) |
| `dotenv` | carrega `.env` — 12-factor: config fora do código |
| `prom-client` | métricas formato Prometheus |
| `jest` + `supertest` | testes — supertest chama o Express em memória, sem porta real |
| `nodemon` | reload automático em dev |

### 1.3 — `src/db/pool.js` — conexão

```javascript
require('dotenv').config();
const { Pool } = require('pg');
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
module.exports = pool;
```

**Pool** (não conexão única) — reutiliza conexões, não abre/fecha a cada query (caro).
`connectionString` via env var — mesma imagem roda em dev/test/prod trocando só a variável.

**Armadilha caída:** `require('dotenv').config()` só estava no `server.js`. Rodar `migrate.js`
sozinho (`node src/db/migrate.js`) não carregava `.env` → `DATABASE_URL` undefined → erro
confuso do driver (`SASL: client password must be a string`). Corrigido movendo o
`dotenv.config()` pro `pool.js`, que é o módulo compartilhado por tudo que toca banco.
**Lição:** ponto único de carregamento de config, não espalhar em cada entrypoint.

### 1.4 — `src/db/migrate.js` — schema idempotente

```sql
CREATE TABLE IF NOT EXISTS comments (
  id SERIAL PRIMARY KEY,
  email TEXT NOT NULL,
  comment TEXT NOT NULL,
  content_id INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_comments_content_id ON comments (content_id);
```

`IF NOT EXISTS` — idempotente, roda em todo boot do container sem erro.
Índice em `content_id` — rota de listagem filtra por matéria; sem índice, table scan completo.
`TIMESTAMPTZ` — guarda timezone, evita ambiguidade servidor↔cliente.

Padrão usado em `migrate.js` e `server.js`: `if (require.main === module)` — arquivo funciona
tanto importado (usado nos testes) quanto executado direto (`node arquivo.js`).

### 1.5 — `src/metrics.js` — RED method

- **Rate** → `http_requests_total` (Counter, labels method/route/status_code)
- **Errors** → mesmo counter, filtra `status_code=~"5.."` no PromQL
- **Duration** → `http_request_duration_seconds` (Histogram com buckets — permite p50/p95/p99, não só média)
- `collectDefaultMetrics` — métricas de processo Node de graça (heap, GC, event loop)
- **Cuidado com cardinalidade:** middleware usa `req.route.path` (`/comment/list/:contentId`),
  não `req.path` (`/comment/list/42`) — senão cada content_id vira série nova no Prometheus.

### 1.6 — `src/routes/health.js`

`GET /health` roda `SELECT 1` no Postgres de verdade — não é health check "sempre 200".
Retorna `503` se banco cair. Usado em 3 lugares do design: smoke-test do deploy (Fase 7),
healthcheck do compose (Fase 2), futuro target-group de load balancer (evolução).

### 1.7 — `src/routes/comments.js` — core da API

Rotas exatas do enunciado: `POST /api/comment/new`, `GET /api/comment/list/:content_id`.

- Validação em camada antes do banco: email (regex), comment não-vazio, content_id inteiro positivo → `400` claro.
- **Queries parametrizadas** (`$1, $2, $3`) — defesa contra SQL injection; nunca concatenar string de usuário na query.
- `RETURNING *` — pega a linha inserida na mesma query, sem SELECT extra.
- Erros inesperados → `500` genérico, sem vazar stack trace pro cliente.

### 1.8 — `src/server.js` — bootstrap

```javascript
require('dotenv').config();
app.use(express.json());        // parse de JSON no body
app.use(metricsMiddleware);     // instrumenta tudo que passa
app.use('/', healthRouter);     // GET /health
app.use('/api', commentsRouter);// prefixo /api nas rotas de comentário
app.get('/metrics', ...);       // fora do prefixo /api — convenção Prometheus
```

### 1.9 — Postgres local pra testar (container avulso, descartável)

```bash
docker run -d --name postgres-dev \
  -e POSTGRES_USER=comments_user -e POSTGRES_PASSWORD=comments_pass -e POSTGRES_DB=comments_db \
  -p 5432:5432 postgres:16-alpine
```

Imagem oficial cria usuário/db automaticamente no primeiro boot a partir das env vars.
`alpine` = imagem mínima. Isso **não** é o setup definitivo (vem no compose, Fase 2) —
só validação rápida ponta a ponta.

### 1.10 — Validação manual (bateu com o enunciado)

```bash
curl -sv host/api/comment/new -X POST -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","comment":"first post!","content_id":1}'
curl -s host/api/comment/list/1
```
→ `201 Created`, id sequencial, listagem em ordem cronológica. `/metrics` confirmado com
contadores reais por rota/método/status.

### 1.11 — Testes automatizados (Jest + Supertest)

`tests/comments.test.js` — 7 testes: caminho feliz (criar+listar), cada validação (400 em
email/comment/content_id inválidos), edge case (lista vazia). `beforeAll` roda migration,
`afterAll` limpa tabela e fecha pool (`pool.end()` — sem isso Jest trava esperando handle
aberto).

```json
"scripts": {
  "test": "jest --detectOpenHandles --forceExit"
}
```
- `--detectOpenHandles` — acusa conexão/timer que ficou aberto (vazamento).
- `--forceExit` — força saída mesmo com handle assíncrono pendurado do driver `pg`.

**Armadilha caída:** editar `package.json` na mão trocou uma linha em vez de adicionar,
JSON ficou inválido (faltou vírgula) → `npm error EJSONPARSE`. Resolvido reescrevendo o
arquivo inteiro via heredoc (`cat > arquivo << 'EOF'`) em vez de editar trecho a trecho —
mais seguro pra arquivos estruturados curtos.

**Resultado:** `7 passed, 7 total`.

## Fase 1 — CONCLUÍDA ✅

- [x] Estrutura do projeto + git
- [x] Express + rotas (comment/new, comment/list, health, metrics)
- [x] Postgres local + migration idempotente
- [x] Validação manual (curl) batendo com o enunciado
- [x] Testes automatizados (7/7 passando)

## Fase 2 — Dockerfile + docker-compose

### 2.1 — Publicação do repositório no GitHub

Repo criado como `comments-api-aws-observability` (público) — nome descreve stack e
arquitetura, sem referência à origem do desafio (portfólio deve comunicar tecnologia,
não contexto de onde surgiu). Autenticação via chave SSH dedicada (`~/.ssh/id_ed25519_github`),
não a chave pessoal do lab — isola credenciais por finalidade.

```bash
ssh-keygen -t ed25519 -C "<email>" -f ~/.ssh/id_ed25519_github -N ""
# ~/.ssh/config: Host github.com → IdentityFile específico
git remote add origin git@github.com:<user>/comments-api-aws-observability.git
git push -u origin main
```

Documentação também organizada em três papéis distintos, sem duplicar conteúdo:
- **spec de design** (`docs/2026-08-12-comments-api-design.md`) — arquitetura completa, ADRs detalhados
- **`docs/DECISOES.md`** — resumo executivo (tabela), leitura rápida pra quem avalia
- **`docs/LOG_DE_ENGENHARIA.md`** (este arquivo) — rastro de execução, comando a comando

### 2.2 — Dockerfile multi-stage

```dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src/ ./src/

FROM node:20-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY --from=build --chown=app:app /app/node_modules ./node_modules
COPY --from=build --chown=app:app /app/src ./src
COPY --chown=app:app package.json ./
USER app
ENV NODE_ENV=production
EXPOSE 5000
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD node -e "require('http').get('http://localhost:5000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"
CMD ["node", "src/server.js"]
```

- **Multi-stage**: stage final não carrega ferramentas de build, só `node_modules` + `src` já prontos. Imagem final: **203MB total / 50.5MB de conteúdo próprio** (resto é a base `node:20-alpine`).
- `npm ci --omit=dev` — build reproduzível via `package-lock.json`, sem devDependencies em produção.
- **Non-root** (`USER app`) — princípio de segurança do spec: comprometer a API não dá root no container.
- `HEALTHCHECK` via `node -e` (não `curl`/`wget`) — imagem alpine minimal não tem esses binários; evita instalar pacote extra só pro healthcheck.
- `.dockerignore` — replica o `.gitignore` pro contexto de build (`node_modules`, `.env`, `tests`, `.git`).

**Validado:** build limpo em ~20s, container isolado testado com `--add-host=host.docker.internal:host-gateway`
(mesma técnica documentada no lab de observabilidade anterior — container precisa desse hostname especial
pra alcançar serviço publicado no host; `localhost` dentro do container aponta pro próprio container).

### 2.3 — docker-compose.yml (stack completa)

Serviços: `postgres`, `api`, `migrate` (job único, `restart: "no"`), `nginx` (único componente
com porta publicada no host — `api` e `postgres` só na rede interna `backend`).

Pontos de design:
- **Rede nomeada do compose** — containers se resolvem pelo **nome do serviço** (`api`, `postgres`)
  via DNS interno do Docker. Não precisa mais de `host.docker.internal` aqui — essa técnica é só
  pra container↔host; dentro do mesmo compose é container↔container.
- `depends_on: condition: service_healthy` — API só sobe depois do Postgres responder `pg_isready`,
  não só "container criado". Evita corrida de inicialização.
- Serviço `migrate` separado da API — roda a migration como tarefa pontual (sobe, executa, morre),
  não como processo de vida longa.
- `.env` do compose separado do `.env` da API — variáveis de infraestrutura (usuário/senha do banco,
  nome da imagem) versus variáveis da aplicação; ambos seguem o padrão `.env` real + `.env.example`
  documentado + `.gitignore`.

nginx como reverse proxy (`proxy_pass http://api:5000` — de novo, nome do serviço, não IP),
repassando headers reais (`X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`) — sem isso a API
veria toda requisição como vinda do próprio nginx.

**Validado:** `docker compose up -d` — todos os 4 serviços saudáveis, fluxo completo do enunciado
testado **através do nginx** (porta 80, não mais direto na API): `POST /api/comment/new` → `201`,
`GET /api/comment/list/1` → lista persistida, `GET /health` → `200` confirmando nginx→API→Postgres.

## Fase 2 — CONCLUÍDA ✅

- [x] Dockerfile multi-stage, non-root, imagem enxuta (203MB)
- [x] docker-compose.yml — API + Postgres + nginx + migration job
- [x] Rede interna do Docker, só nginx exposto (alinhado ao spec de segurança)
- [x] Validado ponta a ponta via porta 80 (nginx)
- [x] Repositório publicado no GitHub como portfólio

Próxima fase: configs de observabilidade (Prometheus, Grafana provisionado, Loki/Promtail, Alertmanager) — Fase 3.
