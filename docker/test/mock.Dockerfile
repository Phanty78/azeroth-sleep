# Disposable stand-in for an AzerothCore server container.
#
# It listens on ${PORT} and keeps every accepted connection open (socat
# SYSTEM:'sleep 3600'), so the supervisor can count and bridge real TCP
# sessions. A busy loop (`yes`) keeps one CPU core hot: docker pause must
# drop the container's CPU usage to ~0, which is what T06 measures.
FROM alpine:3.20

RUN apk add --no-cache socat

# PORT is provided per service by test-compose.yml (3724 / 8085).
CMD ["sh","-c","yes >/dev/null 2>&1 & exec socat TCP4-LISTEN:${PORT},fork,reuseaddr SYSTEM:'sleep 3600'"]
