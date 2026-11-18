#!/usr/bin/env bash
# Host-side helper for the ac-sleep supervisor container.
set -u

CONTAINER_NAME="${SLEEP_CONTAINER_NAME:-ac-sleep}"

usage() {
    cat >&2 <<'EOF'
Usage: sleepctl.sh [-n NAME] <status|wake|freeze|logs>

  status   show target states, connections, idle time and listeners
  wake     unpause all target containers
  freeze   pause all target containers now
  logs     show the last 100 supervisor log lines

  -n NAME  supervisor container name (default: $SLEEP_CONTAINER_NAME or ac-sleep)
EOF
}

while getopts ':n:h' opt; do
    case "$opt" in
        n) CONTAINER_NAME="$OPTARG" ;;
        h) usage; exit 0 ;;
        :)
            printf '[ERROR] option -%s requires a container name\n' "$OPTARG" >&2
            usage
            exit 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

case "$1" in
    status) exec docker exec "$CONTAINER_NAME" /usr/local/bin/monitor.sh status ;;
    wake) exec docker exec "$CONTAINER_NAME" /usr/local/bin/monitor.sh wake ;;
    freeze) exec docker exec "$CONTAINER_NAME" /usr/local/bin/monitor.sh freeze ;;
    logs) exec docker logs --tail 100 "$CONTAINER_NAME" ;;
    *)
        usage
        exit 2
        ;;
esac
