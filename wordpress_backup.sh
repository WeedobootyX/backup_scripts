#!/bin/bash

# This script performs a backup of multiple WordPress file directories and uploads them to a Google Cloud Storage bucket.

# --- Script Configuration ---
set -e
set -u
set -o pipefail

# --- User Configuration ---

# Add the full paths to all the WordPress directories you want to back up.
DIRECTORIES_TO_BACKUP=("/home/weedo/docker/wordpress_files/bubbelbubbel" "/home/weedo/docker/wordpress_files/centipod")

# Google Cloud Storage bucket name
GCS_BUCKET_NAME="centipod_backups"

# --- Path Configuration ---
# Absolute paths to commands on the host machine.
TAR_CMD="/bin/tar"
GSUTIL_CMD="/snap/bin/gsutil"
RM_CMD="/bin/rm"

# --- Main Backup Process ---

# Loop through each directory listed in the DIRECTORIES_TO_BACKUP array
for DIR_PATH in "${DIRECTORIES_TO_BACKUP[@]}"; do
  # Get the site name from the last part of the directory path
  SITE_NAME=$(basename "$DIR_PATH")
  echo "--- Starting backup for site: ${SITE_NAME} ---"

  BACKUP_DATE=$(date +%Y-%m-%d-%H-%M-%S)
  # Create a descriptive archive name
  ARCHIVE_FILE="/tmp/${SITE_NAME}-files-${BACKUP_DATE}.tar.gz"

  # Step 1: Create a compressed tarball of the directory.
  # The -C flag changes to the parent directory, so the archive doesn't contain the full path.
  echo "Creating archive..."
  $TAR_CMD -czf "$ARCHIVE_FILE" -C "$(dirname "$DIR_PATH")" "$SITE_NAME"

  # Step 2: Upload the backup to Google Cloud Storage.
  echo "Uploading to GCS..."
  $GSUTIL_CMD cp "$ARCHIVE_FILE" gs://$GCS_BUCKET_NAME/

  # Step 3: Clean up the local backup file.
  $RM_CMD "$ARCHIVE_FILE"

  echo "--- Backup for ${SITE_NAME} completed successfully. ---"
  echo ""
done

# --- Cleanup Process ---

echo "--- Starting cleanup of old file backups in gs://${GCS_BUCKET_NAME} ---"

declare -A weekly_backups_kept
declare -A monthly_backups_kept

current_date_seconds=$(date +%s)

# The cleanup logic will now look for both .sql.gz and .tar.gz files.
while read -r backup_url; do
  backup_file=$(basename "$backup_url")
  # Use grep to reliably find the date in the filename
  backup_date_str=$(echo "$backup_file" | grep -o -E '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1)

  if [[ -z "$backup_date_str" ]]; then
    echo "Could not parse date from $backup_file, skipping."
    continue
  fi

  backup_date_seconds=$(date -d "$backup_date_str" +%s)
  age_days=$(( (current_date_seconds - backup_date_seconds) / 86400 ))

  # Keep all daily backups for 7 days.
  if [ $age_days -le 7 ]; then
    echo "Keeping daily backup (age ${age_days}d): $backup_file"
    continue
  fi

  # Keep one weekly backup for 4 weeks.
  if [ $age_days -le 28 ]; then
    year_week=$(date -d "$backup_date_str" +%Y-%V)
    if [ -z "${weekly_backups_kept[$year_week]:-''}" ]; then
      echo "Keeping weekly backup for week $year_week (age ${age_days}d): $backup_file"
      weekly_backups_kept[$year_week]=1
    else
      echo "Deleting older daily backup in same week (age ${age_days}d): $backup_file"
      $GSUTIL_CMD rm "$backup_url"
    fi
    continue
  fi

  # Keep one monthly backup for 6 months.
  if [ $age_days -le 180 ]; then
    year_month=$(date -d "$backup_date_str" +%Y-%m)
    if [ -z "${monthly_backups_kept[$year_month]:-''}" ]; then
      echo "Keeping monthly backup for month $year_month (age ${age_days}d): $backup_file"
      monthly_backups_kept[$year_month]=1
    else
      echo "Deleting older weekly/daily backup in same month (age ${age_days}d): $backup_file"
      $GSUTIL_CMD rm "$backup_url"
    fi
    continue
  fi

  # Delete backups older than 6 months.
  echo "Deleting old backup (age ${age_days}d): $backup_file"
  $GSUTIL_CMD rm "$backup_url"

done < <($GSUTIL_CMD ls gs://${GCS_BUCKET_NAME}/*-files-*.tar.gz | sort -r)

echo "--- Cleanup process completed. ---"
