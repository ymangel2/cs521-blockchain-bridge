FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY index.js ./
# config.json is mounted at runtime or copied during build
CMD ["node", "index.js"]
