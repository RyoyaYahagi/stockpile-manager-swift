FROM node:24-alpine

WORKDIR /app

COPY package.json ./
COPY api ./api
COPY server.js ./

ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000

CMD ["npm", "run", "start"]
