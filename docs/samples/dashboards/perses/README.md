# Perses Dashboard Samples

This directory contains Perses dashboard definitions for MaaS observability.

## Dashboards

| Dashboard | Description | File |
|-----------|-------------|------|
| AI Engineer Dashboard | User-focused dashboard showing personal API usage, rate limits, and trends | `ai-engineer-dashboard.yaml` |
| Platform Admin Dashboard | Admin-focused dashboard with system health, all users, and model metrics | `platform-admin-dashboard.yaml` |

## Format

These dashboards are in Perses native YAML format, designed to work with the Perses Operator's `PersesDashboard` CRD.

### Key Differences from Grafana

| Aspect | Grafana | Perses |
|--------|---------|--------|
| Format | JSON | YAML |
| Panel types | `stat`, `timeseries`, `table`, `gauge` | `StatChart`, `TimeSeriesChart`, `Table`, `GaugeChart` |
| Variables | `templating.list[]` | `variables[]` |
| Layout | `gridPos` coordinates | Grid layouts with `$ref` to panels |
| Deployment | `GrafanaDashboard` CRD | `PersesDashboard` CRD |

## Deployment

### Using the Install Script (Recommended)

```bash
# Install Perses with dashboards
./scripts/install-observability.sh --stack perses

# Or install both Grafana and Perses
./scripts/install-observability.sh --stack both
```

### Manual Deployment

```bash
# Apply Perses instance and dashboards
kubectl apply -k deployment/components/observability/perses/
```

## Customization

To customize dashboards:

1. Copy the dashboard file you want to modify
2. Edit the `spec.dashboard.spec.panels` section
3. Apply with `kubectl apply -f your-modified-dashboard.yaml`

## PromQL Queries

Both Grafana and Perses dashboards use the same PromQL queries since they query the same Prometheus backend:

- `authorized_hits{user, tier, model}` - Successful API requests
- `limited_calls{user, tier, model}` - Rate-limited requests
- `istio_requests_total` - Gateway traffic
- `vllm:*` - Model inference metrics

## Related Documentation

- [Perses Documentation](https://perses.dev/)
- [Perses Operator](https://github.com/perses/perses-operator)
- [MaaS Observability Guide](../../content/advanced-administration/observability.md)

