# loki-sql-adaptor

Standalone Go service that exposes a Loki-compatible HTTP API backed by MySQL. Enables existing Perses dashboards (using `LokiDatasource`) to query usage data from SQL instead of Loki.

## Quick Start

### Prerequisites

- Go 1.23+
- MySQL 8.0+ (or MariaDB 10.6+)

### Run locally

```bash
# Start MySQL (example with Docker)
docker run -d --name maas-mysql \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=maas_usage \
  -p 3306:3306 \
  mysql:8.0

# Set connection string
export MYSQL_DSN="root:root@tcp(localhost:3306)/maas_usage?parseTime=true"

# Seed synthetic data
make run-seed

# Start the adaptor
make run
```

### Test

```bash
# Run unit tests (no MySQL required)
make test

# Query the adaptor (example: total tokens in last hour)
curl 'http://localhost:8080/loki/api/v1/query?query=sum(sum_over_time({service_name="maas-gateway"}|unwrap+tokens_total+[$__range]))'

# List available labels
curl 'http://localhost:8080/loki/api/v1/labels'

# Get distinct subscription values
curl 'http://localhost:8080/loki/api/v1/label/subscription/values'
```

### Build

```bash
make build          # builds bin/loki-sql-adaptor
make build-seed     # builds bin/seeddata
make docker-build   # builds container image
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MYSQL_DSN` | Yes | — | MySQL connection string (Go DSN format) |
| `LISTEN_ADDR` | No | `:8080` | HTTP listen address |

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /loki/api/v1/query_range` | Range query (LogQL → SQL, returns matrix/vector) |
| `GET /loki/api/v1/query` | Instant query |
| `GET /loki/api/v1/labels` | List known label names |
| `GET /loki/api/v1/label/:name/values` | List distinct values for a label |
| `GET /health` | Health check |

## Supported LogQL Subset

- Stream selectors: `{key="value", key=~"regex"}`
- Pipeline filters: `| key=~"value" | key!="value"`
- `unwrap <field>`
- `sum_over_time(... [duration])`, `count_over_time(... [duration])`
- `sum(...)`, `sum by (label) (...)`, `count(...)`
- `or vector(0)` suffix (ignored gracefully)
