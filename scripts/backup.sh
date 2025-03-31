#!/bin/bash
# Synopsis: Odoo Full Backup Script
# Description:
#   Creates a comprehensive backup of an Odoo instance including:
#   - PostgreSQL database (via Docker container)
#   - Odoo filestore (Docker volume)
#   - Local configuration and addons directories
#   The backup is combined into a single tarball, compressed, and encrypted with GPG.
#   Old backups are cleaned up based on size and minimum retention settings.
# Usage:
#   Set required environment variables in ENV_FILE and run:
#     ./odoo_backup.sh
# Environment Variables:
#   DB_NAME, DB_ROOT_USER, DB_ROOT_PASSWORD, BACKUP_DIR, ODOO_VOLUME,
#   ODOO_CONFIG, ODOO_ADDONS, RECIPIENT, POSTGRES_CONTAINER
# Author: Darren Gray
# Credits: Developed with assistance from ChatGPT and Grok (xAI)
# Date: March 31, 2025

# Exit on error, unset variables, and pipe failures
set -euo pipefail

ENV_FILE=".env"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TMP_DIR=$(mktemp -d)

# Trap to clean up temporary directory on exit
trap 'rm -rf "$TMP_DIR"; exit' EXIT INT TERM

# Check for required tools
for cmd in docker gpg tar stat; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required tool '$cmd' not found. Exiting."
        exit 1
    fi
done

# Load and validate environment variables
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file $ENV_FILE not found. Exiting."
    exit 1
fi

get_env_var() { grep -E "^${1}=" "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"' || true; }

# Required variables
declare -A VARS=(
    ["DB_NAME"]="Database name"
    ["DB_ROOT_USER"]="Database root user"
    ["DB_ROOT_PASSWORD"]="Database root password"
    ["BACKUP_DIR"]="Backup directory"
    ["ODOO_VOLUME"]="Odoo volume name"
    ["ODOO_CONFIG"]="Odoo config directory"
    ["ODOO_ADDONS"]="Odoo addons directory"
    ["RECIPIENT"]="GPG recipient"
    ["POSTGRES_CONTAINER"]="Postgres container name"
)
for var in "${!VARS[@]}"; do
    value=$(get_env_var "$var")
    if [ -z "$value" ]; then
        echo "Error: Required variable '$var' (${VARS[$var]}) not set in $ENV_FILE. Exiting."
        exit 1
    fi
    declare "$var=$value"
done

# Setup logging
LOG_FILE="$BACKUP_DIR/backup.log"
mkdir -p "$BACKUP_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_FILE"; }
log_info() { log "INFO" "$1"; }
log_error() { log "ERROR" "$1"; exit 1; }

log_info "=== Starting full Odoo backup process at $TIMESTAMP ==="

# 1. Database Dump
DB_DUMP_FILE="$TMP_DIR/${DB_NAME}_db_dump_${TIMESTAMP}.sql"
log_info "Dumping database '$DB_NAME'..."
docker exec "$POSTGRES_CONTAINER" sh -c "PGPASSWORD='$DB_ROOT_PASSWORD' pg_dump -U '$DB_ROOT_USER' '$DB_NAME'" > "$DB_DUMP_FILE" 2>"$TMP_DIR/db_err.log" || {
    log_error "Database dump failed: $(cat "$TMP_DIR/db_err.log")"
}
log_info "Database dump successful: $DB_DUMP_FILE"

# 2. Backup Odoo Filestore
FILESTORE_BACKUP_FILE="$TMP_DIR/odoo_filestore_${TIMESTAMP}.tar.gz"
log_info "Backing up Odoo filestore from volume '$ODOO_VOLUME'..."
docker run --rm -v "${ODOO_VOLUME}:/data" -v "$TMP_DIR:/backup" alpine \
    tar czf "/backup/odoo_filestore_${TIMESTAMP}.tar.gz" -C /data . 2>"$TMP_DIR/fs_err.log" || {
    log_error "Filestore backup failed: $(cat "$TMP_DIR/fs_err.log")"
}
log_info "Filestore backup successful: $FILESTORE_BACKUP_FILE"

# 3. Backup Config and Addons
CONFIG_BACKUP_FILE="$TMP_DIR/odoo_config_${TIMESTAMP}.tar.gz"
ADDONS_BACKUP_FILE="$TMP_DIR/odoo_addons_${TIMESTAMP}.tar.gz"
log_info "Backing up Odoo configuration from '$ODOO_CONFIG'..."
tar czf "$CONFIG_BACKUP_FILE" -C "$(dirname "$ODOO_CONFIG")" "$(basename "$ODOO_CONFIG")" 2>"$TMP_DIR/cfg_err.log" || {
    log_error "Config backup failed: $(cat "$TMP_DIR/cfg_err.log")"
}
log_info "Config backup successful: $CONFIG_BACKUP_FILE"

log_info "Backing up Odoo addons from '$ODOO_ADDONS'..."
tar czf "$ADDONS_BACKUP_FILE" -C "$(dirname "$ODOO_ADDONS")" "$(basename "$ODOO_ADDONS")" 2>"$TMP_DIR/add_err.log" || {
    log_error "Addons backup failed: $(cat "$TMP_DIR/add_err.log")"
}
log_info "Addons backup successful: $ADDONS_BACKUP_FILE"

# 4. Combine and Encrypt
FINAL_TAR="$TMP_DIR/odoo_full_backup_${TIMESTAMP}.tar.gz"
FINAL_BACKUP_PATH="$BACKUP_DIR/odoo_full_backup_${TIMESTAMP}.tar.gz.gpg"
log_info "Creating and encrypting final backup..."
tar czf "$FINAL_TAR" -C "$TMP_DIR" \
    "$(basename "$DB_DUMP_FILE")" \
    "$(basename "$FILESTORE_BACKUP_FILE")" \
    "$(basename "$CONFIG_BACKUP_FILE")" \
    "$(basename "$ADDONS_BACKUP_FILE")" 2>"$TMP_DIR/tar_err.log" || {
    log_error "Final archive failed: $(cat "$TMP_DIR/tar_err.log")"
}
gpg --batch --yes --encrypt -r "$RECIPIENT" -o "$FINAL_BACKUP_PATH" "$FINAL_TAR" 2>"$TMP_DIR/gpg_err.log" || {
    log_error "Encryption failed: $(cat "$TMP_DIR/gpg_err.log")"
}
log_info "Encrypted backup created: $FINAL_BACKUP_PATH"

# 5. Cleanup Old Backups
cleanup_backups() {
    local max_size=$((1024 * 1024 * 1024))  # 1GB
    local min_backups=10
    mapfile -t backups < <(ls -1 "$BACKUP_DIR"/*.tar.gz.gpg 2>/dev/null || true)
    local backup_count=${#backups[@]}
    log_info "Current number of backups: $backup_count"

    if [ "$backup_count" -le "$min_backups" ]; then
        log_info "Number of backups ($backup_count) at or below minimum ($min_backups). Skipping cleanup."
        return
    fi

    total_size=$(du -cb "$BACKUP_DIR"/*.tar.gz.gpg 2>/dev/null | tail -n1 | cut -f1)
    if [ "$total_size" -le "$max_size" ]; then
        log_info "Total size ($total_size bytes) within threshold ($max_size bytes). No cleanup needed."
        return
    fi

    mapfile -t sorted_backups < <(ls -1tr "$BACKUP_DIR"/*.tar.gz.gpg)
    local to_delete=$(($backup_count - $min_backups))
    for ((i = 0; i < to_delete; i++)); do
        rm -f "${sorted_backups[$i]}" && log_info "Deleted old backup: ${sorted_backups[$i]}"
    done
    new_size=$(du -cb "$BACKUP_DIR"/*.tar.gz.gpg 2>/dev/null | tail -n1 | cut -f1)
    log_info "New total backup size: $new_size bytes"
}
cleanup_backups

log_info "=== Full backup process completed successfully at $(date '+%Y%m%d_%H%M%S') ==="
exit 0
