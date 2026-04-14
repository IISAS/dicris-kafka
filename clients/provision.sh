#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "${SCRIPT_DIR}" && echo "🛈  CWD: ${PWD}"

. ./envvars.sh

# CA configuration
[ -z "${CA_ROOT}" ] && { echo "❌ CA_ROOT is not set"; exit 1; }
CA_HOME="${CA_ROOT}/volumes/ca"

CLIENTS_HOME="${SCRIPT_DIR}"
KAFKA_HOME="${CLIENTS_HOME}/.."

cacert_file_ca="/ca/cacert.pem"

###############################################################################


function clean_path() {
  path=$1
  echo "$path" | sed 's#//*#/#g'
  return 0
}


function mkdir_chck() {
  dir=$1
  if [ -d "${dir}" ]; then
    echo "⚠️  dir already exists: ${dir}"
  else
    mkdir -p "${dir}"
  fi
}


function capath2host() {
  path="$1"
  echo $(clean_path "${CA_ROOT}/volumes/${path}")
  return 0
}


function create_credentials() {

  filename="$1"
  password="$2"

  if [ -f "${filename}" ]; then
    echo "⚠️  credentials already exist and will be reused: ${filename}"
    return 0
  fi

  printf '%s\n' "${password}" > "${filename}"
  if [ ! -f "${filename}" ]; then
    echo "❌ credentials not created: ${filename}"
    return 1
  fi

  echo "✅ credentials created: ${filename}"
  return 0
}


function create_keystore() {

  keystore_ca="$1"
  alias="$2"
  CN="$3"
  validity=$4
  storepass="$5"
  keypass="${6:-}"

  keystore_host=$(capath2host "${keystore_ca}")

  if [ -f "${keystore_host}" ]; then
    echo "⚠️  keystore already exists (skipping): ${keystore_host}"
    return 0
  fi

  echo "creating keystore: ${keystore_host}"

  cmd=(${CA_ROOT}/ca.sh keytool \
    -genkeypair \
    -keystore "${keystore_ca}" \
    -alias "${alias}" \
    -validity "${validity}" \
    -keyalg RSA \
    -storetype PKCS12 \
    -storepass "${storepass}" \
    -dname "CN=${CN}")

  if [[ -n $keypass ]]; then
    cmd+=(-keypass "$keypass")
  fi

  "${cmd[@]}"

  if [ ! -f "${keystore_host}" ]; then
    echo "❌ keystore not created: ${keystore_host}"
    return 1
  fi

  echo "✅ keystore created: ${keystore_host}"
  return 0
}


function create_csr() {

  keystore_ca="$1"
  file_ca="$2"
  alias="$3"
  storepass="$4"
  keypass="${5:-}"

  keystore_host=$(capath2host "${keystore_ca}")
  file_host=$(capath2host "${file_ca}")

  if [ -f "${file_host}" ]; then
    echo "⚠️  CSR already exists: ${file_host}"
    return 0
  fi

  cmd=(${CA_ROOT}/ca.sh keytool \
    -certreq \
    -keystore "${keystore_ca}" \
    -file "${file_ca}" \
    -alias "${alias}" \
    -storepass "${storepass}" \
    -storetype PKCS12)

  if [[ -n ${keypass} ]]; then
    cmd+=(-keypass "${keypass}")
  fi

  "${cmd[@]}"

  if [ ! -f "${file_host}" ]; then
    echo "❌ could not create CSR: ${file_host}"
    return 1
  fi

  echo "✅ CSR created: ${file_host}"
  return 0
}


function sign_csr() {

  csr_ca="$1"
  out_ca="$2"
  days=$3

  out_host=$(capath2host "${out_ca}")

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
    -in "${csr_ca}" \
    -out "${out_ca}"

  if [ ! -f "${out_host}" ]; then
    echo "❌ signed certificate not found after signing CSR: ${out_host}"
    return 1
  fi

  echo "✅ certificate signed: ${out_host}"
  return 0
}


function generate_client_properties () {

  truststore_location="$1"
  truststore_password="$2"
  keystore_location="$3"
  keystore_password="$4"
  key_password="${5:-}"

  cat <<EOF
security.protocol=SSL
ssl.endpoint.identification.algorithm=
ssl.keystore.location=${keystore_location}
ssl.keystore.password=${keystore_password}
ssl.truststore.location=${truststore_location}
ssl.truststore.password=${truststore_password}
EOF

  if [[ -n "${key_password}" ]]; then
    echo "ssl.key.password=${key_password}"
  fi
}


function import_cert() {

  keystore_ca="$1"
  file_ca="$2"
  alias="$3"
  storepass="$4"
  keypass="${5:-}"

  keystore_host=$(capath2host "${keystore_ca}")
  file_host=$(capath2host "${file_ca}")

  cmd=(${CA_ROOT}/ca.sh keytool \
    -importcert \
    -keystore "${keystore_ca}" \
    -file "${file_ca}" \
    -alias "${alias}" \
    -storepass "${storepass}" \
    -noprompt)

  if [[ -n "${keypass}" ]]; then
    cmd+=(-keypass "${keypass}")
  fi

  if ! "${cmd[@]}"; then
    echo "❌ cert ${file_host} not imported into ${keystore_host}"
    return 1
  fi

  echo "✅ cert ${file_host} imported into ${keystore_host}"
  return 0
}


function provision_client() {

  #
  # Variables *_ca and *_host refer to the same file,
  # but the *_ca is a path inside the CA docker
  # container and *_host is the path at the host.
  #

  client_name_short="$1"
  storepass="$2"
  validity="${3:-${KAFKA_SSL_CERT_VALIDITY_DAYS:-365}}"

  client_name="${DOCKER_NAMESPACE}${KAFKA_CLIENT_PREFIX}${client_name_short}"
  client_dir_host="${CLIENTS_HOME}/${client_name}"

  secrets_dir_ca="/certs/_clients_/${client_name}/secrets"
  secrets_dir_host=$(capath2host "${secrets_dir_ca}")

  # keystore
  keystore_file_ca="${secrets_dir_ca}/keystore.jks"
  keystore_file_host=$(capath2host "${keystore_file_ca}")
  keystore_credentials_ca="${secrets_dir_ca}/keystore_creds"
  keystore_credentials_host=$(capath2host "${keystore_credentials_ca}")

  csr_file_ca="${secrets_dir_ca}/csr.pem"
  signed_cert_file_ca="${secrets_dir_ca}/cert.pem"

  printf "\nprovisioning client: %s\n" "${client_name}"

  mkdir_chck "${client_dir_host}"
  mkdir_chck "${secrets_dir_host}"

  # keystore credentials
  create_credentials "${keystore_credentials_host}" "${storepass}" || return 1
  read -r keystore_password < "${keystore_credentials_host}"

  create_keystore "${keystore_file_ca}" "${client_name}" "${client_name}" "${validity}" "${keystore_password}" &&
  create_csr "${keystore_file_ca}" "${csr_file_ca}" "${client_name}" "${keystore_password}" &&
  sign_csr "${csr_file_ca}" "${signed_cert_file_ca}" "${validity}" &&
  import_cert "${keystore_file_ca}" "${cacert_file_ca}" "CARoot" "${keystore_password}" &&
  import_cert "${keystore_file_ca}" "${signed_cert_file_ca}" "${client_name}" "${keystore_password}" ||
  return 1

  # stage CA cert and shared truststore alongside keystore in secrets dir
  # before the bulk copy so they all land in client_dir_host together
  cp -v "$(clean_path "${CA_HOME}/cacert.pem")" "${secrets_dir_host}/"
  cp -v "$(capath2host "/certs/truststore.p12")" "${secrets_dir_host}/"

  echo "copying certificates to client's dir ..."
  cp -v "${secrets_dir_host}/"* "${client_dir_host}/"

  # copy global JKS truststore and its credentials to the client
  echo "copying global truststore to the client's dir ..."
  cp -v "${truststore_file_host}" "${client_dir_host}/truststore.jks"
  cp -v "${truststore_credentials_host}" "${client_dir_host}/truststore_creds"

  echo "exporting client keystore to PKCS12 for non-JVM clients ..."
  ${CA_ROOT}/ca.sh keytool -importkeystore \
    -srckeystore "${keystore_file_ca}" \
    -srcstoretype PKCS12 \
    -srcstorepass "${keystore_password}" \
    -destkeystore "${secrets_dir_ca}/keystore.p12" \
    -deststoretype PKCS12 \
    -deststorepass "${keystore_password}" \
    -noprompt
  # convert PKCS12 to PEM key
  ${CA_ROOT}/ca.sh openssl pkcs12 \
    -in "${secrets_dir_ca}/keystore.p12" \
    -nocerts \
    -nodes \
    -out "${secrets_dir_ca}/key.pem" \
    -passin pass:"${keystore_password}"
  cp -v "$(clean_path "${secrets_dir_host}/key.pem")" "${client_dir_host}"
  cp -v "$(clean_path "${secrets_dir_host}/keystore.p12")" "${client_dir_host}"

  echo "Generating client.properties ..."
  generate_client_properties \
    "/opt/client/truststore.jks" \
    "${truststore_password}" \
    "/opt/client/keystore.jks" \
    "${keystore_password}" > "${client_dir_host}/client.properties"

  echo "generating scripts for the client ..."
  kafka_topics_sh_filename_host="kafka-topics-${client_name_short}.sh"
  cat <<EOF > ${kafka_topics_sh_filename_host}
#!/usr/bin/env bash
./kafka-topics.sh "${client_dir_host}" \$*
EOF
  chmod +x "${kafka_topics_sh_filename_host}"

  return 0
}


###############################################################################

truststore_file_ca="/certs/truststore.jks"
truststore_file_host=$(clean_path "${CA_ROOT}/volumes/${truststore_file_ca}")
truststore_credentials_ca="/certs/truststore_creds"
truststore_credentials_host=$(clean_path "${CA_ROOT}/volumes/${truststore_credentials_ca}")

[ ! -f "${truststore_credentials_host}" ] && { echo "❌ truststore credentials not found: ${truststore_credentials_host}"; exit 1; }
read -r truststore_password < "${truststore_credentials_host}"

echo "converting truststore from JKS to PKCS12 ..."
${CA_ROOT}/ca.sh keytool -importkeystore \
  -srckeystore "${truststore_file_ca}" \
  -srcstoretype JKS \
  -srcstorepass "${truststore_password}" \
  -destkeystore "/certs/truststore.p12" \
  -deststoretype PKCS12 \
  -deststorepass "${truststore_password}" \
  -noprompt

if [ -p /dev/stdin ]; then
  # Input is coming from a pipe or redirection
  while IFS=',' read -r client storepass; do
    [[ -z "$client" || $client == \#* ]] && continue
    provision_client "$client" "$storepass"
  done

elif [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
  # No stdin, but a file argument is provided
  while IFS=',' read -r client storepass; do
    [[ -z "$client" || $client == \#* ]] && continue
    provision_client "$client" "$storepass"
  done < "$1"

elif [ -f clients ]; then
  # No stdin, not file argument but 'clients' file exists
  while IFS=',' read -r client storepass; do
    [[ -z "$client" || $client == \#* ]] && continue
    provision_client "$client" "$storepass"
  done < clients

else
  echo "Usage: $0 [filename], via pipe or 'clients' file" >&2
  exit 1
fi
