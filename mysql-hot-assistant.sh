#!/bin/bash

# Default configurations
BACKUP_DIR="/path/on/host/backup" # Directory on host where backups will be stored
LOG_DIR="/path/on/host/logs"      # Directory where logs will be stored
CONTAINER_BACKUP_DIR="/var/lib/mysql-backup" # Directory in container for backup (customizable)
MYSQL_USER="root"
MYSQL_PASSWORD="my-secret-pw"
MARIADB_HOST="127.0.0.1"
MARIADB_PORT="3306"
CONTAINER_NAME="mariadb"
REMOTE_SERVER="user@remote_server:/path/to/destination"
MODE=""        # Can be 'backup' or 'restore'
CONTAINERIZED=false  # By default assume it's running locally
RESTORE_FILE=""
FORCE=false    # Default is no force
TIMESTAMP=$(date +"%F_%H%M%S")  # Avoids ':' in timestamps
LOG_FILE="$LOG_DIR/mysql-backup-restore-$TIMESTAMP.log"
LOCK_FILE="/tmp/mysql_backup_restore.lock"
LOCK_PID_FILE="/tmp/mysql_backup_restore.pid"

# Helper function to display usage
usage() {
  echo "Usage: $0 [--backup | --restore] [options]"
  echo ""
  echo "Options:"
  echo "  --backup                     Perform a backup of the database."
  echo "  --restore                    Restore the database from a backup."
  echo "  --file FILE_PATH             Specify the backup file for restoring."
  echo "  --remote USER@REMOTE:PATH     Remote server for backup transfer (optional)."
  echo "  --container-name NAME         MariaDB container name if running inside Docker."
  echo "  --host HOSTNAME               MariaDB host for connection (default: 127.0.0.1)."
  echo "  --port PORT                   MariaDB port (default: 3306)."
  echo "  --user USERNAME               MariaDB user (default: root)."
  echo "  --password PASSWORD           MariaDB password."
  echo "  --log-dir PATH                Directory where logs will be stored."
  echo "  --backup-dir PATH             Directory where backups will be saved."
  echo "  --force                       Force stop any existing process and run the script."
  echo ""
  exit 1
}

# Parse options
while [[ "$1" != "" ]]; do
  case $1 in
    --backup )          MODE="backup" ;;
    --restore )         MODE="restore" ;;
    --file )            shift; RESTORE_FILE=$1 ;;
    --remote )          shift; REMOTE_SERVER=$1 ;;
    --container-name )  shift; CONTAINER_NAME=$1; CONTAINERIZED=true ;;
    --host )            shift; MARIADB_HOST=$1 ;;
    --port )            shift; MARIADB_PORT=$1 ;;
    --user )            shift; MYSQL_USER=$1 ;;
    --password )        shift; MYSQL_PASSWORD=$1 ;;
    --log-dir )         shift; LOG_DIR=$1 ;;
    --backup-dir )      shift; BACKUP_DIR=$1 ;;
    --force )           FORCE=true ;;
    * )                 usage ;;
  esac
  shift
done

# Function to log messages
log_message() {
  echo "$1" | tee -a $LOG_FILE
}

# Function to check and handle concurrency
check_concurrency() {
  if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat $LOCK_PID_FILE)
    if ps -p $LOCK_PID > /dev/null 2>&1; then
      if [ "$FORCE" == "true" ]; then
        log_message "Force enabled: Terminating previous process with PID $LOCK_PID."
        kill -9 $LOCK_PID
        rm -f $LOCK_FILE $LOCK_PID_FILE
      else
        log_message "Another instance is running (PID: $LOCK_PID). Use --force to terminate it."
        exit 1
      fi
    else
      rm -f $LOCK_FILE $LOCK_PID_FILE
    fi
  fi
  echo $$ > $LOCK_PID_FILE
  touch $LOCK_FILE
}

# Cleanup lock file after script completes
cleanup_lock() {
  rm -f $LOCK_FILE $LOCK_PID_FILE
}

# Function to perform a backup
perform_backup() {
  TIMESTAMP=$(date +"%F_%H%M%S")
  BACKUP_FILE="$BACKUP_DIR/full-backup-$TIMESTAMP.tar.gz"
  log_message "Starting backup at $TIMESTAMP"

  if $CONTAINERIZED; then
    docker exec $CONTAINER_NAME bash -c "mariadb-backup --backup --target-dir=$CONTAINER_BACKUP_DIR/full-backup-$TIMESTAMP" 2>&1 | tee -a $LOG_FILE
    docker exec $CONTAINER_NAME bash -c "tar czvf $CONTAINER_BACKUP_DIR/full-backup-$TIMESTAMP.tar.gz -C $CONTAINER_BACKUP_DIR full-backup-$TIMESTAMP" 2>&1 | tee -a $LOG_FILE
    # No docker cp, backup is automatically mounted on host
  else
    mariadb-backup --backup --target-dir=$BACKUP_DIR/full-backup-$TIMESTAMP --host=$MARIADB_HOST --port=$MARIADB_PORT --user=$MYSQL_USER --password=$MYSQL_PASSWORD 2>&1 | tee -a $LOG_FILE
    tar czvf $BACKUP_FILE -C $BACKUP_DIR full-backup-$TIMESTAMP 2>&1 | tee -a $LOG_FILE
  fi

  log_message "Backup completed: $BACKUP_FILE"
  rm -rf "$BACKUP_DIR/full-backup-$TIMESTAMP"
}

# Function to perform a restore
perform_restore() {
  log_message "Starting restore from $RESTORE_FILE"

  if [ ! -f "$RESTORE_FILE" ]; then
    log_message "Error: Backup file $RESTORE_FILE does not exist."
    exit 1
  fi

  if $CONTAINERIZED; then
    docker exec $CONTAINER_NAME bash -c "tar xzvf $RESTORE_FILE -C $CONTAINER_BACKUP_DIR" 2>&1 | tee -a $LOG_FILE
    docker exec $CONTAINER_NAME bash -c "mariadb-backup --prepare --target-dir=$CONTAINER_BACKUP_DIR/full-backup" 2>&1 | tee -a $LOG_FILE
    docker exec $CONTAINER_NAME bash -c "mariadb-backup --copy-back --target-dir=$CONTAINER_BACKUP_DIR/full-backup" 2>&1 | tee -a $LOG_FILE
  else
    tar xzvf $RESTORE_FILE -C $BACKUP_DIR 2>&1 | tee -a $LOG_FILE
    mariadb-backup --prepare --target-dir=$BACKUP_DIR/full-backup 2>&1 | tee -a $LOG_FILE
    mariadb-backup --copy-back --target-dir=$BACKUP_DIR/full-backup 2>&1 | tee -a $LOG_FILE
  fi

  log_message "Restore completed from $RESTORE_FILE"
  rm -rf "$BACKUP_DIR/full-backup"
}

# Transfer backup to a remote server
transfer_backup() {
  if [ -z "$REMOTE_SERVER" ]; then
    log_message "Remote server not configured. Skipping transfer."
    return
  fi

  log_message "Transferring backup to remote server..."
  scp $BACKUP_FILE $REMOTE_SERVER 2>&1 | tee -a $LOG_FILE
  log_message "Backup transferred to $REMOTE_SERVER"
}

# Main workflow
check_concurrency

if [ "$MODE" == "backup" ]; then
  perform_backup
  transfer_backup
elif [ "$MODE" == "restore" ]; then
  perform_restore
else
  usage
fi

cleanup_lock
log_message "Process finished at $(date)"
