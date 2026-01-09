#!/bin/bash
# MySQL backup to GCS with daily/weekly/monthly retention
set -euo pipefail

# --- User Configuration ---
DATABASES_TO_BACKUP=("prod_hub" "bubbelbubbel_sewp" "centipod_sewordpress" "prod_weatherman")

MYSQL_USER="backupuser"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"

GCS_BUCKET_NAME="centipod_backups"

# --- Path Configuration ---
MYSQLDUMP_CMD="/usr/bin/mysqldump"
GZIP_CMD="/bin/gzip"
GSUTIL_CMD="/snap/bin/gsutil"
RM_CMD="/bin/rm"

# --- Tier configuration (prefixes) ---
# Keep DAILY in bucket root exactly as before.
GCS_DAILY_PREFIX="gs://${GCS_BUCKET_NAME}"
GCS_WEEKLY_PREFIX="gs://${GCS_BUCKET_NAME}/weekly"
GCS_MONTHLY_PREFIX="gs://${GCS_BUCKET_NAME}/monthly"

# Retention rules:
DAILY_DELETE_AGE_DAYS=8          # delete daily backups age >= 8 days
WEEKLY_DELETE_AGE_DAYS=$((5*7))  # delete weekly backups age >= 35 days
MONTHLY_DELETE_AGE_MONTHS=6      # delete monthly backups age >= 6 months

# --- Schedule flags (based on *today*) ---
DOW=$(date +%u)         # 1=Mon ... 6=Sat 7=Sun
DOM=$(date +%d)         # day of month, 01..31

DO_WEEKLY=false
DO_MONTHLY=false
if [[ "$DOW" == "6" ]]; then
  DO_WEEKLY=true
fi
if [[ "$DOM" == "01" ]]; then
  DO_MONTHLY=true
fi

echo "Weekly tier today?  $DO_WEEKLY"
echo "Monthly tier today? $DO_MONTHLY"
echo ""

# --- Backup process ---
for DB_NAME in "${DATABASES_TO_BACKUP[@]}"; do
  echo "--- Starting backup for database: ${DB_NAME} ---"

  BACKUP_DATE=$(date +%Y-%m-%d-%H-%M-%S)
  TMP_SQL_FILE="/tmp/${DB_NAME}-backup-${BACKUP_DATE}.sql"
  FINAL_BACKUP_FILE="${TMP_SQL_FILE}.gz"
  FINAL_BACKUP_BASENAME="$(basename "$FINAL_BACKUP_FILE")"

  echo "Dumping database..."
  $MYSQLDUMP_CMD --no-tablespaces -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" "$DB_NAME" > "$TMP_SQL_FILE"

  if [[ ! -s "$TMP_SQL_FILE" ]]; then
    echo "Error: Backup failed for ${DB_NAME}. Output file is empty or missing."
    continue
  fi

  echo "Compressing backup..."
  $GZIP_CMD "$TMP_SQL_FILE"

  echo "Uploading DAILY to GCS (bucket root)..."
  $GSUTIL_CMD cp "$FINAL_BACKUP_FILE" "${GCS_DAILY_PREFIX}/"

  if [[ "$DO_WEEKLY" == "true" ]]; then
    echo "Uploading WEEKLY copy to GCS (weekly/)..."
    $GSUTIL_CMD cp "$FINAL_BACKUP_FILE" "${GCS_WEEKLY_PREFIX}/"
  fi

  if [[ "$DO_MONTHLY" == "true" ]]; then
    echo "Uploading MONTHLY copy to GCS (monthly/)..."
    $GSUTIL_CMD cp "$FINAL_BACKUP_FILE" "${GCS_MONTHLY_PREFIX}/"
  fi

  echo "Cleaning up local file..."
  $RM_CMD "$FINAL_BACKUP_FILE"

  echo "--- Backup for ${DB_NAME} completed successfully. ---"
  echo ""
done

# --- Helper functions for cleanup ---
parse_backup_date_ymd() {
  # Extract YYYY-MM-DD from filename
  # Returns empty string if not found
  echo "$1" | grep -o -E '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1 || true
}

age_days_from_ymd() {
  local ymd="$1"
  local now_s
  local then_s
  now_s=$(date +%s)
  then_s=$(date -d "$ymd" +%s)
  echo $(( (now_s - then_s) / 86400 ))
}

age_months_from_ymd() {
  # Month-diff ignoring day-of-month; good for "6 months or older" retention
  local ymd="$1"
  local by bm cy cm
  by=$(date -d "$ymd" +%Y)
  bm=$(date -d "$ymd" +%m)
  cy=$(date +%Y)
  cm=$(date +%m)
  echo $(( (10#$cy*12 + 10#$cm) - (10#$by*12 + 10#$bm) ))
}

cleanup_by_days() {
  local prefix="$1"
  local delete_age_days="$2"
  local label="$3"

  echo "--- Cleanup: ${label} in ${prefix} (delete age >= ${delete_age_days} days) ---"

  # If no files match, gsutil ls exits non-zero; guard with || true
  while read -r backup_url; do
    [[ -z "$backup_url" ]] && continue
    local file ymd age
    file=$(basename "$backup_url")
    ymd=$(parse_backup_date_ymd "$file")
    if [[ -z "$ymd" ]]; then
      echo "Skipping (no date found): $file"
      continue
    fi
    age=$(age_days_from_ymd "$ymd")
    if (( age >= delete_age_days )); then
      echo "Deleting (${age}d): $file"
      $GSUTIL_CMD rm "$backup_url"
    else
      echo "Keeping  (${age}d): $file"
    fi
  done < <($GSUTIL_CMD ls "${prefix}/*.sql.gz" 2>/dev/null | sort -r || true)

  echo "--- Cleanup: ${label} completed ---"
  echo ""
}

cleanup_by_months() {
  local prefix="$1"
  local delete_age_months="$2"
  local label="$3"

  echo "--- Cleanup: ${label} in ${prefix} (delete age >= ${delete_age_months} months) ---"

  while read -r backup_url; do
    [[ -z "$backup_url" ]] && continue
    local file ymd age_m
    file=$(basename "$backup_url")
    ymd=$(parse_backup_date_ymd "$file")
    if [[ -z "$ymd" ]]; then
      echo "Skipping (no date found): $file"
      continue
    fi
    age_m=$(age_months_from_ymd "$ymd")
    if (( age_m >= delete_age_months )); then
      echo "Deleting (${age_m}mo): $file"
      $GSUTIL_CMD rm "$backup_url"
    else
      echo "Keeping  (${age_m}mo): $file"
    fi
  done < <($GSUTIL_CMD ls "${prefix}/*.sql.gz" 2>/dev/null | sort -r || true)

  echo "--- Cleanup: ${label} completed ---"
  echo ""
}

# --- Cleanup execution (per tier) ---
cleanup_by_days   "${GCS_DAILY_PREFIX}"   "$DAILY_DELETE_AGE_DAYS"   "DAILY (bucket root)"
cleanup_by_days   "${GCS_WEEKLY_PREFIX}"  "$WEEKLY_DELETE_AGE_DAYS"  "WEEKLY (weekly/)"
cleanup_by_months "${GCS_MONTHLY_PREFIX}" "$MONTHLY_DELETE_AGE_MONTHS" "MONTHLY (monthly/)"

echo "All done."
