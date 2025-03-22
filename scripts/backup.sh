#!/bin/bash

# Script to create encrypted backup of odoo-traefik directory including the folder itself

# Configuration Variables
USERNAME="[USERNAME]"            # Replace with your username (e.g., deployer)
DOMAIN="[DOMAIN]"                # Replace with your domain (e.g., example.com)
RECIPIENT="[GPG_RECIPIENT]"      # Replace with your GPG recipient (e.g., email or key ID)

# Variables
SOURCE_DIR="/home/$USERNAME/odoo-traefik"  # The folder to back up
PARENT_DIR="/home/$USERNAME"               # The parent directory containing odoo-traefik
BACKUP_NAME="${DOMAIN}_odoo_traefik_etc_docker_conf_encrypted_backup_$(date +%Y%m%d_%H%M).tar.gz.gpg"
OUTPUT_DIR="/home/$USERNAME/backups"       # Change this to your preferred backup location
LOG_FILE="/home/$USERNAME/backups/odoo_traefik_config_backup.log"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"  # Also output to console if run manually
}

# Check if source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    log_message "Error: Source directory $SOURCE_DIR does not exist!"
    exit 1
fi

# Check if parent directory exists
if [ ! -d "$PARENT_DIR" ]; then
    log_message "Error: Parent directory $PARENT_DIR does not exist!"
    exit 1
fi

# Check if gpg is installed
if ! command -v gpg &> /dev/null; then
    log_message "Error: GPG is not installed!"
    exit 1
fi

# Check if tar is installed
if ! command -v tar &> /dev/null; then
    log_message "Error: tar is not installed!"
    exit 1
fi

# Perform the backup
log_message "Starting backup process..."
if tar -czf - -C "$PARENT_DIR" "odoo-traefik" | gpg --encrypt -r "$RECIPIENT" -o "$OUTPUT_DIR/$BACKUP_NAME" 2>> "$LOG_FILE"; then
    log_message "Backup completed successfully: $BACKUP_NAME"
else
    log_message "Error: Backup failed!"
    exit 1
fi

# Remove backups older than 30 days
find "$OUTPUT_DIR" -name "*.tar.gz.gpg" -mtime +30 -exec rm -f {} \;