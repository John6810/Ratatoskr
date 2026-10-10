{{/*
Helper templates for ratatoskr.

Pattern follows the Bitnami / community convention. No external chart
dependencies — these helpers are self-contained inside the ratatoskr
chart.

Per-component fullname helpers ensure resource names follow the
Kustomize-side convention: <release>-<component>, e.g. `ratatoskr-mariadb`,
`ratatoskr-unit3d-app`. Operators migrating from Kustomize get the same
short names by installing as `helm install ratatoskr ./helm/ratatoskr`.
*/}}

{{/*
Expand the chart name.
*/}}
{{- define "ratatoskr.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. Combines release name with chart name unless
the release name already contains the chart name (avoids `ratatoskr-ratatoskr`).
Truncated to 63 chars (DNS-1123 limit).
*/}}
{{- define "ratatoskr.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart label value: <name>-<version>, sanitized to DNS-1123.
*/}}
{{- define "ratatoskr.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource.
NOTE: `app.kubernetes.io/name` is intentionally NOT included here —
each component template sets it to the component name (`mariadb`,
`redis`, `meilisearch`, `unit3d-app`, etc.) per the Kustomize base
convention. Putting it in the shared helper would conflict with
per-component overrides and produce duplicate keys.
*/}}
{{- define "ratatoskr.labels" -}}
helm.sh/chart: {{ include "ratatoskr.chart" . }}
{{ include "ratatoskr.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ratatoskr
ratatoskr.io/version: {{ .Chart.Version | quote }}
{{- end -}}

{{/*
Selector labels (subset of common labels — must NOT change between
chart versions, K8s rejects label-selector mutations on Deployments).
Kept narrow on purpose: only `app.kubernetes.io/instance` (release
identity). Per-component templates add `app.kubernetes.io/name:
<component>` to disambiguate workloads within the release.
*/}}
{{- define "ratatoskr.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Claim templates are immutable, including their labels. Preserve labels
from older installs; use version-independent labels for a fresh StatefulSet. */}}
{{- define "ratatoskr.claimLabels" -}}
{{- $root := .root -}}
{{- $name := include (printf "ratatoskr.%s.fullname" .name) $root -}}
{{- $labels := dict "app.kubernetes.io/instance" $root.Release.Name "app.kubernetes.io/managed-by" $root.Release.Service "app.kubernetes.io/part-of" "ratatoskr" "app.kubernetes.io/name" .name "app.kubernetes.io/component" .component -}}
{{- $existing := lookup "apps/v1" "StatefulSet" $root.Release.Namespace $name -}}
{{- if $existing -}}
  {{- range $claim := $existing.spec.volumeClaimTemplates -}}
    {{- if eq $claim.metadata.name "data" -}}
      {{- $labels = $claim.metadata.labels | default dict -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toYaml $labels -}}
{{- end -}}

{{/*
ServiceAccount name. If serviceAccount.create is true, returns the
configured name (or the chart fullname if name empty). Otherwise
returns "default".
*/}}
{{- define "ratatoskr.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ratatoskr.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Per-component fullname helpers. Pattern: <release>-<component>.
Match the resource names used in kustomize/base/<component>/.
*/}}

{{- define "ratatoskr.unit3d.fullname" -}}
{{- printf "%s-unit3d-app" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ratatoskr.queue.fullname" -}}
{{- printf "%s-unit3d-queue" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ratatoskr.scheduler.fullname" -}}
{{- printf "%s-unit3d-scheduler" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ratatoskr.migrate.fullname" -}}
{{- printf "%s-migrate-%d" (include "ratatoskr.fullname" . | trunc 43 | trimSuffix "-") .Release.Revision -}}
{{- end -}}

{{- define "ratatoskr.mariadb.fullname" -}}
{{- printf "%s-mariadb" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ratatoskr.redis.fullname" -}}
{{- printf "%s-redis" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ratatoskr.meilisearch.fullname" -}}
{{- printf "%s-meilisearch" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
unit3d image reference. Falls back to .Chart.AppVersion when tag is empty.
*/}}
{{- define "ratatoskr.unit3d.image" -}}
{{- $registry := .Values.global.imageRegistry | default .Values.unit3d.image.registry -}}
{{- $repository := .Values.unit3d.image.repository -}}
{{- $tag := .Values.unit3d.image.tag | default .Chart.AppVersion -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Generic image reference helper. Pass a component values block; honors
global.imageRegistry override.
Usage: {{ include "ratatoskr.image" (dict "image" .Values.mariadb.image "global" .Values.global) }}
*/}}
{{- define "ratatoskr.image" -}}
{{- $registry := .global.imageRegistry | default .image.registry -}}
{{- $repository := .image.repository -}}
{{- $tag := .image.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
StorageClass resolver — per-component override falls through to
global.storageClass, then to the cluster default ("" omitted from
PVC spec).
Usage: {{ include "ratatoskr.storageClass" (dict "scoped" .Values.mariadb.persistence.storageClass "global" .Values.global.storageClass) }}
*/}}
{{- define "ratatoskr.storageClass" -}}
{{- if .scoped -}}
{{- .scoped -}}
{{- else if .global -}}
{{- .global -}}
{{- end -}}
{{- end -}}

{{/*
==============================================================================
Secret resolution helpers (existingSecret pattern, Bitnami-aligned).
==============================================================================
Each component has 2-3 helpers:
  ratatoskr.<comp>.secretName   — Secret name (existingSecret OR chart-created)
  ratatoskr.<comp>.<key>Key      — key name inside that Secret per password type
*/}}

{{/* MariaDB */}}
{{- define "ratatoskr.mariadb.secretName" -}}
{{- if .Values.mariadb.auth.existingSecret -}}
{{- .Values.mariadb.auth.existingSecret -}}
{{- else -}}
{{- include "ratatoskr.mariadb.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.mariadb.rootPasswordKey" -}}
{{- if .Values.mariadb.auth.existingSecret -}}
{{- .Values.mariadb.auth.existingSecretRootPasswordKey -}}
{{- else -}}
MARIADB_ROOT_PASSWORD
{{- end -}}
{{- end -}}

{{- define "ratatoskr.mariadb.passwordKey" -}}
{{- if .Values.mariadb.auth.existingSecret -}}
{{- .Values.mariadb.auth.existingSecretPasswordKey -}}
{{- else -}}
DB_PASSWORD
{{- end -}}
{{- end -}}

{{- define "ratatoskr.mariadb.backupPasswordKey" -}}
{{- if .Values.mariadb.auth.existingSecret -}}
{{- .Values.mariadb.auth.existingSecretBackupPasswordKey -}}
{{- else -}}
MARIADB_BACKUP_PASSWORD
{{- end -}}
{{- end -}}

{{/* Redis */}}
{{- define "ratatoskr.redis.secretName" -}}
{{- if .Values.redis.auth.existingSecret -}}
{{- .Values.redis.auth.existingSecret -}}
{{- else -}}
{{- include "ratatoskr.redis.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.redis.passwordKey" -}}
{{- if .Values.redis.auth.existingSecret -}}
{{- .Values.redis.auth.existingSecretPasswordKey -}}
{{- else -}}
REDIS_PASSWORD
{{- end -}}
{{- end -}}

{{/* MeiliSearch */}}
{{- define "ratatoskr.meilisearch.secretName" -}}
{{- if .Values.meilisearch.existingSecret -}}
{{- .Values.meilisearch.existingSecret -}}
{{- else -}}
{{- include "ratatoskr.meilisearch.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.meilisearch.masterKeyKey" -}}
{{- if .Values.meilisearch.existingSecret -}}
{{- .Values.meilisearch.existingSecretMasterKeyKey -}}
{{- else -}}
MEILI_MASTER_KEY
{{- end -}}
{{- end -}}

{{/* unit3d application Secret (APP_KEY + bootstrap + DEFAULT_OWNER_*) */}}
{{- define "ratatoskr.unit3d.secretName" -}}
{{- if .Values.unit3d.existingSecret -}}
{{- .Values.unit3d.existingSecret -}}
{{- else -}}
{{- include "ratatoskr.unit3d.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.unit3d.appKeyKey" -}}
{{- if .Values.unit3d.existingSecret -}}
{{- .Values.unit3d.existingSecretAppKeyKey -}}
{{- else -}}
APP_KEY
{{- end -}}
{{- end -}}

{{/*
unit3d-storage-secrets: optional, only created when ANY Storage-aware
disk has driver: s3 AND unit3d.storage.s3.existingSecret is empty.
Operators with all-local storage skip the Secret entirely.
*/}}
{{- define "ratatoskr.storage.secretName" -}}
{{- if .Values.unit3d.storage.s3.existingSecret -}}
{{- .Values.unit3d.storage.s3.existingSecret -}}
{{- else -}}
{{- printf "%s-unit3d-storage" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.storage.s3Enabled" -}}
{{- if or (eq .Values.unit3d.storage.torrentFiles.driver "s3") (or (eq .Values.unit3d.storage.subtitleFiles.driver "s3") (eq .Values.unit3d.storage.attachmentFiles.driver "s3")) -}}true{{- end -}}
{{- end -}}

{{/*
==============================================================================
Hostname / port resolvers (chart-managed vs external endpoint).
==============================================================================
When mariadb.enabled (likewise redis, meilisearch), the chart-deployed
Service is reachable at <release>-<component>:<port>. When false,
operator supplies unit3d.<component>.host + .port (external endpoint).
*/}}

{{- define "ratatoskr.dbHost" -}}
{{- if .Values.mariadb.enabled -}}
{{- include "ratatoskr.mariadb.fullname" . -}}
{{- else -}}
{{- required "unit3d.database.host is required when mariadb.enabled is false" .Values.unit3d.database.host -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.dbPort" -}}
{{- if .Values.mariadb.enabled -}}
3306
{{- else -}}
{{- .Values.unit3d.database.port | default 3306 -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.redisHost" -}}
{{- if .Values.redis.enabled -}}
{{- include "ratatoskr.redis.fullname" . -}}
{{- else -}}
{{- required "unit3d.redis.host is required when redis.enabled is false" .Values.unit3d.redis.host -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.redisPort" -}}
{{- if .Values.redis.enabled -}}
6379
{{- else -}}
{{- .Values.unit3d.redis.port | default 6379 -}}
{{- end -}}
{{- end -}}

{{- define "ratatoskr.meiliUrl" -}}
{{- if .Values.meilisearch.enabled -}}
{{- printf "http://%s:7700" (include "ratatoskr.meilisearch.fullname" .) -}}
{{- else -}}
{{- $host := required "unit3d.meilisearch.host is required when meilisearch.enabled is false" .Values.unit3d.meilisearch.host -}}
{{- $port := .Values.unit3d.meilisearch.port | default 7700 -}}
{{- printf "http://%s:%v" $host $port -}}
{{- end -}}
{{- end -}}

{{/*
Bootstrap-app-key + existingSecret mutex guard. Fail rendering with a
clear message if both are set — they are mutually exclusive (cannot
generate APP_KEY into an operator-managed external Secret).
*/}}
{{- define "ratatoskr.unit3d.bootstrapGuard" -}}
{{- if and .Values.unit3d.bootstrapAppKey .Values.unit3d.existingSecret -}}
{{- fail "unit3d.bootstrapAppKey and unit3d.existingSecret are mutually exclusive: bootstrap cannot generate APP_KEY into an operator-managed external Secret." -}}
{{- end -}}
{{- end -}}

{{/* Shared application configuration. Sensitive service credentials use explicit keys. */}}
{{- define "ratatoskr.unit3d.envFrom" -}}
- configMapRef:
    name: {{ include "ratatoskr.fullname" . }}-unit3d-config
- secretRef:
    name: {{ include "ratatoskr.unit3d.secretName" . | quote }}
{{- end -}}

{{- define "ratatoskr.unit3d.runtimeEnv" -}}
{{ include "ratatoskr.unit3d.env" . }}
{{- range list "DEFAULT_OWNER_PASSWORD" }}
- name: {{ . }}
  value: ""
{{- end }}
{{- end -}}

{{- define "ratatoskr.unit3d.env" -}}
- name: APP_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ratatoskr.unit3d.secretName" . | quote }}
      key: {{ include "ratatoskr.unit3d.appKeyKey" . | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.mariadb.enabled }}
      name: {{ include "ratatoskr.mariadb.secretName" . | quote }}
      key: {{ include "ratatoskr.mariadb.passwordKey" . | quote }}
      {{- else }}
      name: {{ required "unit3d.database.existingSecret is required" .Values.unit3d.database.existingSecret | quote }}
      key: {{ .Values.unit3d.database.existingSecretPasswordKey | quote }}
      {{- end }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.redis.enabled }}
      name: {{ include "ratatoskr.redis.secretName" . | quote }}
      key: {{ include "ratatoskr.redis.passwordKey" . | quote }}
      {{- else }}
      name: {{ required "unit3d.redis.existingSecret is required" .Values.unit3d.redis.existingSecret | quote }}
      key: {{ .Values.unit3d.redis.existingSecretPasswordKey | quote }}
      {{- end }}
- name: MEILISEARCH_KEY
  valueFrom:
    secretKeyRef:
      {{- if .Values.meilisearch.enabled }}
      name: {{ include "ratatoskr.meilisearch.secretName" . | quote }}
      key: {{ include "ratatoskr.meilisearch.masterKeyKey" . | quote }}
      {{- else }}
      name: {{ required "unit3d.meilisearch.existingSecret is required" .Values.unit3d.meilisearch.existingSecret | quote }}
      key: {{ .Values.unit3d.meilisearch.existingSecretMasterKeyKey | quote }}
      {{- end }}
{{- if eq (include "ratatoskr.storage.s3Enabled" .) "true" }}
{{- $root := . }}
{{- range $disk := list "TORRENT_FILES" "SUBTITLE_FILES" "ATTACHMENT_FILES" }}
- name: FILESYSTEM_{{ $disk }}_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ratatoskr.storage.secretName" $root | quote }}
      key: {{ if $root.Values.unit3d.storage.s3.existingSecret }}{{ $root.Values.unit3d.storage.s3.existingSecretKeyKey | quote }}{{ else }}FILESYSTEM_{{ $disk }}_KEY{{ end }}
- name: FILESYSTEM_{{ $disk }}_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "ratatoskr.storage.secretName" $root | quote }}
      key: {{ if $root.Values.unit3d.storage.s3.existingSecret }}{{ $root.Values.unit3d.storage.s3.existingSecretSecretKeyKey | quote }}{{ else }}FILESYSTEM_{{ $disk }}_SECRET{{ end }}
{{- end }}
{{- end }}
{{- end -}}

{{/* A set-once hook is emitted only if its Secret does not exist. */}}
{{- define "ratatoskr.secretMissing" -}}
{{- $existing := lookup "v1" "Secret" .root.Release.Namespace .name -}}
{{- if $existing -}}
{{- if ne (dig "app.kubernetes.io/instance" "" ($existing.metadata.labels | default dict)) .root.Release.Name -}}
{{- fail (printf "Secret %s belongs to another owner; use existingSecret explicitly" .name) -}}
{{- end -}}
{{- range $key := .keys -}}
{{- if not (get ($existing.data | default dict) $key) -}}
{{- fail (printf "Retained Secret %s is missing %s; recover it before upgrading" $.name $key) -}}
{{- end -}}
{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{- define "ratatoskr.migrate.image" -}}
{{- .Values.migrate.image | default (printf "%s/john6810/unit3d-migrate:%s" (.Values.global.imageRegistry | default "ghcr.io") .Chart.AppVersion) -}}
{{- end -}}

{{- define "ratatoskr.validate" -}}
{{- if contains "*" .Values.unit3d.trustedProxies -}}
{{- fail "unit3d.trustedProxies must list trusted proxy CIDRs; wildcard trust permits client IP spoofing" -}}
{{- end -}}
{{- if and (eq .Values.unit3d.appEnv "production") .Values.unit3d.appDebug -}}
{{- fail "unit3d.appDebug must be false in production" -}}
{{- end -}}
{{- if le (int .Values.unit3d.frankenphp.threads) (int .Values.unit3d.frankenphp.workers) -}}
{{- fail "unit3d.frankenphp.threads must exceed workers so FrankenPHP can start" -}}
{{- end -}}
{{- if .Values.ingress.enabled -}}
{{- fail "ingress.enabled is not supported yet; supply ingress separately or set ingress.enabled=false" -}}
{{- end -}}
{{- if not .Values.storage.enabled -}}
{{- fail "storage.enabled=false is unsupported: UNIT3D image disks still require a writable PVC" -}}
{{- end -}}
{{- if not (has .Values.storage.accessMode (list "ReadWriteOnce" "ReadWriteMany")) -}}
{{- fail "storage.accessMode must be ReadWriteOnce or ReadWriteMany for shared UNIT3D storage" -}}
{{- end -}}
{{- range $entry := list (dict "name" "app" "enabled" true "replicas" .Values.unit3d.replicas "hpa" .Values.hpa.app "pdb" .Values.pdb.app) (dict "name" "queue" "enabled" .Values.queue.enabled "replicas" .Values.queue.replicas "hpa" .Values.hpa.queue "pdb" .Values.pdb.queue) -}}
{{- if and (not $entry.enabled) (or $entry.hpa.enabled $entry.pdb.enabled) -}}{{ fail (printf "%s HPA/PDB requires its workload to be enabled" $entry.name) }}{{- end -}}
{{- if and $entry.hpa.enabled (gt (int $entry.hpa.minReplicas) (int $entry.hpa.maxReplicas)) -}}{{ fail (printf "%s HPA minReplicas exceeds maxReplicas" $entry.name) }}{{- end -}}
{{- if and (eq $.Values.storage.accessMode "ReadWriteOnce") (or (gt (int $entry.replicas) 1) (and $entry.hpa.enabled (gt (int $entry.hpa.maxReplicas) 1))) -}}
{{- fail (printf "%s multi-replica/HPA scale-out requires storage.accessMode=ReadWriteMany" $entry.name) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.networkPolicies.enabled (or (not .Values.mariadb.enabled) (not .Values.redis.enabled) (not .Values.meilisearch.enabled)) (empty .Values.networkPolicies.extraEgress) -}}
{{- fail "external services require networkPolicies.extraEgress rules, or networkPolicies.enabled=false" -}}
{{- end -}}
{{- end -}}

{{/* Co-locate all consumers of the shared RWO PVC. The first pod matches itself. */}}
{{- define "ratatoskr.storageAffinity" -}}
{{- if eq .Values.storage.accessMode "ReadWriteOnce" }}
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            ratatoskr.io/storage: {{ include "ratatoskr.fullname" . | quote }}
        topologyKey: kubernetes.io/hostname
{{- end }}
{{- end -}}

{{- define "ratatoskr.lifecycleVolumes" -}}
- name: lifecycle
  configMap:
    name: {{ include "ratatoskr.fullname" . }}-lifecycle
{{- if .Values.migrate.enabled }}
- name: migration-api
  projected:
    sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items:
            - key: ca.crt
              path: ca.crt
      - downwardAPI:
          items:
            - path: namespace
              fieldRef:
                fieldPath: metadata.namespace
{{- end }}
{{- end -}}

{{- define "ratatoskr.workloadInit" -}}
- name: wait-for-migration
  image: {{ include "ratatoskr.unit3d.image" . | quote }}
  imagePullPolicy: {{ .Values.unit3d.image.pullPolicy }}
  command: ["php", "/opt/ratatoskr/lifecycle.php", {{ if .Values.migrate.enabled }}"wait"{{ else }}"storage"{{ end }}]
  env:
    - name: MIGRATION_JOB
      value: {{ include "ratatoskr.migrate.fullname" . | quote }}
  resources:
    requests: {cpu: 25m, memory: 32Mi}
    limits: {cpu: 200m, memory: 128Mi}
  securityContext:
    {{- toYaml .Values.unit3d.containerSecurityContext | nindent 4 }}
  volumeMounts:
    - name: lifecycle
      mountPath: /opt/ratatoskr
      readOnly: true
    - name: storage
      mountPath: /app/storage
    {{- if .Values.migrate.enabled }}
    - name: migration-api
      mountPath: /var/run/secrets/ratatoskr
      readOnly: true
    {{- end }}
{{- end -}}
