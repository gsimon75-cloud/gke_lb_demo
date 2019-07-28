FROM mkenney/npm AS builder
ENV app="Vue_MySQL_Example"
COPY $app /$app
WORKDIR /$app
RUN pwd
RUN ls -l
RUN ls -l /
RUN npm install
RUN npm run buildprod
RUN rm -rf node_modules
RUN npm install --production

FROM node:alpine AS production
LABEL maintainer="gabor.simon75@gmail.com"
ENV app="Vue_MySQL_Example"
RUN mkdir -p /$app/public
WORKDIR /$app
COPY $app/server.sh $app/server_launcher.js $app/rest.js $app/rest_Ansehen.js $app/rest_Kunde.js $app/rest_Wohnung.js $app/config.json ./
COPY --from=builder /$app/public/font public/font
COPY --from=builder /$app/public/*.js /$app/public/*.html public/
COPY --from=builder /$app/node_modules node_modules
EXPOSE 8080/tcp
ENTRYPOINT ["/usr/local/bin/node", "server_launcher.js", "-p", "/tmp/qwer.pid", "-F"]

#$ docker image build -t frontend:latest .
