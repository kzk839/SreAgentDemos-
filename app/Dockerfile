FROM node:22-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev

COPY src/ ./src/
COPY public/ ./public/

EXPOSE 8080

USER node

CMD ["node", "src/server.js"]
