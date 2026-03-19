#!/bin/bash
#############################################################################
# graylog-archive.sh
# Automated Graylog Open archiving — mimics Graylog Enterprise behavior
#
# Features:
#   - Auto-discovers all Graylog indices (handles both graylog_N and
#     graylog_N___<deflector> naming conventions)
#   - Builds creation-date mapping dynamically from Elasticsearch
#   - Creates date-stamped snapshots
#   - Verifies snapshot success before marking complete
#   - Rotates/cleans old snapshots beyond retention window
#   - Alerts on failure via Slack webhook and/or SMTP email
#   - Logs everything with timestamps
#
# Usage:
#   ./graylog-archive.sh                     # snapshot all indices
#   ./graylog-archive.sh 2026-01-01 2026-01-31  # snapshot date range only
#
# Cron (nightly at 02:00):
#   0 2 * * * /usr/local/bin/graylog-archive.sh >> /var/log/graylog-archive.log 2>&1
#############################################################################

set -euo pipefail

##############################################################################
# CONFIGURATION — edit this section
##############################################################################

ES_HOST="http://localhost:9200"          # Elasticsearch host
SNAP_REPO="graylog_archive"             # Snapshot repository name
BACKUP_DIR="/var/backups/elasticsearch"         # Must be accessible by elasticsearch user
MONGO_DB="graylog"                      # Graylog MongoDB database name
MONGO_BACKUP_DIR="/var/backups/graylog/mongo"
CONF_BACKUP_DIR="/var/backups/graylog/conf"
RETENTION_DAYS=30                       # Days to keep snapshots/backups
LOGFILE="/var/log/graylog-archive.log"

# Alerting — leave blank to disable
SLACK_WEBHOOK=""    # e.g. https://hooks.slack.com/services/XXX/YYY/ZZZ
ALERT_EMAIL=""      # e.g. soc@yourcompany.com
ALERT_FROM=""       # e.g. graylog-alerts@yourcompany.com
SMTP_HOST=""        # e.g. smtp.zoho.com
SMTP_PORT="587"

##############################################################################
# INTERNALS — do not edit below
##############################################################################

DATE=$(date +%F_%H-%M)
START_DATE="${1:-}"
END_DATE="${2:-}"

log() {
    echo "[$(date +'%F %T')] $1" | tee -a "$LOGFILE"
}

die() {
    log "FATAL: $1"
    send_alert "FAILED" "$1"
    exit 1
}

send_alert() {
    local status="$1"
    local message="$2"
    local host
    host=$(hostname)

    # Slack
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        local emoji=":white_check_mark:"
        [[ "$status" == "FAILED" ]] && emoji=":red_circle:"
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"$emoji *Graylog Archive [$status]* on \`$host\`\n$message\"}" \
            >/dev/null || true
    fi

    # Email via SMTP (requires mailx/sendmail configured, or use curl for SMTP)
    if [[ -n "$ALERT_EMAIL" && -n "$SMTP_HOST" ]]; then
        echo "$message" | mail -s "Graylog Archive [$status] on $host" \
            -S smtp="smtp://$SMTP_HOST:$SMTP_PORT" \
            -S from="$ALERT_FROM" \
            "$ALERT_EMAIL" 2>/dev/null || true
    fi
}

es_get() {
    # Silent GET to Elasticsearch, exit 1 on curl failure
    curl -sf "$ES_HOST$1" || die "Elasticsearch unreachable at $ES_HOST$1"
}

es_put() {
    local url="$1"
    local data="$2"
    curl -sf -X PUT "$ES_HOST$url" \
        -H "Content-Type: application/json" \
        -d "$data" || die "PUT to $ES_HOST$url failed"
}

##############################################################################
# PRE-FLIGHT
##############################################################################

log "========== Graylog Archive Job Started =========="

# Verify Elasticsearch is up
es_get "/_cluster/health" > /dev/null
log "Elasticsearch reachable."

# Create backup directories
mkdir -p "$BACKUP_DIR" "$MONGO_BACKUP_DIR" "$CONF_BACKUP_DIR"

##############################################################################
# REGISTER SNAPSHOT REPOSITORY (idempotent)
##############################################################################

log "Registering snapshot repository '$SNAP_REPO' at $BACKUP_DIR ..."
es_put "/_snapshot/$SNAP_REPO" \
    "{\"type\":\"fs\",\"settings\":{\"location\":\"$BACKUP_DIR\",\"compress\":true}}"
log "Repository OK."

##############################################################################
# BUILD INDEX → DATE MAPPING (dynamic, no CSV required)
##############################################################################

log "Discovering Graylog indices and creation dates..."

declare -A INDEX_DATES  # index_name → YYYY-MM-DD

# Fetch all index names + creation_date epoch (ms) in one call
# Works for both old-style (graylog_0) and triple-underscore (graylog_0___<deflector>)
mapfile -t INDEX_JSON < <(
    curl -sf "$ES_HOST/_cat/indices/graylog*?h=index,creation.date&s=creation.date:asc" \
    || die "Failed to list indices from Elasticsearch"
)

for line in "${INDEX_JSON[@]}"; do
    index=$(echo "$line" | awk '{print $1}')
    epoch_ms=$(echo "$line" | awk '{print $2}')
    if [[ -n "$index" && -n "$epoch_ms" && "$epoch_ms" =~ ^[0-9]+$ ]]; then
        creation_date=$(date -d "@$((epoch_ms / 1000))" +%Y-%m-%d)
        INDEX_DATES["$index"]="$creation_date"
    fi
done

log "Found ${#INDEX_DATES[@]} Graylog indices."

##############################################################################
# SELECT INDICES TO SNAPSHOT
##############################################################################

INDICES_TO_SNAP=""

if [[ -n "$START_DATE" && -n "$END_DATE" ]]; then
    log "Date-range mode: $START_DATE → $END_DATE"
    start_sec=$(date -d "$START_DATE" +%s)
    end_sec=$(date -d "$END_DATE" +%s)

    for index in "${!INDEX_DATES[@]}"; do
        idx_date="${INDEX_DATES[$index]}"
        idx_sec=$(date -d "$idx_date" +%s)
        if [[ $idx_sec -ge $start_sec && $idx_sec -le $end_sec ]]; then
            INDICES_TO_SNAP="${INDICES_TO_SNAP},${index}"
        fi
    done

    if [[ -z "$INDICES_TO_SNAP" ]]; then
        log "No indices found in date range $START_DATE → $END_DATE. Nothing to do."
        exit 0
    fi
    INDICES_TO_SNAP="${INDICES_TO_SNAP#,}"   # strip leading comma
    SNAP_NAME="snapshot_${START_DATE}_${END_DATE}"
else
    log "Full snapshot mode (all Graylog indices)."
    # Snapshot all graylog* indices
    INDICES_TO_SNAP="graylog*"
    SNAP_NAME="snapshot_full_${DATE}"
fi

log "Snapshot name: $SNAP_NAME"
log "Indices: $INDICES_TO_SNAP"

##############################################################################
# TAKE SNAPSHOT
##############################################################################

log "Creating Elasticsearch snapshot (this may take a while)..."

SNAP_RESULT=$(curl -sf -X PUT \
    "$ES_HOST/_snapshot/$SNAP_REPO/${SNAP_NAME}?wait_for_completion=true" \
    -H "Content-Type: application/json" \
    -d "{\"indices\":\"$INDICES_TO_SNAP\",\"ignore_unavailable\":true,\"include_global_state\":false}" \
    || die "Snapshot API call failed")

##############################################################################
# VERIFY SNAPSHOT SUCCESS
##############################################################################

SNAP_STATE=$(echo "$SNAP_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['snapshot']['state'])
except Exception as e:
    print('PARSE_ERROR')
" 2>/dev/null || echo "PARSE_ERROR")

if [[ "$SNAP_STATE" != "SUCCESS" ]]; then
    die "Snapshot completed but state is '$SNAP_STATE' (expected SUCCESS). Raw: $SNAP_RESULT"
fi

log "Snapshot verified: state = $SNAP_STATE"

##############################################################################
# MONGODB BACKUP
##############################################################################

log "Backing up MongoDB (database: $MONGO_DB)..."
mongodump --db "$MONGO_DB" --out "$MONGO_BACKUP_DIR/mongo-${DATE}" \
    || die "mongodump failed"
log "MongoDB backup complete."

##############################################################################
# GRAYLOG CONFIG BACKUP
##############################################################################

log "Backing up Graylog config files..."
tar -czf "$CONF_BACKUP_DIR/graylog-conf-${DATE}.tgz" \
    /etc/graylog/server \
    /etc/elasticsearch \
    /etc/mongod.conf \
    2>/dev/null || log "Warning: some config paths missing (non-fatal)"
log "Config backup complete."

##############################################################################
# CLEANUP OLD SNAPSHOTS
##############################################################################

log "Cleaning Elasticsearch snapshots older than $RETENTION_DAYS days..."

# List all snapshots in the repo
ALL_SNAPS=$(curl -sf "$ES_HOST/_snapshot/$SNAP_REPO/_all" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('snapshots', []):
    name = s['snapshot']
    start_ms = s.get('start_time_in_millis', 0)
    print(f'{name} {start_ms}')
" 2>/dev/null || echo "")

cutoff_ms=$(( ($(date +%s) - RETENTION_DAYS * 86400) * 1000 ))

while IFS=' ' read -r snap_name snap_ms; do
    [[ -z "$snap_name" ]] && continue
    if (( snap_ms < cutoff_ms )); then
        log "Deleting old snapshot: $snap_name (age > $RETENTION_DAYS days)"
        curl -sf -X DELETE "$ES_HOST/_snapshot/$SNAP_REPO/$snap_name" >/dev/null \
            || log "Warning: could not delete snapshot $snap_name"
    fi
done <<< "$ALL_SNAPS"

log "Cleaning local backups older than $RETENTION_DAYS days..."
find "$MONGO_BACKUP_DIR" -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
find "$CONF_BACKUP_DIR" -name "*.tgz" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true

##############################################################################
# DONE
##############################################################################

log "========== Archive Job Completed Successfully =========="
send_alert "SUCCESS" "Snapshot: $SNAP_NAME | Indices: $INDICES_TO_SNAP"
exit 0
