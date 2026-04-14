#!/usr/bin/env bash

. ./envvars.sh

bootstrap_server="${DOCKER_NAMESPACE}${KAFKA_BROKER_PREFIX}1.${HOSTNAME}:9093"

docker run \
  --rm \
  -v $(realpath "${1}"):/opt/client \
  apache/kafka:4.0.0 \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server ${bootstrap_server} \
  --command-config /opt/client/client.properties \
  ${@:2}

