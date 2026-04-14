#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "${SCRIPT_DIR}" && echo "🛈  CWD: ${PWD}"

. ./envvars.sh

DOCKER_NAMESPACE=${DOCKER_NAMESPACE:-''}
KAFKA_NUM_BROKERS=${KAFKA_NUM_BROKERS:-4}
KAFKA_BROKER_PREFIX=${KAFKA_BROKER_PREFIX:-'kafka-broker-'}
KAFKA_SSL_KEYSTORE_FILENAME=${KAFKA_SSL_KEYSTORE_FILENAME:-'keystore.jks'}
KAFKA_SSL_KEYSTORE_CREDENTIALS=${KAFKA_SSL_KEYSTORE_CREDENTIALS:-'keystore_creds'}
KAFKA_SSL_KEY_CREDENTIALS=${KAFKA_SSL_KEY_CREDENTIALS:-'ssl_key_creds'}
KAFKA_SSL_TRUSTSTORE_FILENAME=${KAFKA_SSL_TRUSTSTORE_FILENAME:-'truststore.jks'}
KAFKA_SSL_TRUSTSTORE_CREDENTIALS=${KAFKA_SSL_TRUSTSTORE_CREDENTIALS:-'truststore_creds'}
KAFKA_CLIENTS_HOME=${KAFKA_CLIENTS_HOME:-'./clients'}


###############################################################################


function rmdir_if_empty() {
  dir=$1
  if [ ! -d "$dir" ]; then
    return
  fi  
  if [ -z "$(find "$dir" -mindepth 1 -maxdepth 1)" ]; then
    rmdir -v $dir
  else
    echo "❌ $dir is not empty"
  fi  
}


###############################################################################


echo "🛈  KAFKA - cleaning ..."
echo "🛈  CWD: ${PWD}"

for i in `seq ${KAFKA_NUM_BROKERS}`; do

  node_name="${DOCKER_NAMESPACE}${KAFKA_BROKER_PREFIX}${i}"
  node_dir="${SCRIPT_DIR}/volumes/${node_name}"
  secrets_dir="${node_dir}/secrets"
  keystore_file="${secrets_dir}/${KAFKA_SSL_KEYSTORE_FILENAME}"
  keystore_password_file="${secrets_dir}/${KAFKA_SSL_KEYSTORE_CREDENTIALS}"
  keystore_ssl_key_file="${secrets_dir}/${KAFKA_SSL_KEY_CREDENTIALS}"
  truststore_file="${secrets_dir}/${KAFKA_SSL_TRUSTSTORE_FILENAME}"
  truststore_password_file="${secrets_dir}/${KAFKA_SSL_TRUSTSTORE_CREDENTIALS}"
  private_key_csr_file="${secrets_dir}/csr.pem"
  signed_private_key_cert_file="${secrets_dir}/cert.pem"

  rm -rfv "${keystore_file}"
  rm -rfv "${keystore_password_file}"
  rm -rfv "${keystore_ssl_key_file}"
  rm -rfv "${truststore_file}"
  rm -rfv "${truststore_password_file}"
  rm -rfv "${private_key_csr_file}"
  rm -rfv "${signed_private_key_cert_file}"

  rmdir_if_empty "${secrets_dir}"
  rmdir_if_empty "${node_dir}"

done

rm -rfv ${KAFKA_SSL_TRUSTSTORE_FILENAME}
rm -rfv ${KAFKA_SSL_TRUSTSTORE_CREDENTIALS}

"${KAFKA_CLIENTS_HOME}/clean.sh"

echo "🛈  KAFKA - cleaning ... done"

