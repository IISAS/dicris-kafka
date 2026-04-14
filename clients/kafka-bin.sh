#!/usr/bin/env bash

. ./envvars.sh

bootstrap_server="${DOCKER_NAMESPACE}${KAFKA_BROKER_PREFIX}1.${HOSTNAME}:9093"

docker run \
  --rm \
  -v $(realpath "${1}"):/opt/client \
  apache/kafka:4.0.0 \
  /opt/kafka/bin/${2} \
  --bootstrap-server ${bootstrap_server} \
  --producer.config /opt/client/client.properties \
  ${@:3}

