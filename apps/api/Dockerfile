FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY index.js db.js migrate.js ./
USER 1000
EXPOSE 3000
CMD ["node", "index.js"]
