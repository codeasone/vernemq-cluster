#!/bin/bash

SELF_HOST=$(hostname)

if [[ -v AWS_CONTAINER_CREDENTIALS_RELATIVE_URI ]]; then
  SELF_IP=$(ip -4 addr show ethwe | grep -oP "(?<=inet).*(?=/)"| sed -e "s/^[[:space:]]*//" | tail -n 1)
else
  SELF_IP=$(ip -4 addr show eth0 | grep -oP "(?<=inet).*(?=/)"| sed -e "s/^[[:space:]]*//" | tail -n 1)
fi

echo "Starting: ${SELF_HOST} ${SELF_IP}"

# Ensure correct ownership and permissions on volumes
chown vernemq:vernemq /var/lib/vernemq /var/log/vernemq
chmod 755 /var/lib/vernemq /var/log/vernemq

sed -i.bak "s/VerneMQ@127.0.0.1/VerneMQ@${SELF_IP}/" /etc/vernemq/vm.args
echo "Registering: ${SELF_IP}"
echo "${SELF_IP}" > /tmp/host
aws s3api put-object --bucket vernemq-discovery --key "${SELF_IP}" --body /tmp/host > /dev/null

sed -i '/########## Start ##########/,/########## End ##########/d' /etc/vernemq/vernemq.conf

echo "########## Start ##########" >> /etc/vernemq/vernemq.conf

env | grep DOCKER_VERNEMQ | grep -v DISCOVERY_NODE | cut -c 16- | tr '[:upper:]' '[:lower:]' | sed 's/__/./g' >> /etc/vernemq/vernemq.conf

echo "erlang.distribution.port_range.minimum = 9100" >> /etc/vernemq/vernemq.conf
echo "erlang.distribution.port_range.maximum = 9109" >> /etc/vernemq/vernemq.conf
echo "listener.tcp.default = 0.0.0.0:1883" >> /etc/vernemq/vernemq.conf

# Tip: don't use 0.0.0.0 for clustering port
echo "listener.vmq.clustering = ${SELF_IP}:44053" >> /etc/vernemq/vernemq.conf
echo "listener.http.metrics = 0.0.0.0:8888" >> /etc/vernemq/vernemq.conf

echo "########## End ##########" >> /etc/vernemq/vernemq.conf

# Check configuration file
su - vernemq -c "/usr/sbin/vernemq config generate 2>&1 > /dev/null" | tee /tmp/config.out | grep error

if [ $? -ne 1 ]; then
  echo "configuration error, exit"
  echo "$(cat /tmp/config.out)"
  exit $?
fi

pid=0

# SIGUSR1-handler
siguser1_handler() {
  echo "stopped"
}

# SIGTERM-handler
sigterm_handler() {
  if [ $pid -ne 0 ]; then
    # this will stop the VerneMQ process
    vmq-admin cluster leave node=VerneMQ@$SELF_IP -k > /dev/null
    wait "$pid"
  fi
  exit 143; # 128 + 15 -- SIGTERM
}

# setup handlers
# on callback, kill the last background process, which is `tail -f /dev/null`
# and execute the specified handler
trap 'kill ${!}; siguser1_handler' SIGUSR1
trap 'kill ${!}; sigterm_handler' SIGTERM

/usr/sbin/vernemq start
pid=$(ps aux | grep '[b]eam.smp' | awk '{print $2}')

sleep 3s

echo "Discovering nodes via S3 bucket"
MASTER_NODES=`aws s3 ls vernemq-discovery | awk '{ print $4 }' | awk 'BEGIN { ORS = " " } { print }'`

for MASTER in $(echo $MASTER_NODES); do
  echo '['$(date -u +"%Y-%m-%dT%H:%M:%SZ")']:join VerneMQ@'${MASTER}
  vmq-admin cluster join discovery-node=VerneMQ@${MASTER}
done

tail -f /var/log/vernemq/console.log
