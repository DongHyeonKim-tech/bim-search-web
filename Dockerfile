FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json .npmrc ./

RUN node -v && npm -v

RUN node -e "const l=require('./package-lock.json'); \
console.log('jquery:', l.packages?.['node_modules/jquery']?.version); \
console.log('lockfileVersion:', l.lockfileVersion)"

# @haeahn-design/* is resolved from Nexus and requires the project .npmrc.
RUN sed -i 's/\r$//' .npmrc && npm ci && rm -f .npmrc


FROM node:24-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN rm -f .npmrc
ARG BUILD_ENV=prod
# Explicitly select env-cmd npm scripts. NODE_ENV remains production.
RUN case "$BUILD_ENV" in \
      dev) npm run build:dev ;; \
      prod) npm run build:prod ;; \
      default) npm run build ;; \
      *) echo "Unsupported BUILD_ENV=$BUILD_ENV" >&2; exit 1 ;; \
    esac

FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
RUN addgroup -S nodejs && adduser -S nextjs -G nodejs
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
# If the project has no public/ directory, create an empty one.
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]
