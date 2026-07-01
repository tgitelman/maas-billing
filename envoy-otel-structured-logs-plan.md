---

name: Envoy OTel Structured Logs
overview: Envoy access logs emitted via OTel Collector to Loki, carrying user_id, subscription, model name, and token counts as structured log records — providing a reliable, independent token accounting channel alongside the existing Limitador-based counters.
todos:

- id: upstream-wasm-shim-tokens
  content: "TODO (deferred): File GitHub issue at kuadrant/wasm-shim requesting set_attribute() for body_values in TokenUsageTask (would eliminate json_to_metadata filter dependency)"
  status: pending
- id: upstream-wasm-shim-429
  content: "TODO (deferred): Request WASM shim to inject model info before rate limit evaluation — currently solved via json_to_metadata INSERT_FIRST (extracts model from request body before rate limiter). Upstream fix would make json_to_metadata request_rules redundant."
  status: pending
- id: upstream-kuadrant-dual-listener
  content: "TODO (deferred): File issue that HTTP+HTTPS listeners cause duplicate ActionSets leading to 403"
  status: pending
- id: pr-envoyfilter
  content: "PR #1035: EnvoyFilter — json_to_metadata + Lua SSE companion (supersedes #1031 Lua). Branch: feature/envoy-otel-log-jsontometa. otel_als_cluster + json_to_metadata + bodyChunks() SSE + X-MaaS headers (user_id, subscription, groups) + FILTER_STATE (key_id, organization_id) + CEL-filtered OTel ALS access log with 11 attributes."
  status: pending
- id: pr-otel-collector
  content: "PR TBD: OTel Collector CR (v1beta1) + RBAC. Branch: feature/otel-collector. Requires Red Hat build of OTel operator. memory_limiter, error_mode:ignore, sending_queue, user_id emission toggle."
  status: pending
- id: pr-dashboards
  content: "PR 5: Dashboard migration (Perses usage dashboards with Loki LogQL, loki-query-proxy for user isolation)"
  status: pending
- id: integrate-configreconcile
  content: "TODO (future): Integrate headers-based-auth-policy Go template configreconcile pipeline into maas-controller — replace manual EnvoyFilter render with controller-managed lifecycle ({{.Name}}, {{.Namespace}}, {{.OTELHost}}, {{.OTELPort}} from Config CR). Currently manually rendered and deployed as static YAML."
  status: pending
isProject: false

---

# Envoy OTel Structured Usage Logs — Implementation Record

## Status: COMPLETE — Full Pipeline Deployed and Verified (2026-06-25)

All core components deployed and verified on clusters `amit.dev.datahub.redhat.com` (ODH) and `ahadas-ahadas-rhoai.dev.datahub.redhat.com` (RHOAI). Pipeline: Envoy → OTel Collector (OpenTelemetryCollector CR) → Loki. Identity via X-MaaS headers + FILTER_STATE (key_id). Verified on both platforms.

**EnvoyFilter** (`maas-model-access-logs`): Native `json_to_metadata` filter + companion Lua SSE filter. Non-streaming: `json_to_metadata` extracts model/tokens from JSON body. Streaming SSE: companion Lua filter uses `bodyChunks()` to iterate chunks without buffering, extracts tokens from the final SSE event. `INSERT_FIRST` for 429 model preservation. CEL filter for inference-only POST logging. `response_type` classification (`hit`/`rate_limit`/`error`). 11 attributes per log record.

**OTel Collector**: `OpenTelemetryCollector` CR (v1beta1) in `opendatahub` namespace via Red Hat build of OpenTelemetry operator. Replaces raw Deployment+ConfigMap+Service. Pipeline: `memory_limiter` → `resource` → `transform` (strip WASM quotes, `error_mode: ignore`) → `transform/redact` → `groupbyattrs` (7 stream labels) → `batch` → Loki (`sending_queue` enabled). `user_id` sensitive data emission disabled by default (toggleable via 2-line comment swap in CR).

**Dashboards**: Two Perses dashboards in `kuadrant-system` using `response_type` stream labels for efficient querying. LokiStack patched for explicit stream label control.

---

## Architecture Before Our Changes

Before this work, the MaaS platform had **no independent audit log** for token consumption. All observability relied on **Limitador counters exposed as Prometheus metrics**. No Loki, no OTel Collector, no structured usage logs.

### Pre-Change Request Flow

```mermaid
flowchart TD
    client(["Client"]) -->|"1: HTTP request\nBearer SA token"| envoy
    subgraph envoyPod ["Envoy Pod - maas-default-gateway"]
        envoy["Envoy Proxy"]
        wasmShim["WASM shim\n(auth + rate limit)"]
        routerPre["Router"]
    end
    subgraph authPre ["Auth"]
        authorinoPre["Authorino"]
    end
    subgraph ratePre ["Rate Limiting"]
        limitadorPre["Limitador"]
    end
    modelPre["Model Server"]

    envoy --> wasmShim
    wasmShim --> authorinoPre
    wasmShim --> limitadorPre
    wasmShim --> routerPre --> modelPre
```

No OTel ALS, no `json_to_metadata`, no OTel Collector, no Loki. Response body consumed by WASM shim for rate limiting only.

### What Was Missing

| Gap | How We Solved It |
| --- | --- |
| No independent audit log | OTel ALS emits a structured log for every request |
| No per-request data | 25 structured attributes per log record in Loki |
| High-cardinality `user` in Prometheus | Per-user data moved to Loki structured metadata |
| Dead `tier` label | Replaced with `subscription` everywhere |
| No token breakdown | `tokens_prompt` and `tokens_completion` extracted by `json_to_metadata` |

---

## Architecture (Final — Verified)

### Complete Request/Response Flow

```mermaid
flowchart TD
    client(["Client"]) -->|"1: HTTP request\nBearer SA token"| envoy
    subgraph envoyPod ["Envoy Pod - maas-default-gateway"]
        envoy["Envoy Proxy"]
        j2m["json_to_metadata\n(request: model\nresponse: tokens + model)"]
        wasmShim["WASM shim\n(auth + rate limit +\nfilter_state identity)"]
        otelALS["OTel ALS + CEL filter\n(inference-only logging)"]
        routerNode["Router"]
    end
    subgraph authBlock ["Auth"]
        authorino["Authorino"]
    end
    subgraph rateBlock ["Rate Limiting"]
        limitador["Limitador"]
    end
    subgraph obsBlock ["Observability Pipeline"]
        otelCollector["OTel Collector CR\n(opendatahub)"]
        loki["LokiStack\n(openshift-logging)"]
    end
    modelServer["Model Server"]

    envoy -->|"2"| j2m
    j2m -->|"3"| wasmShim
    wasmShim -->|"4: auth"| authorino
    wasmShim -->|"5: rate limit"| limitador
    wasmShim -->|"6"| routerNode
    routerNode -->|"7: forward"| modelServer
    modelServer -->|"8: response"| j2m
    otelALS -->|"9: gRPC :4317"| otelCollector
    otelCollector -->|"11: OTLP/HTTP"| loki
```

### OTel Collector Pipeline

```mermaid
flowchart LR
    envoyALS["Envoy OTel ALS"] -->|"gRPC"| otlpRecv["OTLP Receiver :4317"]
    otlpRecv --> memLimiter["memory_limiter\n80% limit, 25% spike"]
    memLimiter --> resourceProc["resource processor\n+service.name/namespace/instance.id"]
    resourceProc --> transformProc["transform\nstrip WASM quotes\n(error_mode: ignore)"]
    transformProc -.->|"optional"| redactProc["transform/redact\ndelete user_id"]
    transformProc --> groupbyProc["groupbyattrs\npromotes: subscription, model,\nresponse_type, method,\nuser_id, key_id, organization_id"]
    redactProc -.-> groupbyProc
    groupbyProc --> batchProc["batch"]
    batchProc --> lokiGw["LokiStack Gateway\n(OTLP/HTTP + TLS + bearer\nsending_queue: 4 consumers)"]
```

### Dual Data Paths

```mermaid
flowchart LR
    subgraph promPath ["Prometheus (aggregate, no user)"]
        limNode["Limitador"] --> promNode["Prometheus"]
    end
    subgraph lokiPath ["Loki (per-request, with user)"]
        otelNode["OTel Collector"] --> lokiNode["Loki"]
    end
```

- **Prometheus**: `authorized_hits`, `authorized_calls`, `limited_calls` with labels `subscription`, `model`, `organization_id`, `cost_center`
- **Loki**: 11 attributes per inference request — `response_code`, `response_type`, `user_id`, `subscription`, `groups`, `key_id`, `organization_id`, `tokens_total`, `tokens_prompt`, `tokens_completion`, `model`

### Data Flow (Step by Step)

1. **Client sends request** with Bearer SA token (or `sk-oai-*` API key)
2. **`json_to_metadata`** (INSERT_FIRST) — `request_rules` extract model from JSON request body (`on_present` only — missing model simply doesn't set metadata, no "unknown" fallback).
3. **WASM shim** calls Authorino (kubernetesTokenReview + subscription-info callout). Stores identity in `filter_state` (userid, keyId, selected_subscription, groups_str). Authorino injects `X-MaaS-*` response headers (Username, Subscription, Group). Access log uses headers for `user_id`/`subscription`/`groups`, FILTER_STATE for `key_id`/`organization_id` (no header equivalent).
4. **WASM shim** evaluates rate limit (Limitador). On 429, sends local reply — `filter_state` is already set (`key_id` available). X-MaaS-* headers available on giteltal/ODH even on 429. Model already extracted from request body.
5. **Request forwarded** to model server (or 429 local reply if rate limited)
6. **Model server responds** — Non-streaming: `json_to_metadata` `response_rules` extract tokens and authoritative model from JSON body. Streaming SSE: `json_to_metadata` fires `on_error` (content-type mismatch, zero buffering), then companion Lua filter iterates `bodyChunks()` to extract tokens from the last SSE event without buffering. On 429, `on_missing` fires but model not overwritten (only `on_present` configured for response model rule).
7. **OTel ALS** fires if CEL filter matches (POST to `/v1/chat/completions` or `/v1/completions`). Emits 11 attributes + 2 resource attributes via gRPC to OTel Collector.
8. **OTel Collector** pipeline: memory_limiter → resource → transform (strip quotes, `error_mode: ignore`) → [optional: transform/redact (delete user_id)] → groupbyattrs (promote 7 keys to resource attributes) → batch → Loki via OTLP/HTTP (sending_queue enabled)

### Perses Dashboard Architecture

Two dashboards in `kuadrant-system` namespace:
- **`usage-admin-loki-dashboard`** — admin view, all users, uses `loki` datasource (direct to LokiStack). Dynamic dropdowns for User, Subscription, Model via `LokiLabelValuesVariable`.
- **`usage-user-loki-dashboard`** — per-user view, uses `scoped-loki` datasource (through loki-query-proxy). Dynamic dropdowns for Subscription, Model.

Two datasources in `kuadrant-system` namespace:
- **`loki`** — direct to LokiStack gateway (SA token auth + kubernetesAuth + TLS)
- **`scoped-loki`** — routes through loki-query-proxy (kubernetesAuth only, no TLS/secret)

**loki-query-proxy** deployed to `kuadrant-system` namespace (default, overridable via kustomize) — Go service that intercepts Loki queries and injects `user_id="<caller>"` filter based on TokenReview of the caller's Kubernetes token.

**Table panel**: Both dashboards have a "Usage breakdown" table with three Loki queries merged via `MergeSeries` transform. All table queries use `[$__range]` (negative offset removed — not supported by this Loki version):
- **Q1**: Tokens per model/subscription — `sum by (model, subscription) (sum_over_time(... | unwrap tokens_total [$__range]))`
- **Q2**: Successful requests per model/subscription — `sum by (model, subscription) (count_over_time(... response_type="hit" ... [$__range]))`
- **Q3**: Rate-limited requests per model/subscription — `sum by (model, subscription) (count_over_time(... response_type="rate_limit" ... [$__range])) or (... response_type="hit" ... * 0)`. The `or (hit * 0)` zero-pads model/subscription pairs with no rate-limited traffic, ensuring Q3 returns the same label sets as Q1/Q2 (required for `MergeSeries` to join correctly — it fails when queries return different numbers of series).

### Deployment Topology

| Namespace | Resources |
|-----------|-----------|
| `kuadrant-system` | loki-query-proxy (deployment, SA, RBAC, service), Perses dashboards (usage-admin-loki-dashboard, usage-user-loki-dashboard), datasources (loki, scoped-loki) |
| `opendatahub` | OpenTelemetryCollector CR `usage-logs` (operator-managed → service `usage-logs-collector`), SA `usage-logs-collector`, ClusterRoleBinding `maas-otel-loki-writer` |
| `openshift-ingress` | EnvoyFilter `maas-model-access-logs` |
| `openshift-logging` | LokiStack `maas-loki` (patched `streamLabels.resourceAttributes`), NetworkPolicy allowing collector from `opendatahub` |
| `openshift-operators` | Red Hat build of OpenTelemetry operator (Subscription `opentelemetry-product`) |

---

## Design Decisions

| Decision | Rationale |
| --- | --- |
| `json_to_metadata` + Lua SSE companion | Native Envoy filter for JSON responses — replaced Lua after ahadas review (PR #1031). Companion Lua filter handles SSE via `bodyChunks()` (zero-buffering chunk iteration). `on_present` only for model prevents "unknown" log pollution. See "Why json_to_metadata replaced Lua" section below. |
| CEL filter (inference-only) | Only `/v1/chat/completions` and `/v1/completions` logged. POST only. Eliminates noise from `/v1/models`, health checks, etc. |
| `response_type` via CEL | `hit`/`rate_limit`/`error` — low cardinality stream label for Loki. Exact `response_code` still available as structured metadata. All dashboard stat/table queries use `response_type` for filtering (e.g. "Total Successful Requests" counts only `response_type="hit"`, not all requests). |
| Identity: X-MaaS-* headers + FILTER_STATE | `user_id`, `subscription`, `groups` use `X-MaaS-*` request headers (Authorino-injected). `key_id` and `organization_id` use FILTER_STATE (no header equivalent). Headers available on 200; `-` on 429 (rate limiter fires before Authorino). FILTER_STATE survives 429. |
| EnvoyFilter (not Istio Telemetry CR) | Telemetry API lacks custom OTel attributes; `ConfigMap/istio` owned by ingress-operator |
| `sed` placeholders (not `envsubst`) | Kustomize can't target YAML-in-YAML |
| OpenTelemetryCollector CR (not raw Deployment) | Upstream alignment with Red Hat build of OTel operator. Operator manages Deployment, Service, health probes, config volume. Replaces raw ConfigMap+Deployment+Service. Requires `opentelemetry-product` operator from OperatorHub. |
| `memory_limiter` first in pipeline | OTel Collector best practice — prevents OOM under burst. 80% limit, 25% spike limit, 5s check interval. |
| `error_mode: ignore` on transform | Malformed attributes (missing field, wrong type) silently skip the statement instead of dropping the entire log record. |
| `sending_queue` on exporter | Decouples collection from export. 4 consumers, 500-item queue. Prevents backpressure from Loki slowdowns from blocking the receiver. |
| `user_id` emission toggle (off by default) | `user_id` sensitive data emission disabled by default — deleted before Loki via `transform/redact`. To enable, uncomment `delete_key` in `transform/redact` and `user_id` in `groupbyattrs.keys` (2-line toggle). Dashboard queries use `customAllValue: ".*"` so `user_id=~".*"` matches entries with or without user_id. Only `user_id` is considered sensitive; `groups` is not. |
| Red Hat OTel Collector image | `ghcr.io` inaccessible from cluster; pinned Red Hat SHA |
| LokiStack bearer token auth | Gateway requires HTTPS + bearer (not `X-Scope-OrgID` + HTTP) |

### Loki Stream Labels vs Structured Metadata (Verified 2026-06-22)

Controlled by LokiStack `spec.limits.global.otlp.streamLabels.resourceAttributes` + OTel Collector `groupbyattrs` processor. Verified via Loki `/series` endpoint.

| Field | Loki Placement | Source |
| --- | --- | --- |
| `service_name` | **Stream label** | Resource attribute (static) |
| `subscription` | **Stream label** | `groupbyattrs` promoted |
| `model` | **Stream label** | `groupbyattrs` promoted |
| `response_type` | **Stream label** | `groupbyattrs` promoted |
| `method` | **Stream label** | `groupbyattrs` promoted |
| `user_id` | **Stream label** | `groupbyattrs` promoted |
| `key_id` | **Stream label** | `groupbyattrs` promoted |
| `organization_id` | **Stream label** | `groupbyattrs` promoted |
| `kubernetes_namespace_name` | **Stream label** | OpenShift default |
| `log_type` | **Stream label** | OpenShift default |
| `response_code` | Structured metadata | Log attribute (not in `groupbyattrs`) |
| `tokens_total`, `tokens_prompt`, `tokens_completion` | Structured metadata | Log attribute |
| `groups` | Structured metadata | Log attribute |

> **10 stream labels** (low cardinality, indexed) — enables `{response_type="rate_limit"}` as a stream selector.
> **Structured metadata** queryable via pipeline filters: `| response_code="200"`, `| json | tokens_total > 100`.
> **Dropped** (per ahadas review #1031): `request_id`, `method`, `path`, `duration_ms`, `downstream_remote_address` — operational data not needed for usage logging.

---

## Known Issue: Perses Datasource Prefix Name Collision

The monitoring-console-plugin uses prefix matching on datasource names (`OcpDatasourceApi.getDatasource()` → `list[0]`). If scoped datasource starts with `loki`, it collides with the admin datasource.

**Solution**: Scoped datasource named `scoped-loki` (not `loki-scoped`). Both require `kubernetesAuth: true`.

---

## Implementation Details

### Files Modified/Created

| File | Change |
| --- | --- |
| `deployment/components/observability/otel-collector/envoy-otel-access-log.yaml` | EnvoyFilter `maas-model-access-logs`: OTel ALS cluster + `json_to_metadata` + Lua SSE companion (`bodyChunks()`) + CEL-filtered access log (11 attributes). |
| `deployment/components/observability/otel-collector/envoy-otel-access-log-lua.yaml` | **Archived** — all-Lua implementation (2 Lua filters: `capture_model` + `extract_tokens` with SSE `bodyChunks()` support). Kept for reference. |
| `deployment/components/observability/otel-collector/otel-collector-cr.yaml` | `OpenTelemetryCollector` CR (v1beta1) — replaces raw Deployment+ConfigMap+Service. Pipeline: `memory_limiter` → `resource` → `transform` → `groupbyattrs` → `batch` → Loki. Includes `transform/redact` (toggleable user_id removal), `sending_queue`, `error_mode: ignore`. Requires Red Hat build of OTel operator. |
| `deployment/components/observability/otel-collector/otel-collector-rbac.yaml` | SA `usage-logs-collector` + ClusterRole + ClusterRoleBinding for Loki write access (namespace: `opendatahub`) |
| `deployment/components/observability/otel-collector/kustomization.yaml` | Kustomization: otel-collector-rbac.yaml + otel-collector-cr.yaml + envoy-otel-access-log.yaml |
| `deployment/components/observability/loki-proxy/` | Loki query proxy (Go source ConfigMap, deployment, RBAC, service) — PR #999 |
| `deployment/components/observability/observability/dashboards/` | Perses dashboards (usage-admin, usage-user), datasources (loki, scoped-loki), kustomization — PRs #995, #988 |
| `deployment/base/observability/telemetry-policy.yaml` | TelemetryPolicy (subscription, model, organization_id, cost_center) |
| `scripts/observability/install-observability.sh` | OTel Collector deploy: kustomize build + sed substitution |

### EnvoyFilter: `maas-model-access-logs` (Final — json_to_metadata)

Four patches applied to `maas-default-gateway` via `targetRefs`:

**Patch 1 — OTel ALS Cluster**: STRICT_DNS cluster to `usage-logs-collector.opendatahub.svc.cluster.local:4317` (gRPC/H2, 5s connect timeout).

**Patch 2 — `json_to_metadata` (INSERT_FIRST)**: Native Envoy filter replacing both Lua filters. Single filter handles both request and response:
- `request_rules`: extracts `model` from JSON request body. `on_present` only — if body has no model field or parsing fails, metadata is simply not set (no "unknown" fallback). INSERT_FIRST position ensures model extraction before rate limiter can short-circuit with 429.
- `response_rules`: extracts `usage.{total_tokens, prompt_tokens, completion_tokens}` with `"0"` fallback (`on_missing`/`on_error`). Extracts authoritative `model` from response (`on_present` only — overwrites request-extracted model on 200 JSON; on SSE/429 the request model stays untouched).
- **SSE pass-through**: Content-Type `text/event-stream` doesn't match `allow_content_types` (default: `application/json`), so response_rules fire `on_error` immediately — zero body buffering, tokens default to "0". The companion Lua SSE filter (Patch 3) then overwrites these with real token values.
- **429 handling**: Error JSON body lacks usage/model, so `on_missing` fires. Tokens default to "0". Response model rule has `on_present` only, so request-extracted model is preserved.

**Patch 3 — Lua SSE Token Extraction (INSERT_BEFORE router)**: Companion to `json_to_metadata` for streaming SSE responses. Request phase sets `is_completions` flag on inference paths. Response phase:
- Returns early for non-inference requests (no `is_completions` flag) and non-SSE responses (handled by `json_to_metadata`).
- For `text/event-stream`: iterates `bodyChunks()` — Envoy Lua API that yields response chunks as they arrive without buffering. Each chunk scanned for `usage.{total_tokens, prompt_tokens, completion_tokens}` and `model`; last-seen values win (token info is in the final SSE event).
- `pcall` wraps the loop for crash safety. No `break` in the `bodyChunks()` loop (Envoy constraint — loop must complete naturally).
- Writes extracted values to dynamic metadata, overwriting `json_to_metadata`'s "0" defaults.
- Future: `sse_to_metadata` (Envoy 1.38+, not yet in OSSM) will replace this Lua filter with a native filter.

**Patch 4 — OTel Access Log + CEL Filter**: CEL expression restricts logging to POST requests on inference paths. 11 structured attributes:

| Attribute | Source | Category |
| --- | --- | --- |
| `response_code` | `%RESPONSE_CODE%` | Response |
| `response_type` | `%CEL(response.code >= 200 && response.code < 300 ? "hit" : (response.code == 429 ? "rate_limit" : "error"))%` | Response |
| `user_id` | `%REQ(X-MaaS-Username)%` | Identity |
| `subscription` | `%REQ(X-MaaS-Subscription)%` | Identity |
| `groups` | `%REQ(X-MaaS-Group)%` | Identity |
| `key_id` | `%FILTER_STATE(wasm.kuadrant.auth.identity.keyId:PLAIN)%` | Identity |
| `organization_id` | `%FILTER_STATE(wasm.kuadrant.auth.identity.organizationId:PLAIN)%` | Identity |
| `tokens_total` | `%DYNAMIC_METADATA(envoy.filters.http.json_to_metadata:tokens_total)%` | Usage |
| `tokens_prompt` | `%DYNAMIC_METADATA(envoy.filters.http.json_to_metadata:tokens_prompt)%` | Usage |
| `tokens_completion` | `%DYNAMIC_METADATA(envoy.filters.http.json_to_metadata:tokens_completion)%` | Usage |
| `model` | `%DYNAMIC_METADATA(envoy.filters.http.json_to_metadata:model)%` | Usage |

Resource attributes: `service.name=maas-gateway`, `service.namespace=openshift-ingress`.

**Attributes intentionally excluded** (present in original POC or Lua version, removed per ahadas review #1031):
- `request_id`, `method`, `path`, `duration_ms`, `downstream_remote_address` — operational data, not needed for usage dashboards.
- `authority`, `upstream_cluster`, `bytes_received`, `bytes_sent`, `response_code_details`, `route_name` — Envoy operational data, not useful for billing/usage.
- `subscription_labels`, `cost_center`, `auth_error`, `auth_error_msg` — not populated by current upstream AuthPolicy. Can be re-added when upstream supports them.

### OTel Collector Configuration

Deployed as `OpenTelemetryCollector` CR (`v1beta1`) named `usage-logs` via Red Hat build of OpenTelemetry operator. The operator manages Deployment, Service (`usage-logs-collector`, convention: `<cr-name>-collector`), health probes, and config volume automatically.

**Prerequisite**: Red Hat build of OpenTelemetry operator installed via OperatorHub (`opentelemetry-product` Subscription in `openshift-operators`).

```yaml
processors:
  memory_limiter:
    check_interval: 5s
    limit_percentage: 80
    spike_limit_percentage: 25
  resource:
    attributes:
    - { action: insert, key: log_type, value: application }
    - { action: upsert, key: service.name, value: maas-gateway }
    - { action: upsert, key: service.namespace, value: openshift-ingress }
    - { action: upsert, key: kubernetes_namespace_name, value: openshift-ingress }
    - { action: upsert, key: service.instance.id, value: "${env:POD_NAME}" }
  transform:
    error_mode: ignore
    log_statements:
    - context: log
      statements:
      - replace_pattern(attributes["user_id"], "^\"(.*)\"$$", "$$1")
      - replace_pattern(attributes["subscription"], "^\"(.*)\"$$", "$$1")
      - replace_pattern(attributes["key_id"], "^\"(.*)\"$$", "$$1")
      - replace_pattern(attributes["groups"], "^\"(.*)\"$$", "$$1")
      - replace_pattern(attributes["organization_id"], "^\"(.*)\"$$", "$$1")
  transform/redact:
    error_mode: ignore
    log_statements:
    - context: log
      statements:
      - delete_key(attributes, "user_id")
  groupbyattrs:
    keys: [subscription, model, response_type, method, user_id, key_id, organization_id]
  batch:
    timeout: 5s
    send_batch_size: 100
    send_batch_max_size: 200
exporters:
  otlphttp/loki:
    sending_queue:
      enabled: true
      num_consumers: 4
      queue_size: 500
```

**Key configuration points**:
- `memory_limiter` is FIRST in the pipeline — OTel Collector best practice to prevent OOM under burst traffic.
- `error_mode: ignore` on `transform` processors — malformed attributes silently skip the statement instead of dropping the entire log record.
- `transform` strips double-quotes from 5 identity attributes (WASM shim wraps some values in quotes).
- `user_id` emission (**disabled by default**) — `transform/redact` deletes `user_id` from log attributes before Loki. To enable emission, uncomment `delete_key` in `transform/redact` and `user_id` in `groupbyattrs.keys` (2-line toggle in CR). Dashboard variables use `customAllValue: ".*"` so `user_id=~".*"` matches all entries regardless of whether `user_id` is present — admin "All" returns correct totals.
- `groupbyattrs` promotes 7 keys from log attributes to resource attributes — these become Loki stream labels (controlled by LokiStack `streamLabels.resourceAttributes`).
- `response_type` (not `response_code`) is a stream label — low cardinality (`hit`/`rate_limit`/`error`), enables efficient Loki filtering.
- `sending_queue` decouples collection from export — Loki slowdowns don't backpressure the receiver.
- Loki endpoint via `sed` placeholder at deploy time.
- CR named `usage-logs` deployed in `opendatahub` namespace. Operator generates service named `usage-logs-collector` (convention: `<cr-name>-collector`).

### Final Envoy Filter Chain

```
[0]  envoy.filters.http.json_to_metadata        (INSERT_FIRST — model from request, tokens+model from JSON response)
[1]  istio.metadata_exchange
[2]  envoy.filters.http.ext_proc.bbr-pre
[3]  kuadrant-maas-default-gateway               (WASM shim — auth + rate limit + filter_state)
[4]  envoy.filters.http.ext_proc.bbr
[5]  envoy.filters.http.grpc_stats
[6]  istio.alpn
[7]  envoy.filters.http.fault
[8]  envoy.filters.http.cors
[9]  istio.stats
[10] envoy.filters.http.lua.sse_tokens           (INSERT_BEFORE router — SSE bodyChunks() token extraction)
[11] envoy.filters.http.router
```

Access log: `envoy.access_loggers.open_telemetry` with CEL filter on NETWORK_FILTER (runs after response, emits to gRPC asynchronously).

---

## Limitations

1. **SSE streaming tokens**: Handled by companion Lua filter using `bodyChunks()` API. Response filters run in reverse chain order: Lua SSE (later in chain) processes the response FIRST and writes real token values, then `json_to_metadata` (first in chain) processes the response LAST. Without `preserve_existing_metadata_value: true` on `on_error`/`on_missing`, `json_to_metadata` would overwrite the Lua-extracted tokens with "0". The `preserve_existing_metadata_value` flag ensures Lua-set values survive. Stream passes through untouched to the client. Model preserved from request body. Requires `stream_options: {"include_usage": true}` on the client request for the model server to emit usage in the final SSE chunk (`llm-d-inference-sim` v0.8.2+ supports this). Future: `sse_to_metadata` (Envoy 1.38+, not yet in OSSM) will replace the Lua companion with a native filter. **Note**: If the model server does not emit `usage` in the final SSE chunk, tokens will remain "0" — this is a model server behavior, not a filter limitation.
2. **429 lack `tokens`**: Rate limiting happens before backend response → `tokens_*` = "0". Model name IS available (from request body via `json_to_metadata` INSERT_FIRST — runs before rate limiter). `response_type="rate_limit"` stream label enables dashboard filtering.
3. **`organization_id` not yet populated**: AuthPolicy `response.success.filters.identity.json.properties` does not include `organizationId`. WASM shim only populates FILTER_STATE keys defined in the identity filter. Requires adding `organizationId` expression to `maasauthpolicy_controller.go`. Pre-wired in EnvoyFilter; will auto-populate when controller is updated.
4. **Dual-listener 403**: HTTP+HTTPS listeners → duplicate ActionSets. Workaround: remove HTTP listener.
5. **Perses Table queries**: Table queries use `[$__range]` without `offset`. Negative offset (`offset -$__range`) was removed — not supported by the deployed Loki version (requires Loki 3.0+). Stat panels work correctly with `[$__range]` + `calculation: last` (takes the last step).
6. **Success rate definition inconsistency** (TODO): Three dashboards define "Success Rate" differently:
   - **Perses Prometheus** (`usage-dashboard.yaml`): `authorized_calls / (authorized_calls + limited_calls)` — 429s count as failures. Upstream `main` has the same formula.
   - **Loki admin/user** (`usage-admin-loki-dashboard.yaml`, `usage-user-loki-dashboard.yaml`): `count(hit) / count(all)` — 429s count as failures. Consistent with upstream Perses.
   - **Grafana** (`dashboard-platform-admin.yaml`): `vllm:request_success_total / vllm:e2e_request_latency_seconds_count` — 429s **excluded** (never reach model). Description: "Rate-limited requests (429) are excluded — they never reach the model and are tracked separately."
   
   **Analysis**: These measure two different things. `authorized / total` = "what % of requests got through" (authorization/throughput rate). `model_success / model_total` = "is the model healthy" (inference success rate). Rate limiting is policy enforcement, not failure — 429 means the system is working correctly. Proposal: rename current panel to "Authorization Rate" and add separate "Inference Success Rate" excluding 429s. Or at minimum, update the description to clarify that 429s are included.

---

## Loki Query Proxy

### Architecture

```
Admin: Dashboard → loki datasource → LokiStack Gateway (direct, SA token)
User:  Dashboard → scoped-loki datasource → loki-query-proxy → LokiStack Gateway
                                                    ↓
                                             TokenReview API
                                             (extract username + groups)
                                                    ↓
                                             LogQL rewrite:
                                             inject | user_id="<caller>"
```

### Design: Why Query Proxy (not LokiStack static mode)

| Aspect | Query Proxy (chosen) | Static Mode (rejected) |
| --- | --- | --- |
| User isolation | Enforced by proxy | Storage-level (Loki-native) |
| Admin cluster-wide | Works (admin bypass) | Blocked (can't aggregate tenants) |
| Operational cost | Low (1 deployment) | High (400 tenant defs + OIDC secrets) |
| LokiStack changes | None | Mode change + per-user tenant blocks |
| Scalability | Unlimited users | CR becomes massive |

### Implementation

Go source (~160 lines, stdlib only) mounted as ConfigMap, run with `go run` on stock `ubi9/go-toolset:1.25`. 5 files in `deployment/components/observability/loki-proxy/` (PR #999).

**Key behaviors**: TokenReview-based auth (no JWT parsing), admin bypass for `system:cluster-admins`/`system:masters`, quote-aware LogQL rewriter, GET only, `allowedPaths` whitelist (includes label/series endpoints for COO 1.5+), hardened security context, JSON error responses.

31/31 tests pass: 15 functional, 9 security, 4 rewriter robustness, 3 admin edge cases.

---

## Verified Test Results

### json_to_metadata + SSE companion via OTel Collector CR (2026-06-24, previous)

- **200 non-streaming (`hit`)**: 11 attributes populated — `model=test/e2e-distinct-model` (from response body, authoritative), `tokens_total=38`, `tokens_prompt=8`, `tokens_completion=30`, `response_type=hit`. Data flows through CR-managed collector (`usage-logs-collector` in `opendatahub`) to Loki.
- **200 streaming SSE (`hit`)**: `model=test/e2e-distinct-model-2`, `tokens_total=76`, `tokens_prompt=8`, `tokens_completion=68` — extracted by Lua SSE companion from final SSE chunk (requires `stream_options.include_usage=true`). `preserve_existing_metadata_value: true` prevents `json_to_metadata` from overwriting Lua-set values. Stream passed through untouched.
- **429 rate-limited (`rate_limit`)**: `model=test/e2e-distinct-model` (from request body — INSERT_FIRST runs before rate limiter). `tokens_total=0`, `tokens_prompt=0`, `tokens_completion=0`. On ODH: `user_id=kube:admin` (CEL FILTER_STATE), `key_id` populated. `subscription`/`groups` = `-` (X-MaaS headers not available on 429). On RHOAI: all identity fields `-` (platform limitation).

### X-MaaS headers + FILTER_STATE (2026-07-01, current)

Identity extraction aligned with ahadas cluster: `user_id`, `subscription`, `groups` from X-MaaS-* headers (Authorino-injected). `key_id` from `%FILTER_STATE(wasm.kuadrant.auth.identity.keyId:PLAIN)%`. `organization_id` from `%FILTER_STATE(wasm.kuadrant.auth.identity.organizationId:PLAIN)%` (not yet populated — AuthPolicy missing `organizationId` property).

- **200 non-streaming (`hit`)**: `user_id=kube:admin`, `subscription=simulator-subscription`, `key_id=<uuid>` (API key), `groups=JSON array`. Tokens extracted.
- **200 streaming SSE (`hit`)**: Same identity. Tokens extracted by Lua SSE companion (`tokens_total=9`).
- **429 rate-limited (`rate_limit`)**: `user_id=kube:admin` (header still available on ODH/giteltal), `subscription=simulator-subscription`, `key_id=<uuid>`. Tokens `0`.
- **`key_id` fix**: ahadas had typo `wasm.auth.identity.keyId` (missing `kuadrant.` prefix) — never worked. Fixed to `wasm.kuadrant.auth.identity.keyId`, verified on both ahadas and giteltal.
- **`organization_id`**: Shows `-`. AuthPolicy `response.success.filters.identity.json.properties` does not include `organizationId`. Requires controller change to populate.
- **Both models**: `test/e2e-distinct-model` and `test/e2e-distinct-model-2` — both correctly extracted and visible in Loki.
- **No "unknown" entries**: Zero "unknown" model entries in Loki. `on_present` only for model prevents log pollution.
- **Non-inference** (`/v1/models`, health checks, GET requests): **NOT logged** — CEL filter restricts to POST on `/v1/chat/completions` and `/v1/completions` only.
- **OTel Collector CR**: 2 replicas running, `memory_limiter` active (512Mi limit, 80% threshold), `sending_queue` enabled (4 consumers). Logs successfully exported to Loki via OTLP/HTTP with bearer token auth and TLS.

### json_to_metadata without SSE companion (2026-06-23, previous)

- **200 non-streaming (`hit`)**: 11 attributes populated — `model=test/e2e-distinct-model` (from response body, authoritative), `tokens_total=61`, `response_type=hit`
- **200 streaming SSE (`hit`)**: `model=test/e2e-distinct-model` (from request body, preserved — response model rule has `on_present` only). `tokens_total=0` (expected — `json_to_metadata` can't parse SSE). Stream passed through untouched, zero buffering.
- **429 rate-limited (`rate_limit`)**: `model=test/e2e-distinct-model` (from request body — INSERT_FIRST runs before rate limiter). `tokens_total=0`. On ODH: `user_id` populated via FILTER_STATE; `subscription`/`groups` = `-` (X-MaaS headers not available on 429, before FILTER_STATE switch).
- **No "unknown" entries**: Zero "unknown" model entries in Loki after fix. Previous "unknown" entries were caused by `on_missing`/`on_error` fallback values — removed by using `on_present` only.
- **Non-inference** (`/v1/models`, health checks, GET requests): **NOT logged** — CEL filter restricts to POST on `/v1/chat/completions` and `/v1/completions` only.

### Lua (2026-06-24, re-verified on cluster)

- **200 non-streaming (`hit`)**: Tokens extracted correctly — `model=test/e2e-distinct-model`, `tokens_total=45`, `tokens_prompt=10`, `tokens_completion=35`.
- **200 SSE streaming with `include_usage` (`hit`)**: Tokens extracted via `bodyChunks()` — `model=test/e2e-distinct-model-2`, `tokens_total=76`, `tokens_prompt=8`, `tokens_completion=68`. No `preserve_existing_metadata_value` issue (no `json_to_metadata` filter to overwrite).
- **200 SSE streaming without `include_usage` (`hit`)**: `tokens_total=0` (expected — model emits `usage:null`).
- **429 rate-limited (`rate_limit`)**: `model=test/e2e-distinct-model` (from request body). `tokens_*=-` (Lua doesn't set fallback "0"). `response_type=rate_limit`.
- **400/404 errors (`error`)**: `model=unknown` — **Bug confirmed**: Lua `capture_model` falls back to `"unknown"` on parse failure, polluting Loki with `model="unknown"` stream label. 3 `unknown` entries found.
- **GET request logged**: CEL filter lacks `request.method == 'POST'` check — GET on completions path is logged (405 response logged as `error`).
- **Token dash values**: Rate-limited entries show `tokens_*=-` (not `"0"`), which breaks `unwrap tokens_total` in LogQL (not a number → silent data loss).

**Bugs confirmed in Lua (all fixed in json_to_metadata)**:
1. `model="unknown"` pollution (3 entries)
2. `tokens_*=-` instead of `"0"` on 429 (breaks `unwrap`)
3. Missing POST check in CEL (GET requests logged)
4. Extra attributes still present (5 attributes ahadas asked to remove)
5. `config-usage` label still present

---

## LogQL Query Patterns

**Total tokens per user (stream selector on `response_type`):**
```logql
sum by (user_id) (sum_over_time({service_name="maas-gateway", response_type="hit"} | unwrap tokens_total [$__range]))
```

**Requests per user:**
```logql
sum by (user_id) (count_over_time({service_name="maas-gateway", response_type="hit"} [$__range]))
```

**Rate-limited count (stream selector — no pipeline filter needed):**
```logql
sum by (model, subscription) (count_over_time({service_name="maas-gateway", response_type="rate_limit"} [$__range]))
```

**Filter by exact response code (structured metadata pipeline filter):**
```logql
{service_name="maas-gateway"} | response_code="500"
```

Stat panels use `[$__range]` + `calculation: last`. Table queries use `[$__range]` (negative offset removed — not supported by deployed Loki). Table Q3 (rate-limited) uses `or (hit * 0)` zero-padding to ensure MergeSeries can join all queries. All stat panels include `model=~"$model"` filter (model is available on all entries including 429s via Lua `capture_model`). Fallbacks: `or vector(0)` on count stats, `or vector(1)` on Success Rate (no traffic = no failures = 100% correct by vacuous truth; `vector(0)` would falsely suggest outage during idle periods). Variables use `LokiLabelValuesVariable` (COO 1.5+). `response_type` as stream label enables fast index-level filtering for hit vs rate_limit vs error.

---

## Deployment Procedure (Current)

```bash
# 0. Prerequisites: Red Hat build of OpenTelemetry operator
#    Install via OperatorHub: Subscription "opentelemetry-product" in openshift-operators
#    Verify: oc get crd opentelemetrycollectors.opentelemetry.io

# 1. Deploy OTel Collector CR + RBAC + EnvoyFilter
#    (resolve LOKI_OTLP_ENDPOINT_PLACEHOLDER and LOKI_TLS_INSECURE_SKIP_VERIFY_PLACEHOLDER
#     in otel-collector-cr.yaml before applying)
kubectl apply -k deployment/components/observability/otel-collector/

# 2. Deploy loki-query-proxy (Go compiles on first start, ~60-90s)
kubectl apply -k deployment/components/observability/loki-proxy/
kubectl rollout status deployment/loki-query-proxy-user -n kuadrant-system --timeout=180s

# 3. Deploy Perses dashboards + datasources
kubectl apply -k deployment/components/observability/observability/dashboards/

# 4. Verify NetworkPolicy allows collector → Loki gateway
#    The Loki gateway NetworkPolicy in openshift-logging must allow ingress from
#    opendatahub namespace, pod label app.kubernetes.io/name=usage-logs-collector
```

Proxy deploys to `kuadrant-system` by default. OTel Collector CR `usage-logs` generates service `usage-logs-collector` in `opendatahub` namespace — EnvoyFilter's cluster endpoint must match.

---

## Review and PR Strategy

### PRs (upstream `opendatahub-io/models-as-a-service`)

| PR | Branch | Status | Scope | Files | Dependencies |
| --- | --- | --- | --- | --- | --- |
| [#1035](https://github.com/opendatahub-io/models-as-a-service/pull/1035) EnvoyFilter | `feature/envoy-otel-log-jsontometa` | Open (draft) | `json_to_metadata` + companion Lua SSE filter. X-MaaS headers for `user_id`/`subscription`/`groups`, FILTER_STATE for `key_id`/`organization_id`. `on_present` only for model. INSERT_FIRST for 429 model preservation. 11 attributes. | 1 file, 345 lines | OTel Collector deployed on port 4317 |
| [#1032](https://github.com/opendatahub-io/models-as-a-service/pull/1032) OTel Collector CR | `feature/otel-collector` | Open (draft) | `OpenTelemetryCollector` CR (v1beta1) + RBAC. Pipeline: `memory_limiter` → `resource` → `transform` (strip WASM quotes, `error_mode: ignore`) → `transform/redact` (user_id emission toggle) → `groupbyattrs` (7 stream labels, user_id togglable) → `batch` → Loki (`sending_queue`). | 2 files (CR + RBAC) | EnvoyFilter PR. OTel operator installed. LokiStack with streamLabels configured. |
| [#999](https://github.com/opendatahub-io/models-as-a-service/pull/999) Loki Query Proxy | `feature/loki-user-proxy` | Open | Go proxy: ConfigMap source, deployment, RBAC, service, kustomization. AllowedPaths includes label/series endpoints. `LOKI_UPSTREAM_URL` uses `__LOKI_GATEWAY_SVC__` sed placeholder. | 5 files, 672 lines | None (standalone) |
| [#995](https://github.com/opendatahub-io/models-as-a-service/pull/995) Admin Dashboard | `feature-loki-admin-dashboard` | Open | Admin usage dashboard + `loki` datasource (direct to LokiStack). `LokiLabelValuesVariable` (COO 1.5+). `customAllValue: ".*"` for absent-label matching. `response_type` stream labels. | 3 files | LokiStack + OTel pipeline deployed. Loki infra provisioned by opendatahub-operator. |
| [#988](https://github.com/opendatahub-io/models-as-a-service/pull/988) User Dashboard | `feature/loki-user-dashboard` | **Closed** | User-scoped dashboard + `scoped-loki` datasource (through proxy). `LokiLabelValuesVariable`. `customAllValue: ".*"`. | 3 files | Proxy PR (#999). |
| [#1031](https://github.com/opendatahub-io/models-as-a-service/pull/1031) EnvoyFilter (Lua) | `feature/envoy-otel-access-log-filter` | **Closed** | Superseded by #1035 (json_to_metadata). Original Lua-only implementation. | — | — |

**Merge order**: EnvoyFilter → OTel Collector → Proxy (#999) → Admin Dashboard (#995) → User Dashboard (#988).

**Note**: Admin Dashboard and Proxy are independent (no code dependency), but User Dashboard requires Proxy (datasource URL points to proxy service). All three dashboard/proxy PRs require the OTel pipeline to be deployed for Loki data to exist.

### PR #995 Review — Round 1 Resolved, Round 2 Resolved (2026-06-22)

**Round 1 (resolved)**: 6 comments addressed — Loki infra files (CA, RBAC, secret) removed from MaaS PRs → platform-level resources for `opendatahub-operator`. Datasource URL fixed (`openshift-logging`), moved to `dashboards/`. Variables upgraded to `LokiLabelValuesVariable` (COO 1.5+).

**Round 2 (resolved — ahadas + CodeRabbit, 2026-06-22)**:

| # | Source | Comment | Resolution |
| --- | --- | --- | --- |
| 1 | ahadas | Datasource display name `"Loki (Admin)"` → `"Usage"` | **Fixed.** Display name changed to `"Usage"`. |
| 2 | ahadas | Datasource URL namespace `openshift-logging` → `opendatahub` | **Fixed.** URL now `__LOKI_GATEWAY_SVC__.opendatahub.svc.cluster.local`. |
| 3 | ahadas | Dashboard description "MaaS API usage" → "model usage" | **Fixed.** Both admin and user dashboards updated. |
| 4 | ahadas + CodeRabbit | Missing `model=~"$model"` in stat panels | **Fixed.** Added to totalRequests, totalRateLimited, successRate (numerator + denominator), activeUsers. CodeRabbit's claim that 429s lack model label is incorrect — `json_to_metadata` INSERT_FIRST extracts model from request body before rate limiting. |
| 5 | CodeRabbit | `or vector(1)` → `or vector(0)` in success rate | **Kept `or vector(1)`.** Fallback fires only with zero traffic. No requests = no failures = 100% is correct (vacuous truth). `vector(0)` would show 0% during idle periods, falsely suggesting outage. Actual outages produce failing requests → division returns sub-1.0 value → fallback never fires. |

### PR Description Updates (2026-06-22)

PR descriptions for #995 and #988 were updated to reflect current behavior. Previously stale references corrected:
- ~~`label_format model="N/A (rate limited)"`~~ → removed; model IS available on 429s (from request body via `json_to_metadata` INSERT_FIRST)
- ~~`response_code="429"` pipeline filter~~ → replaced with `response_type="rate_limit"` stream label
- Added: `customAllValue: ".*"` for absent-label matching. Removed `offset -$__range` (unsupported by Loki version)
- Added: zero-padding `or (hit * 0)` pattern in Q3
- ~~"Total Requests"~~ → now "Total Successful Requests" filtering `response_type="hit"`
- #988 dependency on #995 corrected — Loki infra removed from #995, provisioned by opendatahub-operator

---

## Loki Query Proxy — POC Limitations

| # | Limitation | Production path |
| --- | --- | --- |
| A | `go run` on every pod start (~60-90s cold start) | Init container pre-compile or proper image build |
| B | Full response buffering (`io.ReadAll`) | Fine for dashboard queries. Fix: `io.Copy` streaming for `/tail` |
| C | SA token read from disk per request | No real impact (tmpfs). Production: cache with fsnotify |

---

## Remaining / Deferred Work

1. **~~429 model label~~**: **Resolved.** Model name IS available on 429 responses — Lua `capture_model` extracts it from the request body before rate limiting. No `label_format` workaround needed. Rate-limited requests are queried via `response_type="rate_limit"` stream label with full `sum by (model, subscription)` grouping.
2. **Upstream WASM shim — token counts**: `set_attribute()` for `body_values` would eliminate `json_to_metadata` (~5-line PR). Not blocking.
3. **Upstream Kuadrant — dual-listener**: File bug for HTTP+HTTPS duplicate ActionSets → 403.
4. **~~POC cluster namespace~~**: **Resolved.** Datasource URL namespace changed from `openshift-logging` to `opendatahub` per ahadas review. YAML convention targets `opendatahub` namespace.
5. **Loki infra in opendatahub-operator**: CA ConfigMap, ClusterRoleBinding, SA token Secret removed from MaaS PRs — platform-level resources for operator to provision.
6. **~~CR API version~~**: **Resolved.** CRs migrated to `perses.dev/v1alpha2` (`spec.config.*` structure). Both dashboard and datasource CRs updated.
7. **`PersesGlobalDatasource`**: Available in `v1alpha2`. Deploy `loki` and `scoped-loki` as global datasources so dashboards in any namespace can reference them without duplicating datasource CRs per namespace.

---

## Why json_to_metadata Replaced Lua (2026-06-23)

ahadas's review on PR #1031 asked: "why using Lua here and not json_to_metadata as we did before?" This triggered a deep investigation into whether `json_to_metadata` could fully replace the Lua filters.

### Investigation findings

| Concern | Lua | json_to_metadata | Verdict |
| --- | --- | --- | --- |
| Request body model extraction | `pcall(cjson.decode)` | `request_rules` with `selectors: [{key: model}]` | json_to_metadata simpler |
| Response body token extraction | `pcall(cjson.decode)` + manual field traversal | `response_rules` with nested selectors `[{key: usage}, {key: total_tokens}]` | json_to_metadata simpler |
| SSE streaming | Explicit `content-type` check, skip body | Content-type mismatch → immediate `on_error`, zero buffering | json_to_metadata handles it natively |
| 429 model preservation | Request-body model set before rate limiter (INSERT_FIRST) | Same — INSERT_FIRST runs before rate limiter | Equivalent |
| "unknown" fallback risk | `pcall` returns "unknown" on failure | `on_present` only — no metadata set on failure | json_to_metadata cleaner (no log pollution) |
| Performance | Lua sandbox overhead on every request | Native C++ filter | json_to_metadata faster |
| Code complexity | 2 Lua filters, ~80 lines each | 1 filter, ~50 lines YAML | json_to_metadata simpler |

### Lua bugs found during review

**Bug 1 — "unknown" model pollution**: Lua `capture_model` defaults to `"unknown"` on three paths: no body, regex miss, `pcall` failure. This writes `model="unknown"` to dynamic metadata, which Loki indexes as a real stream label value. Causes spurious "unknown" entries in dashboards. `json_to_metadata` uses `on_present` only — no metadata set on failure, access log outputs `"-"` (standard Envoy convention for missing metadata).

**Bug 2 — SSE tokens are `"-"` not `"0"`**: Lua `extract_tokens` returns early on `text/event-stream` without setting any token metadata. Access log outputs `"-"` for `tokens_total`. Dashboard queries using `unwrap tokens_total` fail on `"-"` (not a number) → **silent data loss**. `json_to_metadata` explicitly sets `"0"` via `on_error`, so `unwrap` works correctly.

**Bug 3 — Missing POST check in CEL filter**: Lua version's CEL expression only checks path (`request.path.endsWith`), not method. A `GET /v1/completions` (monitoring probe, browser) would be logged with empty body → model="unknown", tokens="-". `json_to_metadata` version adds `request.method == 'POST'` to the CEL expression.

### Lua regex fragility

Lua parses JSON with regex (`string.match(raw, '"model"%s*:%s*"([^"]+)"')`). Edge cases that break:
- Model name with escaped quotes: `"model": "meta/llama-3\"beta"` → regex captures `meta/llama-3\` (truncated)
- Unicode escapes: `"model": "meta\u002fllama"` → regex captures literal escape (wrong)
- Key shadowing: if `"model"` appears in a nested string before the real model field, regex matches the wrong value
- `json_to_metadata` uses Envoy's native JSON parser (nlohmann/json) — handles all edge cases correctly.

### Body buffering scope tradeoff

**Lua advantage**: `capture_model` checks the request path first and returns early for non-inference paths. Only inference requests have their body buffered.

**json_to_metadata**: `request_rules` apply to ALL `application/json` requests through the gateway (model discovery, API key creation, etc.). All get their body buffered and parsed.

**Practical impact**: Negligible. Non-inference traffic on the MaaS gateway is tiny (occasional model listing, key management). The extra parsing of small JSON payloads adds no measurable overhead. Not worth the complexity of two Lua filters and three bugs.

### ahadas review compliance

| ahadas comment (#1031) | json_to_metadata | Lua |
| --- | --- | --- |
| Rename to `maas-model-access-logs` | Done | Done |
| Drop `config-usage` label | Done | Not done |
| Collector → `usage-logs-collector.opendatahub` | Done | Not done |
| Drop `request_id`, `method`, `path`, `duration_ms`, `downstream_remote_address` | Done (all 5) | Not done (all 5 still present) |
| Add POST check to CEL | Done | Not done |
| "why Lua not json_to_metadata?" | Answered — switched | N/A |

Score: json_to_metadata 11/11, Lua 2/11.

### SSE deep dive

Token usage IS present in the last SSE chunk (`data: {"usage": {...}}`), but `json_to_metadata` checks the response `Content-Type` header first. `text/event-stream` doesn't match `allow_content_types` (default: `application/json`), so `on_error` fires immediately without reading the body. Adding `text/event-stream` to `allow_content_types` would cause the filter to buffer the entire SSE stream (breaking real-time delivery) and then fail JSON parsing anyway (SSE is `data: {...}\n\n`, not valid JSON).

**Current solution**: Companion Lua filter (`envoy.filters.http.lua.sse_tokens`) positioned `INSERT_BEFORE router`. Uses `bodyChunks()` — Envoy's Lua API for non-buffering response body iteration. Each chunk is scanned for `usage.{total_tokens, prompt_tokens, completion_tokens}` and `model`; last-seen values win (token info is in the final SSE event). The stream passes through to the client untouched. `pcall` wraps the loop for crash safety. No `break` in the loop (Envoy constraint — `bodyChunks()` must complete naturally).

**Future**: `sse_to_metadata` (Envoy 1.38+, not yet in OSSM) understands SSE framing natively and can extract from the last event. `json_to_metadata` and `sse_to_metadata` complement each other — `json_to_metadata` skips `text/event-stream`, `sse_to_metadata` only processes `text/event-stream`. Zero conflict. When available, the Lua SSE companion filter will be replaced.

### Envoy version compatibility

| OSSM Version | Istio | Envoy | `json_to_metadata` | `sse_to_metadata` |
| --- | --- | --- | --- | --- |
| 2.6 | 1.20 | ~1.28 | Available | No |
| 3.0 | 1.24 | ~1.32 | Available | No |
| Future (12-18mo) | — | 1.38+ | Available | Available |

---

## RHOAI Cluster Assessment (2026-06-25)

### Cluster: `ahadas-ahadas-rhoai.dev.datahub.redhat.com`

| Component | Version / Detail |
| --- | --- |
| Platform | OpenShift AI Self-Managed **3.5.0-ea.2** |
| OpenShift | **4.21.18** (k8s 1.34.8) |
| OSSM | Red Hat OpenShift Service Mesh **3.3.4** |
| RHCL (Kuadrant) | **1.3.4** (Authorino 1.3.1, Limitador 1.3.1) |
| OTel Operator | Red Hat build of OpenTelemetry **0.152.0-1** |
| Loki | **Not deployed** (no LokiStack CRD, no Loki pods) |

### Deployed MaaS resources

| Resource | Namespace | Name | Notes |
| --- | --- | --- | --- |
| MaaSModelRef | `llm` | `arik` (Ready) | `facebook/opt-125m` model, single endpoint |
| MaaSSubscription | `models-as-a-service` | `facebook-opt-125m-cpu-subscription` (Active) | 100 tokens/min |
| MaaSAuthPolicy | `models-as-a-service` | `facebook-opt-125m-cpu-access` (Active) | `system:authenticated` |
| Gateway | `openshift-ingress` | `maas-default-gateway` | + `data-science-gateway` (RHOAI) |
| WasmPlugin | `openshift-ingress` | `kuadrant-maas-default-gateway` | Kuadrant WASM plugin present |

### EnvoyFilters on cluster (openshift-ingress)

| Name | Purpose |
| --- | --- |
| `data-science-authn-filter` | RHOAI connectivity operator — `ext_authz` to `kube-auth-proxy` + Lua for OAuth/OIDC token handling |
| `kuadrant-auth-maas-default-gateway` | Kuadrant auth WASM plugin cluster definition |
| `kuadrant-ratelimiting-maas-default-gateway` | Kuadrant rate limiting |
| `maas-default-gateway-authn-ssl` | Authorino gRPC cluster for MaaS gateway |
| `maas-model-access-logs` | **Our EnvoyFilter** — `json_to_metadata` + OTel ALS (deployed for testing) |
| `payload-processing` | MaaS `ext_proc` for request/response body processing |
| `ipp-disable` | Disables IPP (inference processing plugin) |

### OTel Collector on RHOAI

| CR Name | Namespace | Mode | Exporter | Notes |
| --- | --- | --- | --- | --- |
| `user-usage` | `redhat-ods-monitoring` | Deployment (1 replica) | **`debug` only** (stdout) | No Loki exporter — logs go to stdout only |
| `data-science-collector` | `redhat-ods-monitoring` | StatefulSet (2 replicas) | — | General RHOAI telemetry (not MaaS usage) |

Collector pipeline: `resource` → `batch` → `groupbyattrs` (only `response_code`) → `debug`.
Service endpoint: `user-usage-collector.redhat-ods-monitoring.svc.cluster.local:4317`.

### Identity field extraction — ODH vs RHOAI gap

**Critical finding**: The `FILTER_STATE(wasm.kuadrant.auth.identity.*)` keys that our EnvoyFilter uses for identity extraction return `-` on RHOAI. The `X-MaaS-*` request headers (injected by Authorino) work on both platforms.

Verified from RHOAI collector logs (2026-06-25):

| Field | Source | ODH (amit) | RHOAI (ahadas) |
| --- | --- | --- | --- |
| `user_id` | `%FILTER_STATE(wasm.kuadrant.auth.identity.userid:PLAIN)%` | `kube:admin` | `-` |
| `user_id` | `%REQ(X-MaaS-Username)%` | Available (not used) | `tgitelma@redhat.com` |
| `key_id` | `%FILTER_STATE(wasm.kuadrant.auth.identity.keyId:PLAIN)%` | Works | `-` |
| `subscription` | `%FILTER_STATE(wasm.kuadrant.auth.identity.selected_subscription:PLAIN)%` | Works | Not tested (likely `-`) |
| `groups` | `%FILTER_STATE(wasm.kuadrant.auth.identity.groups_str:PLAIN)%` | Works | Not tested (likely `-`) |
| `organization_id` | `%FILTER_STATE(wasm.kuadrant.auth.identity.organizationId:PLAIN)%` | Works | Not tested (likely `-`) |

**Root cause**: RHOAI 3.5.0-ea.2 with RHCL 1.3.4 does not populate the Kuadrant WASM `filter_state` identity keys the same way as ODH with Kuadrant 1.4.2+. Both platforms have the same AuthConfig `filters.identity` and `X-MaaS-*` response header definitions in the controller code, but the WASM plugin behavior differs.

**Available X-MaaS-* headers** (confirmed in AuthConfig on both ODH and RHOAI):

| Header | Available | Covers field |
| --- | --- | --- |
| `X-MaaS-Username` | Yes (both) | `user_id` |
| `X-MaaS-Subscription` | Yes (both) | `subscription` |
| `X-MaaS-Group` | Yes (both) | `groups` (JSON array, not comma-separated) |
| `X-MaaS-Key-Id` | **No header** | `key_id` — only via `filters.identity` |
| `X-MaaS-OrganizationId` | **No header** | `organization_id` — only via `filters.identity` |

**What works on both platforms unchanged**: `json_to_metadata` (model/tokens), Lua SSE companion, CEL filter, `response_type` classification, OTel ALS structure, FILTER_STATE identity extraction.

### Implemented solution: X-MaaS headers + FILTER_STATE (2026-07-01)

**Aligned with ahadas cluster deployment.** Per-field best source based on header availability:

| Field | Source | ODH 200 | ODH 429 |
| --- | --- | --- | --- |
| `user_id` | `%REQ(X-MaaS-Username)%` | works | works (on giteltal ODH) |
| `subscription` | `%REQ(X-MaaS-Subscription)%` | works | works (on giteltal ODH) |
| `groups` | `%REQ(X-MaaS-Group)%` | works | works (on giteltal ODH) |
| `key_id` | `%FILTER_STATE(wasm.kuadrant.auth.identity.keyId:PLAIN)%` | works | works |
| `organization_id` | `%FILTER_STATE(wasm.kuadrant.auth.identity.organizationId:PLAIN)%` | `-` (not in AuthPolicy) | `-` |

**`key_id` prefix fix**: ahadas originally had `wasm.auth.identity.keyId` (missing `kuadrant.`). Tested with API key → `-`. Patched to `wasm.kuadrant.auth.identity.keyId` → emitted correctly on both clusters.

**`organization_id` blocker**: The AuthPolicy's `response.success.filters.identity.json.properties` does not include an `organizationId` expression. The WASM shim only populates FILTER_STATE keys that are defined in the AuthPolicy identity filter. Adding `organizationId` requires a change to `maasauthpolicy_controller.go`.

**No OTel Collector changes required** — headers and FILTER_STATE values handled directly by EnvoyFilter.

---

### Tested scenarios (cluster verification 2026-06-24, CR + SSE companion + user_id emission toggle)

| Scenario | Model | Tokens | Response Type | Verified in Loki |
| --- | --- | --- | --- | --- |
| Non-streaming 200 | `test/e2e-distinct-model` (from response, authoritative) | `38` (total=38, prompt=8, completion=30) | `hit` | Yes |
| Non-streaming 200 (model 2) | `test/e2e-distinct-model-2` (from response) | Extracted | `hit` | Yes |
| **Streaming SSE 200** | `test/e2e-distinct-model-2` (from SSE chunks) | `76` (total=76, prompt=8, completion=68) | `hit` | Yes |
| 429 rate-limited | `test/e2e-distinct-model` (from request, preserved) | `0` (all three) | `rate_limit` | Yes |
| 500 error | `test/e2e-distinct-model` | `0` | `error` | Yes |
| No "unknown" entries | All entries have real model names | — | — | Yes |
| OTel Collector CR | Data flows through `usage-logs-collector` (opendatahub) | — | — | Yes |
| memory_limiter active | 512Mi limit, 80% threshold, 25% spike | — | — | Yes (collector logs) |
| user_id emission disabled | `user_id` absent from new entries (transform/redact) | — | — | Yes |
| `user_id=~".*"` (All) | Returns ALL entries including those without user_id | — | — | Yes |
| `user_id=~"kube:admin"` | Returns only entries with user_id present | — | — | Yes |
| `customAllValue: ".*"` | Perses "All" dropdown uses `.*` not pipe-joined values | — | — | Yes (dashboard fix) |

### Tested scenarios (cluster verification 2026-06-23, json_to_metadata only)

| Scenario | Model | Tokens | Response Type | Verified in Loki |
| --- | --- | --- | --- | --- |
| Non-streaming 200 | `test/e2e-distinct-model` (from response, authoritative) | `61` (extracted) | `hit` | Yes |
| Streaming SSE 200 | `test/e2e-distinct-model` (from request, preserved) | `0` (expected) | `hit` | Yes |
| 429 rate-limited | `test/e2e-distinct-model` (from request, preserved) | `0` (expected) | `rate_limit` | Yes |
| 401 unauthorized | `test/e2e-distinct-model` (from request) | `0` | `error` | Yes |
| No "unknown" entries | All new entries have real model names | — | — | Yes |

### Tested scenarios (cluster verification 2026-06-24, Lua filter)

| Scenario | Model | Tokens | Response Type | Verified in Loki |
| --- | --- | --- | --- | --- |
| Non-streaming 200 | `test/e2e-distinct-model` | `45` (total=45, prompt=10, completion=35) | `hit` | Yes |
| **Streaming SSE 200 (include_usage)** | `test/e2e-distinct-model-2` | `76` (total=76, prompt=8, completion=68) | `hit` | Yes |
| Streaming SSE 200 (no include_usage) | `test/e2e-distinct-model` | `0` | `hit` | Yes |
| 429 rate-limited | `test/e2e-distinct-model` | `-` (**BUG**: not `"0"`, breaks `unwrap`) | `rate_limit` | Yes |
| 400 malformed body | `unknown` (**BUG**: model="unknown" pollution) | `0` | `error` | Yes |
| 404 missing model | `unknown` (**BUG**: model="unknown" pollution) | `0` | `error` | Yes |
| GET request logged | `unknown` (**BUG**: no POST check in CEL) | `-` | `error` | Yes |
| **"unknown" model entries** | **3 entries** (vs 0 in json_to_metadata) | — | — | **BUG confirmed** |

### Files

| File | Status |
| --- | --- |
| `envoy-otel-access-log.yaml` | **Current** — json_to_metadata implementation |
| `envoy-otel-access-log-lua.yaml` | **Archived** — previous Lua implementation, kept for reference |

---

## Hybrid Filter Alignment Record (2026-06-22)

The final `maas-model-access-logs` EnvoyFilter consolidates the original POC (`envoy-otel-access-log-poc-filter-state.yaml`, now deleted) with the `headers-based-auth-policy` branch into a single production-ready filter.

### Key Decisions in Consolidation

| Decision | What changed | Why |
| --- | --- | --- |
| ~~Lua replaces `json_to_metadata`~~ **Reversed (2026-06-23)** | ~~Switched from C++ native filter to Lua~~ → **Switched back to `json_to_metadata`** after ahadas review. See "Why json_to_metadata Replaced Lua" section. | Native filter is simpler, faster, and avoids "unknown" fallback pollution. Lua version archived as `envoy-otel-access-log-lua.yaml`. |
| CEL filter added | Log only `/v1/chat/completions` and `/v1/completions` | Eliminates `/v1/models`, health check, and other non-inference noise |
| `response_type` via CEL | `hit`/`rate_limit`/`error` computed from response code | Low-cardinality stream label replaces `response_code` for Loki filtering |
| Streaming detection | Lua checks `content-type: text/event-stream` before body buffering | Prevents SSE response corruption; tokens report "0" (accepted trade-off) |
| Attribute reduction (25 → 16) | Removed `authority`, `upstream_cluster`, `bytes_*`, `response_code_details`, `route_name`, `subscription_labels`, `cost_center`, `auth_error`, `auth_error_msg` | Operational attributes not useful for usage logging; identity attributes not populated by upstream |
| `groupbyattrs` updated | `response_code` → `response_type` | Reduces stream cardinality; enables `{response_type="rate_limit"}` as stream selector |
| LokiStack patched | `streamLabels.resourceAttributes` updated | Explicit control over which attributes become stream labels vs structured metadata |

### Files After Consolidation

| File | Status |
| --- | --- |
| `envoy-otel-access-log.yaml` | **Current** — `json_to_metadata` implementation (2026-06-23) |
| `envoy-otel-access-log-lua.yaml` | **Archived** — Lua implementation (2026-06-22), kept for reference |
| `envoy-otel-access-log-poc-filter-state.yaml` | **Deleted** — original POC, no longer needed |

---

## Security Review

### POC observability security (this work)

- **No secrets logged**: `Authorization` header never captured in access logs. `sk-oai-*` API keys never appear in logs. Only `key_id` (database UUID) is logged.
- **Identity source**: All identity attributes read from `FILTER_STATE(wasm.kuadrant.auth.identity.*)` — internal Envoy state that never touches the wire. Not spoofable by clients. Not affected by PR #912's header changes.
- **Header spoofing**: AuthPolicy SET semantics prevent spoofing of `X-MaaS-*` headers. Filter_state not spoofable.
- **OTel Collector**: NetworkPolicy restricts ingress to gateway pods only.
- **Response body trust**: Pre-existing boundary — both WASM shim and json_to_metadata trust same source.
- **Loki access**: Write via SA with `create` on `loki.grafana.com/application`. Read via separate SA.
- **Proxy**: TokenReview API only (no JWT parsing). Hardened container. Gateway-level OPA/RBAC.
- **API key flow**: `sk-oai-*` keys used directly for inference (`Authorization: Bearer sk-oai-*`), configurable expiration. Authorino extracts `keyId` (UUID) → logged. Key itself never logged.

### Platform security state post-PR #912 (upstream)

> **Status as of 2026-06-21**: PR #912 merged 2026-06-11. Two defense-in-depth controls removed. No exit-path stripping mechanism exists.

- **`Authorization` header reaches model backends**: `sk-oai-*` API keys and OpenShift tokens are forwarded to model backends in cleartext. Previously stripped to empty by per-model AuthPolicies. Removed because `FilterModelsByAccess` in maas-api needs the original header for model discovery probes. No alternative stripping mechanism (ext_proc, Lua, Envoy config) exists in the current codebase.
- **Identity headers reach model backends**: `X-MaaS-Username`, `X-MaaS-Group`, `X-MaaS-Tenant`, `X-MaaS-Subscription` are injected by the gateway AuthPolicy and flow to all upstream workloads. Previously deliberately excluded from model routes (defense-in-depth). No Envoy filter or ext_proc strips them on the exit path.
- **Stale documentation**: `README.md` still claims Kuadrant 1.4.2+ is required for "authorization header stripping capability" — the capability is no longer used.
- **Stale test comment**: `TestHeaderSpoofing` comment claims AuthPolicy "strips identity headers before forwarding to the model backend" — test only validates Authorino SET semantics, not actual stripping.
- **`headers-based-auth-policy` branch comparison**: The `bro-adm` fork's approach uses Lua to strip `X-MaaS-Username`, `X-MaaS-Group`, `X-MaaS-Key-Id` before upstream, but does NOT strip `X-MaaS-Subscription`. Our POC avoids the problem entirely by never putting identity on the wire (filter_state only).

---

## Upstream AuthPolicy Security Regression (PR #912, merged 2026-06-11)

### Summary

[PR #912](https://github.com/opendatahub-io/models-as-a-service/pull/912) (`feat: move auth-policy to gateway level for multi-tenancy`, author: ishitasequeira, approved by: jland-redhat) moved authentication from per-model HTTPRoute-scoped AuthPolicies to a single Gateway-scoped AuthPolicy. This architectural change removed two security controls that were previously in place.

### What was removed

**1. Authorization header stripping — REMOVED**

Before PR #912, each per-model AuthPolicy explicitly stripped the `Authorization` header to prevent credential exfiltration to model backends:

```go
// Strip Authorization header to prevent token exfiltration to model backends
// Both API keys and OpenShift tokens are validated by Authorino, but should
// not be forwarded to model services to prevent credential theft
"Authorization": map[string]any{
    "plain": map[string]any{ "value": "" },
    "key":   "authorization",
},
```

This was removed in PR #912. The new test explicitly asserts it must NOT be stripped:

```go
if _, exists := headers["Authorization"]; exists {
    t.Errorf("Authorization header should NOT be stripped (needed by FilterModelsByAccess)")
}
```

The stated reason: `maas-api` calls `FilterModelsByAccess()` (`maas-api/internal/models/discovery.go`), which probes each model's `/v1/models` endpoint using the caller's original `Authorization` header to determine access. A single gateway-level AuthPolicy cannot selectively strip the header for model routes while preserving it for maas-api routes.

**2. Identity headers to model backends — RE-ADDED**

Before PR #912, identity headers were deliberately kept off the wire for model routes (defense-in-depth):

```go
// Identity headers intentionally removed for defense-in-depth:
// User identity, groups, and key IDs are not forwarded to upstream model workloads
// to prevent accidental disclosure in logs or dumps. All identity information remains
// available to TRLP and telemetry via auth.identity and filters.identity below.
// Exception: X-MaaS-Subscription is injected for Istio Telemetry.
```

PR #912 reversed this. The gateway AuthPolicy now injects `X-MaaS-Username`, `X-MaaS-Group`, `X-MaaS-Tenant`, and `X-MaaS-Subscription` as response headers. Since the per-model AuthPolicies (now lightweight, `require-group-membership` only) do not override the response section, these headers flow through to ALL upstream workloads — including model backends.

The test was renamed from `TestMaaSAuthPolicyReconciler_NoIdentityHeadersUpstream` to `TestMaaSAuthPolicyReconciler_IdentityHeadersUpstream`, reversing the assertion.

### Before vs After

| Security control | Before PR #912 (per-model AuthPolicy) | After PR #912 (gateway AuthPolicy) |
| --- | --- | --- |
| `Authorization` header | Stripped to empty (prevents credential exfiltration) | **Not stripped** — `sk-oai-*` API keys and OpenShift tokens reach model backends |
| `X-MaaS-Username` | NOT injected to model backends | **Injected** — flows to model backends |
| `X-MaaS-Group` | NOT injected to model backends | **Injected** — flows to model backends |
| `X-MaaS-Subscription` | Injected (needed for Istio Telemetry) | Injected (unchanged) |
| `X-MaaS-Tenant` | Did not exist | **Injected** — flows to model backends |
| Identity via `filters.identity` | Available (internal filter_state) | Available (unchanged) |

### Why it happened

The move to a single gateway AuthPolicy creates an architectural constraint: response headers set at the Gateway level apply to ALL routes (maas-api + model backends). The old per-model AuthPolicies could selectively strip/inject per route.

`FilterModelsByAccess` in maas-api needs the original `Authorization` header to probe model endpoints. With a single gateway policy, stripping it would break model listing. The PR chose to keep credentials flowing rather than break functionality.

### PR description disclosure

The PR description does NOT mention:
- Removal of `Authorization` header stripping
- Re-addition of identity headers to model backends
- Reversal of the defense-in-depth decision
- The `FilterModelsByAccess` dependency as the reason

The description frames the response headers as a new feature: "Response header injection — sets X-MaaS-Subscription, userId, username, groups". The `README.md` still states Kuadrant 1.4.2+ is required for "authorization header stripping capability" — but the capability is no longer being used.

### No exit-path stripping exists

Verified: there is **no mechanism** (ext_proc, Envoy config, Istio, Lua filter) that strips `Authorization` or `X-MaaS-*` headers before they reach model backends. Checked:

| Component | What it does with headers | Strips identity/auth? |
| --- | --- | --- |
| Authorino (AuthPolicy) | Overwrites client-injected headers with real values (SET semantics) | No — sets real values, doesn't remove them |
| ext_proc pre-processing (Stage 1) | Extracts model from request body → sets `X-Gateway-Model-Name` | No |
| ext_proc post-processing (Stage 2) | Model resolution, API key injection (`apikey-injection` plugin) | No evidence of stripping (source in separate repo/image) |
| EnvoyFilter `envoy-filter.yaml` | `request_header_mode: "SEND"` — sends headers TO ext_proc | No |

The only possible exit-path stripping is in the `apikey-injection` ext_proc plugin (which replaces `Authorization` with provider credentials for `ExternalModel` backends) — but that's a separate image whose source isn't in this repo, and it only applies to `ExternalModel` routes with `credentialRef`.

### What model backends receive post-PR #912

After PR #912, model backends receive all of the following on every request:

| Header | Content | Risk |
| --- | --- | --- |
| `Authorization` | `Bearer sk-oai-*` (API key) or OpenShift token — **the actual credential** | Credential exfiltration if backend is compromised |
| `X-MaaS-Username` | Real username (set by Authorino) | Identity disclosure |
| `X-MaaS-Group` | Real groups as JSON array (set by Authorino) | Group membership disclosure |
| `X-MaaS-Subscription` | Subscription name (set by Authorino) | Subscription info disclosure |
| `X-MaaS-Tenant` | Tenant name (set by Authorino) | Tenant info disclosure |

### Stale E2E test comment

The `TestHeaderSpoofing` test comment (line 69-70 of `maasauthpolicy_controller_test.go`) says:

> "The AuthPolicy is configured to strip identity headers (X-MaaS-Username, X-MaaS-Group, X-MaaS-Key-Id) before forwarding to the model backend."

This comment describes the **pre-PR #912 behavior** and is stale. The test itself only validates that Authorino's SET semantics overwrite attacker-injected values — it does **not** verify that headers are removed before reaching the model backend. The test proves spoofing doesn't affect authorization, but identity headers still flow to backends.

### Impact on this POC

Our OTel access log EnvoyFilter reads identity from `FILTER_STATE(wasm.kuadrant.auth.identity.*)` — internal Envoy state that never touches the wire. This design choice is **unaffected** by PR #912 and remains the more secure approach for observability data extraction.

---

## Comparison: Final Hybrid vs Original POC vs `headers-based-auth-policy` Branch

The final EnvoyFilter (`maas-model-access-logs`) is a hybrid combining the best of the original POC and the `headers-based-auth-policy` branch ([bro-adm/models-as-a-service](https://github.com/bro-adm/models-as-a-service/tree/headers-based-auth-policy)).

### What Was Taken From Each

| Feature | Source | Rationale |
| --- | --- | --- |
| `FILTER_STATE` identity | **Original POC** | Internal Envoy state, survives 429, not spoofable, never on wire |
| Lua token/model extraction | **Branch** | Request-side model extraction (available on 429s); aligned with branch direction |
| CEL inference-only filter | **Branch** | Only logs completions — eliminates noise |
| `response_type` classification | **Branch** | Low-cardinality stream label for efficient Loki filtering |
| `targetRefs` gateway targeting | **Original POC** | Works on Gateway API clusters (branch's `workloadSelector` doesn't) |
| `pcall` error safety | **New** | Prevents Lua crashes from malformed payloads |
| Streaming detection | **New** | Skips response body buffering for `text/event-stream` |
| Quote stripping in OTel Collector | **New** | WASM shim wraps some values in quotes; collector strips them |

### Three-Way Comparison

| Aspect | Original POC | `headers-based-auth-policy` branch | Lua hybrid (archived) | **Final — json_to_metadata** |
| --- | --- | --- | --- | --- |
| Token extraction | `json_to_metadata` (C++) | Lua (regex) | Lua (regex + pcall) | **`json_to_metadata`** (native C++) |
| Model extraction | Response body | Request body | Request body + response overwrite | **Request body + response overwrite** |
| Identity source | `FILTER_STATE` | `DYNAMIC_METADATA(ext_authz)` | `FILTER_STATE` | **`FILTER_STATE`** |
| Log scope | All requests | Inference only (CEL) | Inference only (CEL) | **POST only + inference paths (CEL)** |
| `response_type` | No | Yes (CEL) | Yes (CEL) | **Yes (CEL)** |
| Streaming safety | No (buffers SSE) | No | Yes (Lua content-type check) | **Yes (content-type mismatch → on_error)** |
| Error safety | N/A (C++ filter) | No pcall | pcall on all body parsing | **Native — on_present only for model** |
| "unknown" fallback | N/A | N/A | Yes (pollutes Loki) | **No — missing model omits metadata** |
| Attributes | 25 (many redundant) | ~20 | 16 (focused) | **11 (minimal)** |
| Deployment | Static YAML | Go template (controller) | Static YAML | Static YAML (controller integration TODO) |
| Identity on 429 | Yes | No (ext_authz not populated) | Yes | **Yes** |

### Security Comparison

| Aspect | Original POC / Final Hybrid | `headers-based-auth-policy` |
| --- | --- | --- |
| Identity transport | `FILTER_STATE` (internal Envoy state, never on wire) | HTTP headers (on wire, must be stripped per-header) |
| Leak risk to model backends | None | Lua strips 3 headers but `X-MaaS-Subscription` is NOT stripped |
| Spoofing risk | None (filter_state cannot be spoofed by clients) | Depends on Authorino SET semantics overwriting client-injected headers |
