#!/bin/bash
# WordPress files backup to GCS with daily/weekly/monthly retention
set -euo pipefail

# --- User Configuration ---

# Add the full paths to all the WordPress directories you want to back up.
DIRECTORIES_TO_BACKUP=(
  "/home/weedo/docker/wordpress_files/bubbelbubbel"
  "/home/weedo/docker/wordpress_files/centipod"
)

# Google Cloud Storage bucket name
GCS_BUCKET_NAME="centipod_backups"

# --- Path Configuration ---
TAR_CMD="/bin/tar"
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

# --- Schedule flags (based on today) ---
DOW=$(date +%u)   # 1=Mon ... 6=Sat 7=Sun
DOM=$(date +%d)   # 01..31

DO_WEEKLY=false
DO_MONTHLY=false
if [[ "$DOW" == "6" ]]; then
  DO_WEEKLY=true
fi
if [[ "$DOM" == "01" ]]; then
  DO_MONTHLY=true
f
