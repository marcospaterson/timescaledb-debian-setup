#!/bin/bash
# 01-vm-setup.sh
# Initial Debian VM setup with static IP configuration and system updates
# 
# This script performs the initial setup of a Debian VM including:
# - System updates and essential packages
# - Static IP configuration
# - Timezone and locale setup
# - Basic security hardening

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOGFILE="/var/log/vm-setup-$(date +%Y%m%d_%H%M%S).log"

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

# Load environment variables if .env exists
if [ -f ".env" ]; then
    source .env
    info "Loaded environment variables from .env file"
else
    warning ".env file not found, using default values"
    STATIC_IP=${STATIC_IP:-"10.0.10.30"}
    GATEWAY=${GATEWAY:-"10.0.10.1"}
    DNS_SERVERS=${DNS_SERVERS:-"8.8.8.8 8.8.4.4"}
    NETMASK=${NETMASK:-"255.255.255.0"}
    INTERFACE=${INTERFACE:-"eth0"}
    TIMEZONE=${TIMEZONE:-"UTC"}
    LOCALE=${LOCALE:-"en_US.UTF-8"}
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

info "Starting VM setup process..."
info "Target static IP: $STATIC_IP"
info "Gateway: $GATEWAY"
info "Interface: $INTERFACE"

# Update system packages
info "Updating system packages..."
apt-get update -y >> "$LOGFILE" 2>&1
apt-get upgrade -y >> "$LOGFILE" 2>&1
success "System packages updated"

# Install essential packages
info "Installing essential packages..."
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    unzip \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    fail2ban \
    rsync \
    cron \
    logrotate \
    net-tools \
    dnsutils \
    psmisc >> "$LOGFILE" 2>&1
success "Essential packages installed"

# Set timezone
info "Setting timezone to $TIMEZONE..."
timedatectl set-timezone "$TIMEZONE" >> "$LOGFILE" 2>&1
success "Timezone set to $TIMEZONE"

# Set locale
info "Setting locale to $LOCALE..."
if ! locale -a | grep -q "^$LOCALE"; then
    locale-gen "$LOCALE" >> "$LOGFILE" 2>&1
fi
update-locale LANG="$LOCALE" >> "$LOGFILE" 2>&1
success "Locale set to $LOCALE"

# Configure static IP
info "Configuring static IP address..."

# Backup current network configuration
cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)
info "Network configuration backed up"

# Create new network configuration
cat > /etc/network/interfaces << EOF
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto $INTERFACE
iface $INTERFACE inet static
    address $STATIC_IP
    netmask $NETMASK
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
EOF

success "Static IP configuration created"

# Configure DNS
info "Configuring DNS resolution..."
cat > /etc/resolv.conf << EOF
# DNS configuration
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF

success "DNS configuration updated"

# Configure hostname
info "Setting hostname..."
CURRENT_HOSTNAME=$(hostname)
NEW_HOSTNAME="timescaledb-server"
hostnamectl set-hostname "$NEW_HOSTNAME" >> "$LOGFILE" 2>&1

# Update /etc/hosts
sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1 $NEW_HOSTNAME/g" /etc/hosts
echo "$STATIC_IP $NEW_HOSTNAME" >> /etc/hosts

success "Hostname set to $NEW_HOSTNAME"

# Configure basic firewall
info "Configuring firewall (UFW)..."
ufw --force reset >> "$LOGFILE" 2>&1
ufw default deny incoming >> "$LOGFILE" 2>&1
ufw default allow outgoing >> "$LOGFILE" 2>&1

# Allow SSH
ufw allow ssh >> "$LOGFILE" 2>&1

# Allow PostgreSQL from local network (will be refined later)
ufw allow from 10.0.0.0/8 to any port 5432 >> "$LOGFILE" 2>&1

# Enable firewall
ufw --force enable >> "$LOGFILE" 2>&1
success "Basic firewall configured"

# Configure fail2ban
info "Configuring fail2ban..."
systemctl enable fail2ban >> "$LOGFILE" 2>&1
systemctl start fail2ban >> "$LOGFILE" 2>&1
success "fail2ban configured and started"

# Create system user for database operations
info "Creating database operations user..."
if ! id -u dbadmin > /dev/null 2>&1; then
    useradd -m -s /bin/bash dbadmin
    usermod -aG sudo dbadmin
    success "User 'dbadmin' created"
else
    info "User 'dbadmin' already exists"
fi

# Set up log rotation for our logs
info "Setting up log rotation..."
cat > /etc/logrotate.d/timescaledb-setup << EOF
/var/log/vm-setup-*.log
/var/log/timescaledb-*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF

success "Log rotation configured"

# Create directory structure for TimescaleDB
info "Creating directory structure..."
mkdir -p /opt/timescaledb/{scripts,config,backups,logs}
chmod 755 /opt/timescaledb
chown root:root /opt/timescaledb
success "Directory structure created"

# System optimization for database workload
info "Applying system optimizations..."

# Kernel parameters for database performance
cat >> /etc/sysctl.conf << EOF

# TimescaleDB optimizations
vm.swappiness = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
kernel.shmmax = 4294967295
kernel.shmall = 268435456
kernel.sem = 250 32000 100 128
fs.file-max = 65536
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF

# Apply the changes
sysctl -p >> "$LOGFILE" 2>&1
success "System optimizations applied"

# Configure limits
info "Configuring system limits..."
cat >> /etc/security/limits.conf << EOF

# TimescaleDB limits
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
postgres soft nofile 65536
postgres hard nofile 65536
postgres soft nproc 65536
postgres hard nproc 65536
EOF

success "System limits configured"

# Final system cleanup
info "Performing final cleanup..."
apt-get autoremove -y >> "$LOGFILE" 2>&1
apt-get autoclean >> "$LOGFILE" 2>&1
success "System cleanup completed"

# Generate setup summary
info "Generating setup summary..."
cat > /opt/timescaledb/setup-summary.txt << EOF
TimescaleDB VM Setup Summary
Generated: $(date)

Network Configuration:
- Static IP: $STATIC_IP
- Gateway: $GATEWAY
- DNS: $DNS_SERVERS
- Interface: $INTERFACE

System Configuration:
- Hostname: $NEW_HOSTNAME
- Timezone: $TIMEZONE
- Locale: $LOCALE

Security:
- Firewall: Enabled (UFW)
- Fail2ban: Active
- SSH: Port 22 (allowed)
- PostgreSQL: Port 5432 (restricted to local network)

Directories Created:
- /opt/timescaledb/scripts
- /opt/timescaledb/config
- /opt/timescaledb/backups
- /opt/timescaledb/logs

Users Created:
- dbadmin (sudo access)

Next Steps:
1. Run: ./scripts/02-mount-disk.sh (if using additional disk)
2. Run: ./scripts/03-install-docker.sh
3. Reboot the system to apply network changes

Logs: $LOGFILE
EOF

success "Setup summary created at /opt/timescaledb/setup-summary.txt"

# Display completion message
echo
echo "================================================================"
echo -e "${GREEN}VM Setup Completed Successfully!${NC}"
echo "================================================================"
echo
echo "Summary:"
echo "- System updated and essential packages installed"
echo "- Static IP configured: $STATIC_IP"
echo "- Hostname set to: $NEW_HOSTNAME"
echo "- Firewall configured and enabled"
echo "- System optimized for database workload"
echo
echo "Next Steps:"
echo "1. Reboot the system: sudo reboot"
echo "2. After reboot, run: ./scripts/02-mount-disk.sh"
echo "3. Then run: ./scripts/03-install-docker.sh"
echo
echo -e "${YELLOW}Note: A reboot is required to apply network configuration changes${NC}"
echo
echo "Setup log: $LOGFILE"
echo "Summary: /opt/timescaledb/setup-summary.txt"
echo
echo "================================================================"
