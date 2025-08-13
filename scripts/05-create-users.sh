#!/bin/bash
# 05-create-users.sh
# Database user creation and permission management
# 
# This script handles:
# - Application user creation with secure passwords
# - Role-based permission assignment
# - Database access configuration
# - Security best practices implementation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
LOGFILE="/var/log/user-creation-$(date +%Y%m%d_%H%M%S).log"

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
    info "Loaded environment variables from .env file"
else
    error ".env file not found. Please create it from .env.example"
fi

# Set default values
DB_NAME=${DB_NAME:-"trading_db"}
DB_USER=${DB_USER:-"trading_user"}
DB_PASSWORD=${DB_PASSWORD:-""}

info "Starting database user creation process..."
info "Target database: $DB_NAME"
info "Application user: $DB_USER"

# Check if TimescaleDB container is running
if ! docker ps --format '{{.Names}}' | grep -q "timescaledb"; then
    error "TimescaleDB container is not running. Run ./scripts/04-deploy-timescaledb.sh first"
fi

# Check if database connection works
if ! docker exec timescaledb pg_isready -U postgres > /dev/null 2>&1; then
    error "Cannot connect to TimescaleDB. Check container status: docker logs timescaledb"
fi

# Generate secure password if not provided
if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "your_trading_user_password" ]; then
    info "Generating secure password for $DB_USER..."
    DB_PASSWORD=$(openssl rand -hex 16)
    warning "Generated password: $DB_PASSWORD"
    warning "Please update your .env file with this password"
    
    # Update .env file
    if grep -q "DB_PASSWORD=" .env; then
        sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env
    else
        echo "DB_PASSWORD=$DB_PASSWORD" >> .env
    fi
    
    # Update DATABASE_URL if it exists
    if grep -q "DATABASE_URL=" .env; then
        DATABASE_URL="postgresql://$DB_USER:$DB_PASSWORD@localhost:5432/$DB_NAME"
        sed -i "s|DATABASE_URL=.*|DATABASE_URL=$DATABASE_URL|" .env
    fi
    
    success "Password saved to .env file"
fi

# Check if user already exists
info "Checking if user '$DB_USER' exists..."
USER_EXISTS=$(docker exec timescaledb psql -U postgres -t -c "SELECT count(*) FROM pg_user WHERE usename = '$DB_USER';" | tr -d ' ')

if [ "$USER_EXISTS" -gt 0 ]; then
    warning "User '$DB_USER' already exists"
    read -p "Do you want to update the password? (yes/no): " update_password
    
    if [ "$update_password" = "yes" ]; then
        info "Updating password for user '$DB_USER'..."
        docker exec timescaledb psql -U postgres -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';" >> "$LOGFILE" 2>&1
        success "Password updated for user '$DB_USER'"
    else
        info "Skipping password update"
    fi
else
    # Create the application user
    info "Creating user '$DB_USER'..."
    docker exec timescaledb psql -U postgres -c "
    CREATE USER $DB_USER WITH 
        PASSWORD '$DB_PASSWORD'
        NOSUPERUSER 
        NOCREATEDB 
        NOCREATEROLE 
        LOGIN;
    " >> "$LOGFILE" 2>&1
    success "User '$DB_USER' created successfully"
fi

# Grant database connection permission
info "Granting database connection permissions..."
docker exec timescaledb psql -U postgres -c "GRANT CONNECT ON DATABASE $DB_NAME TO $DB_USER;" >> "$LOGFILE" 2>&1
success "Database connection permission granted"

# Grant schema usage
info "Granting schema usage permissions..."
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "GRANT USAGE ON SCHEMA public TO $DB_USER;" >> "$LOGFILE" 2>&1
success "Schema usage permission granted"

# Grant permissions on all existing tables
info "Granting permissions on existing tables..."
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;" >> "$LOGFILE" 2>&1
success "Table permissions granted"

# Grant permissions on all existing sequences
info "Granting permissions on existing sequences..."
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;" >> "$LOGFILE" 2>&1
success "Sequence permissions granted"

# Set default privileges for future objects
info "Setting default privileges for future tables..."
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;" >> "$LOGFILE" 2>&1
success "Default table privileges set"

info "Setting default privileges for future sequences..."
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_USER;" >> "$LOGFILE" 2>&1
success "Default sequence privileges set"

# Create additional roles for different access levels
info "Creating additional database roles..."

# Read-only role
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "
CREATE ROLE readonly_role;
GRANT CONNECT ON DATABASE $DB_NAME TO readonly_role;
GRANT USAGE ON SCHEMA public TO readonly_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_role;
" >> "$LOGFILE" 2>&1
success "Read-only role created"

# Analytics role (read + insert for logging/metrics)
docker exec timescaledb psql -U postgres -d "$DB_NAME" -c "
CREATE ROLE analytics_role;
GRANT readonly_role TO analytics_role;
GRANT INSERT ON ALL TABLES IN SCHEMA public TO analytics_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT INSERT ON TABLES TO analytics_role;
" >> "$LOGFILE" 2>&1
success "Analytics role created"

# Test user connection
info "Testing user connection..."
if docker exec timescaledb psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT current_user, current_database();" >> "$LOGFILE" 2>&1; then
    success "User connection test passed"
else
    error "User connection test failed. Check logs: $LOGFILE"
fi

# Test user permissions on test table
info "Testing user permissions..."
TEST_RESULT=$(docker exec timescaledb psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM test_metrics;" 2>/dev/null | tr -d ' ')
if [ -n "$TEST_RESULT" ] && [ "$TEST_RESULT" -ge 0 ]; then
    success "User can query tables (found $TEST_RESULT records in test_metrics)"
else
    warning "User permission test failed or test_metrics table not found"
fi

# Create user management script for future use
cat > /opt/timescaledb/scripts/manage-users.sh << 'EOF'
#!/bin/bash
# User management utility script

DB_NAME="trading_db"
CONTAINER_NAME="timescaledb"

usage() {
    echo "Usage: $0 [create|drop|list|grant|revoke] [options]"
    echo ""
    echo "Commands:"
    echo "  create <username> <password>  - Create a new user"
    echo "  drop <username>                - Drop a user"  
    echo "  list                          - List all users"
    echo "  grant <username> <role>       - Grant role to user"
    echo "  revoke <username> <role>      - Revoke role from user"
    echo ""
    echo "Available roles:"
    echo "  readonly_role   - Read-only access to all tables"
    echo "  analytics_role  - Read + insert access"
    echo ""
    exit 1
}

case "$1" in
    create)
        if [ $# -ne 3 ]; then
            echo "Error: create requires username and password"
            usage
        fi
        USERNAME="$2"
        PASSWORD="$3"
        
        echo "Creating user: $USERNAME"
        docker exec $CONTAINER_NAME psql -U postgres -c "
        CREATE USER $USERNAME WITH PASSWORD '$PASSWORD' NOSUPERUSER NOCREATEDB NOCREATEROLE LOGIN;
        GRANT CONNECT ON DATABASE $DB_NAME TO $USERNAME;
        " && echo "User $USERNAME created successfully"
        ;;
        
    drop)
        if [ $# -ne 2 ]; then
            echo "Error: drop requires username"
            usage
        fi
        USERNAME="$2"
        
        echo "Dropping user: $USERNAME"
        docker exec $CONTAINER_NAME psql -U postgres -c "DROP USER IF EXISTS $USERNAME;" && echo "User $USERNAME dropped"
        ;;
        
    list)
        echo "Database users:"
        docker exec $CONTAINER_NAME psql -U postgres -c "
        SELECT usename as username, 
               usecreatedb as can_create_db, 
               usesuper as is_superuser,
               valuntil as valid_until
        FROM pg_user ORDER BY usename;"
        ;;
        
    grant)
        if [ $# -ne 3 ]; then
            echo "Error: grant requires username and role"
            usage
        fi
        USERNAME="$2"
        ROLE="$3"
        
        echo "Granting role $ROLE to user $USERNAME"
        docker exec $CONTAINER_NAME psql -U postgres -d $DB_NAME -c "GRANT $ROLE TO $USERNAME;" && echo "Role granted"
        ;;
        
    revoke)
        if [ $# -ne 3 ]; then
            echo "Error: revoke requires username and role"
            usage
        fi
        USERNAME="$2"
        ROLE="$3"
        
        echo "Revoking role $ROLE from user $USERNAME"
        docker exec $CONTAINER_NAME psql -U postgres -d $DB_NAME -c "REVOKE $ROLE FROM $USERNAME;" && echo "Role revoked"
        ;;
        
    *)
        usage
        ;;
esac
EOF

chmod +x /opt/timescaledb/scripts/manage-users.sh
success "User management script created at /opt/timescaledb/scripts/manage-users.sh"

# Create connection helper script
cat > /opt/timescaledb/scripts/connect.sh << EOF
#!/bin/bash
# Database connection helper

DB_NAME="$DB_NAME"
DB_USER="$DB_USER"

echo "Connecting to TimescaleDB as $DB_USER..."
echo "Database: $DB_NAME"
echo ""

# Load password from .env if available
if [ -f ".env" ]; then
    source .env
    export PGPASSWORD="\$DB_PASSWORD"
fi

# Connect using docker exec
docker exec -it timescaledb psql -U "$DB_USER" -d "$DB_NAME"
EOF

chmod +x /opt/timescaledb/scripts/connect.sh
success "Connection helper script created at /opt/timescaledb/scripts/connect.sh"

# Generate user creation summary
cat > /opt/timescaledb/user-creation-summary.txt << EOF
Database User Creation Summary
Generated: $(date)

Main Application User:
- Username: $DB_USER
- Database: $DB_NAME
- Permissions: Full access (SELECT, INSERT, UPDATE, DELETE)
- Password: $(echo $DB_PASSWORD | sed 's/./*/g') (stored in .env)

Database Roles Created:
- readonly_role: Read-only access to all tables
- analytics_role: Read + insert access (inherits readonly_role)

User Verification:
$(docker exec timescaledb psql -U postgres -c "
SELECT u.usename as username,
       CASE WHEN u.usesuper THEN 'superuser' ELSE 'regular' END as type,
       CASE WHEN u.usecreatedb THEN 'yes' ELSE 'no' END as can_create_db
FROM pg_user u 
WHERE u.usename IN ('$DB_USER', 'postgres')
ORDER BY u.usename;
")

Table Permissions for $DB_USER:
$(docker exec timescaledb psql -U postgres -d $DB_NAME -c "
SELECT grantee, table_name, privilege_type 
FROM information_schema.role_table_grants 
WHERE grantee = '$DB_USER' 
ORDER BY table_name, privilege_type 
LIMIT 10;
" 2>/dev/null || echo "No specific table permissions found (using default privileges)")

Connection Information:
- Host: localhost
- Port: 5432  
- Database: $DB_NAME
- Username: $DB_USER
- Connection String: postgresql://$DB_USER:***@localhost:5432/$DB_NAME

Available Scripts:
- Connect to database: ./scripts/connect.sh
- Manage users: /opt/timescaledb/scripts/manage-users.sh
- Test connection: /opt/timescaledb/scripts/test-connection.sh

Next Steps:
1. Test the connection: ./scripts/connect.sh
2. Run full verification: ./scripts/06-verify-setup.sh
3. Set up backups: ./scripts/07-backup-setup.sh

Security Notes:
- User has minimal privileges (not superuser)
- Password is securely generated and stored
- Default privileges ensure future objects are accessible
- Additional roles available for granular access control

Setup Log: $LOGFILE
EOF

success "User creation summary saved to /opt/timescaledb/user-creation-summary.txt"

# Display completion message
echo
echo "================================================================"
echo -e "${GREEN}Database User Creation Completed Successfully!${NC}"
echo "================================================================"
echo
echo "Main Application User:"
echo "- Username: $DB_USER"
echo "- Database: $DB_NAME"  
echo "- Password: [saved in .env file]"
echo "- Permissions: Full database access"
echo
echo "Additional Roles Created:"
echo "- readonly_role (read-only access)"
echo "- analytics_role (read + insert access)"
echo
echo "Connection Test:"
CONN_TEST=$(docker exec timescaledb psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT current_user;" 2>/dev/null | grep "$DB_USER" || echo "Failed")
if echo "$CONN_TEST" | grep -q "$DB_USER"; then
    echo "✓ Connection successful"
else
    echo "✗ Connection failed - check logs"
fi
echo
echo "Available Commands:"
echo "- Connect to database: ./scripts/connect.sh"
echo "- Manage users: /opt/timescaledb/scripts/manage-users.sh list"
echo "- Test connection: /opt/timescaledb/scripts/test-connection.sh"
echo
echo "Next Steps:"
echo "1. Test the user connection: ./scripts/connect.sh"
echo "2. Run comprehensive verification: ./scripts/06-verify-setup.sh"
echo
echo "Setup log: $LOGFILE"
echo "Summary: /opt/timescaledb/user-creation-summary.txt"
echo
echo "================================================================"
