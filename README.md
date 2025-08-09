# TimescaleDB on Debian VM: Complete Setup Guide

A comprehensive, production-ready guide for setting up PostgreSQL/TimescaleDB on a Debian VM from scratch. This repository provides step-by-step instructions, automation scripts, and best practices for deploying a robust time-series database server.

## 🚀 Quick Start

```bash
git clone https://github.com/marcospaterson/timescaledb-debian-setup.git
cd timescaledb-debian-setup
chmod +x scripts/*.sh
./scripts/01-vm-setup.sh
```

## 📋 What This Guide Covers

### Infrastructure Setup
- ✅ Debian VM configuration with static IP
- ✅ Disk mounting for data persistence
- ✅ System updates and essential packages
- ✅ Docker installation and configuration
- ✅ Network security and firewall setup

### Database Deployment
- ✅ TimescaleDB container with Docker Compose
- ✅ Data volume management and persistence
- ✅ User creation and permission management
- ✅ Database backup and restore procedures
- ✅ Performance monitoring and optimization

### Production Readiness
- ✅ Automated deployment scripts
- ✅ Comprehensive verification tests
- ✅ Environment configuration management
- ✅ Maintenance and troubleshooting guides

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────┐
│                Debian VM                │
│  ┌─────────────────────────────────────┐│
│  │            Docker Host              ││
│  │  ┌─────────────────────────────────┐││
│  │  │      TimescaleDB Container      │││
│  │  │                                 │││
│  │  │  ┌─────────────────────────────┐│││
│  │  │  │      PostgreSQL + TS        ││││
│  │  │  │                             ││││
│  │  │  │  Port: 5432                 ││││
│  │  │  │  Volume: /mnt/timescaledb   ││││
│  │  │  └─────────────────────────────┘│││
│  │  └─────────────────────────────────┘││
│  └─────────────────────────────────────┘│
└─────────────────────────────────────────┘
```

## 📖 Step-by-Step Guide

### Prerequisites
- Debian 12 (Bookworm) VM with root access
- At least 2GB RAM and 20GB storage
- Network connectivity and sudo privileges
- Additional disk for data persistence (recommended)

### Phase 1: VM Preparation
1. [Initial VM Setup](docs/01-vm-setup.md) - Static IP, updates, packages
2. [Disk Configuration](docs/02-disk-setup.md) - Mounting additional storage
3. [Docker Installation](docs/03-docker-setup.md) - Container runtime setup

### Phase 2: Database Deployment
4. [TimescaleDB Setup](docs/04-timescaledb-setup.md) - Container deployment
5. [User Management](docs/05-user-management.md) - Database users and permissions
6. [Data Persistence](docs/06-data-persistence.md) - Volume configuration

### Phase 3: Production Hardening
7. [Security Configuration](docs/07-security.md) - Firewall and access control
8. [Backup Strategy](docs/08-backup-restore.md) - Automated backups
9. [Monitoring Setup](docs/09-monitoring.md) - Health checks and alerts

## 🛠️ Automation Scripts

All setup steps are automated with numbered scripts in the `scripts/` directory:

| Script | Description | Purpose |
|--------|-------------|---------|
| `01-vm-setup.sh` | Initial VM configuration | System updates, packages, network |
| `02-mount-disk.sh` | Disk mounting and formatting | Data persistence setup |
| `03-install-docker.sh` | Docker installation | Container runtime |
| `04-deploy-timescaledb.sh` | TimescaleDB deployment | Database container |
| `05-create-users.sh` | Database user creation | Access management |
| `06-verify-setup.sh` | Comprehensive verification | Health checks |
| `07-backup-setup.sh` | Backup automation | Data protection |

## 📊 Database Specifications

### Container Configuration
- **Image**: `timescale/timescaledb-ha:pg17`
- **PostgreSQL Version**: 17
- **TimescaleDB Version**: Latest stable
- **Memory**: 2GB allocated
- **Storage**: Persistent volume mounted
- **Port**: 5432 (PostgreSQL standard)

### Database Schema
- **Main Database**: `myapp_db`
- **Default User**: `app_user`
- **Admin User**: `postgres`
- **Schema**: `public` with full permissions
- **Extensions**: TimescaleDB, pgcrypto, uuid-ossp

## 🔒 Security Features

### Network Security
- Firewall configured (UFW)
- Port 5432 restricted to authorized IPs
- SSH key-based authentication recommended
- Docker daemon secured

### Database Security
- Non-root database users
- Password-based authentication
- Role-based access control
- Encrypted connections (TLS)

## 📈 Performance Optimization

### System Level
- Kernel parameters tuned for database workload
- Memory settings optimized for TimescaleDB
- I/O scheduler configured for database operations
- Network buffers tuned for high throughput

### Database Level
- Shared memory configuration
- Connection pooling settings
- Checkpoint and WAL optimization
- Vacuum and analyze automation

## 🔄 Environment Configuration

The setup includes comprehensive environment management:

```bash
# Database and network configuration
DB_NAME=myapp_db
DB_USER=app_user
DB_PASSWORD=your_secure_password

# Network settings  
STATIC_IP=192.168.1.100
GATEWAY=192.168.1.1
```

## 🧪 Testing and Verification

### Automated Tests
- Container health checks
- Database connectivity tests
- User permission verification
- Data persistence validation
- Performance benchmarks

### Manual Verification
```bash
# Test database connection
psql -U app_user -d myapp_db -h localhost

# Check TimescaleDB extension
SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';

# Verify data persistence
docker restart timescaledb
psql -U app_user -d myapp_db -c "SELECT COUNT(*) FROM your_table;"
```

## 📦 What's Included

```
timescaledb-debian-setup/
├── README.md                    # This file
├── docker-compose.yml           # TimescaleDB container definition
├── .env.example                 # Environment template
├── docs/                        # Detailed documentation
│   ├── 01-vm-setup.md
│   ├── 02-disk-setup.md
│   ├── 03-docker-setup.md
│   ├── 04-timescaledb-setup.md
│   ├── 05-user-management.md
│   ├── 06-data-persistence.md
│   ├── 07-security.md
│   ├── 08-backup-restore.md
│   └── 09-monitoring.md
├── scripts/                     # Automation scripts
│   ├── 01-vm-setup.sh
│   ├── 02-mount-disk.sh
│   ├── 03-install-docker.sh
│   ├── 04-deploy-timescaledb.sh
│   ├── 05-create-users.sh
│   ├── 06-verify-setup.sh
│   └── 07-backup-setup.sh
├── config/                      # Configuration files
│   ├── postgresql.conf
│   ├── pg_hba.conf
│   └── timescaledb.conf
└── blog-post.md                 # Detailed blog post version
```

## 🚨 Troubleshooting

### Common Issues

**Connection Refused**
```bash
# Check if container is running
docker ps | grep timescaledb

# Check logs
docker logs timescaledb

# Verify port binding
netstat -tlnp | grep 5432
```

**Permission Denied**
```bash
# Re-run user creation script
./scripts/05-create-users.sh

# Check user permissions
psql -U postgres -d myapp_db -c "SELECT grantee, table_name, privilege_type FROM information_schema.role_table_grants WHERE grantee = 'app_user';"
```

**Data Not Persisting**
```bash
# Verify volume mount
docker inspect timescaledb | grep -A 10 "Mounts"

# Check disk space
df -h /mnt/timescaledb-data
```

## 🤝 Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.

### Development Setup
```bash
git clone https://github.com/marcospaterson/timescaledb-debian-setup.git
cd timescaledb-debian-setup
./scripts/01-vm-setup.sh
```

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Related Resources

- [TimescaleDB Official Documentation](https://docs.timescale.com/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Docker Compose Reference](https://docs.docker.com/compose/)
- [Debian System Administration](https://www.debian.org/doc/manuals/debian-reference/)

## 📬 Support

- **Documentation**: Check the `docs/` directory for detailed guides
- **Issues**: [GitHub Issues](https://github.com/marcospaterson/timescaledb-debian-setup/issues)
- **Discussions**: [GitHub Discussions](https://github.com/marcospaterson/timescaledb-debian-setup/discussions)
- **Blog Post**: [Detailed setup guide](blog-post.md)

## 📊 Project Status

![Build Status](https://github.com/marcospaterson/timescaledb-debian-setup/actions/workflows/test.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Docker](https://img.shields.io/badge/docker-supported-blue.svg)
![PostgreSQL](https://img.shields.io/badge/postgresql-17-blue.svg)
![TimescaleDB](https://img.shields.io/badge/timescaledb-latest-orange.svg)

---

⭐ **Star this repository** if you find it helpful!

Built with ❤️ by [Marcos Paterson](https://github.com/marcospaterson)
