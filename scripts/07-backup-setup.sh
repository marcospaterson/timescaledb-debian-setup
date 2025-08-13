#!/bin/bash
# 07-backup-setup.sh
# Automated backup system setup for TimescaleDB
# 
# This script creates a comprehensive backup system including:
# - Automated daily, weekly, and monthly backups
# - Backup retention policies
# - Backup verification and restoration testing
# - Monitoring and alerting for backup failures

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOGFILE="/var/log/backup-setup-$(date +%Y%m%d_%H%M%S).log"

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

error() {
    log "${RED}ERROR: $1${NC}" >&2
    exit 1
}

success() {
    log "${GREEN}SUCCESS: $1${NC}"
}

warning() {
    log "${YELLOW}WARNING: $1${NC}"
}

info() {
    log "${BLUE}INFO: $1${NC}"
}

# Load environment variables
if [ -f ".env" ]; then
    source .env
else
    warning ".env file not found, using defaults"
fi

# Set default values
DB_NAME=${DB_NAME:-"trading_db"}
DB_USER=${DB_USER:-"postgres"}
TSDB_DATA_PATH=${TSDB_DATA_PATH:-"/mnt/timescaledb-data"}
BACKUP_PATH=${BACKUP_PATH:-"$TSDB_DATA_PATH/backups"}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

info "Starting backup system setup..."
info "Database: $DB_NAME"
info "Backup path: $BACKUP_PATH"
info "Retention: $BACKUP_RETENTION_DAYS days"

# Verify TimescaleDB is running
if ! docker ps --format '{{.Names}}' | grep -q "timescaledb"; then
    error "TimescaleDB container is not running"
fi

# Create backup directory structure
info "Creating backup directory structure..."
mkdir -p "$BACKUP_PATH"/{daily,weekly,monthly,archive,restore-tests}
mkdir -p /opt/timescaledb/{scripts,logs}
chown -R root:root "$BACKUP_PATH"
chmod -R 755 "$BACKUP_PATH"
success "Backup directory structure created"

# Create backup configuration file
info "Creating backup configuration..."
cat > /opt/timescaledb/backup.conf << EOF
# TimescaleDB Backup Configuration
# Generated: $(date)

# Database settings
CONTAINER_NAME="timescaledb"
DB_NAME="$DB_NAME"
DB_USER="postgres"

# Backup settings
BACKUP_BASE_PATH="$BACKUP_PATH"
DAILY_BACKUP_PATH="$BACKUP_PATH/daily"
WEEKLY_BACKUP_PATH="$BACKUP_PATH/weekly"
MONTHLY_BACKUP_PATH="$BACKUP_PATH/monthly"
ARCHIVE_PATH="$BACKUP_PATH/archive"

# Retention settings (in days)
DAILY_RETENTION=7
WEEKLY_RETENTION=28
MONTHLY_RETENTION=365
ARCHIVE_RETENTION=1825  # 5 years

# Backup options
BACKUP_FORMAT="custom"  # custom, plain, tar
COMPRESSION_LEVEL=6
PARALLEL_JOBS=2

# Monitoring
ENABLE_BACKUP_VERIFICATION=true
ENABLE_EMAIL_ALERTS=false
EMAIL_RECIPIENT=""

# S3/Remote backup settings (optional)
ENABLE_REMOTE_BACKUP=false
S3_BUCKET=""
S3_PREFIX="timescaledb-backups"
AWS_REGION="us-east-1"
EOF

success "Backup configuration created"

# Create main backup script
info "Creating main backup script..."
cat > /opt/timescaledb/scripts/backup-database.sh << 'EOF'
#!/bin/bash
# TimescaleDB backup script with comprehensive features

# Load configuration
source /opt/timescaledb/backup.conf

# Setup logging
BACKUP_LOG="/opt/timescaledb/logs/backup-$(date +%Y%m%d).log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

log_backup() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$BACKUP_LOG"
}

# Function to create backup
create_backup() {
    local backup_type="$1"
    local backup_path="$2"
    local retention_days="$3"
    
    log_backup "Starting $backup_type backup..."
    
    # Create backup filename
    local backup_file="$backup_path/${DB_NAME}_${backup_type}_${TIMESTAMP}.backup"
    local metadata_file="$backup_path/${DB_NAME}_${backup_type}_${TIMESTAMP}_metadata.txt"
    
    # Create metadata file
    cat > "$metadata_file" << METADATA_EOF
Backup Type: $backup_type
Database: $DB_NAME
Timestamp: $(date)
Backup File: $(basename "$backup_file")
Server Version: $(docker exec $CONTAINER_NAME psql -U $DB_USER -t -c "SELECT version();" 2>/dev/null | head -1 | sed 's/^ *//')
TimescaleDB Version: $(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null | tr -d ' ')
Database Size: $(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null | tr -d ' ')
Table Count: $(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')
Hypertable Count: $(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT count(*) FROM timescaledb_information.hypertables;" 2>/dev/null | tr -d ' ')
METADATA_EOF
    
    # Perform backup
    log_backup "Creating backup: $(basename "$backup_file")"
    
    if docker exec $CONTAINER_NAME pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=custom \
        --compress="$COMPRESSION_LEVEL" \
        --jobs="$PARALLEL_JOBS" \
        --verbose \
        > "$backup_file" 2>>"$BACKUP_LOG"; then
        
        log_backup "Backup created successfully: $(basename "$backup_file")"
        
        # Calculate backup size
        local backup_size=$(du -h "$backup_file" | cut -f1)
        echo "Backup Size: $backup_size" >> "$metadata_file"
        
        # Verify backup integrity
        if [ "$ENABLE_BACKUP_VERIFICATION" = "true" ]; then
            log_backup "Verifying backup integrity..."
            if docker exec $CONTAINER_NAME pg_restore --list "$backup_file" > /dev/null 2>&1; then
                log_backup "Backup verification successful"
                echo "Verification: PASSED" >> "$metadata_file"
            else
                log_backup "ERROR: Backup verification failed"
                echo "Verification: FAILED" >> "$metadata_file"
                return 1
            fi
        fi
        
        log_backup "$backup_type backup completed successfully (size: $backup_size)"
        
    else
        log_backup "ERROR: Backup failed"
        return 1
    fi
    
    # Clean up old backups
    log_backup "Cleaning up old $backup_type backups (retention: $retention_days days)"
    find "$backup_path" -name "*_${backup_type}_*.backup" -mtime +$retention_days -exec rm -f {} \;
    find "$backup_path" -name "*_${backup_type}_*_metadata.txt" -mtime +$retention_days -exec rm -f {} \;
    
    # Remote backup (if enabled)
    if [ "$ENABLE_REMOTE_BACKUP" = "true" ] && [ -n "$S3_BUCKET" ]; then
        log_backup "Uploading backup to S3..."
        aws s3 cp "$backup_file" "s3://$S3_BUCKET/$S3_PREFIX/$(basename "$backup_file")" && \
        aws s3 cp "$metadata_file" "s3://$S3_BUCKET/$S3_PREFIX/$(basename "$metadata_file")"
        log_backup "Remote backup uploaded to S3"
    fi
    
    return 0
}

# Function to send alert email
send_alert() {
    local subject="$1"
    local message="$2"
    
    if [ "$ENABLE_EMAIL_ALERTS" = "true" ] && [ -n "$EMAIL_RECIPIENT" ]; then
        echo "$message" | mail -s "$subject" "$EMAIL_RECIPIENT"
        log_backup "Alert email sent: $subject"
    fi
}

# Main backup logic
case "$1" in
    daily)
        if create_backup "daily" "$DAILY_BACKUP_PATH" "$DAILY_RETENTION"; then
            log_backup "Daily backup completed successfully"
        else
            send_alert "TimescaleDB Daily Backup Failed" "Daily backup failed on $(date). Check logs: $BACKUP_LOG"
            exit 1
        fi
        ;;
    weekly)
        if create_backup "weekly" "$WEEKLY_BACKUP_PATH" "$WEEKLY_RETENTION"; then
            log_backup "Weekly backup completed successfully"
        else
            send_alert "TimescaleDB Weekly Backup Failed" "Weekly backup failed on $(date). Check logs: $BACKUP_LOG"
            exit 1
        fi
        ;;
    monthly)
        if create_backup "monthly" "$MONTHLY_BACKUP_PATH" "$MONTHLY_RETENTION"; then
            log_backup "Monthly backup completed successfully"
        else
            send_alert "TimescaleDB Monthly Backup Failed" "Monthly backup failed on $(date). Check logs: $BACKUP_LOG"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {daily|weekly|monthly}"
        echo "Example: $0 daily"
        exit 1
        ;;
esac

log_backup "Backup process completed"
EOF

chmod +x /opt/timescaledb/scripts/backup-database.sh
success "Main backup script created"

# Create backup restoration script
info "Creating backup restoration script..."
cat > /opt/timescaledb/scripts/restore-database.sh << 'EOF'
#!/bin/bash
# TimescaleDB backup restoration script

source /opt/timescaledb/backup.conf

RESTORE_LOG="/opt/timescaledb/logs/restore-$(date +%Y%m%d_%H%M%S).log"

log_restore() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$RESTORE_LOG"
}

usage() {
    echo "Usage: $0 <backup_file> [target_database]"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/backup.backup"
    echo "  $0 /path/to/backup.backup restored_db"
    echo ""
    echo "Available backups:"
    find "$BACKUP_BASE_PATH" -name "*.backup" -type f | sort -r | head -10
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

BACKUP_FILE="$1"
TARGET_DB="${2:-${DB_NAME}_restored_$(date +%Y%m%d_%H%M%S)}"

if [ ! -f "$BACKUP_FILE" ]; then
    log_restore "ERROR: Backup file not found: $BACKUP_FILE"
    exit 1
fi

log_restore "Starting database restoration..."
log_restore "Backup file: $BACKUP_FILE"
log_restore "Target database: $TARGET_DB"

# Create target database
log_restore "Creating target database: $TARGET_DB"
docker exec $CONTAINER_NAME psql -U postgres -c "CREATE DATABASE \"$TARGET_DB\";" 2>>"$RESTORE_LOG"

# Install extensions in target database
log_restore "Installing required extensions..."
docker exec $CONTAINER_NAME psql -U postgres -d "$TARGET_DB" -c "
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
" 2>>"$RESTORE_LOG"

# Restore backup
log_restore "Restoring backup data..."
if docker exec -i $CONTAINER_NAME pg_restore \
    -U postgres \
    -d "$TARGET_DB" \
    --verbose \
    --jobs="$PARALLEL_JOBS" \
    < "$BACKUP_FILE" 2>>"$RESTORE_LOG"; then
    
    log_restore "Database restoration completed successfully"
    
    # Verify restoration
    log_restore "Verifying restored database..."
    TABLE_COUNT=$(docker exec $CONTAINER_NAME psql -U postgres -d "$TARGET_DB" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')
    HYPERTABLE_COUNT=$(docker exec $CONTAINER_NAME psql -U postgres -d "$TARGET_DB" -t -c "SELECT count(*) FROM timescaledb_information.hypertables;" 2>/dev/null | tr -d ' ')
    
    log_restore "Restoration verification:"
    log_restore "- Tables restored: $TABLE_COUNT"
    log_restore "- Hypertables restored: $HYPERTABLE_COUNT"
    log_restore "- Target database: $TARGET_DB"
    
    echo "Restoration completed successfully!"
    echo "Restored database: $TARGET_DB"
    echo "Log file: $RESTORE_LOG"
    
else
    log_restore "ERROR: Database restoration failed"
    docker exec $CONTAINER_NAME psql -U postgres -c "DROP DATABASE IF EXISTS \"$TARGET_DB\";" 2>>"$RESTORE_LOG"
    exit 1
fi
EOF

chmod +x /opt/timescaledb/scripts/restore-database.sh
success "Backup restoration script created"

# Create backup monitoring script
info "Creating backup monitoring script..."
cat > /opt/timescaledb/scripts/backup-monitor.sh << 'EOF'
#!/bin/bash
# Backup monitoring and health check script

source /opt/timescaledb/backup.conf

MONITOR_LOG="/opt/timescaledb/logs/backup-monitor.log"

log_monitor() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$MONITOR_LOG"
}

# Check if recent backup exists
check_recent_backup() {
    local backup_type="$1"
    local backup_path="$2"
    local max_age_hours="$3"
    
    local recent_backup=$(find "$backup_path" -name "*_${backup_type}_*.backup" -mtime -1 | head -1)
    
    if [ -n "$recent_backup" ]; then
        local backup_age=$(stat -c %Y "$recent_backup")
        local current_time=$(date +%s)
        local age_hours=$(( (current_time - backup_age) / 3600 ))
        
        if [ $age_hours -lt $max_age_hours ]; then
            log_monitor "OK: Recent $backup_type backup found (${age_hours}h old)"
            return 0
        else
            log_monitor "WARNING: $backup_type backup is ${age_hours}h old (threshold: ${max_age_hours}h)"
            return 1
        fi
    else
        log_monitor "ERROR: No recent $backup_type backup found"
        return 1
    fi
}

# Check backup integrity
check_backup_integrity() {
    local backup_file="$1"
    
    if docker exec $CONTAINER_NAME pg_restore --list "$backup_file" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Monitor backup storage space
check_backup_storage() {
    local usage=$(df "$BACKUP_BASE_PATH" | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [ "$usage" -gt 85 ]; then
        log_monitor "WARNING: Backup storage is ${usage}% full"
        return 1
    elif [ "$usage" -gt 95 ]; then
        log_monitor "ERROR: Backup storage is ${usage}% full - critical"
        return 2
    else
        log_monitor "OK: Backup storage usage: ${usage}%"
        return 0
    fi
}

# Main monitoring logic
log_monitor "Starting backup monitoring check..."

# Check recent backups
check_recent_backup "daily" "$DAILY_BACKUP_PATH" 30
DAILY_STATUS=$?

check_recent_backup "weekly" "$WEEKLY_BACKUP_PATH" 168  # 7 days
WEEKLY_STATUS=$?

# Check storage
check_backup_storage
STORAGE_STATUS=$?

# Check latest backup integrity
LATEST_BACKUP=$(find "$BACKUP_BASE_PATH" -name "*.backup" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
if [ -n "$LATEST_BACKUP" ]; then
    if check_backup_integrity "$LATEST_BACKUP"; then
        log_monitor "OK: Latest backup integrity check passed"
        INTEGRITY_STATUS=0
    else
        log_monitor "ERROR: Latest backup integrity check failed"
        INTEGRITY_STATUS=1
    fi
else
    log_monitor "WARNING: No backup files found for integrity check"
    INTEGRITY_STATUS=1
fi

# Generate summary
if [ $DAILY_STATUS -eq 0 ] && [ $WEEKLY_STATUS -eq 0 ] && [ $STORAGE_STATUS -eq 0 ] && [ $INTEGRITY_STATUS -eq 0 ]; then
    log_monitor "SUMMARY: All backup checks passed"
    exit 0
else
    log_monitor "SUMMARY: Some backup checks failed"
    exit 1
fi
EOF

chmod +x /opt/timescaledb/scripts/backup-monitor.sh
success "Backup monitoring script created"

# Create backup report script
info "Creating backup report script..."
cat > /opt/timescaledb/scripts/backup-report.sh << 'EOF'
#!/bin/bash
# Generate backup status report

source /opt/timescaledb/backup.conf

echo "TimescaleDB Backup Status Report"
echo "================================"
echo "Generated: $(date)"
echo "Database: $DB_NAME"
echo ""

# Daily backups
echo "Daily Backups:"
echo "--------------"
if [ -d "$DAILY_BACKUP_PATH" ]; then
    find "$DAILY_BACKUP_PATH" -name "*.backup" -type f | sort -r | head -7 | while read backup; do
        size=$(du -h "$backup" | cut -f1)
        date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
        echo "  $(basename "$backup") - $size - $date"
    done
else
    echo "  No daily backup directory found"
fi
echo ""

# Weekly backups
echo "Weekly Backups:"
echo "---------------"
if [ -d "$WEEKLY_BACKUP_PATH" ]; then
    find "$WEEKLY_BACKUP_PATH" -name "*.backup" -type f | sort -r | head -4 | while read backup; do
        size=$(du -h "$backup" | cut -f1)
        date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
        echo "  $(basename "$backup") - $size - $date"
    done
else
    echo "  No weekly backup directory found"
fi
echo ""

# Monthly backups
echo "Monthly Backups:"
echo "----------------"
if [ -d "$MONTHLY_BACKUP_PATH" ]; then
    find "$MONTHLY_BACKUP_PATH" -name "*.backup" -type f | sort -r | head -12 | while read backup; do
        size=$(du -h "$backup" | cut -f1)
        date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
        echo "  $(basename "$backup") - $size - $date"
    done
else
    echo "  No monthly backup directory found"
fi
echo ""

# Storage usage
echo "Storage Usage:"
echo "--------------"
if [ -d "$BACKUP_BASE_PATH" ]; then
    echo "  Total backup size: $(du -sh "$BACKUP_BASE_PATH" | cut -f1)"
    echo "  Disk usage: $(df -h "$BACKUP_BASE_PATH" | tail -1 | awk '{print $5}') ($(df -h "$BACKUP_BASE_PATH" | tail -1 | awk '{print $3}') used of $(df -h "$BACKUP_BASE_PATH" | tail -1 | awk '{print $2}'))"
    echo ""
    
    # Breakdown by type
    for type in daily weekly monthly; do
        path_var="${type^^}_BACKUP_PATH"
        path=${!path_var}
        if [ -d "$path" ]; then
            size=$(du -sh "$path" 2>/dev/null | cut -f1)
            count=$(find "$path" -name "*.backup" -type f | wc -l)
            echo "  $type: $size ($count files)"
        fi
    done
fi
echo ""

# Last backup status
echo "Last Backup Status:"
echo "-------------------"
LAST_LOG=$(find /opt/timescaledb/logs -name "backup-*.log" -type f | sort | tail -1)
if [ -n "$LAST_LOG" ]; then
    echo "  Last backup log: $(basename "$LAST_LOG")"
    if grep -q "completed successfully" "$LAST_LOG"; then
        echo "  Status: SUCCESS"
    else
        echo "  Status: CHECK LOG - may have failed"
    fi
    echo "  Log entries:"
    tail -5 "$LAST_LOG" | sed 's/^/    /'
else
    echo "  No backup logs found"
fi
EOF

chmod +x /opt/timescaledb/scripts/backup-report.sh
success "Backup report script created"

# Schedule backup jobs
info "Setting up backup schedule..."

# Remove any existing backup cron jobs
crontab -l 2>/dev/null | grep -v "backup-database.sh" | crontab -

# Add new backup schedule
(crontab -l 2>/dev/null; cat << CRON_EOF
# TimescaleDB Backup Schedule
# Daily backup at 2 AM
0 2 * * * /opt/timescaledb/scripts/backup-database.sh daily >> /opt/timescaledb/logs/cron-backup.log 2>&1

# Weekly backup on Sunday at 3 AM  
0 3 * * 0 /opt/timescaledb/scripts/backup-database.sh weekly >> /opt/timescaledb/logs/cron-backup.log 2>&1

# Monthly backup on 1st day at 4 AM
0 4 1 * * /opt/timescaledb/scripts/backup-database.sh monthly >> /opt/timescaledb/logs/cron-backup.log 2>&1

# Backup monitoring every hour
0 * * * * /opt/timescaledb/scripts/backup-monitor.sh >> /opt/timescaledb/logs/cron-monitor.log 2>&1
CRON_EOF
) | crontab -

success "Backup schedule configured"

# Setup log rotation for backup logs
info "Configuring log rotation for backup logs..."
cat > /etc/logrotate.d/timescaledb-backup << 'EOF'
/opt/timescaledb/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
    postrotate
        # Restart rsyslog if needed
        /bin/kill -HUP $(cat /var/run/rsyslogd.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
EOF

success "Log rotation configured for backup logs"

# Create initial test backup
info "Creating initial test backup..."
if /opt/timescaledb/scripts/backup-database.sh daily; then
    success "Initial test backup created successfully"
else
    warning "Initial test backup failed - check configuration"
fi

# Generate setup summary
cat > /opt/timescaledb/backup-setup-summary.txt << EOF
TimescaleDB Backup System Summary
Generated: $(date)

Configuration:
- Database: $DB_NAME
- Backup Path: $BACKUP_PATH
- Retention: $BACKUP_RETENTION_DAYS days
- Format: Custom (compressed)
- Compression Level: 6
- Parallel Jobs: 2

Backup Schedule:
- Daily: Every day at 2:00 AM (retention: 7 days)
- Weekly: Every Sunday at 3:00 AM (retention: 28 days)  
- Monthly: 1st of month at 4:00 AM (retention: 365 days)
- Monitoring: Every hour

Directory Structure:
$(find "$BACKUP_PATH" -type d | head -10)

Scripts Created:
- Main backup: /opt/timescaledb/scripts/backup-database.sh
- Restoration: /opt/timescaledb/scripts/restore-database.sh
- Monitoring: /opt/timescaledb/scripts/backup-monitor.sh
- Reporting: /opt/timescaledb/scripts/backup-report.sh

Configuration File:
- Location: /opt/timescaledb/backup.conf
- Customize retention, paths, and alerting settings here

Log Files:
- Backup logs: /opt/timescaledb/logs/backup-YYYYMMDD.log
- Monitor logs: /opt/timescaledb/logs/backup-monitor.log
- Cron logs: /opt/timescaledb/logs/cron-backup.log

Usage Examples:
- Manual backup: /opt/timescaledb/scripts/backup-database.sh daily
- Restore backup: /opt/timescaledb/scripts/restore-database.sh /path/to/backup.backup
- Check status: /opt/timescaledb/scripts/backup-report.sh
- Monitor health: /opt/timescaledb/scripts/backup-monitor.sh

Current Status:
$(if [ -f "$BACKUP_PATH/daily" ]; then
    echo "- Daily backup directory: Ready"
    echo "- Latest backup: $(find "$BACKUP_PATH/daily" -name "*.backup" -type f | sort -r | head -1 | xargs -r basename)"
else
    echo "- Daily backup directory: Not yet created"
fi)

Next Steps:
1. Customize /opt/timescaledb/backup.conf if needed
2. Test backup: /opt/timescaledb/scripts/backup-database.sh daily
3. Test restore: /opt/timescaledb/scripts/restore-database.sh <backup_file>
4. Review cron schedule: crontab -l
5. Set up email alerts (optional)

Security Notes:
- Backups contain sensitive data - secure the backup directory
- Consider encrypting backups for additional security
- Regular restore testing is recommended
- Monitor backup storage space usage

Setup Log: $LOGFILE
EOF

success "Backup setup summary created"

# Display completion message
echo
echo "================================================================"
echo -e "${GREEN}Backup System Setup Completed Successfully!${NC}"
echo "================================================================"
echo
echo "Backup Configuration:"
echo "- Database: $DB_NAME"
echo "- Backup location: $BACKUP_PATH"
echo "- Retention policy: $BACKUP_RETENTION_DAYS days"
echo "- Schedule: Daily (2 AM), Weekly (Sun 3 AM), Monthly (1st 4 AM)"
echo
echo "Available Commands:"
echo "- Manual backup: /opt/timescaledb/scripts/backup-database.sh daily"
echo "- Restore backup: /opt/timescaledb/scripts/restore-database.sh <file>"
echo "- Status report: /opt/timescaledb/scripts/backup-report.sh"
echo "- Health check: /opt/timescaledb/scripts/backup-monitor.sh"
echo
echo "Cron Schedule:"
crontab -l | grep -E "(backup|monitor)" | sed 's/^/  /'
echo
echo "Test the backup system:"
echo "1. Run: /opt/timescaledb/scripts/backup-database.sh daily"
echo "2. Check: /opt/timescaledb/scripts/backup-report.sh"
echo "3. Test restore: /opt/timescaledb/scripts/restore-database.sh <backup_file>"
echo
echo "Configuration: /opt/timescaledb/backup.conf"
echo "Setup summary: /opt/timescaledb/backup-setup-summary.txt"
echo "Setup log: $LOGFILE"
echo
echo "================================================================"
