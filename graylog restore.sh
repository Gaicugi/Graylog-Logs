#!/bin/bash
#############################################################################
# graylog-restore.sh
# Restore a Graylog archive snapshot (Elasticsearch indices + MongoDB)
#
# Usage:
#   ./graylog-restore.sh --list                           # list available snapshots
#   ./graylog-restore.sh --snap snapshot_full_2026-03-01  # restore a snapshot
#   ./graylog-restore.sh --mongo /var/backups/graylog/mongo/mongo-2026-03-01_02-00
#############################################################################

set -euo pipefail

ES_HOST="http://localhost:9200"
SNAP_REPO="graylog_archive"
MONGO_DB="graylog"

usage() {
    echo "Usage:"
    echo "  $0 --list"
    echo "  $0 --snap <snapshot_name>"
    echo "  $0 --mongo <path_to_mongo_dump_dir>"
    exit 1
}

[[ $# -eq 0 ]] && usage

case "$1" in
    --list)
        echo "Available snapshots in repo '$SNAP_REPO':"
        curl -sf "$ES_HOST/_snapshot/$SNAP_REPO/_all" \
            | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('snapshots', []):
    name = s['snapshot']
    state = s.get('state', '?')
    start = s.get('start_time', '?')
    indices = ', '.join(s.get('indices', []))
    print(f'  {name}  [{state}]  started={start}')
    print(f'    indices: {indices}')
    print()
"
        ;;

    --snap)
        [[ -z "${2:-}" ]] && usage
        SNAP_NAME="$2"
        echo "Restoring snapshot: $SNAP_NAME from repo '$SNAP_REPO'"
        echo "WARNING: This will restore indices into Elasticsearch."
        echo "         Existing indices with the same name will conflict — close them first."
        read -r -p "Continue? [y/N] " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && exit 0

        curl -sf -X POST "$ES_HOST/_snapshot/$SNAP_REPO/${SNAP_NAME}/_restore" \
            -H "Content-Type: application/json" \
            -d '{"ignore_unavailable":true,"include_global_state":false}' \
            && echo "" && echo "Restore initiated. Monitor with:" \
            && echo "  curl $ES_HOST/_snapshot/$SNAP_REPO/${SNAP_NAME}" \
            || echo "Restore API call failed."
        ;;

    --mongo)
        [[ -z "${2:-}" ]] && usage
        DUMP_DIR="$2"
        [[ ! -d "$DUMP_DIR" ]] && echo "Directory not found: $DUMP_DIR" && exit 1
        echo "Restoring MongoDB from: $DUMP_DIR"
        echo "WARNING: This will overwrite the '$MONGO_DB' database."
        read -r -p "Continue? [y/N] " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && exit 0
        mongorestore --db "$MONGO_DB" --drop "$DUMP_DIR/$MONGO_DB"
        echo "MongoDB restore complete. Restart Graylog: systemctl restart graylog-server"
        ;;

    *)
        usage
        ;;
esac

