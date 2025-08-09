# VM Setup Guide

This guide covers the initial setup of a Debian VM for TimescaleDB deployment, including system configuration, network setup, and performance optimization.

## Prerequisites

- Fresh Debian 12 (Bookworm) installation
- Root or sudo access
- At least 2GB RAM and 20GB storage
- Network connectivity

## Overview

The VM setup script (`01-vm-setup.sh`) performs:

- System updates and essential package installation
- Static IP configuration
- System optimization for database workloads
- Security hardening (firewall, fail2ban)
- User management setup

## Configuration Options

Before running the setup, configure your environment variables in `.env`:

```bash
# Network Configuration
STATIC_IP=192.168.1.100
GATEWAY=192.168.1.1
DNS_SERVERS="8.8.8.8 8.8.4.4"
NETMASK=255.255.255.0
INTERFACE=eth0

# System Configuration  
TIMEZONE=UTC
LOCALE=en_US.UTF-8
```

## Running the Setup

```bash
# Make script executable
chmod +x scripts/01-vm-setup.sh

# Run as root
sudo ./scripts/01-vm-setup.sh
```

## What the Script Does

### 1. System Updates
- Updates package repositories
- Upgrades all installed packages
- Installs essential utilities and tools

### 2. Package Installation
The script installs these essential packages:
- `curl`, `wget`, `git` - Download and version control tools
- `vim`, `htop` - Text editor and system monitoring
- `docker-ce`, `docker-compose` - Container runtime (if not using separate Docker script)
- `ufw`, `fail2ban` - Security tools
- `rsync`, `cron` - Backup and scheduling tools
- Network utilities and monitoring tools

### 3. Network Configuration
Creates static IP configuration in `/etc/network/interfaces`:

```
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 8.8.8.8 8.8.4.4
```

### 4. System Optimization
Applies database-specific kernel parameters in `/etc/sysctl.conf`:

```
# Memory management
vm.swappiness = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Shared memory
kernel.shmmax = 4294967295
kernel.shmall = 268435456

# Network buffers  
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
```

### 5. Security Configuration
- Configures UFW firewall with default deny policy
- Allows SSH (port 22) and PostgreSQL (port 5432) from private networks
- Installs and configures fail2ban for intrusion protection
- Sets up system limits for database users

### 6. User Management
- Creates `dbadmin` user with sudo privileges
- Configures proper user limits for PostgreSQL workloads

## Post-Setup Verification

After running the script, verify the setup:

### Check Network Configuration
```bash
# Verify IP configuration
ip addr show eth0

# Test connectivity
ping 8.8.8.8

# Check DNS resolution
nslookup google.com
```

### Check System Configuration
```bash
# Verify firewall status
sudo ufw status

# Check fail2ban status
sudo systemctl status fail2ban

# Verify system limits
ulimit -n
```

### Check Optimization Settings
```bash
# Check kernel parameters
sysctl vm.swappiness
sysctl kernel.shmmax

# Check system timezone
timedatectl status
```

## Troubleshooting

### Network Issues
If network configuration fails:
1. Check interface name: `ip link show`
2. Manually configure: `sudo nano /etc/network/interfaces`
3. Restart networking: `sudo systemctl restart networking`

### SSH Access Issues
If you lose SSH access after network changes:
1. Use console access to check configuration
2. Verify firewall rules: `sudo ufw status numbered`
3. Check SSH service: `sudo systemctl status ssh`

### Permission Issues
If user creation fails:
1. Check existing users: `cat /etc/passwd`
2. Manually create user: `sudo useradd -m -s /bin/bash dbadmin`
3. Add to sudo group: `sudo usermod -aG sudo dbadmin`

## Manual Configuration

If you prefer manual setup instead of the script:

### 1. Update System
```bash
sudo apt update && sudo apt upgrade -y
```

### 2. Install Packages
```bash
sudo apt install -y curl wget git vim htop unzip \
    software-properties-common apt-transport-https \
    ca-certificates gnupg lsb-release ufw fail2ban \
    rsync cron net-tools dnsutils
```

### 3. Configure Static IP
```bash
sudo cp /etc/network/interfaces /etc/network/interfaces.backup
sudo nano /etc/network/interfaces
# Add your static IP configuration
sudo systemctl restart networking
```

### 4. Configure Firewall
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow from 10.0.0.0/8 to any port 5432
sudo ufw enable
```

### 5. Apply System Optimizations
```bash
sudo nano /etc/sysctl.conf
# Add database optimizations
sudo sysctl -p
```

## Next Steps

After VM setup completion:

1. **Reboot the system** to apply network changes:
   ```bash
   sudo reboot
   ```

2. **Verify network connectivity** after reboot:
   ```bash
   ping 8.8.8.8
   ssh user@your-new-static-ip
   ```

3. **Run disk setup** if using additional storage:
   ```bash
   ./scripts/02-mount-disk.sh
   ```

4. **Install Docker** for container management:
   ```bash
   ./scripts/03-install-docker.sh
   ```

## Security Considerations

### Firewall Rules
The default firewall configuration allows:
- SSH (port 22) from anywhere
- PostgreSQL (port 5432) from private networks only

For production, restrict SSH to specific IP addresses:
```bash
sudo ufw delete allow ssh
sudo ufw allow from YOUR_IP_ADDRESS to any port 22
```

### User Security
- Change default passwords immediately
- Use SSH keys instead of password authentication
- Regularly update the system: `sudo apt update && sudo apt upgrade`

### Network Security
- Use private networks when possible
- Consider VPN access for remote administration
- Monitor logs regularly: `sudo tail -f /var/log/auth.log`

## Performance Tuning

### Memory Settings
The script applies conservative memory settings. For systems with more RAM, adjust:

```bash
# For 8GB+ systems
echo 'kernel.shmmax = 17179869184' >> /etc/sysctl.conf  # 16GB
echo 'kernel.shmall = 2097152' >> /etc/sysctl.conf      # 8GB in pages
```

### I/O Scheduler
For SSD storage, optimize the I/O scheduler:
```bash
echo 'deadline' > /sys/block/sda/queue/scheduler
# Make permanent in /etc/rc.local or systemd service
```

### CPU Governor
For consistent performance:
```bash
echo 'performance' > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

This VM setup provides a solid foundation for TimescaleDB deployment with security, performance, and reliability in mind.
