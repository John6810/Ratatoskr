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
{{- printf "%s-unit3d-migrate" (include "ratatoskr.fullname" .) | trunc 63 | trimSuffix "-" -}}
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
{{- $registry := .Values.unit3d.image.registry | default .Values.global.imageRegistry -}}
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
{{- $registry := .image.registry | default .global.imageRegistry -}}
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

{{/*
Shared envFrom block for the four UNIT3D workloads (app, queue,
scheduler, migrate). Renders configMapRef + 4 mandatory secretRefs
(unit3d/db/redis/meili — chart-managed or operator-supplied per toggle)
+ 1 optional secretRef for S3 storage credentials.

Usage in a workload Deployment/Job:
  envFrom:
    {{- include "ratatoskr.unit3d.envFrom" . | nindent 12 }}
*/}}
{{- define "ratatoskr.unit3d.envFrom" -}}
- configMapRef:
    name: {{ include "ratatoskr.fullname" . }}-unit3d-config
- secretRef:
    name: {{ include "ratatoskr.unit3d.secretName" . | quote }}
{{- if .Values.mariadb.enabled }}
- secretRef:
    name: {{ include "ratatoskr.mariadb.secretName" . | quote }}
{{- else }}
- secretRef:
    name: {{ required "unit3d.database.existingSecret is required when mariadb.enabled is false" .Values.unit3d.database.existingSecret | quote }}
{{- end }}
{{- if .Values.redis.enabled }}
- secretRef:
    name: {{ include "ratatoskr.redis.secretName" . | quote }}
{{- else }}
- secretRef:
    name: {{ required "unit3d.redis.existingSecret is required when redis.enabled is false" .Values.unit3d.redis.existingSecret | quote }}
{{- end }}
{{- if .Values.meilisearch.enabled }}
- secretRef:
    name: {{ include "ratatoskr.meilisearch.secretName" . | quote }}
{{- else }}
- secretRef:
    name: {{ required "unit3d.meilisearch.existingSecret is required when meilisearch.enabled is false" .Values.unit3d.meilisearch.existingSecret | quote }}
{{- end }}
- secretRef:
    name: {{ include "ratatoskr.storage.secretName" . | quote }}
    optional: true
{{- end -}}
