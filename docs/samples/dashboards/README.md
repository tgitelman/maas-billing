# MaaS Dashboards

This directory contains dashboard samples for the MaaS platform, available in both Grafana (JSON) and Perses (YAML) formats.

## Dashboard Files

### Grafana Dashboards (JSON)

| File | Description |
| ---- | ----------- |
| `platform-admin-dashboard.json` | Unified view for platform administrators |
| `ai-engineer-dashboard.json` | API key-filtered view for AI engineers |
| `maas-token-metrics-dashboard.json` | Legacy token metrics dashboard |

### Perses Dashboards (YAML)

| File | Description |
| ---- | ----------- |
| `perses/platform-admin-dashboard.yaml` | Platform admin dashboard for Perses |
| `perses/ai-engineer-dashboard.yaml` | AI engineer dashboard for Perses |

## Documentation Files

| File | Description |
| ---- | ----------- |
| `METRICS-SUMMARY.md` | **Main reference** - Complete metrics documentation, queries, and limitations |
| `METRICS-EXPORT-FLOW.md` | Architecture flow showing how metrics are exported |
| `PROMETHEUS-COUNTER-BEHAVIOR.md` | Educational guide on Prometheus counter behavior |
| `perses/README.md` | Perses-specific documentation and deployment guide |

## Installation

### Automated Deployment (Recommended)

```bash
# Install Grafana dashboards
./scripts/install-observability.sh --stack grafana

# Install Perses dashboards
./scripts/install-observability.sh --stack perses

# Install both
./scripts/install-observability.sh --stack both
```

### Manual Import

**Grafana:**

1. Go to Grafana → Dashboards → Import
2. Upload the desired dashboard JSON file
3. Select Prometheus datasource

**Perses:**

```bash
kubectl apply -f deployment/components/observability/perses/dashboards/ -n openshift-operators
```

## Available Metrics

### Token & Request Metrics (Limitador)

| Metric | Description | Labels |
| ------ | ----------- | ------ |
| `authorized_hits` | **Total tokens consumed** (extracted from `usage.total_tokens` in model responses) | `user`, `tier`, `model` |
| `authorized_calls` | Total requests allowed | `user`, `tier`, `model` |
| `limited_calls` | Total requests rate-limited | `user`, `tier`, `model` |
| `limitador_up` | Limitador health status | `limitador_namespace` |

!!! info "Tokens vs Requests"
    With `TokenRateLimitPolicy`, `authorized_hits` tracks **token consumption**, not request counts. Use `authorized_calls` for request counts.

### Gateway Metrics (Istio)

| Metric | Description | Labels |
| ------ | ----------- | ------ |
| `istio_requests_total` | Total gateway requests | `response_code`, `destination_service_name` |
| `istio_request_duration_milliseconds_bucket` | Request latency histogram | `destination_service_name`, `le` |

### Model Metrics (vLLM/KServe)

| Metric | Description | Labels |
| ------ | ----------- | ------ |
| `vllm:num_requests_running` | Requests currently being processed | `model_name` |
| `vllm:num_requests_waiting` | Requests waiting in queue | `model_name` |
| `vllm:gpu_cache_usage_perc` | GPU KV cache utilization | `model_name` |
| `vllm:e2e_request_latency_seconds` | End-to-end inference latency | `model_name` |

### Kubernetes Metrics

| Metric | Description | Labels |
| ------ | ----------- | ------ |
| `kube_pod_status_phase` | Pod status | `namespace`, `pod`, `phase` |
| `ALERTS` | Prometheus alerts | `alertname`, `alertstate`, `namespace` |

## Common Queries

```promql
# Token consumption per user
sum by (user) (authorized_hits)

# Request count per user
sum by (user) (authorized_calls)

# Top 10 users by tokens consumed
topk(10, sum by (user) (authorized_hits))

# Top 10 users by request count
topk(10, sum by (user) (authorized_calls))

# Token consumption by tier
sum by (tier) (authorized_hits)

# Success rate per tier
sum by (tier) (authorized_calls) / (sum by (tier) (authorized_calls) + sum by (tier) (limited_calls))

# Rate limit violations by tier
sum by (tier) (rate(limited_calls[5m]))

# P95 latency by service (Istio)
histogram_quantile(0.95, sum by (destination_service_name, le) (rate(istio_request_duration_milliseconds_bucket[5m])))

# P99 latency by service
histogram_quantile(0.99, sum by (destination_service_name, le) (rate(istio_request_duration_milliseconds_bucket[5m])))

# Model inference P95 latency (vLLM)
histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le, model_name))

# Unauthorized requests (401)
sum(rate(istio_requests_total{response_code="401"}[5m]))

# Overall error rate (4xx + 5xx)
sum(rate(istio_requests_total{response_code=~"4.."}[5m])) + sum(rate(istio_requests_total{response_code=~"5.."}[5m]))

# Firing alerts in MaaS namespaces
count(ALERTS{alertstate="firing", namespace=~"llm|kuadrant-system|maas-api"})
```

## Dashboard Panels

### Platform Admin Dashboard

**Variables (dropdown selectors):**

- `Datasource` - Prometheus datasource
- `MaaS Namespace` - Filter by namespace (default: All)
- `Model` - Filter model metrics by model name (default: All)

**Sections:**

| Section | Panels |
| ------- | ------ |
| **Component Health** | Limitador status, Authorino status, MaaS API pods, Gateway pods, Firing alerts |
| **Key Metrics** | Total authorized hits, Current rate, Success rate, Active users, P50 latency |
| **Traffic Analysis** | Request rate by model, Overall error rate, Request rate by tier, P95/P99 latency by service, Rate limit violations by tier, Success rate by tier |
| **Top Users** | Top 10 by request hits (`authorized_calls`), Top 10 by token consumption (`authorized_hits`) |
| **Token Consumption** | Token consumption by tier, Token consumption by user |
| **Detailed Breakdown** | Request rate by user, Request volume by user/model/tier |
| **Model Metrics** | Requests running, Requests waiting, GPU cache usage, Total requests, Model queue depth, Model inference latency |
| **User Tracking** | Requests & errors per user (authorized vs rate-limited) |
| **Resource Allocation** | Resource allocation per model table (CPU/Memory requests/limits) |
| **Blocked Features** | Input/Output token breakdown per user (placeholder), Implementation notes |

### AI Engineer Dashboard

**Variables:**

- `User` - Filter by API key / user identifier

**Sections:**

| Section | Panels |
| ------- | ------ |
| **My Usage Summary** | My Total Tokens, Current Rate (5m avg), Rate Limited Requests, My Success Rate |
| **Usage Trends** | Usage by Model, Request Trends (Success vs Rate Limited) |
| **Hourly Usage Patterns** | Hourly Usage by Model |
| **Detailed Analysis** | Request Volume by Model, Rate Limited by Model |
| **Usage Summary** | Usage Summary by Model & Tier |

## Grafana vs Perses

| Aspect | Grafana | Perses |
|--------|---------|--------|
| **Format** | JSON | YAML |
| **Panel types** | `stat`, `timeseries`, `table`, `gauge` | `StatChart`, `TimeSeriesChart`, `Table`, `GaugeChart` |
| **Variables** | `templating.list[]` | `variables[]` |
| **Layout** | `gridPos` coordinates | Grid layouts with `$ref` to panels |
| **Deployment** | `GrafanaDashboard` CRD | `PersesDashboard` CRD |
| **Console Integration** | External route | Built into OpenShift Console |

## Known Limitations

### Working Features

- Per-user, per-model, per-tier filtering
- Token consumption tracking via `authorized_hits`
- Request count tracking via `authorized_calls`
- P50/P95/P99 latency from Istio gateway histograms
- Error tracking (401, 429, 5xx) from Istio + Limitador
- Alert integration (MaaS-filtered firing alerts)
- vLLM/KServe model metrics (queue depth, GPU cache, inference latency)
- Rate limit violation tracking

### Blocked Features

| Feature | Status | Blocker |
|---------|--------|---------|
| **Latency per user** | Blocked | Istio metrics don't include `user` label (requires EnvoyFilter) |
| **Input/Output token breakdown per user** | Blocked | vLLM doesn't label metrics with `user` (requires vLLM changes) |

!!! note "Token Consumption IS Available"
    Total token consumption per user **is available** via `authorized_hits{user="..."}`. The blocked feature is specifically the **input/output token breakdown** (prompt tokens vs generation tokens) per user.

## Related Files

- **TelemetryPolicy**: `deployment/base/observability/telemetry-policy.yaml`
- **ServiceMonitors**: `deployment/components/observability/prometheus/`
- **Grafana Dashboards CRD**: `deployment/components/observability/dashboards/`
- **Perses Dashboards CRD**: `deployment/components/observability/perses/dashboards/`

## Customization

To customize dashboards:

1. Import into Grafana / apply to cluster
2. Edit panels as needed
3. Export updated JSON / YAML
4. Replace files with your custom version
