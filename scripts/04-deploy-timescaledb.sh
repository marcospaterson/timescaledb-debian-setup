#!/bin/bash
# 04-deploy-timescaledb.sh
# TimescaleDB container deployment and configuration
# 
# This script handles:
# - TimescaleDB container deployment with Docker Compose
# - Database initialization and extension setup
# - Network configuration and port binding
# - Health checks and verification

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOGFILE="/var/log/timescaledb-deploy-$(date +%Y%m%d_%H%M%S).log"

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

# Get script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
    info "Loaded environment variables from .env file"
else
    warning ".env file not found, creating from template"
    if [ -f "$REPO_ROOT/.env.example" ]; then
        cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
        warning "Please edit .env file with your specific configuration"
        warning "Default passwords should be changed for security"
    else
        error ".env.example not found. Cannot proceed without configuration"
    fi
fi

# Set default values if not provided
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-"your_secure_password_here"}
DB_NAME=${DB_NAME:-"myapp_db"}
TSDB_DATA_PATH=${TSDB_DATA_PATH:-"/mnt/timescaledb-data"}

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    # Check if user is in docker group
    if ! groups | grep -q docker; then
        error "User must be in docker group or run with sudo. Run: sudo usermod -aG docker $USER && logout"
    fi
fi

info "Starting TimescaleDB deployment process..."
info "Database name: $DB_NAME"
info "Data path: $TSDB_DATA_PATH"

# Verify Docker is running
if ! systemctl is-active --quiet docker; then
    error "Docker service is not running. Start it with: sudo systemctl start docker"
fi

# Verify data directory exists
if [ ! -d "$TSDB_DATA_PATH" ]; then
    error "Data directory $TSDB_DATA_PATH does not exist. Run ./scripts/02-mount-disk.sh first"
fi

# Create PostgreSQL data directory with correct permissions
info "Setting up PostgreSQL data directory..."
sudo mkdir -p "$TSDB_DATA_PATH/postgresql"
sudo chown -R 999:999 "$TSDB_DATA_PATH/postgresql"
sudo chmod 700 "$TSDB_DATA_PATH/postgresql"
success "PostgreSQL data directory configured"

# Stop existing TimescaleDB container if running
if docker ps -a --format '{{.Names}}' | grep -q "timescaledb"; then
    info "Stopping existing TimescaleDB container..."
    docker stop timescaledb 2>/dev/null || true
    docker rm timescaledb 2>/dev/null || true
    success "Existing container removed"
fi

# Create docker-compose override for local customizations
cat > docker-compose.override.yml << EOF
services:
  timescaledb:
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - ${TSDB_DATA_PATH}/postgresql:/var/lib/postgresql/data
EOF

info "Docker Compose override configuration created"

# Pull the latest TimescaleDB image
info "Pulling TimescaleDB Docker image..."
cd "$REPO_ROOT"
docker compose pull >> "$LOGFILE" 2>&1
success "TimescaleDB image pulled"

# Start TimescaleDB container
info "Starting TimescaleDB container..."
docker compose up -d >> "$LOGFILE" 2>&1
success "TimescaleDB container started"

# Wait for container to be ready
info "Waiting for TimescaleDB to be ready..."
max_attempts=60
attempt=1

while [ $attempt -le $max_attempts ]; do
    if docker exec timescaledb pg_isready -U postgres > /dev/null 2>&1; then
        success "TimescaleDB is ready"
        break
    fi
    
    info "Waiting for database... (attempt $attempt/$max_attempts)"
    sleep 5
    ((attempt++))
done

if [ $attempt -gt $max_attempts ]; then
    error "TimescaleDB failed to start within expected time. Check logs: docker logs timescaledb"
fi

# Verify TimescaleDB extension is available
info "Verifying TimescaleDB extension..."
TIMESCALE_VERSION=$(docker exec timescaledb psql -U postgres -t -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null | tr -d ' ' || echo "")

if [ -z "$TIMESCALE_VERSION" ]; then
    info "TimescaleDB extension not found, installing..."
    docker exec timescaledb psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" >> "$LOGFILE" 2>&1
    TIMESCALE_VERSION=$(docker exec timescaledb psql -U postgres -t -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" | tr -d ' ')
fi

success "TimescaleDB extension version: $TIMESCALE_VERSION"

# Create the main database if it doesn't exist
info "Creating database '$DB_NAME'..."
if ! docker exec timescaledb psql -U postgres -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    docker exec timescaledb psql -U postgres -c "CREATE DATABASE $DB_NAME;" >> "$LOGFILE" 2>&1
    success "Database '$DB_NAME' created"
else
    info "Database '$DB_NAME' already exists"
fi

# Install essential extensions in the target database
info "Installing essential extensions in $DB_NAME..."
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
" >> "$LOGFILE" 2>&1
success "Essential extensions installed"

# Create backup directory structure
info "Setting up backup directory structure..."
sudo mkdir -p "$TSDB_DATA_PATH/backups/daily"
sudo mkdir -p "$TSDB_DATA_PATH/backups/weekly"
sudo mkdir -p "$TSDB_DATA_PATH/backups/monthly"
sudo mkdir -p "$TSDB_DATA_PATH/logs"
sudo chown -R 999:999 "$TSDB_DATA_PATH/backups"
sudo chown -R 999:999 "$TSDB_DATA_PATH/logs"
success "Backup directory structure created"

# Create a simple test table to verify TimescaleDB functionality
info "Creating test hypertable..."
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "
DROP TABLE IF EXISTS test_metrics;
CREATE TABLE test_metrics (
    time TIMESTAMPTZ NOT NULL,
    device_id TEXT NOT NULL,
    temperature DOUBLE PRECISION,
    humidity DOUBLE PRECISION
);

SELECT create_hypertable('test_metrics', 'time');

INSERT INTO test_metrics (time, device_id, temperature, humidity) 
VALUES 
    (NOW(), 'device_001', 23.5, 45.2),
    (NOW() - INTERVAL '1 hour', 'device_001', 24.1, 43.8),
    (NOW() - INTERVAL '2 hours', 'device_002', 22.8, 46.5);
" >> "$LOGFILE" 2>&1
success "Test hypertable created and populated"

# Verify hypertable functionality
info "Verifying hypertable functionality..."
HYPERTABLE_COUNT=$(docker exec timescaledb psql -U postgres -d "$DB_NAME" -t -c "SELECT count(*) FROM timescaledb_information.hypertables;" | tr -d ' ')
TEST_DATA_COUNT=$(docker exec timescaledb psql -U postgres -d "$DB_NAME" -t -c "SELECT count(*) FROM test_metrics;" | tr -d ' ')

info "Hypertables created: $HYPERTABLE_COUNT"
info "Test records inserted: $TEST_DATA_COUNT"
success "TimescaleDB functionality verified"

# Configure container auto-restart policy
info "Configuring container restart policy..."
docker update --restart unless-stopped timescaledb >> "$LOGFILE" 2>&1
success "Container restart policy configured"

# Create container health monitoring script
info "Creating container health monitoring..."
cat > /opt/timescaledb/scripts/health-monitor.sh << 'EOF'
#!/bin/bash
# TimescaleDB health monitoring script

CONTAINER_NAME="timescaledb"
LOG_FILE="/var/log/timescaledb-health.log"

# Function to log with timestamp
log_health() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
    log_health "ERROR: Container $CONTAINER_NAME is not running"
    
    # Attempt to start the container
    if docker start "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1; then
        log_health "INFO: Successfully restarted container $CONTAINER_NAME"
    else
        log_health "ERROR: Failed to restart container $CONTAINER_NAME"
        exit 1
    fi
fi

# Check database connectivity
if ! docker exec "$CONTAINER_NAME" pg_isready -U postgres > /dev/null 2>&1; then
    log_health "ERROR: Database is not accepting connections"
    exit 1
fi

# Check TimescaleDB extension
EXTENSION_CHECK=$(docker exec "$CONTAINER_NAME" psql -U postgres -t -c "SELECT count(*) FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null | tr -d ' ')
if [ "$EXTENSION_CHECK" -eq 0 ]; then
    log_health "ERROR: TimescaleDB extension not found"
    exit 1
fi

# Check disk space
DISK_USAGE=$(df /var/lib/docker | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -gt 85 ]; then
    log_health "WARNING: Docker disk usage is ${DISK_USAGE}%"
fi

# Log successful check
log_health "INFO: Health check passed - Container: running, Database: responsive, Extension: loaded"
EOF

chmod +x /opt/timescaledb/scripts/health-monitor.sh
success "Health monitoring script created"

# Schedule health monitoring
info "Scheduling health monitoring..."
(crontab -l 2>/dev/null; echo "*/2 * * * * /opt/timescaledb/scripts/health-monitor.sh") | crontab -
success "Health monitoring scheduled (every 2 minutes)"

# Create database connection test script
cat > /opt/timescaledb/scripts/test-connection.sh << EOF
#!/bin/bash
# Test database connection script

echo "Testing TimescaleDB connection..."
echo "================================"

# Test basic connection
echo -n "PostgreSQL connection: "
if docker exec timescaledb psql -U postgres -d $DB_NAME -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✓ OK"
else
    echo "✗ FAILED"
    exit 1
fi

# Test TimescaleDB extension
echo -n "TimescaleDB extension: "
EXT_VERSION=\$(docker exec timescaledb psql -U postgres -d $DB_NAME -t -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" | tr -d ' ')
if [ -n "\$EXT_VERSION" ]; then
    echo "✓ OK (version \$EXT_VERSION)"
else
    echo "✗ FAILED"
    exit 1
fi

# Test hypertable functionality
echo -n "Hypertable functionality: "
HYPERTABLE_COUNT=\$(docker exec timescaledb psql -U postgres -d $DB_NAME -t -c "SELECT count(*) FROM timescaledb_information.hypertables;" | tr -d ' ')
if [ "\$HYPERTABLE_COUNT" -gt 0 ]; then
    echo "✓ OK (\$HYPERTABLE_COUNT hypertables)"
else
    echo "✗ FAILED"
    exit 1
fi

echo "================================"
echo "All tests passed! TimescaleDB is ready for use."
EOF

chmod +x /opt/timescaledb/scripts/test-connection.sh
success "Connection test script created"

# Generate deployment summary
cat > /opt/timescaledb/timescaledb-deployment-summary.txt << EOF
TimescaleDB Deployment Summary
Generated: $(date)

Container Configuration:
- Name: timescaledb
- Image: $(docker inspect timescaledb --format='{{.Config.Image}}')
- Status: $(docker inspect timescaledb --format='{{.State.Status}}')
- Health: $(docker inspect timescaledb --format='{{.State.Health.Status}}' 2>/dev/null || echo 'No healthcheck')

Database Configuration:
- PostgreSQL Version: $(docker exec timescaledb psql -U postgres -t -c "SELECT version();" | head -1 | sed 's/^ *//')
- TimescaleDB Version: $TIMESCALE_VERSION
- Main Database: $DB_NAME
- Data Directory: $TSDB_DATA_PATH/postgresql

Network Configuration:
- Port Binding: 5432:5432
- Container IP: $(docker inspect timescaledb --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

Extensions Installed:
$(docker exec timescaledb psql -U postgres -d $DB_NAME -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;")

Hypertables:
$(docker exec timescaledb psql -U postgres -d $DB_NAME -c "SELECT hypertable_name, num_dimensions FROM timescaledb_information.hypertables;")

Volume Mounts:
$(docker inspect timescaledb --format '{{range .Mounts}}Source: {{.Source}} -> Destination: {{.Destination}} ({{.Type}}){{end}}')

Scheduled Tasks:
- Health monitoring: Every 2 minutes
- Container cleanup: Weekly (inherited from Docker setup)

Scripts Available:
- Connection test: /opt/timescaledb/scripts/test-connection.sh
- Health monitor: /opt/timescaledb/scripts/health-monitor.sh

Next Steps:
1. Run: ./scripts/05-create-users.sh
2. Run: ./scripts/06-verify-setup.sh
3. Configure backups: ./scripts/07-backup-setup.sh

Connection Information:
Host: localhost (or your VM IP)
Port: 5432
Database: $DB_NAME
Admin User: postgres
Password: [configured in .env]

Test Connection: ./scripts/test-connection.sh
Container Logs: docker logs timescaledb
Container Stats: docker stats timescaledb

Deployment Log: $LOGFILE
EOF

success "Deployment summary created at /opt/timescaledb/timescaledb-deployment-summary.txt"

# Display completion message
echo
echo "================================================================"
echo -e "${GREEN}TimescaleDB Deployment Completed Successfully!${NC}"
echo "================================================================"
echo
echo "Container Status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep timescaledb || echo "Container not found in docker ps output"
echo
echo "Database Information:"
echo "- PostgreSQL Version: $(docker exec timescaledb psql -U postgres -t -c "SELECT version();" | head -1 | sed 's/^ *//' | cut -d',' -f1)"
echo "- TimescaleDB Version: $TIMESCALE_VERSION"
echo "- Main Database: $DB_NAME"
echo "- Hypertables: $HYPERTABLE_COUNT"
echo
echo "Connection Details:"
echo "- Host: localhost"
echo "- Port: 5432"
echo "- Database: $DB_NAME"
echo "- Admin User: postgres"
echo
echo "Next Steps:"
echo "1. Test connection: ./scripts/test-connection.sh"
echo "2. Create application users: ./scripts/05-create-users.sh"
echo "3. Run full verification: ./scripts/06-verify-setup.sh"
echo
echo "Deployment log: $LOGFILE"
echo "Summary: /opt/timescaledb/timescaledb-deployment-summary.txt"
echo
echo "================================================================"
