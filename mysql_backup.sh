#!/bin/bash

# This script performs a backup of multiple MySQL databases and uploads them to a Google Cloud Storage bucket.

# --- Script Configuration ---
set -e
set -u
set -o pipefail

# --- User Configuration ---

# Add all the databases you want to back up to this list, separated by spaces.
DATABASES_TO_BACKUP=("prod_hub" "bubbelbubbel_sewp" "centipod_sewordpress" "prod_weatherman")

# Database connection details.
# The password for this user should be stored in ~/.my.cnf
MYSQL_USER="backupuser"

# The host and port of your MySQL server.
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"

# Google Cloud Storage bucket name
GCS_BUCKET_NAME="centipod_backups"

# --- Path Configuration ---
MYSQLDUMP_CMD="/usr/bin/mysqldump"
GZIP_CMD="/bin/gzip"
GSUTIL_CMD="/snap/bin/gsutil"
RM_CMD="/bin/rm"

# --- Main Process ---

# Loop through each database listed in the DATABASES_TO_BACKUP array
for DB_NAME in "${DATABASES_TO_BACKUP[@]}"; do
  echo "--- Starting backup for database: ${DB_NAME} ---"

  BACKUP_DATE=$(date +%Y-%m-%d-%H-%M-%S)
  # Include the DB name in the filename for clarity
  TMP_SQL_FILE="/tmp/${DB_NAME}-backup-${BACKUP_DATE}.sql"
  FINAL_BACKUP_FILE="${TMP_SQL_FILE}.gz"

  # Step 1: Create the uncompressed backup file.
  echo "Dumping database..."
  $MYSQLDUMP_CMD --no-tablespaces -h $MYSQL_HOST -P $MYSQL_PORT -u $MYSQL_USER $DB_NAME > $TMP_SQL_FILE

  # Step 2: Check if the backup file was created and is not empty.
  if [ ! -s "$TMP_SQL_FILE" ]; then
      echo "Error: Backup failed for ${DB_NAME}. The output file is empty or was not created."
      # We continue to the next database instead of exiting
      continue
  fi

  # Step 3: Compress the backup file.
  echo "Compressing backup..."
  $GZIP_CMD $TMP_SQL_FILE

  # Step 4: Upload the backup to Google Cloud Storage.
  echo "Uploading to GCS..."
  $GSUTIL_CMD cp $FINAL_BACKUP_FILE gs://$GCS_BUCKET_NAME/

  # Step 5: Clean up the local backup file.
  $RM_CMD $FINAL_BACKUP_FILE

  echo "--- Backup for ${DB_NAME} completed successfully. ---"
  echo ""

done

# --- Cleanup Process ---

echo "--- Starting cleanup of old backups in gs://${GCS_BUCKET_NAME} ---"

declare -A weekly_backups_kept
declare -A monthly_backups_kept

current_date_seconds=$(date +%s)

# The cleanup logic remains the same and will clean backups for all databases.
while read -r backup_url; do
  backup_file=$(basename "$backup_url")
  # Improved date parsing to be more robust
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

done < <($GSUTIL_CMD ls gs://${GCS_BUCKET_NAME}/*.sql.gz | sort -r)

echo "--- Cleanup process completed. ---"
