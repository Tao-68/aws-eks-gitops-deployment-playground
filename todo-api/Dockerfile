FROM node:22-alpine

LABEL org.opencontainers.image.source="https://github.com/Tao-68/aws-eks-gitops-deployment-playground"

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js ./

ENV HOST=0.0.0.0 \
    PORT=3001
EXPOSE 3001

USER node

CMD ["node", "server.js"]