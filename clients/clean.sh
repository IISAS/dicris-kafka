#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "${SCRIPT_DIR}" && echo "🛈  CWD: ${PWD}"

. ./envvars.sh


CLIENTS_HOME=${SCRIPT_DIR}
echo "🛈  CLIENTS_HOME: ${CLIENTS_HOME}"

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

function delete_client() {

  client_name_short="$1"
  client_name="${DOCKER_NAMESPACE}${KAFKA_CLIENT_PREFIX:-client-}${client_name_short}"
  client_dir="${CLIENTS_HOME}/${client_name}"

  keystore_file="${client_dir}/keystore.jks"
  keystore_file_p12="${client_dir}/keystore.p12"
  keystore_credentials="${client_dir}/keystore_creds"
  truststore_file="${client_dir}/truststore.jks"
  truststore_file_p12="${client_dir}/truststore.p12"
  truststore_credentials="${client_dir}/truststore_creds"
  key_file="${client_dir}/key.pem"
  csr_file="${client_dir}/csr.pem"
  cert_file="${client_dir}/cert.pem"
  cacert_file="${client_dir}/cacert.pem"
  client_properties_file="${client_dir}/client.properties"

  if [ -f "${CLIENTS_HOME}/kafka-topics-${client_name_short}.sh" ]; then
    rm -v "${CLIENTS_HOME}/kafka-topics-${client_name_short}.sh" 
  fi

  if [ ! -d "$client_dir" ]; then
    return
  fi

  echo "removing client: $client_name"

  if [ -f "$keystore_file" ]; then
    rm -v "$keystore_file"
  fi

  if [ -f "$keystore_file_p12" ]; then
    rm -v "$keystore_file_p12"
  fi

  if [ -f "$keystore_credentials" ]; then
    rm -v "$keystore_credentials"
  fi

  if [ -f "$truststore_file" ]; then
    rm -v "$truststore_file"
  fi

  if [ -f "$truststore_file_p12" ]; then
    rm -v "$truststore_file_p12"
  fi

  if [ -f "$truststore_credentials" ]; then
    rm -v "$truststore_credentials"
  fi

  if [ -f "$key_file" ]; then
    rm -v "$key_file"
  fi

  if [ -f "$csr_file" ]; then
    rm -v "$csr_file"
  fi

  if [ -f "$cert_file" ]; then
    rm -v "$cert_file"
  fi

  if [ -f "$cacert_file" ]; then
    rm -v "$cacert_file"
  fi
 
  if [ -f "$client_properties_file" ]; then
    rm -v "$client_properties_file"
  fi

  rmdir_if_empty "${client_dir}"

  if [ ! -d "$client_dir" ]; then
    echo "✅ removed client: $client_name"
  fi

  # clean CA volumes so re-provisioning generates fresh keys and certs
  if [ -n "${CA_ROOT:-}" ]; then
    ca_client_dir="${CA_ROOT}/volumes/certs/_clients_/${client_name}"
    if [ -d "${ca_client_dir}" ]; then
      rm -rfv "${ca_client_dir}"
      echo "✅ removed CA volumes for: ${client_name}"
    fi
  fi
}

if [ -p /dev/stdin ]; then
  echo "🛈  Cleaning clients ..."
  # Input is coming from a pipe or redirection
  while IFS=',' read -r client storepass; do
    [[ -z "$client" || $client == \#* ]] && continue
    delete_client "$client"
  done
  echo "🛈  Cleaning clients ... done"

elif [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
  echo "🛈  Cleaning clients ..."
  # No stdin, but a file argument is provided
  while IFS=',' read -r client storepass; do
    [[ -z "$client" || $client == \#* ]] && continue
    delete_client "$client"
  done < "$1"
  echo "🛈  Cleaning clients ... done"

elif [ -f clients ]; then
  echo "🛈  Cleaning clients ..."
  # No stdin, not file argument but 'clients' file exists
  while IFS=',' read -r client storepass; do
    [[ -z "$client" || $client == \#* ]] && continue
    delete_client "$client"
  done < clients
  echo "🛈  Cleaning clients ... done"

else
  echo "Usage: $0 [filename], via pipe, or 'clients' file" >&2
  exit 1
fi

