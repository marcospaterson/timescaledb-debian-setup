#!/bin/bash

# =============================================================================
# VM Security Hardening Script
# =============================================================================
# Comprehensive security hardening for TimescaleDB VM
# Implements fail2ban, UFW, SSH hardening, and system security
# =============================================================================

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging function
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${PURPLE}=== $1 ===${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root. Use sudo when needed."
        exit 1
    fi
}

# Update system packages
update_system() {
    log_section "Updating System Packages"
    sudo apt update && sudo apt upgrade -y
    log_success "System packages updated"
}

# Install security packages
install_security_packages() {
    log_section "Installing Security Packages"
    
    log_info "Installing UFW firewall..."
    sudo apt install -y ufw
    
    log_info "Installing fail2ban..."
    sudo apt install -y fail2ban
    
    log_info "Installing additional security tools..."
    sudo apt install -y \
        unattended-upgrades \
        logwatch \
        rkhunter \
        chkrootkit \
        aide \
        lynis \
        acct \
        psmisc \
        lsof \
        htop \
        iftop \
        nethogs \
        nmap
    
    log_success "Security packages installed"
}

# Configure UFW firewall
setup_ufw() {
    log_section "Configuring UFW Firewall"
    
    # Reset UFW to defaults
    sudo ufw --force reset
    
    # Set default policies
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # Allow SSH (adjust port if needed)
    SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    sudo ufw allow ${SSH_PORT}/tcp comment 'SSH'
    
    # Allow PostgreSQL/TimescaleDB (only from specific networks if needed)
    sudo ufw allow 5432/tcp comment 'PostgreSQL/TimescaleDB'
    
    # Allow HTTP/HTTPS for potential web interfaces
    sudo ufw allow 80/tcp comment 'HTTP'
    sudo ufw allow 443/tcp comment 'HTTPS'
    
    # Allow Docker network communication
    sudo ufw allow from 172.16.0.0/12 comment 'Docker networks'
    
    # Enable UFW
    sudo ufw --force enable
    
    # Show status
    sudo ufw status numbered
    
    log_success "UFW firewall configured and enabled"
}

# Configure fail2ban
setup_fail2ban() {
    log_section "Configuring fail2ban"
    
    # Create jail.local configuration
    sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
# Ignore local IP addresses
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

# Ban time (10 minutes)
bantime = 600

# Find time window (10 minutes)
findtime = 600

# Max retry attempts
maxretry = 3

# Email notifications (configure as needed)
destemail = root@localhost
sender = root@localhost
mta = sendmail
action = %(action_)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 2
bantime = 1800

[postgresql]
enabled = true
port = 5432
filter = postgresql
logpath = /var/log/postgresql/*.log
maxretry = 3
bantime = 3600

[nginx-http-auth]
enabled = false
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[nginx-noscript]
enabled = false
port = http,https
filter = nginx-noscript
logpath = /var/log/nginx/access.log
maxretry = 6
bantime = 86400

[nginx-badbots]
enabled = false
port = http,https
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
EOF

    # Create PostgreSQL filter
    sudo tee /etc/fail2ban/filter.d/postgresql.conf > /dev/null << 'EOF'
[Definition]
failregex = ^.*FATAL:.*authentication failed for user.*$
            ^.*FATAL:.*password authentication failed for user.*$
            ^.*FATAL:.*no pg_hba.conf entry for host.*$
ignoreregex =
EOF

    # Start and enable fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    
    log_success "fail2ban configured and started"
}

# Harden SSH configuration
harden_ssh() {
    log_section "Hardening SSH Configuration"
    
    # Backup original SSH config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Apply SSH hardening
    sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null << 'EOF'
# SSH Hardening Configuration

# Change default port (uncomment and modify as needed)
#Port 2222

# Protocol and security
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Authentication
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Root login
PermitRootLogin no

# User restrictions
AllowUsers msp
#DenyUsers root
MaxAuthTries 3
MaxStartups 3:30:10
LoginGraceTime 30

# Security options
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable dangerous features
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no

# Logging
SyslogFacility AUTHPRIV
LogLevel VERBOSE

# Ciphers and algorithms (modern secure options)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
EOF

    # Test SSH configuration
    if sudo sshd -t; then
        log_success "SSH configuration is valid"
        sudo systemctl restart ssh
        log_success "SSH service restarted with hardened configuration"
    else
        log_error "SSH configuration has errors. Please check manually."
        return 1
    fi
}

# Configure automatic security updates
setup_unattended_upgrades() {
    log_section "Configuring Automatic Security Updates"
    
    # Configure unattended-upgrades
    sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
    // Add packages to blacklist if needed
};

Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF

    # Enable automatic updates
    sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

    sudo systemctl enable unattended-upgrades
    sudo systemctl start unattended-upgrades
    
    log_success "Automatic security updates configured"
}

# System hardening
harden_system() {
    log_section "System Hardening"
    
    # Kernel parameter hardening
    sudo tee /etc/sysctl.d/99-security.conf > /dev/null << 'EOF'
# Network security
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Memory protection
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
EOF

    # Apply sysctl settings
    sudo sysctl -p /etc/sysctl.d/99-security.conf
    
    # Set secure file permissions
    sudo chmod 700 /root
    sudo chmod 600 /etc/ssh/sshd_config
    
    log_success "System hardening applied"
}

# Configure log monitoring
setup_log_monitoring() {
    log_section "Setting up Log Monitoring"
    
    # Configure logwatch
    sudo tee /etc/cron.daily/00logwatch > /dev/null << 'EOF'
#!/bin/bash
/usr/sbin/logwatch --output mail --mailto root --detail high
EOF
    
    sudo chmod +x /etc/cron.daily/00logwatch
    
    # Create log rotation for application logs
    sudo tee /etc/logrotate.d/timescaledb-app > /dev/null << 'EOF'
/var/log/timescaledb-app/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 msp msp
}
EOF

    log_success "Log monitoring configured"
}

# Security audit tools
setup_security_audit() {
    log_section "Setting up Security Audit Tools"
    
    # Initialize AIDE (takes a while)
    log_info "Initializing AIDE database (this may take a few minutes)..."
    sudo aide --init || log_warning "AIDE initialization failed - check manually"
    
    if [ -f /var/lib/aide/aide.db.new ]; then
        sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
        log_success "AIDE database initialized"
    fi
    
    # Create security audit script
    sudo tee /usr/local/bin/security-audit.sh > /dev/null << 'EOF'
#!/bin/bash
# Daily security audit script

echo "=== Security Audit Report $(date) ==="

echo -e "\n=== Firewall Status ==="
ufw status numbered

echo -e "\n=== Fail2ban Status ==="
fail2ban-client status

echo -e "\n=== Active Connections ==="
ss -tulnp | grep :22
ss -tulnp | grep :5432

echo -e "\n=== Failed Login Attempts ==="
grep "Failed password" /var/log/auth.log | tail -10

echo -e "\n=== Recent User Logins ==="
last -10

echo -e "\n=== System Load ==="
uptime
df -h
free -h

echo -e "\n=== Process Check ==="
ps aux --sort=-%cpu | head -10
EOF

    sudo chmod +x /usr/local/bin/security-audit.sh
    
    # Schedule daily security audit
    echo "0 6 * * * root /usr/local/bin/security-audit.sh > /var/log/security-audit.log 2>&1" | sudo tee -a /etc/crontab
    
    log_success "Security audit tools configured"
}

# Create monitoring dashboard
create_monitoring_dashboard() {
    log_section "Creating Monitoring Dashboard"
    
    tee /home/msp/security-status.sh > /dev/null << 'EOF'
#!/bin/bash
# Security Status Dashboard

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================================="
echo "         SECURITY STATUS DASHBOARD"
echo "=================================================="

# UFW Status
echo -e "\n${GREEN}Firewall Status:${NC}"
sudo ufw status | head -5

# Fail2ban Status
echo -e "\n${GREEN}Fail2ban Status:${NC}"
sudo fail2ban-client status

# SSH Connections
echo -e "\n${GREEN}Current SSH Connections:${NC}"
who

# System Resources
echo -e "\n${GREEN}System Resources:${NC}"
echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
echo "Memory: $(free -h | awk '/^Mem:/ {print $3"/"$2}')"
echo "Disk: $(df -h / | awk 'NR==2 {print $3"/"$2" ("$5" used)"}')"

# Recent Security Events
echo -e "\n${GREEN}Recent Failed Logins:${NC}"
grep "Failed password" /var/log/auth.log | tail -3 | awk '{print $1" "$2" "$3" - "$11}' || echo "No recent failures"

echo -e "\n${GREEN}Banned IPs:${NC}"
sudo fail2ban-client status sshd 2>/dev/null | grep "Banned IP list" || echo "No banned IPs"

echo "=================================================="
EOF

    chmod +x /home/msp/security-status.sh
    
    log_success "Monitoring dashboard created at ~/security-status.sh"
}

# Main execution
main() {
    log_section "VM Security Hardening Script"
    
    check_root
    
    log_info "Starting comprehensive VM security hardening..."
    log_warning "This script will modify system configurations. Ensure you have backup access!"
    
    read -p "Continue with VM hardening? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Hardening cancelled."
        exit 0
    fi
    
    update_system
    install_security_packages
    setup_ufw
    setup_fail2ban
    harden_ssh
    setup_unattended_upgrades
    harden_system
    setup_log_monitoring
    setup_security_audit
    create_monitoring_dashboard
    
    log_section "Security Hardening Complete"
    
    log_success "VM security hardening completed successfully!"
    log_info "Next steps:"
    echo "  1. Test SSH connection from another terminal before closing this session"
    echo "  2. Run ~/security-status.sh to check security status"
    echo "  3. Consider changing SSH port in /etc/ssh/sshd_config.d/99-hardening.conf"
    echo "  4. Set up SSH key authentication and disable password auth"
    echo "  5. Configure email alerts for fail2ban and logwatch"
    
    log_warning "IMPORTANT: Test your SSH connection before logging out!"
}

# Run main function
main "$@"
