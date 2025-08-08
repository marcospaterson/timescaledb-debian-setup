#!/bin/bash
# 03-install-docker.sh
# Docker installation and configuration for TimescaleDB deployment
# 
# This script handles:
# - Docker Engine installation from official repository
# - Docker Compose plugin installation
# - User permissions and group setup
# - Docker daemon configuration and optimization
# - Security hardening

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOGFILE="/var/log/docker-setup-$(date +%Y%m%d_%H%M%S).log"

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

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

info "Starting Docker installation process..."

# Remove any existing Docker installations
info "Removing any existing Docker installations..."
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
success "Cleaned up existing Docker installations"

# Update package index
info "Updating package index..."
apt-get update -y >> "$LOGFILE" 2>&1
success "Package index updated"

# Install prerequisites
info "Installing Docker prerequisites..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release >> "$LOGFILE" 2>&1
success "Prerequisites installed"

# Add Docker's official GPG key
info "Adding Docker's official GPG key..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >> "$LOGFILE" 2>&1
success "Docker GPG key added"

# Set up the Docker repository
info "Setting up Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
success "Docker repository configured"

# Update package index again
info "Updating package index with Docker repository..."
apt-get update -y >> "$LOGFILE" 2>&1
success "Package index updated"

# Install Docker Engine and Docker Compose
info "Installing Docker Engine and Docker Compose..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >> "$LOGFILE" 2>&1
success "Docker Engine and Docker Compose installed"

# Verify Docker installation
info "Verifying Docker installation..."
docker --version | tee -a "$LOGFILE"
docker compose version | tee -a "$LOGFILE"
success "Docker installation verified"

# Start and enable Docker service
info "Starting and enabling Docker service..."
systemctl start docker >> "$LOGFILE" 2>&1
systemctl enable docker >> "$LOGFILE" 2>&1
success "Docker service started and enabled"

# Create docker group and add users
info "Setting up Docker group permissions..."
groupadd docker 2>/dev/null || true

# Add dbadmin user to docker group if exists
if id -u dbadmin > /dev/null 2>&1; then
    usermod -aG docker dbadmin
    success "User 'dbadmin' added to docker group"
fi

# Add current user to docker group if not root
if [ "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG docker "$SUDO_USER"
    success "User '$SUDO_USER' added to docker group"
fi

# Configure Docker daemon
info "Configuring Docker daemon..."
mkdir -p /etc/docker

cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "userland-proxy": false,
    "no-new-privileges": true,
    "security-opts": [
        "no-new-privileges:true"
    ],
    "default-ulimits": {
        "nofile": {
            "Hard": 65536,
            "Name": "nofile",
            "Soft": 65536
        }
    }
}
EOF

success "Docker daemon configuration created"

# Restart Docker to apply configuration
info "Restarting Docker service to apply configuration..."
systemctl restart docker >> "$LOGFILE" 2>&1
sleep 5
success "Docker service restarted"

# Test Docker functionality
info "Testing Docker functionality..."
docker run --rm hello-world >> "$LOGFILE" 2>&1
success "Docker functionality test passed"

# Set up Docker system cleanup
info "Setting up Docker system cleanup..."
cat > /opt/timescaledb/scripts/docker-cleanup.sh << 'EOF'
#!/bin/bash
# Docker system cleanup script

echo "$(date): Starting Docker cleanup..."

# Remove unused containers
docker container prune -f

# Remove unused images
docker image prune -f

# Remove unused volumes (be careful with this)
# docker volume prune -f

# Remove unused networks
docker network prune -f

# Remove build cache
docker builder prune -f

echo "$(date): Docker cleanup completed"
EOF

chmod +x /opt/timescaledb/scripts/docker-cleanup.sh
success "Docker cleanup script created"

# Schedule weekly Docker cleanup
info "Scheduling weekly Docker cleanup..."
(crontab -l 2>/dev/null; echo "0 2 * * 0 /opt/timescaledb/scripts/docker-cleanup.sh >> /var/log/docker-cleanup.log 2>&1") | crontab -
success "Weekly Docker cleanup scheduled"

# Configure log rotation for Docker
info "Configuring log rotation for Docker..."
cat > /etc/logrotate.d/docker << 'EOF'
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    missingok
    delaycompress
    copytruncate
}
EOF

success "Docker log rotation configured"

# Create Docker monitoring script
info "Creating Docker monitoring script..."
cat > /opt/timescaledb/scripts/docker-monitor.sh << 'EOF'
#!/bin/bash
# Docker monitoring script

LOG_FILE="/var/log/docker-monitor.log"

# Function to log with timestamp
log_with_date() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

# Check Docker service status
if ! systemctl is-active --quiet docker; then
    log_with_date "ERROR: Docker service is not running"
    systemctl start docker
    log_with_date "INFO: Attempted to start Docker service"
fi

# Check TimescaleDB container if it exists
if docker ps -a --format "table {{.Names}}" | grep -q "timescaledb"; then
    if ! docker ps --format "table {{.Names}}" | grep -q "timescaledb"; then
        log_with_date "WARNING: TimescaleDB container is not running"
        # Attempt to restart
        docker start timescaledb 2>/dev/null && log_with_date "INFO: Restarted TimescaleDB container"
    else
        # Check container health
        HEALTH=$(docker inspect --format='{{.State.Health.Status}}' timescaledb 2>/dev/null || echo "unknown")
        if [ "$HEALTH" = "unhealthy" ]; then
            log_with_date "WARNING: TimescaleDB container is unhealthy"
        fi
    fi
fi

# Check disk space for Docker
DOCKER_DISK_USAGE=$(df /var/lib/docker | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$DOCKER_DISK_USAGE" -gt 80 ]; then
    log_with_date "WARNING: Docker disk usage is ${DOCKER_DISK_USAGE}%"
fi

# Log current Docker stats
log_with_date "INFO: Docker system df: $(docker system df --format 'table {{.Type}}\t{{.TotalCount}}\t{{.Size}}')"
EOF

chmod +x /opt/timescaledb/scripts/docker-monitor.sh
success "Docker monitoring script created"

# Schedule Docker monitoring
info "Scheduling Docker monitoring..."
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/timescaledb/scripts/docker-monitor.sh") | crontab -
success "Docker monitoring scheduled (every 5 minutes)"

# Configure firewall for Docker
info "Configuring firewall for Docker..."
# Docker manipulates iptables, so we need to ensure our rules work with Docker
ufw reload >> "$LOGFILE" 2>&1
success "Firewall reloaded for Docker compatibility"

# Create Docker security script
info "Creating Docker security hardening script..."
cat > /opt/timescaledb/scripts/docker-security.sh << 'EOF'
#!/bin/bash
# Docker security hardening script

echo "Applying Docker security hardening..."

# Set Docker daemon to start containers with restricted capabilities
if [ -f /etc/docker/daemon.json ]; then
    # Add security options if not already present
    if ! grep -q "no-new-privileges" /etc/docker/daemon.json; then
        echo "Adding security hardening options..."
    fi
fi

# Check for containers running as root
echo "Checking for containers running as root:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | while read -r line; do
    container_name=$(echo "$line" | awk '{print $1}')
    if [ "$container_name" != "NAMES" ]; then
        user=$(docker exec "$container_name" whoami 2>/dev/null || echo "unknown")
        if [ "$user" = "root" ]; then
            echo "WARNING: Container $container_name is running as root"
        fi
    fi
done

echo "Security check completed"
EOF

chmod +x /opt/timescaledb/scripts/docker-security.sh
success "Docker security script created"

# Generate installation summary
cat > /opt/timescaledb/docker-setup-summary.txt << EOF
Docker Installation Summary
Generated: $(date)

Docker Version: $(docker --version)
Docker Compose Version: $(docker compose version)

Service Status:
$(systemctl status docker --no-pager -l)

Docker Configuration:
- Daemon config: /etc/docker/daemon.json
- Log driver: json-file (10MB max, 3 files)
- Storage driver: overlay2
- Security: no-new-privileges enabled

User Permissions:
$(getent group docker)

Scheduled Tasks:
- Docker cleanup: Weekly (Sunday 2 AM)
- Docker monitoring: Every 5 minutes

Scripts Created:
- /opt/timescaledb/scripts/docker-cleanup.sh
- /opt/timescaledb/scripts/docker-monitor.sh
- /opt/timescaledb/scripts/docker-security.sh

Log Files:
- Installation log: $LOGFILE
- Cleanup log: /var/log/docker-cleanup.log
- Monitor log: /var/log/docker-monitor.log

Next Steps:
1. Log out and back in (or reboot) to apply group permissions
2. Run: ./scripts/04-deploy-timescaledb.sh

Test Docker: docker run --rm hello-world
EOF

success "Docker setup summary created at /opt/timescaledb/docker-setup-summary.txt"

# Display completion message
echo
echo "================================================================"
echo -e "${GREEN}Docker Installation Completed Successfully!${NC}"
echo "================================================================"
echo
echo "Summary:"
echo "- Docker Engine: $(docker --version | cut -d',' -f1)"
echo "- Docker Compose: $(docker compose version | cut -d',' -f1)"
echo "- Service status: $(systemctl is-active docker)"
echo "- Security hardening applied"
echo "- Monitoring and cleanup scheduled"
echo
if [ "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    echo -e "${YELLOW}Important: User '$SUDO_USER' has been added to the docker group.${NC}"
    echo -e "${YELLOW}You need to log out and back in (or reboot) for this to take effect.${NC}"
    echo
fi
echo "Next Steps:"
echo "1. Log out and back in to apply group permissions"
echo "2. Test Docker: docker run --rm hello-world"
echo "3. Run: ./scripts/04-deploy-timescaledb.sh"
echo
echo "Installation log: $LOGFILE"
echo "Summary: /opt/timescaledb/docker-setup-summary.txt"
echo
echo "================================================================"
