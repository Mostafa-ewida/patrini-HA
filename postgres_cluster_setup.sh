#!/bin/bash
# postgres_cluster_setup.sh - HA Cluster Setup with IP-Based Role Assignment


#CHANGEME
# Hostname configuration (for /etc/hosts)
declare -A HOSTNAMES=(
    ["10.128.0.15"]="etcd"
    ["10.128.0.13"]="psgr01"
    ["10.128.0.14"]="psgr02"
)

#CHANGEME
# Node configuration with IP-based roles
declare -A NODE_ROLES=(
    # Format: ["ip"]="role1,role2"
    ["10.128.0.15"]="etcd,haproxy"          # Combined etcd and haproxy on same IP
    ["10.128.0.13"]="postgres"
    ["10.128.0.14"]="postgres"
)



#CHANGEME
# Common variables
PG_VERSION="14"
VIRTUAL_IP="10.128.0.100"
VIP_INTERFACE="ens4"
MAIN_HAPROXY_IP="10.128.0.15"
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


# Get current IP and roles
# get the IPV4 of Current node
CURRENT_IP=$(hostname -i | awk '{print $1}')
IFS=',' read -ra CURRENT_ROLES <<< "${NODE_ROLES[$CURRENT_IP]}"
CURRENT_HOST=${HOSTNAMES[$CURRENT_IP]}
# Generate node lists by role
POSTGRES_IPS=()
ETCD_IPS=()
HAPROXY_IPS=()



for ip in "${!NODE_ROLES[@]}"; do
    IFS=',' read -ra roles <<< "${NODE_ROLES[$ip]}"
    for role in "${roles[@]}"; do
        case "$role" in
            postgres) POSTGRES_IPS+=("$ip") ;;
            etcd) ETCD_IPS+=("$ip") ;;
            haproxy) HAPROXY_IPS+=("$ip") ;;
        esac
    done
done


# Generate etcd initial cluster string
INITIAL_CLUSTER=""
for ip in "${ETCD_IPS[@]}"; do
    INITIAL_CLUSTER+="${HOSTNAMES[$ip]}=http://${ip}:2380,"
done
INITIAL_CLUSTER=${INITIAL_CLUSTER%,}





if [ -z "$CURRENT_ROLES" ]; then
    echo "Error: Current IP not found in node configuration!"
    exit 1
fi

# Function to update system
update_system() {
    echo "-[$CURRENT_IP] Updating system packages..."
    sudo apt update  > /dev/null 2>&1
    sudo apt upgrade -y > /dev/null 2>&1
    sudo apt install -y wget curl gnupg2 jq > /dev/null 2>&1
    echo "+[$CURRENT_IP] Updating DONE"

}

# Function to configure hosts file
configure_hosts() {
    echo "-[$CURRENT_IP] Configuring /etc/hosts..."
    sudo cp /etc/hosts /etc/hosts.bak
    
    for ip in "${!HOSTNAMES[@]}"; do
        if ! grep -q "$ip  ${HOSTNAMES[$ip]}" /etc/hosts; then
            echo "  Adding entry: $ip  ${HOSTNAMES[$ip]}"
            sudo bash -c "echo '$ip  ${HOSTNAMES[$ip]}' >> /etc/hosts"
        fi
    done
    echo "+[$CURRENT_IP] Configuring /etc/hosts  DONE"

}

# Function to setup PostgreSQL node
setup_postgres_node() {
    echo "-[$CURRENT_IP] Setting up PostgreSQL node..."
    
    # Install PostgreSQL and dependencies
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add - > /dev/null 2>&1
    echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list  > /dev/null 2>&1
    sudo apt update  > /dev/null 2>&1
    sudo apt install -y postgresql-$PG_VERSION postgresql-client-$PG_VERSION postgresql-contrib \
    python3-pip python3-dev libpq-dev  > /dev/null 2>&1
    sudo pip3 install --upgrade pip  > /dev/null 2>&1
    sudo pip install patroni python-etcd psycopg2-binary  > /dev/null 2>&1

    sudo systemctl stop postgresql
    sudo ln -sf /usr/lib/postgresql/${PG_VERSION}/bin/* /usr/sbin/  > /dev/null 2>&1

    # Create Patroni directories
    sudo mkdir -p $PATRONI_DATA_DIR 
    sudo chown postgres:postgres $PATRONI_DATA_DIR
    sudo chmod 700 $PATRONI_DATA_DIR


    # Generate pg_hba entries
    # PG_HBA_ENTRIES=""
    # for ip in "${POSTGRES_IPS[@]}"; do
    #     PG_HBA_ENTRIES+="    - host replication replicator ${ip}/32 md5\n"
    # done

    PG_HBA_ENTRIES=$(for ip in "${POSTGRES_IPS[@]}"; do
    echo "    - host replication replicator $ip/0 md5"
done)

# Create Patroni config
sudo tee /etc/patroni.yml > /dev/null <<EOF
scope: postgres
namespace: /db/
name: $CURRENT_HOST
restapi:
  listen: $CURRENT_IP:8008
  connect_address: $CURRENT_IP:8008
etcd:
  hosts: 
$(printf "    - %s:2379\n" "${ETCD_IPS[@]}")

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
    use_pg_rewind: true
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator   127.0.0.1/32 md5
${PG_HBA_ENTRIES}
    - host all all   0.0.0.0/0   md5
  users:
    admin:
       password: admin
       options:
       - createrole
       - createdb
postgresql:
   listen: $CURRENT_IP:5432
   connect_address: $CURRENT_IP:5432
   data_dir: $PATRONI_DATA_DIR
   pgpass: /tmp/pgpass
   authentication:
    replication:
      username: $PATRONI_REPL_USER_NAME 
      password: $PATRONI_REPL_USER_PASS
    superuser:
      username: $PATRONI_SUPER_USER_NAME
      password: $PATRONI_SUPER_USER_PASS
      parameters:
        unix_socket_directories: '.'
tags:
   nofailover: false
   noloadbalance: false
   clonefrom: false
   nosync: false
EOF
    # Create Patroni service file
    sudo tee /etc/systemd/system/patroni.service > /dev/null <<EOF
[Unit]
Description=Patroni Orchestration
After=syslog.target network.target
[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni.yml
KillMode=process
TimeoutSec=30
Restart=no
[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable patroni > /dev/null 2>&1
    sudo systemctl start patroni

    echo "+[$CURRENT_IP] Setting up PostgreSQL DONE"

}

# Function to setup etcd node
setup_etcd_node() {
    echo "-[$CURRENT_IP] Setting up etcd node..."
    
    # Determine etcd name based on IP position
    ETCD_NAME=$CURRENT_HOST
 
    sudo apt install -y etcd  > /dev/null 2>&1

    sudo tee /etc/default/etcd > /dev/null <<EOF
ETCD_NAME="$ETCD_NAME"
ETCD_DATA_DIR=$ETCD_DATA_DIR
ETCD_LISTEN_PEER_URLS="http://$CURRENT_IP:2380"
ETCD_LISTEN_CLIENT_URLS="http://$CURRENT_IP:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$CURRENT_IP:2380"
ETCD_INITIAL_CLUSTER="$INITIAL_CLUSTER"
ETCD_ADVERTISE_CLIENT_URLS="http://$CURRENT_IP:2379"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-1"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF

    sudo mkdir -p /var/lib/etcd
    sudo chown etcd:etcd /var/lib/etcd
    sudo systemctl restart etcd
    sudo systemctl enable etcd  > /dev/null 2>&1

    echo "+[$CURRENT_IP] Setting up etcd DONE"

}

# Function to setup HAProxy node
setup_haproxy_node() {
    echo "-[$CURRENT_IP] Setting up HAProxy node..."
    
    sudo apt install -y haproxy keepalived  > /dev/null 2>&1

    # Generate server entries

    SERVER_ENTRIES=$(for ip in "${POSTGRES_IPS[@]}"; do
    printf "    server %s %s:5432 maxconn 100 check port 8008\n" "$ip" "${HOSTNAMES[$ip]}"
done)
    # Configure HAProxy
    sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 2000

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000

listen stats
    mode http
    bind *:$HAPROXY_STAT_PORT
    stats enable
    stats uri /
    stats refresh 10s
    stats admin if TRUE

listen postgres
    bind *:$HAPROXY_POSTGRES_PORT
    option httpchk
    http-check expect status 200
    balance roundrobin
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
$SERVER_ENTRIES
EOF

    # Configure keepalived (different priorities for HAProxy nodes)
    local priority=100

    [[ "$CURRENT_IP" == $MAIN_HAPROXY_IP ]] && priority=101  # First haproxy gets higher priority

    sudo tee /etc/keepalived/keepalived.conf > /dev/null <<EOF
vrrp_script chk_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    interface $VIP_INTERFACE
    state $([[ "$priority" == 101 ]] && echo "MASTER" || echo "BACKUP")
    virtual_router_id 51
    priority $priority
    virtual_ipaddress {
        $VIRTUAL_IP
    }
    track_script {
        chk_haproxy
    }
}
EOF

    sudo systemctl restart haproxy
    sudo systemctl enable haproxy > /dev/null 2>&1
    sudo systemctl restart keepalived
    sudo systemctl enable keepalived > /dev/null 2>&1

    echo "+[$CURRENT_IP] Setting up HAProxy node DONE"

}

# Main execution
echo "=== Starting Postgres-$PG_VERSION cluster setup on $CURRENT_IP (${CURRENT_ROLES[*]}) ==="
update_system
configure_hosts

for role in "${CURRENT_ROLES[@]}"; do
    case "$role" in
        postgres) setup_postgres_node ;;
        etcd) setup_etcd_node ;;
        haproxy) setup_haproxy_node ;;
    esac
done

# Verification
sleep 10

echo "=== Setup complete for $CURRENT_IP (${CURRENT_ROLES[*]}) ==="
echo "=== Verification ==="


if [[ " ${CURRENT_ROLES[*]} " =~ " etcd " ]]; then
    echo "ETCD Status:"
    ETCDCTL_API=3 etcdctl --endpoints=http://$CURRENT_IP:2379 endpoint health
    ETCDCTL_API=3 etcdctl --endpoints=http://$CURRENT_IP:2379 member list
fi

if [[ " ${CURRENT_ROLES[*]} " =~ " haproxy " ]]; then
    echo "HAProxy Status:"
    curl -sI http://localhost:7000 | head -1
    echo "Keepalived Status:"
    ip a show eth0 | grep $VIRTUAL_IP || echo "VIP not assigned (may be normal for backup node)"
fi

if [[ " ${CURRENT_ROLES[*]} " =~ " postgres " ]]; then
    echo "Patroni Status:"
    sudo systemctl status patroni --no-pager | grep -E "Active:|Loaded:"
    echo "PostgreSQL Reachable: $(curl -s http://$CURRENT_IP:8008 | jq -r .state)"

    echo "Super_User_Name: $PATRONI_SUPER_USER_NAME"
    echo "Super_User_Password: $PATRONI_SUPER_USER_PASS"

fi
