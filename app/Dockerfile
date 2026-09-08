# Stage 1: build — instala dependências
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src/ ./src/

# Stage 2: runtime — imagem final, só o necessário
FROM node:24-alpine
WORKDIR /app

# Atualiza os pacotes do sistema. A imagem base e reconstruida em cadencia
# propria, e ate la carrega correcoes ja publicadas no Alpine — hoje, OpenSSL.
RUN apk --no-cache upgrade

# Remove o npm da imagem final. A aplicacao executa "node src/server.js": o npm
# so e necessario no estagio de build, para instalar dependencias. Mante-lo aqui
# nao acrescenta nada e arrasta as vulnerabilidades das dependencias do proprio
# npm (brace-expansion, ip-address, tar) para dentro do runtime.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
           /usr/local/bin/corepack \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
           /opt/yarn-* \
           /usr/local/bin/yarn \
           /usr/local/bin/yarnpkg

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
