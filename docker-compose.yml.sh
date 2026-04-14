#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd ${SCRIPT_DIR}

. ./envvars.sh >&2

# CA configuration
[ -z "${CA_ROOT}" ] && { echo "❌ CA_ROOT is not set"; exit 1; }


function get_KAFKA_CONROLLER_QUORUM_VOTERS() {
  voters=''
  for i in `seq ${KAFKA_NUM_CONTROLLERS}`; do
    voters="${voters},${i}@${DOCKER_NAMESPACE}${KAFKA_CONTROLLER_PREFIX}${i}:${KAFKA_PORT_CONTROLLER}"
  done
  echo "${voters:1}"
  return 0
}

KAFKA_HOME=${SCRIPT_DIR}
KAFKA_CONTROLLER_QUORUM_VOTERS=$(get_KAFKA_CONROLLER_QUORUM_VOTERS)
KAFKA_CLUSTER_ID=${KAFKA_CLUSTER_ID:-$(./cluster-id.py)}


###############################################################################


function provision_controller_service() {
  node_id=$1
  controller_id=$2
  cat <<EOF
  ${KAFKA_CONTROLLER_PREFIX}${controller_id}:
    image: ${KAFKA_IMAGE}
    container_name: ${DOCKER_NAMESPACE}${KAFKA_CONTROLLER_PREFIX}${controller_id}
    environment:
      KAFKA_NODE_ID: ${node_id}
      KAFKA_PROCESS_ROLES: 'controller'
      KAFKA_CONTROLLER_QUORUM_VOTERS: '${KAFKA_CONTROLLER_QUORUM_VOTERS}'
      KAFKA_CONTROLLER_LISTENER_NAMES: 'CONTROLLER'
      KAFKA_LISTENERS: 'CONTROLLER://:${KAFKA_PORT_CONTROLLER}'
      CLUSTER_ID: '${KAFKA_CLUSTER_ID}'
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_LOG_DIRS: '/tmp/kraft-combined-logs'
    networks:
      kafka-network:
EOF
}


function provision_broker_service() {
  node_id=$1
  broker_id=$2
  broker_name="${DOCKER_NAMESPACE}${KAFKA_BROKER_PREFIX}${broker_id}"
  cat <<EOF
  ${KAFKA_BROKER_PREFIX}${broker_id}:
    image: ${KAFKA_IMAGE}
    hostname: ${broker_name}.${HOSTNAME}
    container_name: ${broker_name}
    volumes:
      - ${CA_ROOT}/volumes/certs/${broker_name}/secrets:/etc/kafka/secrets
    environment:
      KAFKA_NODE_ID: ${node_id}
      KAFKA_PROCESS_ROLES: 'broker'
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: 'SSL:SSL,CONTROLLER:PLAINTEXT,SSL-INTERNAL:SSL'
      KAFKA_LISTENERS: 'SSL-INTERNAL://:1${KAFKA_PORT_BROKER},SSL://:${KAFKA_PORT_BROKER}'
      KAFKA_CONTROLLER_QUORUM_VOTERS: '${KAFKA_CONTROLLER_QUORUM_VOTERS}'
      KAFKA_INTER_BROKER_LISTENER_NAME: 'SSL-INTERNAL'
      KAFKA_SECURITY_PROTOCOL: SSL
      KAFKA_ADVERTISED_LISTENERS: 'SSL-INTERNAL://${broker_name}:1${KAFKA_PORT_BROKER},SSL://${broker_name}.${HOSTNAME}:${KAFKA_PORT_BROKER}'
      KAFKA_CONTROLLER_LISTENER_NAMES: 'CONTROLLER'
      CLUSTER_ID: '${KAFKA_CLUSTER_ID}'
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_LOG_DIRS: '/tmp/kraft-combined-logs'
      KAFKA_LOG_MESSAGE_TIMESTAMP_TYPE: CreateTime
      KAFKA_SSL_KEYSTORE_FILENAME: ${KAFKA_SSL_KEYSTORE_FILENAME}
      KAFKA_SSL_KEYSTORE_CREDENTIALS: ${KAFKA_SSL_KEYSTORE_CREDENTIALS}
      KAFKA_SSL_KEY_CREDENTIALS: ${KAFKA_SSL_KEY_CREDENTIALS}
      KAFKA_SSL_TRUSTSTORE_FILENAME: ${KAFKA_SSL_TRUSTSTORE_FILENAME}
      KAFKA_SSL_TRUSTSTORE_CREDENTIALS: ${KAFKA_SSL_TRUSTSTORE_CREDENTIALS}
      KAFKA_SSL_CLIENT_AUTH: 'required'
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
    labels:
      - "traefik.enable=true"
      - "traefik_instance=${TRAEFIK_INSTANCE}"
      - "traefik.docker.network=${TRAEFIK_NETWORK}"
      - "traefik.tcp.routers.${broker_name}.tls=true"
      - "traefik.tcp.routers.${broker_name}.entrypoints=${TRAEFIK_ENTRYPOINT_KAFKA_TLS}"
      - "traefik.tcp.routers.${broker_name}.tls.passthrough=true"
      - "traefik.tcp.routers.${broker_name}.rule=HostSNI(\`${broker_name}.${HOSTNAME}\`)"
      - "traefik.tcp.routers.${broker_name}.service=${broker_name}-service"
      - "traefik.tcp.services.${broker_name}-service.loadbalancer.server.port=${KAFKA_PORT_BROKER}"
    networks:
      kafka-network:
      traefik-network:
        aliases:
          - "${broker_name}"
    depends_on:
EOF
  for i in `seq ${KAFKA_NUM_CONTROLLERS}`; do
    cat <<EOF
      - ${KAFKA_CONTROLLER_PREFIX}${i}
EOF
  done
}


###############################################################################


echo "services:"

node_id=1

for i in `seq ${KAFKA_NUM_CONTROLLERS}`; do
  provision_controller_service ${node_id} ${i}
  node_id=$((node_id + 1))
done

for i in `seq ${KAFKA_NUM_BROKERS}`; do
  provision_broker_service ${node_id} ${i}
  node_id=$((node_id + 1))
done

cat <<EOF
networks:
  kafka-network:
  traefik-network:
    name: "${TRAEFIK_NETWORK}"
    external: true
EOF
