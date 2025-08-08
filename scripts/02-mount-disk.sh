#!/bin/bash
# 02-mount-disk.sh
# Disk mounting and formatting for TimescaleDB data persistence
# 
# This script handles:
# - Additional disk detection and formatting
# - Mount point creation and configuration
# - Persistent mounting via fstab
# - Directory permissions setup

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOGFILE="/var/log/disk-setup-$(date +%Y%m%d_%H%M%S).log"

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
    # Default values
    TSDB_DATA_PATH=${TSDB_DATA_PATH:-"/mnt/timescaledb-data"}
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

info "Starting disk setup process..."
info "Target data path: $TSDB_DATA_PATH"

# Function to detect additional disks
detect_disks() {
    info "Detecting available disks..."
    
    # List all block devices
    lsblk -p -o NAME,SIZE,TYPE,MOUNTPOINT | tee -a "$LOGFILE"
    
    # Find unmounted disks larger than 1GB
    AVAILABLE_DISKS=$(lsblk -p -n -o NAME,SIZE,TYPE,MOUNTPOINT | grep "disk" | grep -v "/" | awk '$3=="disk" {print $1}')
    
    if [ -z "$AVAILABLE_DISKS" ]; then
        warning "No additional unmounted disks found"
        warning "Proceeding with directory creation on root filesystem"
        return 1
    fi
    
    info "Available disks for TimescaleDB data:"
    for disk in $AVAILABLE_DISKS; do
        SIZE=$(lsblk -n -o SIZE "$disk")
        info "  $disk (Size: $SIZE)"
    done
    
    return 0
}

# Function to select and format disk
setup_disk() {
    local selected_disk=""
    
    # If only one disk available, use it
    local disk_count=$(echo "$AVAILABLE_DISKS" | wc -l)
    if [ "$disk_count" -eq 1 ]; then
        selected_disk="$AVAILABLE_DISKS"
        info "Auto-selecting disk: $selected_disk"
    else
        # Multiple disks - need user selection
        info "Multiple disks available. Please select one:"
        echo "$AVAILABLE_DISKS" | nl
        read -p "Enter disk number (or 0 to skip disk setup): " disk_num
        
        if [ "$disk_num" -eq 0 ]; then
            warning "Skipping disk setup"
            return 1
        fi
        
        selected_disk=$(echo "$AVAILABLE_DISKS" | sed -n "${disk_num}p")
    fi
    
    if [ -z "$selected_disk" ]; then
        error "Invalid disk selection"
    fi
    
    info "Selected disk: $selected_disk"
    
    # Confirm disk formatting
    warning "This will DESTROY ALL DATA on $selected_disk"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        error "Disk setup cancelled by user"
    fi
    
    # Unmount if mounted
    if mountpoint -q "$selected_disk"* 2>/dev/null; then
        info "Unmounting existing partitions..."
        umount "$selected_disk"* 2>/dev/null || true
    fi
    
    # Create partition table
    info "Creating partition table on $selected_disk..."
    parted -s "$selected_disk" mklabel gpt >> "$LOGFILE" 2>&1
    parted -s "$selected_disk" mkpart primary ext4 0% 100% >> "$LOGFILE" 2>&1
    success "Partition table created"
    
    # Wait for partition to be ready
    sleep 2
    partprobe "$selected_disk" >> "$LOGFILE" 2>&1
    sleep 2
    
    # Format the partition
    local partition="${selected_disk}1"
    info "Formatting partition $partition with ext4..."
    mkfs.ext4 -F "$partition" >> "$LOGFILE" 2>&1
    success "Partition formatted with ext4"
    
    # Set label
    e2label "$partition" "timescaledb-data" >> "$LOGFILE" 2>&1
    success "Partition labeled as 'timescaledb-data'"
    
    return 0
}

# Function to create mount point and mount disk
setup_mount() {
    local partition="$1"
    
    # Create mount point
    info "Creating mount point: $TSDB_DATA_PATH"
    mkdir -p "$TSDB_DATA_PATH"
    success "Mount point created"
    
    # Get UUID of the partition
    local uuid=$(blkid -s UUID -o value "$partition")
    info "Partition UUID: $uuid"
    
    # Create fstab entry
    info "Adding entry to /etc/fstab..."
    
    # Backup fstab
    cp /etc/fstab "/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Add mount entry
    echo "UUID=$uuid $TSDB_DATA_PATH ext4 defaults,noatime 0 2" >> /etc/fstab
    success "fstab entry added"
    
    # Mount the partition
    info "Mounting partition..."
    mount "$TSDB_DATA_PATH" >> "$LOGFILE" 2>&1
    success "Partition mounted successfully"
    
    # Verify mount
    if mountpoint -q "$TSDB_DATA_PATH"; then
        success "Mount point verification successful"
        df -h "$TSDB_DATA_PATH" | tee -a "$LOGFILE"
    else
        error "Mount verification failed"
    fi
}

# Function to setup directory structure without additional disk
setup_directory_only() {
    info "Setting up directory structure on root filesystem..."
    
    mkdir -p "$TSDB_DATA_PATH"
    success "Data directory created: $TSDB_DATA_PATH"
    
    info "Available space:"
    df -h "$(dirname $TSDB_DATA_PATH)" | tee -a "$LOGFILE"
}

# Function to set permissions and ownership
setup_permissions() {
    info "Setting up directory permissions and ownership..."
    
    # Create subdirectories for organization
    mkdir -p "$TSDB_DATA_PATH/postgresql"
    mkdir -p "$TSDB_DATA_PATH/backups"
    mkdir -p "$TSDB_DATA_PATH/logs"
    
    # Set ownership (postgres user will be created by Docker)
    # For now, set to root with appropriate permissions
    chown -R root:root "$TSDB_DATA_PATH"
    chmod -R 755 "$TSDB_DATA_PATH"
    
    # PostgreSQL data directory needs specific permissions
    chmod 700 "$TSDB_DATA_PATH/postgresql"
    
    success "Permissions and ownership configured"
    
    info "Directory structure:"
    tree "$TSDB_DATA_PATH" 2>/dev/null || ls -la "$TSDB_DATA_PATH"
}

# Function to create disk monitoring script
create_monitoring() {
    info "Creating disk monitoring script..."
    
    cat > /opt/timescaledb/scripts/disk-monitor.sh << 'EOF'
#!/bin/bash
# Disk space monitoring for TimescaleDB

TSDB_DATA_PATH="/mnt/timescaledb-data"
THRESHOLD=90
EMAIL_ALERT=""

# Check disk usage
USAGE=$(df "$TSDB_DATA_PATH" | tail -1 | awk '{print $5}' | sed 's/%//')

if [ "$USAGE" -gt "$THRESHOLD" ]; then
    MESSAGE="WARNING: TimescaleDB disk usage is ${USAGE}% (threshold: ${THRESHOLD}%)"
    echo "$(date): $MESSAGE" >> /var/log/disk-monitor.log
    
    # Send email if configured
    if [ -n "$EMAIL_ALERT" ]; then
        echo "$MESSAGE" | mail -s "TimescaleDB Disk Alert" "$EMAIL_ALERT"
    fi
    
    # Log to syslog
    logger -t timescaledb-monitor "$MESSAGE"
fi

# Log current usage
echo "$(date): Disk usage: ${USAGE}%" >> /var/log/disk-monitor.log
EOF

    chmod +x /opt/timescaledb/scripts/disk-monitor.sh
    success "Disk monitoring script created"
    
    # Add to crontab
    info "Adding disk monitoring to crontab..."
    (crontab -l 2>/dev/null; echo "*/15 * * * * /opt/timescaledb/scripts/disk-monitor.sh") | crontab -
    success "Disk monitoring scheduled (every 15 minutes)"
}

# Main execution
info "Starting disk setup process..."

# Detect available disks
if detect_disks; then
    # Additional disk found
    if setup_disk; then
        local partition="${selected_disk}1"
        setup_mount "$partition"
    else
        # User chose to skip disk setup
        setup_directory_only
    fi
else
    # No additional disk found
    setup_directory_only
fi

# Set up permissions regardless of disk setup
setup_permissions

# Create monitoring
create_monitoring

# Generate completion summary
cat > /opt/timescaledb/disk-setup-summary.txt << EOF
TimescaleDB Disk Setup Summary
Generated: $(date)

Data Path: $TSDB_DATA_PATH
Mount Type: $(if mountpoint -q "$TSDB_DATA_PATH"; then echo "Dedicated disk partition"; else echo "Directory on root filesystem"; fi)

Directory Structure:
$(ls -la "$TSDB_DATA_PATH")

Disk Usage:
$(df -h "$TSDB_DATA_PATH")

Mount Information:
$(if mountpoint -q "$TSDB_DATA_PATH"; then
    echo "Mount point: $TSDB_DATA_PATH"
    echo "Filesystem: $(findmnt -n -o FSTYPE "$TSDB_DATA_PATH")"
    echo "UUID: $(findmnt -n -o UUID "$TSDB_DATA_PATH")"
    echo "Options: $(findmnt -n -o OPTIONS "$TSDB_DATA_PATH")"
else
    echo "No dedicated mount point (using root filesystem)"
fi)

Monitoring:
- Disk monitoring script: /opt/timescaledb/scripts/disk-monitor.sh
- Scheduled check: Every 15 minutes
- Threshold: 90%
- Log file: /var/log/disk-monitor.log

Next Steps:
1. Run: ./scripts/03-install-docker.sh
2. Run: ./scripts/04-deploy-timescaledb.sh

Setup Log: $LOGFILE
EOF

success "Disk setup summary created at /opt/timescaledb/disk-setup-summary.txt"

# Display completion message
echo
echo "================================================================"
echo -e "${GREEN}Disk Setup Completed Successfully!${NC}"
echo "================================================================"
echo
echo "Summary:"
echo "- Data directory: $TSDB_DATA_PATH"
if mountpoint -q "$TSDB_DATA_PATH"; then
    echo "- Mount type: Dedicated disk partition"
    echo "- Available space: $(df -h "$TSDB_DATA_PATH" | tail -1 | awk '{print $4}')"
else
    echo "- Mount type: Directory on root filesystem"
    echo "- Available space: $(df -h "$(dirname $TSDB_DATA_PATH)" | tail -1 | awk '{print $4}')"
fi
echo "- Permissions configured for PostgreSQL"
echo "- Disk monitoring enabled"
echo
echo "Next Steps:"
echo "1. Run: ./scripts/03-install-docker.sh"
echo "2. Run: ./scripts/04-deploy-timescaledb.sh"
echo
echo "Setup log: $LOGFILE"
echo "Summary: /opt/timescaledb/disk-setup-summary.txt"
echo
echo "================================================================"
