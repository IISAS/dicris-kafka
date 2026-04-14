# dicris-kafka

Deploys an Apache Kafka 4.0.0 cluster in KRaft mode (no Zookeeper) with mutual TLS (mTLS) authentication, fronted by Traefik for external SNI-based TCP routing.

## Topology

| Role | Count | Ports |
|---|---|---|
| Controllers | 2 | 9092 (CONTROLLER, internal) |
| Brokers | 4 | 9093 (SSL, external via Traefik), 19093 (SSL-INTERNAL, inter-broker) |

Brokers are reachable externally as `<broker-name>.<HOSTNAME>:9093` via Traefik TCP passthrough.

## Prerequisites

- A running CA instance from `../dicris-ca`
- An external Docker network named `reverse_proxy` (Traefik)
- Environment configured in `../.env` — see [Configuration](#configuration)

## Configuration

Environment is loaded in two layers by `envvars.sh` (local first, global overrides):

| File | Scope |
|---|---|
| `../.env` (loaded as `.env-global`) | Project-wide: `DEPLOYMENT_HOME`, `HOSTNAME`, `DOCKER_NAMESPACE`, Traefik settings, `CA_ROOT` |
| `.env` | Kafka-specific: image version, broker/controller counts, ports, SSL credential filenames |

Key variables in `../.env`:

```
DEPLOYMENT_HOME=<absolute path to deployment/>
CA_ROOT=${DEPLOYMENT_HOME}/dicris-ca
```

Key variables in `.env`:

```
KAFKA_NUM_BROKERS=4
KAFKA_NUM_CONTROLLERS=2
KAFKA_PORT_BROKER=9093
KAFKA_PORT_CONTROLLER=9092
KAFKA_SSL_CERT_VALIDITY_DAYS=3650   # optional override
```

## Usage

### Provision

Generates `docker-compose.yml`, creates all broker keystores/truststores via the CA, and provisions clients:

```bash
./provision.sh
```

### Start / Stop

```bash
./cmd.sh --profile kafka up -d          # all controllers and brokers
./cmd.sh --profile kafka-controllers up -d
./cmd.sh --profile kafka-brokers up -d
./cmd.sh down
./cmd.sh ps
./cmd.sh --profile kafka logs -f
```

### Clean

Removes all PKI artifacts (keystores, truststores, CSRs, signed certs) for brokers and clients:

```bash
./clean.sh
```

### Regenerate docker-compose.yml only

```bash
./docker-compose.yml.sh > docker-compose.yml
```

## Clients

Clients are defined in `clients/clients` as CSV (`name,password`):

```
alpha,password
bravo,password
```

Each provisioned client gets a directory `clients/<namespace>client-<name>/` containing:

| File | Purpose |
|---|---|
| `keystore.jks` / `keystore.p12` | Client identity |
| `truststore.jks` | Shared cluster truststore |
| `key.pem` | Private key in PEM format |
| `client.properties` | Ready-to-use Kafka client config |

A per-client helper script `clients/kafka-topics-<name>.sh` is also generated.

### Kafka CLI via Docker

```bash
# List / create / describe topics
clients/kafka-topics-alpha.sh --list
clients/kafka-topics-alpha.sh --create --topic my-topic --partitions 1 --replication-factor 1

# Produce messages
clients/kafka-console-producer.sh clients/dicris-client-alpha --topic my-topic

# Any Kafka bin command
clients/kafka-bin.sh clients/dicris-client-alpha kafka-consumer-groups.sh --list
```

## PKI Layout

All PKI material lives inside the CA directory (`CA_ROOT`). Broker secrets are mounted into containers at `/etc/kafka/secrets` from `CA_ROOT/volumes/certs/<broker-name>/secrets/`.

A shared truststore (`truststore.jks`) contains the CA root certificate and all broker signed certificates. It is distributed to every broker and every client.

Certificate validity defaults to 3650 days and can be overridden via `KAFKA_SSL_CERT_VALIDITY_DAYS` in `.env`.
