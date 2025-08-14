#!/bin/bash

# =============================================================================
# Security Assessment Script
# =============================================================================
# Quick assessment of current VM security status
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=================================================="
echo "           SECURITY ASSESSMENT REPORT"
echo "=================================================="

# Check firewall status
echo -e "\n${BLUE}🔥 FIREWALL STATUS${NC}"
if command -v ufw &> /dev/null; then
    if sudo ufw status | grep -q "Status: active"; then
        echo -e "${GREEN}✓ UFW firewall is active${NC}"
    else
        echo -e "${RED}✗ UFW firewall is inactive${NC}"
    fi
else
    echo -e "${RED}✗ UFW not installed${NC}"
fi

# Check fail2ban
echo -e "\n${BLUE}🛡️  FAIL2BAN STATUS${NC}"
if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}✓ fail2ban is running${NC}"
    BANNED=$(sudo fail2ban-client status 2>/dev/null | grep "Jail list" | wc -w)
    echo "   Active jails: $((BANNED - 2))"
else
    echo -e "${RED}✗ fail2ban not running${NC}"
fi

# Check SSH configuration
echo -e "\n${BLUE}🔐 SSH SECURITY${NC}"
SSH_CONFIG="/etc/ssh/sshd_config"

# Check root login
if grep -q "^PermitRootLogin no" $SSH_CONFIG || grep -q "^PermitRootLogin no" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    echo -e "${GREEN}✓ Root login disabled${NC}"
else
    echo -e "${RED}✗ Root login may be enabled${NC}"
fi

# Check password authentication
if grep -q "^PasswordAuthentication" $SSH_CONFIG; then
    if grep -q "^PasswordAuthentication yes" $SSH_CONFIG; then
        echo -e "${YELLOW}⚠ Password authentication enabled${NC}"
    else
        echo -e "${GREEN}✓ Password authentication disabled${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Password authentication setting unclear${NC}"
fi

# Check SSH port
SSH_PORT=$(grep "^Port" $SSH_CONFIG 2>/dev/null | awk '{print $2}' || echo "22")
if [ "$SSH_PORT" = "22" ]; then
    echo -e "${YELLOW}⚠ Using default SSH port 22${NC}"
else
    echo -e "${GREEN}✓ Using custom SSH port $SSH_PORT${NC}"
fi

# Check system updates
echo -e "\n${BLUE}📦 SYSTEM UPDATES${NC}"
if command -v unattended-upgrades &> /dev/null; then
    echo -e "${GREEN}✓ Automatic updates installed${NC}"
else
    echo -e "${RED}✗ Automatic updates not configured${NC}"
fi

# Check for pending updates
UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "0")
if [ "$UPDATES" -eq 0 ]; then
    echo -e "${GREEN}✓ System is up to date${NC}"
else
    echo -e "${YELLOW}⚠ $UPDATES package updates available${NC}"
fi

# Check open ports
echo -e "\n${BLUE}🌐 NETWORK EXPOSURE${NC}"
echo "Open ports:"
ss -tulnp | grep LISTEN | while read line; do
    PORT=$(echo $line | awk '{print $5}' | cut -d: -f2)
    PROCESS=$(echo $line | awk '{print $7}' | cut -d'"' -f2)
    echo "  Port $PORT - $PROCESS"
done

# Check user accounts
echo -e "\n${BLUE}👤 USER ACCOUNTS${NC}"
USERS=$(getent passwd | grep -E ":(100[0-9]|[0-9]{4,}):" | wc -l)
echo "Regular user accounts: $USERS"

# Check for sudo access
SUDO_USERS=$(grep -E '^sudo:' /etc/group | cut -d: -f4 | tr ',' '\n' | wc -l)
echo "Users with sudo access: $SUDO_USERS"

# Check disk space
echo -e "\n${BLUE}💽 DISK USAGE${NC}"
df -h / | tail -1 | awk '{
    usage = int($5)
    if (usage > 90) 
        print "\033[0;31m✗ Disk usage critical: " $5 "\033[0m"
    else if (usage > 80) 
        print "\033[1;33m⚠ Disk usage high: " $5 "\033[0m"
    else 
        print "\033[0;32m✓ Disk usage normal: " $5 "\033[0m"
}'

# Check memory usage
echo -e "\n${BLUE}🧠 MEMORY USAGE${NC}"
free | awk '/^Mem:/ {
    usage = int($3/$2 * 100)
    if (usage > 90) 
        print "\033[0;31m✗ Memory usage critical: " usage "%\033[0m"
    else if (usage > 80) 
        print "\033[1;33m⚠ Memory usage high: " usage "%\033[0m"
    else 
        print "\033[0;32m✓ Memory usage normal: " usage "%\033[0m"
}'

# Check for security tools
echo -e "\n${BLUE}🛠️  SECURITY TOOLS${NC}"
TOOLS=("aide" "rkhunter" "chkrootkit" "lynis" "logwatch")
for tool in "${TOOLS[@]}"; do
    if command -v $tool &> /dev/null; then
        echo -e "${GREEN}✓ $tool installed${NC}"
    else
        echo -e "${RED}✗ $tool not installed${NC}"
    fi
done

# Security recommendations
echo -e "\n${BLUE}📋 RECOMMENDATIONS${NC}"
echo "High Priority:"
if ! command -v ufw &> /dev/null || ! sudo ufw status | grep -q "Status: active"; then
    echo -e "${RED}  • Install and configure UFW firewall${NC}"
fi
if ! systemctl is-active --quiet fail2ban; then
    echo -e "${RED}  • Install and configure fail2ban${NC}"
fi
if grep -q "^PermitRootLogin yes" $SSH_CONFIG; then
    echo -e "${RED}  • Disable SSH root login${NC}"
fi

echo -e "\nMedium Priority:"
if [ "$SSH_PORT" = "22" ]; then
    echo -e "${YELLOW}  • Change SSH port from default${NC}"
fi
if ! command -v unattended-upgrades &> /dev/null; then
    echo -e "${YELLOW}  • Configure automatic security updates${NC}"
fi

echo -e "\nLow Priority:"
echo -e "${BLUE}  • Set up SSH key authentication${NC}"
echo -e "${BLUE}  • Install intrusion detection tools${NC}"
echo -e "${BLUE}  • Configure log monitoring${NC}"

echo -e "\n=================================================="
echo -e "${GREEN}Run ./scripts/harden-vm.sh to apply security hardening${NC}"
echo "=================================================="
