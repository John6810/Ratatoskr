# Monitoring

ratatoskr v0.4 documents an observability *baseline*, not a complete production observability
stack. Application-level metrics (a Laravel `/metrics` endpoint) are **not shipped** — UNIT3D
v9.2.0 vanilla does not expose Prometheus metrics, and adding them requires modifying the
application image. Distributing a modified image triggers AGPL-3.0 §13 source-disclosure
obligations for the operator. The v0.8 roadmap will ship ServiceMonitor manifests, pre-built
Grafana dashboards committed to `monitoring/grafana-dashboards/`, and an optional metrics image
variant with `spatie/laravel-prometheus` pre-installed. See the [v0.8 forward-reference](#v08-forward-reference)
section for the full scope.

## Stack overview

The recommended baseline:

- **Prometheus** (or Prometheus Operator / kube-prometheus-stack) for metric scraping and storage
- **Grafana** for dashboards and alerting UI
- **Loki + Grafana Alloy** (or Promtail for older stacks) for log aggregation
- **Alertmanager** (bundled with Prometheus Operator) for alert routing

This stack is the Kubernetes community default: all components are CNCF projects or Grafana Labs
OSS releases, and they run alongside ratatoskr without coupling to its application manifests.
Operators on Datadog, New Relic, or Dynatrace can replace the collection layer with their vendor
agent — the metric sources documented below remain the same.

What this guide does not prescribe: a specific Helm chart version, an alert routing destination
(PagerDuty / Opsgenie / Slack), or a retention policy. Those are operator decisions.

## Metrics: what to scrape

### Layer 1 — Kubernetes infrastructure

These are cluster-wide, not ratatoskr-specific. A default kube-prometheus-stack installation
covers all three without additional configuration:

- **kube-state-metrics**: pod phase, deployment rollout status, PVC binding state
- **node-exporter**: node CPU, memory, disk, and network I/O
- **cAdvisor** (built into the kubelet): per-container CPU and memory usage

If you are not using kube-prometheus-stack, install each component separately. The
kube-prometheus-stack Helm chart (`prometheus-community/kube-prometheus-stack`) is the fastest
path: it deploys the operator, kube-state-metrics, node-exporter, cAdvisor scraping, Grafana,
and Alertmanager in one release.

### Layer 2 — Stateful infrastructure

The three StatefulSets ratatoskr deploys do not expose Prometheus metrics natively in their
base images — they require sidecar exporters or an experimental flag.

| Component | Metrics source | Port | Notes |
|---|---|---|---|
| `mariadb` | `mysqld_exporter` sidecar | TCP 9104 | Bitnami image: `bitnami/mysqld-exporter` or `prom/mysqld-exporter` |
| `redis` | `redis_exporter` sidecar | TCP 9121 | `oliver006/redis_exporter` |
| `meilisearch` | Built-in `/metrics` (experimental flag) | TCP 7700 | Requires `MEILI_EXPERIMENTAL_ENABLE_METRICS=true` — see note below |

> ⚠️ **MeiliSearch metrics flag.** The `getmeili/meilisearch:v1.43` image (pinned in
> `kustomize/base/meilisearch/statefulset.yaml`) ships a built-in Prometheus `/metrics` endpoint
> behind an experimental feature flag. Enable it by setting the environment variable
> `MEILI_EXPERIMENTAL_ENABLE_METRICS=true` in the MeiliSearch StatefulSet. The equivalent
> `config.toml` key is `experimental_enable_metrics = true`. The endpoint is served at
> `GET /metrics` on port 7700 alongside the main MeiliSearch API.
>
> **Experimental** means Meilisearch makes no stability guarantee for this endpoint across
> versions: metric names, label cardinality, or the flag itself may change in a future release.
> Test after each MeiliSearch version bump. Do not enable this flag in the base overlay — add it
> as an overlay patch so each environment opts in explicitly.

None of these exporters or flags are shipped in `kustomize/base/` at v0.4. They are ROADMAP'd to
v0.8 as opt-in Components under `kustomize/base/monitoring/`.

#### ServiceMonitor examples (Prometheus Operator)

Operators running Prometheus Operator can add these ServiceMonitor resources in their overlay.
They are operator-extension manifests — not part of the ratatoskr base.

```yaml
# kustomize/overlays/prod-rwx/monitoring/servicemonitor-mariadb.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mariadb
  namespace: unit3d
  labels:
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/part-of: ratatoskr
    # Match the label selector on your Prometheus CR's serviceMonitorSelector
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: mariadb
  endpoints:
    - port: metrics      # Service port name for the mysqld_exporter sidecar
      interval: 30s
      path: /metrics
```

```yaml
# kustomize/overlays/prod-rwx/monitoring/servicemonitor-redis.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis
  namespace: unit3d
  labels:
    app.kubernetes.io/name: redis
    app.kubernetes.io/part-of: ratatoskr
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: redis
  endpoints:
    - port: metrics      # Service port name for the redis_exporter sidecar
      interval: 30s
      path: /metrics
```

```yaml
# kustomize/overlays/prod-rwx/monitoring/servicemonitor-meilisearch.yaml
# Requires MEILI_EXPERIMENTAL_ENABLE_METRICS=true on the StatefulSet
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: meilisearch
  namespace: unit3d
  labels:
    app.kubernetes.io/name: meilisearch
    app.kubernetes.io/part-of: ratatoskr
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: meilisearch
  endpoints:
    - port: http         # Port 7700 — MeiliSearch serves both API and /metrics here
      interval: 30s
      path: /metrics
      bearerTokenSecret:
        name: meilisearch-secrets
        key: MEILI_MASTER_KEY
```

The `bearerTokenSecret` on the MeiliSearch ServiceMonitor is required: the `/metrics` endpoint
respects the master key when `MEILI_ENV=production`.

#### PrometheusRule examples

Starting-point alert thresholds. Tune these after observing baseline traffic patterns on your
deployment — do not treat the numbers below as universal.

```yaml
# kustomize/overlays/prod-rwx/monitoring/prometheusrule-infra.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ratatoskr-infra
  namespace: unit3d
  labels:
    app.kubernetes.io/part-of: ratatoskr
    release: prometheus
spec:
  groups:
    - name: mariadb
      rules:
        - alert: MariaDBConnectionsSaturated
          expr: |
            (
              mysql_global_status_threads_connected
              / mysql_global_variables_max_connections
            ) > 0.80
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "MariaDB connection pool above 80%"
            description: >
              MariaDB in namespace {{ $labels.namespace }} is using
              {{ printf "%.0f" (mul $value 100) }}% of max_connections.
              Consider enabling ProxySQL or raising max_connections in the
              MariaDB ConfigMap.

    - name: redis
      rules:
        - alert: RedisMemoryEvicting
          expr: rate(redis_evicted_keys_total[5m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Redis is evicting keys"
            description: >
              Redis in namespace {{ $labels.namespace }} is evicting keys,
              indicating memory pressure. Review maxmemory and
              maxmemory-policy settings.

    - name: meilisearch
      rules:
        - alert: MeiliSearchIndexSizeGrowing
          # meilisearch_db_size_bytes is exposed by the /metrics endpoint
          # when MEILI_EXPERIMENTAL_ENABLE_METRICS=true
          expr: |
            increase(meilisearch_db_size_bytes[1h]) > 500000000
          for: 0m
          labels:
            severity: info
          annotations:
            summary: "MeiliSearch index grew > 500 MB in an hour"
            description: >
              The MeiliSearch LMDB store in namespace {{ $labels.namespace }}
              grew by more than 500 MB in the last hour. Verify the PVC has
              sufficient headroom (base size: 5Gi).
```

### Layer 3 — Application and ingress

**Traefik IngressRoute.** Traefik exposes a Prometheus metrics endpoint on the entrypoint
configured in its static config. The default port in many distributions is `:8082`; your
installation may differ. Enable it in Traefik's static config:

```yaml
# Traefik static config — operator-side, not managed by ratatoskr.
# See https://doc.traefik.io/traefik/observability/metrics/prometheus/
entryPoints:
  metrics:
    address: ":8082"
metrics:
  prometheus:
    entryPoint: metrics
```

ratatoskr does not configure Traefik's static config — the ingress controller is operator-supplied
per [ADR-0003](./adr/0003-ingress-controller-assumption.md).

**FrankenPHP / Caddy.** Caddy supports a Prometheus `metrics` directive in the Caddyfile that
exposes Go runtime and server metrics. The ratatoskr `docker/Caddyfile` does **not** enable this
directive — the `admin off` global block disables the Caddy admin API, and no `metrics` global
option is present. Operators who want Caddy metrics must add the directive in their own image fork:

```caddyfile
# Patch to add Caddy metrics — requires a fork of docker/Caddyfile.
# The metrics directive requires admin NOT be set to "off".
# Change "admin off" to a bound address and add the metrics global option.
{
    frankenphp {
        # ... existing config unchanged ...
    }

    admin 127.0.0.1:2019

    servers {
        metrics
    }
}
```

Forking the Caddyfile means building a custom image. That image is a modified version of the
ratatoskr image — distributing it triggers AGPL-3.0 §13 source-disclosure obligations.

**UNIT3D Laravel application.** UNIT3D v9.2.0 does not expose a `/metrics` endpoint. The
framework (Laravel 11) has no built-in Prometheus integration. Two operator paths for
application-level metrics:

1. Fork the ratatoskr image, add `spatie/laravel-prometheus` (or equivalent), expose `/metrics`
   with HTTP auth, and add a NetworkPolicy ingress rule restricting access to the Prometheus pod.
   Distributing this image triggers AGPL-3.0 §13.
2. Wait for v0.8, which will ship a documented recipe and an optional pre-built image variant
   (`ghcr.io/<operator>/unit3d-metrics:<version>`) with `spatie/laravel-prometheus` pre-installed.

At v0.4, there are no application-layer request-rate, error-rate, or queue-depth Prometheus
metrics available from the vanilla image. The Traefik metrics endpoint provides HTTP request
counts and error rates at the ingress layer as a partial substitute.

## Logs: Loki + Alloy

### Log sources

- **Application logs**: UNIT3D emits structured logs to stdout via Laravel's Monolog integration.
  In the ratatoskr Kubernetes deployment, all stdout/stderr from `unit3d-app`,
  `unit3d-queue`, and `unit3d-scheduler` pods flows through the container runtime log driver.
  See [security-hardening.md § Audit and incident response](./security-hardening.md#audit-and-incident-response)
  for `kubectl logs` usage and persistence guidance.
- **Container stdout/stderr**: picked up by a Grafana Alloy or Promtail DaemonSet running on
  every node.
- **Kubernetes events** (optional): the `kube-events-exporter` tool or Alloy's native Kubernetes
  event discovery can push cluster events into Loki. Useful for correlating pod restarts and
  scheduling failures with application errors.

### Label discipline

ratatoskr base manifests apply the standard `app.kubernetes.io/*` labels on every workload
resource. Loki labels should include:

- `namespace` — always; scopes all queries to the `unit3d` namespace
- `app.kubernetes.io/name` — always; distinguishes `mariadb`, `redis`, `meilisearch`, `unit3d-app`
- `app.kubernetes.io/component` — distinguishes `unit3d-app` (serves HTTP) from `unit3d-queue`
  (processes jobs) and `unit3d-scheduler` (dispatches cron)

Keep high-cardinality values — request IDs, user IDs, trace IDs — out of Loki labels. They
belong in the log line content, not in label selectors. High-cardinality labels generate a Loki
label explosion that degrades query performance and increases storage costs.

### Alloy DaemonSet configuration

The following Alloy configuration snippet discovers pods in the `unit3d` namespace, attaches the
relevant Kubernetes labels, and pushes to a Loki endpoint. Replace `<loki-endpoint>` with your
Loki push URL (e.g. `http://loki.monitoring.svc.cluster.local:3100`).

```hcl
// Grafana Alloy river config — deployed as a DaemonSet by the Alloy Helm chart.
// Reference: https://grafana.com/docs/alloy/latest/

discovery.kubernetes "unit3d_pods" {
  role = "pod"
  namespaces {
    names = ["unit3d"]
  }
}

discovery.relabel "unit3d_pods" {
  targets = discovery.kubernetes.unit3d_pods.targets

  // Keep only running pods
  rule {
    source_labels = ["__meta_kubernetes_pod_phase"]
    regex         = "Running"
    action        = "keep"
  }

  // Map standard Kubernetes meta-labels to Loki labels
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    target_label  = "app"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_component"]
    target_label  = "component"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
}

loki.source.kubernetes "unit3d" {
  targets    = discovery.relabel.unit3d_pods.output
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "<loki-endpoint>/loki/api/v1/push"
  }
}
```

For Promtail (legacy stacks), the equivalent is a `scrape_configs` block with
`kubernetes_sd_configs` targeting the `unit3d` namespace. See the
[Promtail Kubernetes discovery documentation](https://grafana.com/docs/loki/latest/send-data/promtail/configuration/#kubernetes_sd_config)
for the exact configuration schema.

## Dashboards

ratatoskr does not ship Grafana dashboards in v0.4. The following community dashboards are
suitable starting points. Import them via Grafana UI: **Dashboards > New > Import > paste the ID
> select your Prometheus or Loki datasource > Import**.

| Dashboard | ID | Datasource | Notes |
|---|---|---|---|
| Kubernetes / Views / Namespaces | [15758](https://grafana.com/grafana/dashboards/15758/) | Prometheus | Namespace-scoped view of pod counts, CPU, memory, network |
| Traefik Official Standalone | [17346](https://grafana.com/grafana/dashboards/17346/) | Prometheus | Traefik request rates, error rates, entrypoint metrics |
| MySQL Overview | [7362](https://grafana.com/grafana/dashboards/7362/) | Prometheus | MariaDB/MySQL via mysqld_exporter; shows connections, queries, InnoDB stats |
| Redis Dashboard for Prometheus Redis Exporter 1.x | [763](https://grafana.com/grafana/dashboards/763/) | Prometheus | Memory, hit rate, evictions, connected clients via redis_exporter |
| Loki Dashboard | [13186](https://grafana.com/grafana/dashboards/13186/) | Loki | Log search with namespace/pod filter and timeline |

These are community-maintained dashboards and their contents may change between revisions.
Pin a specific revision after import by exporting the JSON and committing it to your fork.

v0.8 will commit ratatoskr-specific dashboard JSON to `monitoring/grafana-dashboards/` with
sidecar provisioning via Grafana's `dashboardProviders` configmap. That includes UNIT3D-specific
panels: ratio distribution, peer load, queue depth, and scheduler lag per the
[v0.8 roadmap entry](./ROADMAP.md).

## Alerts: baseline rules

The following PrometheusRule adds six alert rules to a Prometheus Operator installation.
Apply it in your overlay under `kustomize/overlays/<env>/monitoring/`.

Rule 1 (`KubePodCrashLooping`) is already shipped by kube-prometheus-stack. The manifest below
references it in a comment rather than redefining it — adding a duplicate rule name with different
thresholds creates confusing silences.

```yaml
# kustomize/overlays/prod-rwx/monitoring/prometheusrule-baseline.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ratatoskr-baseline
  namespace: unit3d
  labels:
    app.kubernetes.io/name: ratatoskr
    app.kubernetes.io/part-of: ratatoskr
    release: prometheus   # must match your Prometheus CR's ruleSelector
spec:
  groups:
    - name: ratatoskr.baseline
      # KubePodCrashLooping is defined by kube-prometheus-stack.
      # Refer to that rule; do not redefine it here.
      rules:
        - alert: UNIT3DHighErrorRate
          # Requires Traefik metrics with the unit3d router name label.
          # Adjust the router label to match your IngressRoute name.
          expr: |
            (
              sum(rate(traefik_router_requests_total{
                router=~"unit3d.*",
                code=~"5.."
              }[5m]))
              /
              sum(rate(traefik_router_requests_total{
                router=~"unit3d.*"
              }[5m]))
            ) > 0.05
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "UNIT3D 5xx rate above 5%"
            description: >
              More than 5% of requests to UNIT3D routers are returning 5xx
              over the last 5 minutes. Check unit3d-app logs and MariaDB
              connectivity.

        - alert: MariaDBConnectionsSaturated
          expr: |
            (
              mysql_global_status_threads_connected
              / mysql_global_variables_max_connections
            ) > 0.80
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "MariaDB connections above 80% of max_connections"
            description: >
              Active connections are {{ printf "%.0f" (mul $value 100) }}%
              of max_connections. FrankenPHP worker processes hold persistent
              connections; scale down replicas or raise max_connections.
              See ADR-0001 for the connection-pooling roadmap.

        - alert: RedisMemoryEvicting
          expr: rate(redis_evicted_keys_total[5m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Redis is evicting keys"
            description: >
              Redis is evicting keys under memory pressure. Sessions,
              cache entries, and broadcast state may be lost. Review the
              maxmemory setting in the Redis StatefulSet.

        - alert: PVCAlmostFull
          expr: |
            (
              kubelet_volume_stats_used_bytes
              / kubelet_volume_stats_capacity_bytes
            ) > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "PVC {{ $labels.persistentvolumeclaim }} above 85% full"
            description: >
              PVC {{ $labels.persistentvolumeclaim }} in namespace
              {{ $labels.namespace }} is {{ printf "%.0f" (mul $value 100) }}%
              full. Expand the volume or clean up unused data. The
              unit3d-storage PVC holds image disks; the meilisearch data PVC
              holds the LMDB index store.

        - alert: CertificateExpiringSoon
          # Requires cert-manager with the Prometheus integration enabled.
          # https://cert-manager.io/docs/configuration/prometheus-metrics/
          expr: |
            certmanager_certificate_expiration_timestamp_seconds
            - time() < 30 * 24 * 3600
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "TLS certificate expires in less than 30 days"
            description: >
              Certificate {{ $labels.name }} in namespace
              {{ $labels.namespace }} expires in less than 30 days. Verify
              that the cert-manager ClusterIssuer can reach the ACME endpoint
              and that the Certificate resource is not in a failed state.
```

All thresholds above are starting points. Observe baseline traffic after launch and adjust
`for:` durations and percentage thresholds to match real patterns before enabling paging-level
severity.

## ⚠️ NetworkPolicy implications

`kustomize/base/networkpolicies/` enforces default-deny with additive allows (see the
[NetworkPolicy README](../kustomize/base/networkpolicies/README.md)). The base policies allow
ingress to `unit3d-app` only from namespaces labeled `network.ratatoskr.io/ingress=true`, and
grant no inbound access to the infrastructure pods from outside the `unit3d` namespace.

To allow Prometheus to scrape the ratatoskr pods, add an ingress patch in your overlay:

```yaml
# kustomize/overlays/prod-rwx/monitoring/netpol-prometheus-scrape.yaml
# Allows Prometheus pods (in the monitoring namespace) to reach
# metrics endpoints inside the unit3d namespace.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: unit3d
spec:
  podSelector: {}    # applies to all pods in unit3d namespace
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              # Label your monitoring namespace accordingly:
              # kubectl label namespace monitoring network.ratatoskr.io/monitoring=true
              network.ratatoskr.io/monitoring: "true"
      ports:
        - port: 9104      # mysqld_exporter
          protocol: TCP
        - port: 9121      # redis_exporter
          protocol: TCP
        - port: 7700      # meilisearch /metrics (experimental)
          protocol: TCP
```

Label the monitoring namespace before applying:

```bash
kubectl label namespace monitoring network.ratatoskr.io/monitoring=true
```

The Alloy DaemonSet pods (for log collection) run on every node and connect to the Loki endpoint
outside the cluster — that traffic is handled by the operator's monitoring stack internal
NetworkPolicies and is not a ratatoskr concern.

For the inverse direction — restricting which external hosts ratatoskr pods can reach — see
[security-hardening.md § Network: NetworkPolicy egress tightening](./security-hardening.md#network-networkpolicy-egress-tightening).

## v0.8 forward-reference

The [v0.8 roadmap entry](./ROADMAP.md) will deliver:

- Prometheus Operator ServiceMonitor manifests under `kustomize/base/monitoring/` as an opt-in
  Component, covering `mariadb`, `redis`, and `meilisearch`
- Pre-built Grafana dashboard JSON under `monitoring/grafana-dashboards/` with sidecar
  provisioning via `dashboardProviders`; UNIT3D-specific panels for ratio distribution, peer load,
  queue depth, and scheduler lag
- An optional `unit3d-metrics` image variant (`ghcr.io/<operator>/unit3d-metrics:<version>`)
  with `spatie/laravel-prometheus` pre-installed, including a documented endpoint, auth
  middleware, and NetworkPolicy ingress restriction
- A Loki LogQL recipe library for common operations queries (queue job failures, announce
  error patterns, migration output)
- Sentry integration for PHP error tracking

## See also

- [docs/architecture.md](./architecture.md) — component graph showing all workloads and their
  data dependencies
- [docs/security-hardening.md](./security-hardening.md) — audit logging, log discipline, and
  NetworkPolicy egress tightening
- [docs/upgrade-guide.md](./upgrade-guide.md) — rollback procedures and observability during
  version bumps
- [docs/adr/0001-database-deployment-topology.md](./adr/0001-database-deployment-topology.md) —
  MariaDB single-replica design and connection-pooling limitations relevant to connection
  saturation alerts
- [docs/ROADMAP.md](./ROADMAP.md) — v0.8 observability scope
