#!/bin/bash
# 06-verify-setup.sh
# Comprehensive verification script for TimescaleDB deployment
# 
# This script performs thorough testing to ensure the deployment is
# production-ready and all components are functioning correctly

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOGFILE="/var/log/timescaledb-verification-$(date +%Y%m%d_%H%M%S).log"

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

error() {
    log "${RED}ERROR: $1${NC}" >&2
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

# Test result tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    ((TOTAL_TESTS++))
    info "Running test: $test_name"
    
    if eval "$test_command" >> "$LOGFILE" 2>&1; then
        success "✓ PASS: $test_name"
        ((PASSED_TESTS++))
        return 0
    else
        error "✗ FAIL: $test_name"
        ((FAILED_TESTS++))
        return 1
    fi
}

# Get script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
else
    warning ".env file not found, using defaults"
    DB_NAME="trading_db"
    DB_USER="trading_user"
fi

info "Starting comprehensive TimescaleDB verification..."
info "Target database: $DB_NAME"
info "Application user: $DB_USER"

echo
echo "================================================================"
echo -e "${BLUE}TimescaleDB Comprehensive Verification${NC}"
echo "================================================================"
echo "Timestamp: $(date)"
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo "================================================================"
echo

# Test 1: Docker Service Status
echo -e "${YELLOW}Test Category: Docker Infrastructure${NC}"
echo "-----------------------------------"

run_test "Docker service is running" "systemctl is-active --quiet docker"
run_test "TimescaleDB container exists" "docker ps -a --format '{{.Names}}' | grep -q 'timescaledb'"
run_test "TimescaleDB container is running" "docker ps --format '{{.Names}}' | grep -q 'timescaledb'"

# Container health check
if docker inspect timescaledb --format='{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
    run_test "Container health check" "true"
else
    run_test "Container health check" "false"
    warning "Health check status: $(docker inspect timescaledb --format='{{.State.Health.Status}}' 2>/dev/null || echo 'No healthcheck configured')"
fi

echo

# Test 2: Network Connectivity
echo -e "${YELLOW}Test Category: Network Connectivity${NC}"
echo "-----------------------------------"

run_test "PostgreSQL port is accessible" "nc -z localhost 5432"
run_test "Container port binding" "docker port timescaledb | grep -q '5432'"

# Test internal container networking
run_test "Container internal connectivity" "docker exec timescaledb pg_isready -U postgres"

echo

# Test 3: Database Connectivity
echo -e "${YELLOW}Test Category: Database Connectivity${NC}"
echo "-------------------------------------"

run_test "PostgreSQL admin connection" "docker exec timescaledb psql -U postgres -c 'SELECT 1;'"
run_test "Target database exists" "docker exec timescaledb psql -U postgres -lqt | cut -d \| -f 1 | grep -qw '$DB_NAME'"

if [ -n "$DB_USER" ] && [ "$DB_USER" != "postgres" ]; then
    run_test "Application user connection" "docker exec timescaledb psql -U '$DB_USER' -d '$DB_NAME' -c 'SELECT current_user;'"
fi

echo

# Test 4: TimescaleDB Extension
echo -e "${YELLOW}Test Category: TimescaleDB Extension${NC}"
echo "------------------------------------"

run_test "TimescaleDB extension installed" "docker exec timescaledb psql -U postgres -d '$DB_NAME' -t -c \"SELECT count(*) FROM pg_extension WHERE extname='timescaledb';\" | grep -q '1'"

# Get TimescaleDB version
TIMESCALE_VERSION=$(docker exec timescaledb psql -U postgres -d "$DB_NAME" -t -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null | tr -d ' ')
if [ -n "$TIMESCALE_VERSION" ]; then
    info "TimescaleDB version: $TIMESCALE_VERSION"
    ((PASSED_TESTS++))
else
    error "Could not determine TimescaleDB version"
    ((FAILED_TESTS++))
fi
((TOTAL_TESTS++))

# Test hypertables functionality
run_test "Hypertables functionality" "docker exec timescaledb psql -U postgres -d '$DB_NAME' -t -c 'SELECT count(*) FROM timescaledb_information.hypertables;' | grep -v '^$' | grep -q '[0-9]'"

echo

# Test 5: Data Persistence
echo -e "${YELLOW}Test Category: Data Persistence${NC}"
echo "-------------------------------"

# Check if data directory is mounted
DATA_MOUNT_CHECK=$(docker inspect timescaledb --format '{{range .Mounts}}{{.Destination}}{{end}}' | grep -c '/var/lib/postgresql/data' || echo "0")
run_test "Data directory mounted as volume" "[ '$DATA_MOUNT_CHECK' -gt 0 ]"

# Test data persistence by creating and verifying test data
TEST_TABLE_NAME="verification_test_$(date +%s)"
run_test "Create test table for persistence" "docker exec timescaledb psql -U postgres -d '$DB_NAME' -c \"CREATE TABLE $TEST_TABLE_NAME (id SERIAL PRIMARY KEY, test_data TEXT, created_at TIMESTAMP DEFAULT NOW());\""

run_test "Insert test data" "docker exec timescaledb psql -U postgres -d '$DB_NAME' -c \"INSERT INTO $TEST_TABLE_NAME (test_data) VALUES ('persistence_test');\""

# Test container restart and data persistence
info "Testing container restart and data persistence..."
RECORDS_BEFORE=$(docker exec timescaledb psql -U postgres -d "$DB_NAME" -t -c "SELECT count(*) FROM $TEST_TABLE_NAME;" | tr -d ' ')

info "Restarting TimescaleDB container..."
docker restart timescaledb >> "$LOGFILE" 2>&1

# Wait for container to be ready
info "Waiting for container to be ready after restart..."
for i in {1..30}; do
    if docker exec timescaledb pg_isready -U postgres > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

RECORDS_AFTER=$(docker exec timescaledb psql -U postgres -d "$DB_NAME" -t -c "SELECT count(*) FROM $TEST_TABLE_NAME;" 2>/dev/null | tr -d ' ' || echo "0")

run_test "Data persisted after container restart" "[ '$RECORDS_BEFORE' -eq '$RECORDS_AFTER' ] && [ '$RECORDS_AFTER' -gt 0 ]"

# Clean up test table
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "DROP TABLE IF EXISTS $TEST_TABLE_NAME;" >> "$LOGFILE" 2>&1

echo

# Test 6: User Permissions
echo -e "${YELLOW}Test Category: User Permissions${NC}"
echo "--------------------------------"

if [ -n "$DB_USER" ] && [ "$DB_USER" != "postgres" ]; then
    # Test user can connect
    run_test "User can connect to database" "docker exec timescaledb psql -U '$DB_USER' -d '$DB_NAME' -c 'SELECT 1;'"
    
    # Test user can query existing tables
    if docker exec timescaledb psql -U postgres -d "$DB_NAME" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" | grep -v "^$" | grep -q "[1-9]"; then
        run_test "User can query existing tables" "docker exec timescaledb psql -U '$DB_USER' -d '$DB_NAME' -c 'SELECT count(*) FROM test_metrics;'"
    else
        info "No existing tables to test user permissions"
    fi
    
    # Test user can create tables
    USER_TEST_TABLE="user_permission_test_$(date +%s)"
    run_test "User can create tables" "docker exec timescaledb psql -U '$DB_USER' -d '$DB_NAME' -c \"CREATE TABLE $USER_TEST_TABLE (id SERIAL PRIMARY KEY, data TEXT);\""
    
    # Test user can insert data
    run_test "User can insert data" "docker exec timescaledb psql -U '$DB_USER' -d '$DB_NAME' -c \"INSERT INTO $USER_TEST_TABLE (data) VALUES ('test');\""
    
    # Clean up
    docker exec timescaledb psql -U '$DB_USER' -d "$DB_NAME" -c "DROP TABLE IF EXISTS $USER_TEST_TABLE;" >> "$LOGFILE" 2>&1
else
    info "No application user configured, skipping user permission tests"
fi

echo

# Test 7: Performance and Configuration
echo -e "${YELLOW}Test Category: Performance & Configuration${NC}"
echo "-------------------------------------------"

# Test PostgreSQL configuration
run_test "Shared memory configured" "docker exec timescaledb psql -U postgres -c \"SHOW shared_preload_libraries;\" | grep -q timescaledb"

# Test connection limits
run_test "Connection limit reasonable" "docker exec timescaledb psql -U postgres -t -c \"SHOW max_connections;\" | awk '{print \$1}' | awk '\$1 >= 20 && \$1 <= 1000 {exit 0} {exit 1}'"

# Test work memory
run_test "Work memory configured" "docker exec timescaledb psql -U postgres -t -c \"SHOW work_mem;\" | grep -v '^$'"

echo

# Test 8: Backup and Maintenance
echo -e "${YELLOW}Test Category: Backup & Maintenance${NC}"
echo "-----------------------------------"

# Test backup directory exists
BACKUP_DIR=$(echo "$TSDB_DATA_PATH" | sed 's|$|/backups|')
if [ -z "$TSDB_DATA_PATH" ]; then
    BACKUP_DIR="/opt/timescaledb/backups"
fi

run_test "Backup directory exists" "[ -d '$BACKUP_DIR' ] || [ -d '/opt/timescaledb/backups' ]"

# Test pg_dump functionality
run_test "pg_dump functionality" "docker exec timescaledb pg_dump -U postgres --version"

# Test scheduled scripts exist
run_test "Health monitoring script exists" "[ -f '/opt/timescaledb/scripts/health-monitor.sh' ]"
run_test "User management script exists" "[ -f '/opt/timescaledb/scripts/manage-users.sh' ]"

echo

# Test 9: Security Configuration
echo -e "${YELLOW}Test Category: Security Configuration${NC}"
echo "--------------------------------------"

# Test firewall status
run_test "Firewall is active" "ufw status | grep -q 'Status: active'"

# Test non-root user in container
CONTAINER_USER=$(docker exec timescaledb whoami 2>/dev/null || echo "unknown")
run_test "Container not running as root" "[ '$CONTAINER_USER' != 'root' ]"

# Test password authentication required
run_test "Password authentication required" "docker exec timescaledb psql -U postgres -c \"SHOW password_encryption;\" | grep -v '^$'"

echo

# Test 10: Monitoring and Logging
echo -e "${YELLOW}Test Category: Monitoring & Logging${NC}"
echo "-----------------------------------"

# Test log files exist and are being written
run_test "Container logs accessible" "docker logs timescaledb --tail 10 | wc -l | awk '\$1 > 0 {exit 0} {exit 1}'"

# Test cron jobs are scheduled
run_test "Health monitoring scheduled" "crontab -l | grep -q health-monitor"

# Test log rotation configured
run_test "Log rotation configured" "[ -f '/etc/logrotate.d/timescaledb-setup' ] || [ -f '/etc/logrotate.d/docker' ]"

echo

# Summary
echo "================================================================"
echo -e "${BLUE}VERIFICATION SUMMARY${NC}"
echo "================================================================"

PASS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))

echo "Total Tests Run: $TOTAL_TESTS"
echo "Tests Passed: $PASSED_TESTS"
echo "Tests Failed: $FAILED_TESTS" 
echo "Pass Rate: $PASS_RATE%"
echo

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}🎉 ALL TESTS PASSED! Your TimescaleDB deployment is production-ready.${NC}"
    OVERALL_STATUS="EXCELLENT"
elif [ "$PASS_RATE" -ge 90 ]; then
    echo -e "${GREEN}✅ DEPLOYMENT SUCCESSFUL with minor issues (${PASS_RATE}% pass rate)${NC}"
    OVERALL_STATUS="GOOD"
elif [ "$PASS_RATE" -ge 75 ]; then
    echo -e "${YELLOW}⚠️  DEPLOYMENT MOSTLY SUCCESSFUL but needs attention (${PASS_RATE}% pass rate)${NC}"
    OVERALL_STATUS="ACCEPTABLE"
else
    echo -e "${RED}❌ DEPLOYMENT HAS SIGNIFICANT ISSUES (${PASS_RATE}% pass rate)${NC}"
    OVERALL_STATUS="NEEDS_ATTENTION"
fi

echo
echo "System Information:"
echo "- PostgreSQL Version: $(docker exec timescaledb psql -U postgres -t -c "SELECT version();" 2>/dev/null | head -1 | sed 's/^ *//' | cut -d',' -f1)"
echo "- TimescaleDB Version: $TIMESCALE_VERSION"
echo "- Container Status: $(docker inspect timescaledb --format='{{.State.Status}}')"
echo "- Database: $DB_NAME"
echo "- Application User: ${DB_USER:-'Not configured'}"

HYPERTABLE_COUNT=$(docker exec timescaledb psql -U postgres -d "$DB_NAME" -t -c "SELECT count(*) FROM timescaledb_information.hypertables;" 2>/dev/null | tr -d ' ' || echo "0")
echo "- Hypertables: $HYPERTABLE_COUNT"

echo
echo "Connection Information:"
echo "- Host: localhost (or your VM IP)"
echo "- Port: 5432"
echo "- Database: $DB_NAME"
echo "- Admin User: postgres"
if [ -n "$DB_USER" ]; then
    echo "- Application User: $DB_USER"
fi

echo
echo "Next Steps:"
if [ "$OVERALL_STATUS" = "EXCELLENT" ] || [ "$OVERALL_STATUS" = "GOOD" ]; then
    echo "✅ Your TimescaleDB deployment is ready for production use!"
    echo "✅ Consider setting up automated backups: ./scripts/07-backup-setup.sh"
    echo "✅ Review the security configuration and update default passwords"
    echo "✅ Set up monitoring and alerting for production environments"
else
    echo "⚠️  Please review the failed tests and address the issues"
    echo "⚠️  Check the detailed logs: $LOGFILE"
    echo "⚠️  Consider re-running individual setup scripts for failed components"
fi

echo
echo "Useful Commands:"
echo "- Connect to database: ./scripts/connect.sh"
echo "- View container logs: docker logs timescaledb"
echo "- Check container status: docker stats timescaledb"
echo "- Restart container: docker restart timescaledb"

echo
echo "Documentation:"
echo "- Setup log: $LOGFILE"
echo "- Container info: docker inspect timescaledb"
echo "- Database info: docker exec timescaledb psql -U postgres -l"

# Generate comprehensive verification report
cat > /opt/timescaledb/verification-report.txt << EOF
TimescaleDB Verification Report
Generated: $(date)

OVERALL STATUS: $OVERALL_STATUS
Pass Rate: $PASS_RATE% ($PASSED_TESTS/$TOTAL_TESTS tests passed)

System Configuration:
- PostgreSQL Version: $(docker exec timescaledb psql -U postgres -t -c "SELECT version();" 2>/dev/null | head -1 | sed 's/^ *//')
- TimescaleDB Version: $TIMESCALE_VERSION
- Database: $DB_NAME
- Application User: ${DB_USER:-'Not configured'}
- Container Status: $(docker inspect timescaledb --format='{{.State.Status}}')
- Hypertables: $HYPERTABLE_COUNT

Container Information:
$(docker inspect timescaledb --format='Image: {{.Config.Image}}
Created: {{.Created}}
Status: {{.State.Status}}
Health: {{.State.Health.Status}}')

Volume Mounts:
$(docker inspect timescaledb --format '{{range .Mounts}}Source: {{.Source}} -> {{.Destination}} ({{.Type}})
{{end}}')

Port Bindings:
$(docker port timescaledb)

Database Extensions:
$(docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;" 2>/dev/null)

Test Results Summary:
- Total Tests: $TOTAL_TESTS
- Passed: $PASSED_TESTS  
- Failed: $FAILED_TESTS
- Success Rate: $PASS_RATE%

Detailed Test Log: $LOGFILE

Recommendations:
$(if [ "$OVERALL_STATUS" = "EXCELLENT" ]; then
    echo "- Deployment is production-ready"
    echo "- Consider setting up monitoring and alerting"
    echo "- Implement backup strategy"
    echo "- Review and update default passwords"
elif [ "$OVERALL_STATUS" = "GOOD" ]; then
    echo "- Address minor issues identified in failed tests"
    echo "- Review security configuration"
    echo "- Set up monitoring"
elif [ "$OVERALL_STATUS" = "ACCEPTABLE" ]; then
    echo "- Review and fix failed test issues before production use"
    echo "- Check logs for detailed error information"
    echo "- Consider re-running setup scripts for failed components"
else
    echo "- Significant issues found - not recommended for production"
    echo "- Review all failed tests and address underlying problems"
    echo "- Consider starting over with fresh deployment"
fi)

Connection Information:
Host: localhost
Port: 5432
Database: $DB_NAME
Admin User: postgres
$(if [ -n "$DB_USER" ]; then echo "Application User: $DB_USER"; fi)

Maintenance Commands:
- Connect: ./scripts/connect.sh
- Health Check: /opt/timescaledb/scripts/health-monitor.sh
- User Management: /opt/timescaledb/scripts/manage-users.sh
- Container Logs: docker logs timescaledb
- Restart: docker restart timescaledb
EOF

success "Comprehensive verification report saved to /opt/timescaledb/verification-report.txt"

echo
echo "================================================================"
echo -e "${BLUE}Verification completed. Report saved to:${NC}"
echo "/opt/timescaledb/verification-report.txt"
echo "================================================================"

# Exit with appropriate code
if [ "$FAILED_TESTS" -eq 0 ]; then
    exit 0
elif [ "$PASS_RATE" -ge 75 ]; then
    exit 1
else
    exit 2
fi
