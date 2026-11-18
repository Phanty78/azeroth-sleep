# azeroth-sleep Docker supervisor: socat wake proxy + idle monitor.
FROM alpine:3.20
ENV DOCKER_CONFIG=/tmp
RUN apk add --no-cache bash socat iproute2 docker-cli
COPY sleep-common.sh entrypoint.sh monitor.sh thaw.sh bridge.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/*.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
