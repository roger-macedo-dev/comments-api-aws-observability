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

## Fase 3 — Observabilidade

### 3.1 — Prometheus: scrape + alerting

`observability/prometheus/prometheus.yml` — três jobs (`prometheus`, `comments-api`, `node_exporter`),
todos referenciados pelo **nome do serviço** no compose (`api:5000`, `node_exporter:9100`), resolvido
via DNS interno do Docker — mesmo princípio usado em toda a stack desde a Fase 2.

`observability/prometheus/alert-rules.yml` — 4 regras: `NodeExporterDown`, `MemoriaAlta` (herdadas
do lab anterior, já validadas lá), `APIDown` (equivalente pro job da API) e `TaxaErroAlta`:

```promql
sum(rate(http_requests_total{job="comments-api", status_code=~"5.."}[5m]))
/
sum(rate(http_requests_total{job="comments-api"}[5m])) > 0.1
```

`sum()` aplicado **antes** da divisão em ambos os lados — correção que evita o `NaN` por mismatch
de labels (lição já documentada no lab de observabilidade original).

### 3.2 — Alertmanager

Config mínima (`resolve_timeout: 5m`, receiver vazio) — alertas visíveis na UI; webhook
Discord/Slack fica como próximo passo, não implementado no escopo desta entrega.

### 3.3 — Promtail: mudança de estratégia vs. o lab anterior

No lab AWS, o Promtail lia arquivos de log do host (`/var/log/{messages,secure,...}`) porque a
aplicação rodava direto na instância via systemd — exigiu build customizado com suporte a journal
(limitação conhecida da imagem oficial). **Aqui o contexto é diferente**: tudo roda em containers
Docker, então a fonte correta é o **socket do Docker** (`docker_sd_configs` + `unix:///var/run/docker.sock`),
que descobre containers automaticamente e captura stdout/stderr de cada um. Não existe mais a
classe de problema do glob binário (`/var/log/*log` pegando `lastlog` e quebrando o parser) —
o modelo de coleta é outro. **Não precisamos do build customizado do Promtail neste projeto.**

`relabel_configs` extrai o nome do container como label `container`, pra filtrar por serviço
no Grafana/Loki.

### 3.4 — Grafana provisionado via YAML (fecha o gap do lab anterior)

No lab anterior, datasources e dashboard eram configurados **clicando na UI** — repetível a cada
vez que uma instância nova subia. Aqui, dois arquivos YAML resolvem isso permanentemente:

- `provisioning/datasources/datasources.yml` — Prometheus + Loki, `access: proxy` (o servidor
  Grafana fala com eles, não o browser do usuário — não expõe Prometheus/Loki diretamente),
  `editable: false` (força mudança via código, não via UI).
- `provisioning/dashboards/dashboards.yml` (provider) + `dashboards/json/comments-api-red.json`
  (dashboard) — 4 painéis: **Rate** (`sum(rate(...)) by (route)`), **Errors** (% de 5xx, mesma
  fórmula corrigida do alerta), **Duration** (`histogram_quantile(0.95, ...)` — p95, não média,
  pra não esconder outliers) e um painel extra de **SLO/error budget** (disponibilidade % na
  última hora, com thresholds visuais vermelho/amarelo/verde) — o diferencial sobre "só ter
  dashboard bonito" identificado na fase de design.

**Validado via API do Grafana (sem clicar em nada na UI):**
```bash
curl -s -u admin:<senha> http://localhost:3000/api/datasources   # → Prometheus, Loki
curl -s -u admin:<senha> http://localhost:3000/api/search         # → Comments API — RED
```
Confirma que o provisioning funcionou 100% automático desde o primeiro boot.

### 3.5 — docker-compose.yml expandido: +6 serviços

`node_exporter`, `prometheus` (porta 9091 externa — mesma decisão do lab, consistência entre
ambientes mesmo sem Cockpit aqui), `alertmanager` (9093), `loki` (sem porta publicada — só
Grafana/Promtail acessam via rede interna, decisão de segurança), `promtail` (monta o socket
Docker), `grafana` (3000).

Versões de imagem **fixadas** (`v2.55.1`, `3.2.1`, `11.3.1`), não `latest` — builds reproduzíveis.
Volumes de config montados `:ro` (read-only) — serviços leem, nunca escrevem config.

**Validado:** `docker compose up -d` — 10 containers no total, todos saudáveis. Prometheus com
3/3 targets `up` confirmado via `/api/v1/targets`.

### 3.6 — Bug real encontrado: pool do Postgres sem handler de erro derrubava a API

Durante o teste do ciclo de alerta (parar o Postgres pra gerar erros 5xx reais), a API **crashou**
em vez de responder com erro — o container reiniciou sozinho (`restart: unless-stopped` mascarou
o problema à primeira vista). Log do container mostrou stack trace de erro não tratado.

**Causa raiz:** o driver `pg` emite um evento `error` no objeto `Pool` quando perde conexão com
um client idle. Sem um listener registrado para esse evento, o Node.js trata como exceção não
capturada e **derruba o processo inteiro** — comportamento documentado do driver, não um bug do
driver em si, mas uma omissão nossa.

**Fix** em `app/src/db/pool.js`:
```javascript
pool.on('error', (err) => {
  console.error('Erro inesperado no pool do Postgres:', err.message);
});
```
mais `connectionTimeoutMillis: 3000` (sem isso, uma nova tentativa de conexão contra uma porta
fechada pode ficar pendurada indefinidamente — foi o que travou o terminal na primeira tentativa
de teste, antes do fix).

**Lição:** "matar o Postgres e ver o que acontece" não foi só validação do alerta — expôs uma
falha de robustez real que só aparece sob falha de dependência, exatamente o tipo de teste que
justifica existir. Corrigido, rebuildado, revalidado: com o fix, a mesma sequência de 20 requisições
com banco fora do ar termina rápido, loga o erro, **não derruba o container**.

### 3.7 — Ciclo completo de alerta validado (`inactive → pending → firing → resolved`)

Repetindo o método do lab anterior, mas agora contra a API real (não infraestrutura sintética):

1. `docker stop compose-postgres-1` + 20 requisições → todas retornam 500 (com o fix aplicado,
   sem travar nem derrubar a API).
2. Após ~2min (`for: 2m` da regra): `TaxaErroAlta -> firing`, confirmado também no Alertmanager
   via `/api/v2/alerts` (`state: active`).
3. `APIDown` permaneceu `inactive` durante todo o incidente — comportamento correto: o `up` do
   Prometheus reflete se `/metrics` responde (o processo continuou vivo), não se as dependências
   do processo estão saudáveis. É `TaxaErroAlta` que existe justamente para cobrir esse cenário
   — distinção importante entre "processo vivo" e "processo saudável".
4. `docker start compose-postgres-1` + tráfego saudável → após a janela de 5min do `rate()`
   "esvaziar" os erros antigos, `TaxaErroAlta -> inactive` de novo.

### 3.8 — Loki: validação via rede interna, não pelo host

Loki não tem porta publicada no compose (decisão de segurança — só precisa ser alcançado por
Grafana/Promtail, ambos na rede interna). Testar com `curl localhost:3100` do host falha
(`Conexão recusada`) por design, não por erro — a validação correta é de dentro da rede:
```bash
docker exec compose-promtail-1 wget -qO- http://loki:3100/loki/api/v1/label/container/values
```
Confirmado: logs de todos os 9 containers indexados e rotulados corretamente.

## Fase 3 — CONCLUÍDA ✅

- [x] Prometheus — scrape de API + node_exporter, 4 regras de alerta
- [x] Alertmanager — config mínima, ciclo completo validado
- [x] Grafana — provisionamento 100% automático (datasources + dashboard RED/SLO), zero clique
- [x] Loki + Promtail — coleta via socket Docker, logs de todos os serviços confirmados
- [x] Bug de robustez real encontrado e corrigido (pool sem handler de erro)
- [x] docker-compose.yml com 10 serviços, todos saudáveis

## Fase 4 — Terraform (provisionamento AWS)

### 4.1 — Usuário IAM dedicado

Criado `terraform-comments-api` (sem acesso ao console web, só CLI/API), separado do
usuário pessoal da conta AWS — se a credencial vazar, o dano fica limitado a este escopo.

**Trade-off consciente de permissão:** `PowerUserAccess` + `IAMFullAccess` (não uma policy
custom mínima). Justificativa: conta pessoal dedicada a este projeto, `IAMFullAccess` é
necessário porque o Terraform **cria roles IAM** (para o EC2 usar SSM). Documentado como
decisão pragmática — em ambiente corporativo real, a evolução seria uma policy JSON
escopada às ações exatas usadas.

Credenciais configuradas via `aws configure` na VM (nunca coladas em chat/log — ficam em
`~/.aws/credentials`, fora do repo). Validado com `aws sts get-caller-identity`.

### 4.2 — Bootstrap do backend remoto (S3 + lock nativo)

Problema clássico: o bucket S3 do state precisa existir **antes** de qualquer `terraform
init` usá-lo como backend — referência circular se tentado via Terraform. Resolvido com
bootstrap único via AWS CLI (fora do Terraform principal):

```bash
aws s3api create-bucket --bucket comments-api-tfstate-<account-id> --region us-east-2 ...
aws s3api put-bucket-versioning ...    # histórico de versões do state
aws s3api put-bucket-encryption ...    # AES256 em repouso
```

Nome do bucket inclui o **Account ID** — nomes de bucket S3 são globais únicos entre todas
as contas AWS do mundo.

**Decisão corrigida em tempo real:** o plano original prevejia lock via tabela DynamoDB
(`dynamodb_table` no backend), mas o Terraform 1.15.8 instalado já **deprecia** esse
parâmetro — substituído por `use_lockfile = true`, lock nativo via escrita condicional no
próprio S3, sem precisar de tabela separada. Adotamos o método atual, removemos a tabela
DynamoDB criada por engano no primeiro bootstrap (`aws dynamodb delete-table`) — versão de
ferramenta mais nova que a documentação/plano original previa; resolvido ajustando ao
estado real da ferramenta, não forçando o método antigo.

### 4.3 — Divergência resolvida: subnet única em vez de pública+privada

O spec original desenhava nginx em subnet pública e API+Postgres em subnet privada — mas
isso pressupõe **hosts separados**. A Fase 2 já havia consolidado tudo num único
`docker-compose.yml` (decisão ADR #2, "1 EC2 + Docker Compose") — não é possível colocar
containers do mesmo compose em subnets diferentes, subnet é propriedade da instância, não
do container.

**Resolução:** uma única subnet pública. A segregação real de fato já vem de outro lugar —
o próprio compose (só `nginx` publica porta pro host; `api`/`postgres`/observabilidade só
existem na rede interna `backend` do Docker) e do Security Group (só porta 80 liberada).
Subnet privada seria redundante com isolamento que já existe. Bônus: elimina a necessidade
de **NAT Gateway** (~$0,045/hora + tráfego, item clássico de fatura AWS surpresa) — subnet
pública com Internet Gateway já dá saída sem esse custo contínuo.

Consequência: variáveis `private_subnet_cidr` e `my_ip` (pensada para regra de SSH de
fallback) removidas do `variables.tf` antes mesmo de serem usadas — YAGNI, sem SSH não
existe cenário que precise delas.

### 4.4 — Arquivos Terraform

| Arquivo | Recursos |
|---|---|
| `versions.tf` | provider AWS + random, backend S3 com lock nativo |
| `variables.tf` | `environment` (sem default — força escolha explícita), `instance_type`, CIDRs, `use_rds` |
| `network.tf` | VPC, subnet pública, Internet Gateway, route table |
| `security.tf` | 1 Security Group — ingress só porta 80, egress liberado total |
| `iam.tf` | role da instância (`AmazonSSMManagedInstanceCore` + policy custom de leitura do Parameter Store escopada por `/comments-api/${environment}/*`), instance profile |
| `secrets.tf` | `random_password` (senha DB + Grafana) + `aws_ssm_parameter` (`SecureString` para senhas, `String` para valores não sensíveis) |
| `ec2.tf` | `data "aws_ami"` (Amazon Linux 2023 mais recente, dinâmico) + `aws_instance` — **sem `key_name`**, nenhuma chave SSH associada |
| `outputs.tf` | `instance_id`, `public_ip`, `environment` — contrato para Ansible/pipeline lerem depois |
| `envs/dev.tfvars` | valores do ambiente dev |

Pontos de design que reforçam a decisão #7 (SSM, sem SSH):
- Nenhuma regra de ingress para porta 22 em lugar nenhum do código.
- `aws_instance.app` não declara `key_name` — não existe, fisicamente, uma chave SSH
  associada a essa instância.
- IAM policy de leitura do Parameter Store escopada por ambiente — instância de dev
  comprometida não alcança segredos de prod, mesmo o usuário Terraform tendo permissão ampla.

### 4.5 — Correções durante o `terraform plan`/`apply`

**Arquivo esquecido:** `secrets.tf` foi instruído mas não criado na primeira passada — o
`terraform plan` mostrou só 11 recursos em vez dos 17 esperados. Detectado comparando a
contagem esperada com o plano real, confirmado com `ls *.tf`, corrigido recriando o arquivo
antes de aplicar. **Lição:** sempre conferir a contagem de recursos do plano contra o que
se espera, não só rodar `apply` cegamente.

**AMI exige disco maior:** `terraform apply` falhou na criação da instância —
`InvalidBlockDeviceMapping: Volume of size 20GB is smaller than snapshot ..., expect size
>= 30GB`. A AMI mais recente do Amazon Linux 2023 mudou o tamanho do snapshot-base desde
que o spec original previu 20GB (mesmo valor usado no lab anterior, mas para volume raiz
mínimo, não para builds locais). Corrigido para `volume_size = 30` — ainda dentro do free
tier de EBS (30GB grátis/mês). Terraform aplicou de forma incremental: como os outros 16
recursos já existiam no state, só a instância entrou no segundo `apply`.

### 4.6 — Validação end-to-end

```bash
terraform apply -var-file=envs/dev.tfvars   # 17 recursos criados
aws ssm describe-instance-information ...    # PingStatus: Online
aws ssm start-session --target i-0af... ...  # shell dentro da EC2, sem SSH
```

Faltava o `session-manager-plugin` na VM de controle (binário auxiliar que a AWS CLI invoca
para o streaming da sessão — não tem pacote `dnf` oficial, só RPM direto da Amazon, mesma
situação da AWS CLI v2). Instalado, sessão aberta com sucesso: `whoami` → `ssm-user`,
`/etc/os-release` confirma Amazon Linux 2023 real, na nuvem, acessado sem chave e sem porta
22 aberta em lugar nenhum.

## Fase 4 — CONCLUÍDA ✅

- [x] Usuário IAM dedicado, credenciais fora do repo
- [x] Backend remoto S3 com lock nativo, versionamento e criptografia
- [x] VPC + subnet pública + IGW + route table
- [x] Security Group — só porta 80, sem SSH
- [x] IAM role da instância — SSM + leitura de Parameter Store escopada por ambiente
- [x] Segredos gerados pelo Terraform, armazenados como `SecureString` no SSM
- [x] EC2 provisionada — Amazon Linux 2023, sem key pair
- [x] Acesso validado via SSM Session Manager, zero SSH

Próxima fase: Ansible — configuração da instância (Docker, deploy da stack via compose,
leitura de segredos do SSM) — Fase 5.

**Lembrete de custo:** instância `dev` ficará rodando até a Fase 5 estar pronta para
configurá-la; ao final da sessão, `terraform destroy -var-file=envs/dev.tfvars` se não for
usar nas próximas horas.
