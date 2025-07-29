# PostgreSQL HA Cluster Setup Script

## Overview

This script automates the setup of a highly available PostgreSQL cluster using:
- **Patroni** for PostgreSQL HA and automatic failover  
- **etcd** for distributed configuration storage and leader election  
- **HAProxy** with **Keepalived** for load balancing and virtual IP management

  <img width="1811" height="686" alt="image" src="https://github.com/user-attachments/assets/e5c85b9e-aef4-417c-b784-15d9da557dbe" />


## Features

- Role-based node configuration (PostgreSQL, etcd, HAProxy)  
- Automatic configuration based on node IP address  
- Integrated health checks and monitoring  
- Virtual IP failover for HAProxy nodes  
- Secure replication and authentication setup  

## Prerequisites

- Ubuntu servers  
- All nodes must have passwordless sudo access  
- Network connectivity between all nodes  

## Configuration

Before running the script, edit the following variables at the top of the script:

```bash
# Hostname configuration
declare -A HOSTNAMES=(
    ["10.128.0.6"]="etcd01"
    ["10.128.0.12"]="etcd02"
    ["10.128.0.8"]="psql01"
    ["10.128.0.9"]="psql02"
  # ["10.128.0.xx"]="harpoxy01"
  # ["10.128.0.xx"]="etcd03"
  # ...
)

# Node roles configuration
# you can use mulitple roles for one node if you're tight on resources as I have done here ["10.128.0.6"]="etcd,haproxy"
declare -A NODE_ROLES=(
    ["10.128.0.6"]="etcd,haproxy"
    ["10.128.0.12"]="etcd,haproxy"
    ["10.128.0.8"]="postgres"
    ["10.128.0.9"]="postgres"
  # ["10.128.0.xx"]="harpoxy"
  # ["10.128.0.xx"]="etcd"
  # ...
)

# Common variables
PG_VERSION="14"
VIRTUAL_IP="10.128.0.9"
VIP_INTERFACE="ens4"
MAIN_HAPROXY_IP="10.128.0.6"
HAPROXY_POSTGRES_PORT="5000"
HAPROXY_STAT_PORT="7000"
CLUSTER_SCOPE="postgres"
CLUSTER_NAMESPACE="/db/"
PATRONI_DATA_DIR="/dev/data/patroni"
ETCD_DATA_DIR=""/var/lib/etcd""
PATRONI_SUPER_USER_NAME="postgres"
PATRONI_SUPER_USER_PASS="BgtQhzSnq2ud7ctf"
PATRONI_REPL_USER_NAME="replicator"
PATRONI_REPL_USER_PASS="W7zKgLKd210SKW8Y"
```
## Usage
```
wget https://raw.githubusercontent.com/Mostafa-ewida/patroni-ha/refs/heads/main/postgres_cluster_setup.sh
```
```
chmod +x postgres_cluster_setup.sh
```
Then update the configuration variables for your environment
```
vi postgres_cluster_setup.sh
```
and run it using
```
sudo ./postgres_cluster_setup.sh
```


## Verification

### Node-Specific Verification Commands

| Node Type    | Verification Command                          | Expected Output                     |
|--------------|-----------------------------------------------|-------------------------------------|
| etcd         | `ETCDCTL_API=3 etcdctl endpoint health`       | `http://<ip>:2379 is healthy`       |
| HAProxy      | `curl -sI http://localhost:7000`              | `HTTP/1.1 200 OK`                   |
| PostgreSQL   | `sudo systemctl status patroni`               | `Active: active (running)`          |
|              | `curl -s http://localhost:8008`               | JSON with PostgreSQL state          |

## Post-Installation Access

### Connection Information

| Component       | Access Method                     | Credentials                          |
|-----------------|-----------------------------------|--------------------------------------|
| PostgreSQL      | `psql -h $VIRTUAL_IP -p $HAPROXY_POSTGRES_PORT -U $PATRONI_SUPER_USER_NAME` | Username: `postgres`Password: `BgtQhzSnq2ud7ctf` |
| HAProxy Stats   | `http://<any_haproxy_ip>:$HAPROXY_STAT_PORT` | No auth by default                   |
| Patroni API     | `http://<postgres_node_ip>:8008`  | No auth by default                   |

## Maintenance Commands

```bash
# View cluster status
patronictl -c /etc/patroni.yml list

# more commands to help you navigate
patronictl -c /etc/patroni.yml --help
```


### Log Locations

- **Patroni**: 
  ```bash
  journalctl -u patroni
  ```
