#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "${SCRIPT_DIR}" && echo "🛈  CWD: ${PWD}"

. ./envvars.sh

# CA configuration
[ -z "${CA_ROOT}" ] && { echo "❌ CA_ROOT is not set"; exit 1; }
CA_HOME="${CA_ROOT}/volumes/ca"

KAFKA_HOME=${SCRIPT_DIR}
KAFKA_CLIENTS_HOME="${KAFKA_HOME}/clients"

cacert_file_ca="/ca/cacert.pem"
cacert_file_host="${CA_HOME}/cacert.pem"

# Cert validity in days — override via .env if needed
KAFKA_SSL_CERT_VALIDITY_DAYS=${KAFKA_SSL_CERT_VALIDITY_DAYS:-3650}


###############################################################################


function clean_path() {
  path=$1
  echo "$path" | sed 's#//*#/#g'
  return 0
}

# Convert a CA container path (e.g. /certs/foo) to its host equivalent
function capath2host() {
  clean_path "${CA_ROOT}/volumes/$1"
}


function import_cert() {

  keystore_ca=$1
  file=$2
  alias=$3
  storepass=$4
  keypass=${5:-}

  keystore_host=$(capath2host "${keystore_ca}")

  cmd=(${CA_ROOT}/ca.sh keytool \
    -importcert \
    -keystore "${keystore_ca}" \
    -file "${file}" \
    -alias "${alias}" \
    -storepass "${storepass}" \
    -noprompt)

  if [[ -n "${keypass}" ]]; then
    cmd+=(-keypass "${keypass}")
  fi

  if ! "${cmd[@]}"; then
    echo "❌ cert ${file} not imported into ${keystore_host}"
    return 1
  fi

  echo "✅ cert ${file} imported into ${keystore_host}"
  return 0
}


function create_csr() {

  keystore=$1
  file=$2
  alias=$3
  storepass=$4
  keypass=$5

  file_host=$(capath2host "${file}")

  if [ -f "${file_host}" ]; then
    echo "⚠️  CSR already exists: ${file_host}"
    return 0
  fi

  ${CA_ROOT}/ca.sh keytool \
    -certreq \
    -keystore "${keystore}" \
    -file "${file}" \
    -alias "${alias}" \
    -storepass "${storepass}" \
    -keypass "${keypass}" \
    -storetype PKCS12

  if [ -f "${file_host}" ]; then
    echo "✅ CSR created: ${file_host}"
  else
    echo "❌ could not create CSR: ${file_host}"
    return 1
  fi

  return 0
}


function sign_csr() {

  csr=$1
  out=$2
  days=$3

  out_host=$(capath2host "${out}")

  if [ -f "${out_host}" ]; then
    echo "⚠️  certificate already exists: ${out_host}"
    return 0
  fi

  ${CA_ROOT}/ca.sh openssl ca \
    -batch \
    -config /etc/ssl/openssl.cnf \
    -policy signing_policy \
    -extensions signing_req \
    -days "${days}" \
    -in "${csr}" \
    -out "${out}"

  if [ ! -f "${out_host}" ]; then
    echo "❌ signed certificate not found after signing CSR: ${out_host}"
    return 1
  fi

  echo "✅ certificate signed: ${out_host}"
  return 0
}


###############################################################################

./docker-compose.yml.sh > docker-compose.yml

truststores=()
common_truststore_filename="/certs/${KAFKA_SSL_TRUSTSTORE_FILENAME}"
common_truststore_filename_host=$(capath2host "${common_truststore_filename}")

common_truststore_password_file="/certs/${KAFKA_SSL_TRUSTSTORE_CREDENTIALS}"
common_truststore_password_file_host=$(capath2host "${common_truststore_password_file}")


# store truststore password in a file
if [ ! -f "${common_truststore_password_file_host}" ]; then
  printf '%s\n' "${KAFKA_SSL_TRUSTSTORE_PASSWORD}" > "${common_truststore_password_file_host}"
else
  echo "⚠️  truststore password file already exists: ${common_truststore_password_file_host}"
fi

# reload passwords from the disk
read -r KAFKA_SSL_TRUSTSTORE_PASSWORD < "${common_truststore_password_file_host}"

# add CARoot cert into the global truststore
import_cert "${common_truststore_filename}" "${cacert_file_ca}" 'CARoot' "${KAFKA_SSL_TRUSTSTORE_PASSWORD}"

# generate keystores for brokers
for i in $(seq "${KAFKA_NUM_BROKERS}"); do

  node_name="${DOCKER_NAMESPACE}${KAFKA_BROKER_PREFIX}${i}"

  echo -e "\n### ${node_name} ###\n"

  secrets_dir="/certs/${node_name}/secrets"
  secrets_dir_host=$(capath2host "${secrets_dir}")
  keystore_file="${secrets_dir}/${KAFKA_SSL_KEYSTORE_FILENAME}"
  keystore_file_host=$(capath2host "${keystore_file}")
  keystore_password_file="${secrets_dir}/${KAFKA_SSL_KEYSTORE_CREDENTIALS}"
  keystore_ssl_key_file="${secrets_dir}/${KAFKA_SSL_KEY_CREDENTIALS}"
  truststore_file="${secrets_dir}/${KAFKA_SSL_TRUSTSTORE_FILENAME}"
  truststore_file_host=$(capath2host "${truststore_file}")
  private_key_csr_file="${secrets_dir}/csr.pem"
  signed_private_key_cert_file="${secrets_dir}/cert.pem"

  # create broker's secrets dir at host to store keystore and truststore
  mkdir -p "${secrets_dir_host}"

  # store keystore password in a file
  if [ ! -f "$(capath2host "${keystore_password_file}")" ]; then
    printf '%s\n' "${KAFKA_SSL_KEYSTORE_PASSWORD}" > "$(capath2host "${keystore_password_file}")"
  else
    echo "⚠️  keystore password file already exists: $(capath2host "${keystore_password_file}")"
  fi

  # store SSL key password in a file
  if [ ! -f "$(capath2host "${keystore_ssl_key_file}")" ]; then
    printf '%s\n' "${KAFKA_SSL_KEY_PASSWORD}" > "$(capath2host "${keystore_ssl_key_file}")"
  else
    echo "⚠️  keystore ssl key file already exists: $(capath2host "${keystore_ssl_key_file}")"
  fi

  # reload passwords from the disk
  read -r KAFKA_SSL_KEYSTORE_PASSWORD < "$(capath2host "${keystore_password_file}")"
  read -r KAFKA_SSL_KEY_PASSWORD < "$(capath2host "${keystore_ssl_key_file}")"

  # create keystore with a private key
  if [ ! -f "${keystore_file_host}" ]; then
    if ${CA_ROOT}/ca.sh keytool \
      -genkeypair \
      -keystore "${keystore_file}" \
      -alias "${node_name}" \
      -validity "${KAFKA_SSL_CERT_VALIDITY_DAYS}" \
      -keyalg RSA \
      -storetype pkcs12 \
      -storepass "${KAFKA_SSL_KEYSTORE_PASSWORD}" \
      -keypass "${KAFKA_SSL_KEY_PASSWORD}" \
      -dname "CN=${node_name}"; then
      echo "✅ keystore created: ${keystore_file_host}"
    else
      echo "❌ keystore creation failed: ${keystore_file_host}"
      continue
    fi
  else
    echo "⚠️  keystore already exists: ${keystore_file_host}"
  fi

  # obtain certificate for the private key
  create_csr "${keystore_file}" "${private_key_csr_file}" "${node_name}" "${KAFKA_SSL_KEYSTORE_PASSWORD}" "${KAFKA_SSL_KEY_PASSWORD}" || continue
  sign_csr "${private_key_csr_file}" "${signed_private_key_cert_file}" "${KAFKA_SSL_CERT_VALIDITY_DAYS}" || continue
  import_cert "${keystore_file}" "${cacert_file_ca}" 'CARoot' "${KAFKA_SSL_KEYSTORE_PASSWORD}" "${KAFKA_SSL_KEY_PASSWORD}" || continue
  import_cert "${keystore_file}" "${signed_private_key_cert_file}" "${node_name}" "${KAFKA_SSL_KEYSTORE_PASSWORD}" "${KAFKA_SSL_KEY_PASSWORD}" || continue
  import_cert "${common_truststore_filename}" "${signed_private_key_cert_file}" "${node_name}" "${KAFKA_SSL_TRUSTSTORE_PASSWORD}" || continue

  # copy common truststore credentials
  mkdir -p "./volumes/${node_name}/secrets"
  cp -v "${common_truststore_password_file_host}" "${secrets_dir_host}"
  truststores+=("${truststore_file_host}")

done

echo "copying truststore to Kafka nodes..."

for truststore in "${truststores[@]-}"; do
  cp -v "${common_truststore_filename_host}" "${truststore}"
done

"${KAFKA_CLIENTS_HOME}/provision.sh"
