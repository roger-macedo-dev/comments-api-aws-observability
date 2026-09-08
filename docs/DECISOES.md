# Decisões de Arquitetura — Comments API + Infra AWS

Resumo executivo das decisões técnicas do projeto. Detalhamento completo em
[`docs/2026-08-12-comments-api-design.md`](2026-08-12-comments-api-design.md);
rastro de execução em [`docs/LOG_DE_ENGENHARIA.md`](LOG_DE_ENGENHARIA.md).

## Contexto do problema

API REST de comentários (inserção e listagem por matéria), com infraestrutura e
pipeline de deploy automatizados, com ambientes isolados na AWS. O desafio previa
três ambientes (dev/test/prod); estão provisionados `dev` e `prod`, e `test` segue
descrito no design — o código é o mesmo, muda apenas o workspace.

## Decisões

| # | Decisão | Alternativas descartadas | Justificativa |
|---|---|---|---|
| 1 | Cloud: **AWS** | GCP, Azure | Domínio prévio do time; ecossistema conhecido |
| 2 | Compute: **EC2 + Ansible + Docker Compose** | ECS Fargate, EKS | Automação de ponta a ponta (IaaS+IaaC) com custo controlado; EKS é overkill de custo/complexidade pro escopo |
| 3 | API: **Node/Express + Postgres** | Flask, Go | Stack web moderna, ecossistema maduro de testes e observabilidade |
| 4 | Ambientes: **Terraform workspaces sob demanda** | 3 instâncias fixas 24/7 | Isolamento real de IaC multi-ambiente sem custo de infraestrutura ociosa |
| 5 | CI/CD: **GitHub Actions + GHCR** | GitLab CI self-hosted | Integração nativa com o repositório do projeto |
| 6 | Deploy: **automático em dev, gate manual em prod** | automático em ambos | Segurança operacional — falha de deploy não derruba produção sem revisão. Implementado como regra de proteção do Environment, fora do YAML: o job aguarda aprovação humana e cada ambiente usa credencial e segredos próprios |
| 7 | Acesso ao host: **SSM Session Manager** | SSH + chave + porta 22 | Elimina porta exposta; acesso auditado via IAM, sem gestão de chaves distribuídas |
| 8 | Secrets: **SSM Parameter Store** | `.env` no host / segredos no Git | Segredos nunca residem no host nem no controle de versão; least privilege via IAM |
| 9 | Banco em prod: **toggle RDS** (`use_rds`) | sempre container / sempre RDS | Ambientes de baixo custo usam container; produção usa serviço gerenciado (backup, Multi-AZ) via flag de configuração — 12-factor |
| 10 | State do Terraform: **S3 com lock nativo** (`use_lockfile`) | state local, lock via DynamoDB | Colaboração segura, lock contra execução concorrente sem depender de tabela separada; método atual recomendado pelo Terraform (DynamoDB lock foi depreciado) |
| 11 | Coleta de logs: **Grafana Alloy** | Promtail | Promtail atingiu EOL em 03/2026 (sem mais suporte oficial); Alloy é o coletor atual recomendado pelo Grafana Labs |
| 12 | Alertas preditivos: **predict_linear (Prometheus nativo)** | ML externo (Prophet/PyOD) | Extrapolação de tendência resolve o caso de uso sem infraestrutura adicional; ML dedicado seria overengineering pro escopo atual |
| 13 | Verificação de deploy: **smoke test com rollback automático** | confiar no código de saída do `compose up` | Container que sobe e morre em seguida daria falso positivo; o rollback devolve a versão anterior sem intervenção manual |
| 14 | Credencial do pipeline: **OIDC com role por ambiente** | chave de acesso estática nos secrets | O runner apresenta um token assinado pelo GitHub e recebe credenciais temporárias; não há segredo de longa duração em lugar nenhum. A política de confiança fixa os identificadores numéricos do dono e do repositório, imunes a renomeação, e o Environment do job — a role de dev não pode ser assumida por um job de prod |
| 15 | Observabilidade: **exporters de sistema e de banco** | apenas métricas da aplicação | Aplicação saudável não significa infraestrutura saudável: a API pode responder bem enquanto o banco acumula conexões ou perde eficiência de cache. O `node_exporter` monta o sistema de arquivos do host — sem isso mede o próprio container e reporta número errado, o que é pior que não medir |
| 16 | Provedor OIDC no estado de `dev`, referenciado por `prod` | camada compartilhada com estado próprio | O provedor é único por conta AWS e não cabe em nenhum dos dois ambientes. Enquanto forem dois workspaces do mesmo código, uma flag controla quem o cria — ao custo de uma regra de operação: destruir `prod` antes de `dev`. A separação em camada compartilhada está registrada como evolução |
| 17 | Varredura de **imagem** além de filesystem no CI | apenas `scan-type: fs` | A varredura de filesystem cobre as dependências declaradas; a da imagem cobre também o sistema operacional da base e o ferramental que vem com ela. Na primeira execução encontrou 6 vulnerabilidades altas que a anterior nunca veria |
| 18 | Runtime **sem npm e sem corepack** | imagem base como vem | A aplicação executa `node src/server.js`; npm e corepack servem ao estágio de build. Três das seis vulnerabilidades vinham das dependências do próprio npm — ferramenta de construção não é ferramenta de execução |
| 19 | `apk upgrade` na imagem final | esperar a base ser reconstruída | Troca reprodutibilidade bit a bit por correção de segurança imediata. A base é reconstruída em cadência própria e até lá carrega correções já publicadas no Alpine. Em ambiente regulado a escolha seria a oposta, com digest fixo e atualização controlada |
| 20 | Base oficial do Node, **não** imagem endurecida de terceiro | distroless ou imagem endurecida comercial | Avaliado após as correções: a varredura ficou limpa, então a troca resolveria zero achados atuais ao custo de adaptar healthcheck para forma exec e usuário provido pela imagem. Reavaliar se CVEs voltarem a ser recorrentes na base oficial |

## Caminho de evolução (fora do escopo desta entrega)

Documentado e defendido, não construído — decisão consciente de escopo:

```
1 EC2 + Docker Compose   →  Auto Scaling Group + ALB  →  ECS Fargate
Postgres em container    →  RDS Multi-AZ (toggle já implementado no código)
nginx em HTTP             →  ALB + ACM (TLS)
Recursos de conta no      →  camada compartilhada com estado próprio
estado de dev                (provedor OIDC, bucket de state)
```

## Requisitos avaliados × status da entrega

| Requisito | Status |
|---|---|
| Automação de infraestrutura (IaaS) | ✅ Terraform — provisionamento completo, validado end-to-end na AWS |
| Automação de configuração (IaaC) | ✅ Ansible (`aws_ssm`) — validado end-to-end na AWS, zero SSH |
| Pipeline de deploy | ✅ GitHub Actions — testes, segurança, build/push (GHCR) e deploy automático em dev via Ansible/aws_ssm, com smoke test end-to-end e rollback automático; gate de aprovação humana em produção, implementado como regra de proteção do Environment e validado nos dois caminhos (aprovação e recusa) |
| Monitoramento e métricas | ✅ Prometheus + Grafana + Loki + Alloy + Alertmanager, métricas RED da API, dashboard com painel de SLO |
| Desenvolvimento da API | ✅ Node/Express + Postgres, testado (7 testes automatizados) |
