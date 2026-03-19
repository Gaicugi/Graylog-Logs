#!/bin/bash
#############################################################################
# graylog-archive-setup.sh
# One-time setup: directories, permissions, ES repo registration, cron entry
# Run as root once before first use of graylog-archive.sh
#############################################################################

set -euo pipefail

ES_HOST="http://localhost:9200"
SNAP_REPO="graylog_archive"
BACKUP_DIR="/var/backups/elasticsearch"
MONGO_BACKUP_DIR="/var/backups/graylog/mongo"
CONF_BACKUP_DIR="/var/backups/graylog/conf"
ARCHIVE_SCRIPT="/usr/local/bin/graylog-archive.sh"

echo "[SETUP] Creating backup directories..."
mkdir -p "$BACKUP_DIR" "$MONGO_BACKUP_DIR" "$CONF_BACKUP_DIR"

# Elasticsearch needs to own the snapshot directory
echo "[SETUP] Setting ownership for Elasticsearch snapshot path..."
chown -R elasticsearch:elasticsearch "$BACKUP_DIR"
chmod -R 750 "$BACKUP_DIR"

# Other dirs owned by root (mongodump runs as root via cron)
chown -R root:root "$MONGO_BACKUP_DIR" "$CONF_BACKUP_DIR"
chmod -R 700 "$MONGO_BACKUP_DIR" "$CONF_BACKUP_DIR"

echo "[SETUP] Registering snapshot repository in Elasticsearch..."
curl -sf -X PUT "$ES_HOST/_snapshot/$SNAP_REPO" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"fs\",\"settings\":{\"location\":\"$BACKUP_DIR\",\"compress\":true}}" \
    && echo "" && echo "[SETUP] Repository registered OK." \
    || echo "[SETUP] WARNING: Could not register repo — check Elasticsearch is running and path.repo is set."

echo ""
echo "[SETUP] -------------------------------------------------------"
echo "[SETUP] IMPORTANT: Add the snapshot path to elasticsearch.yml"
echo "        path.repo: [\"/var/backups/elasticsearch\"]"
echo "        Then restart Elasticsearch: systemctl restart elasticsearch"
echo "[SETUP] -------------------------------------------------------"
echo ""

# Install archive script
if [[ -f "$ARCHIVE_SCRIPT" ]]; then
    echo "[SETUP] Archive script already at $ARCHIVE_SCRIPT — not overwriting."
else
    echo "[SETUP] Copy graylog-archive.sh to $ARCHIVE_SCRIPT and chmod +x it."
fi

# Cron entry
CRON_LINE="0 2 * * * $ARCHIVE_SCRIPT >> /var/log/graylog-archive.log 2>&1"
if crontab -l 2>/dev/null | grep -q "graylog-archive"; then
    echo "[SETUP] Cron entry already exists — skipping."
else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo "[SETUP] Cron entry added: $CRON_LINE"
fi

echo "[SETUP] Setup complete."
