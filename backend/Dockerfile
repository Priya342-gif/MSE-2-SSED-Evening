# syntax=docker/dockerfile:1
FROM node:20-alpine AS base
WORKDIR /app

# Install production dependencies only
COPY package.json ./
RUN npm install --omit=dev

# Copy application source
COPY src/ ./src/

EXPOSE 3000
ENV NODE_ENV=production

CMD ["node", "src/server.js"]
