FROM node:22-alpine AS build
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts
COPY build-web.cjs ./
COPY web ./web
RUN BEAST_STAGING_DIST=/build/public npm run build:web

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080 BEAST_STAGING_DIST=/app/public
COPY --from=build --chown=node:node /build/public ./public
COPY --chown=node:node serve-web.cjs ./
COPY --chown=node:node web/pricing.cjs ./web/pricing.cjs
RUN chown node:node /app
USER node
EXPOSE 8080
CMD ["node", "serve-web.cjs"]
