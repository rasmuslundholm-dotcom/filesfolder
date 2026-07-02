#!/usr/bin/env bash
#
# Stockholm: migrate ONE Docker-Compose Intric instance -> the k3s cluster.
#
# Built incrementally from the trafikkontoret CANARY (see stockholm-k8s-migration-plan.md §7).
# Idempotent-ish, guided, verifies at each gate. Runs ON the server (sthlmfai01p), which has
# read-only access to the old data at /mnt/inspect and writable SAN at /mnt/sandisk.
#
# SAFETY: the old data (/mnt/inspect, /mnt/old-*) is READ-ONLY. This script only ever READS it
# and writes copies to /mnt/sandisk. It never modifies or deletes anything on the old disks.
#
# COVERS: the three external-Zitadel instances (trafikkontoret, stadsbyggnadskontoret, intric).
# NOT YET: fastighetskontoret (self-hosted local Zitadel) needs the extra Zitadel-DB migration.
#
# Usage:
#   export GHCR_USER=<github-username> GHCR_PAT=<packages:read PAT>
#   export ZITADEL_ACCESS_TOKEN=<machine PAT for this instance's project on login.intric.ai>
#   ./migrate-instance.sh <project>          # e.g. stadsbyggnadskontoret
#
# Most config is DERIVED from the old .env; only the three secrets above are operator-supplied.

set -euo pipefail

PROJECT="${1:?usage: migrate-instance.sh <project> (e.g. stadsbyggnadskontoret)}"
NS="${NS:-$PROJECT}"
REL="${REL:-$PROJECT}"

# --- fixed platform config (shared across instances) -------------------------
PROXY="${PROXY:-http://proxy-sta.adstockholm.se:8080}"
NO_PROXY_VAL="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.adstockholm.se,.stockholm.se,.umnfi.net"
CHART_TGZ="${CHART_TGZ:-/mnt/sandisk/intric-helm-5.10.3.tgz}"
CA_BUNDLE_HOST="${CA_BUNDLE_HOST:-/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem}"
SRC_PG_IMAGE="${SRC_PG_IMAGE:-docker.io/pgvector/pgvector:pg13}"
SRC_S3_IMAGE="${SRC_S3_IMAGE:-rustfs/rustfs:1.0.0-alpha.81}"   # match source on-disk format
MC_IMAGE="${MC_IMAGE:-minio/mc}"

# --- derived paths on the box ------------------------------------------------
OLD_ENV="/mnt/old-home/ecogpt/intric/${PROJECT}/.env"
OLD_PG="/mnt/inspect/docker/volumes/${PROJECT}_postgres_data/_data"
OLD_S3="/mnt/inspect/docker/volumes/${PROJECT}_s3_data/_data"
WORK_PG="/mnt/sandisk/${PROJECT}-pgdata"
WORK_S3="/mnt/sandisk/${PROJECT}-s3data"
DUMP="/mnt/sandisk/${PROJECT}.dump"

log(){ echo -e ">> $*" >&2; }
die(){ echo -e "error: $*" >&2; exit 1; }
confirm(){ read -rp "$1 [y/N]: " a </dev/tty || true; case "$a" in [yY]*) ;; *) die "aborted";; esac; }
kc(){ kubectl -n "$NS" "$@"; }

# derive a value from the old .env (strips surrounding quotes)
envval(){ grep -m1 "^$1=" "$OLD_ENV" | cut -d= -f2- | tr -d '\042\047'; }

# --- preflight ---------------------------------------------------------------
preflight(){
  log "PREFLIGHT for ${PROJECT} (ns=${NS}, release=${REL})"
  [ -f "$OLD_ENV" ] || die "old .env not found at $OLD_ENV"
  [ -d "$OLD_PG" ]  || die "old PG volume not found at $OLD_PG"
  [ -d "$OLD_S3" ]  || die "old S3 volume not found at $OLD_S3"
  [ -f "$CHART_TGZ" ] || die "chart tgz not found at $CHART_TGZ"
  findmnt /mnt/inspect -o OPTIONS | grep -q '\bro\b' || die "/mnt/inspect is NOT read-only — refuse to run"
  : "${GHCR_USER:?set GHCR_USER}" "${GHCR_PAT:?set GHCR_PAT}" "${ZITADEL_ACCESS_TOKEN:?set ZITADEL_ACCESS_TOKEN}"
  FRONTEND_HOST="$(envval INTRIC_FRONTEND_HOST)"; [ -n "$FRONTEND_HOST" ] || die "INTRIC_FRONTEND_HOST missing in .env"
  BACKEND_HOST="$(envval INTRIC_BACKEND_HOST)";   [ -n "$BACKEND_HOST" ]  || die "INTRIC_BACKEND_HOST missing in .env"
  ZITADEL_URL="$(envval ZITADEL_ENDPOINT)";       ZITADEL_URL="${ZITADEL_URL:-https://login.intric.ai}"
  ZITADEL_CLIENT_ID="$(envval ZITADEL_PROJECT_CLIENT_ID)"; [ -n "$ZITADEL_CLIENT_ID" ] || die "ZITADEL_PROJECT_CLIENT_ID missing"
  ZITADEL_PROJECT_ID="$(envval ZITADEL_PROJECT_ID)";       [ -n "$ZITADEL_PROJECT_ID" ] || die "ZITADEL_PROJECT_ID missing"
  S3_BUCKET="$(envval S3_BUCKET_NAME)";           S3_BUCKET="${S3_BUCKET:-$PROJECT}"
  log "  frontend=$FRONTEND_HOST backend=$BACKEND_HOST zitadel=$ZITADEL_URL client=$ZITADEL_CLIENT_ID bucket=$S3_BUCKET"
  log "PREFLIGHT OK"
}

# --- namespace + CA bundle + secrets -----------------------------------------
prep_namespace(){
  log "namespace + CA bundle + secrets"
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
  kc get configmap intric-ca-bundle >/dev/null 2>&1 || \
    kc create configmap intric-ca-bundle --from-file=ca-bundle.crt="$CA_BUNDLE_HOST"

  kc get secret ghcr-pull >/dev/null 2>&1 || \
    kc create secret docker-registry ghcr-pull --docker-server=ghcr.io \
      --docker-username="$GHCR_USER" --docker-password="$GHCR_PAT"

  kc get secret "${REL}-zitadel" >/dev/null 2>&1 || \
    kc create secret generic "${REL}-zitadel" --from-literal=access-token="$ZITADEL_ACCESS_TOKEN"

  # whole old .env (quote-stripped, de-duped) -> extraEnvVarsSecret
  local tmp; tmp="$(mktemp)"
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$OLD_ENV" | tr -d '\042\047' | awk -F= '!seen[$1]++' > "$tmp"
  kc get secret "${REL}-env" >/dev/null 2>&1 || kc create secret generic "${REL}-env" --from-env-file="$tmp"

  # carried app keys + generated microservice jwt
  if ! kc get secret "${REL}-intric-app" >/dev/null 2>&1; then
    kc create secret generic "${REL}-intric-app" \
      --from-literal=URL_SIGNING_KEY="$(grep -m1 '^URL_SIGNING_KEY=' "$tmp" | cut -d= -f2-)" \
      --from-literal=INTRIC_SUPER_API_KEY="$(grep -m1 '^INTRIC_SUPER_API_KEY=' "$tmp" | cut -d= -f2-)" \
      --from-literal=MICROSERVICE_JWT_SECRET="$(openssl rand -hex 32)"
  fi
  rm -f "$tmp"
  log "secrets ready: ghcr-pull, ${REL}-zitadel, ${REL}-env, ${REL}-intric-app"
}

# --- render values + helm install --------------------------------------------
install_chart(){
  local vals="/mnt/sandisk/${PROJECT}-values.yaml"
  cat > "$vals" <<EOF
global:
  proxy: { httpProxy: "$PROXY", httpsProxy: "$PROXY", noProxy: "$NO_PROXY_VAL" }
  caBundle: { configMapName: "intric-ca-bundle", key: "ca-bundle.crt" }
intricImagePullCredentials: { existingSecret: "ghcr-pull" }
intricApp: { auth: { existingSecret: "${REL}-intric-app" } }
intricBackendApiServer:
  logLevel: INFO
  cors: { allowAll: true }
  extraEnvVarsSecret: "${REL}-env"
  extraEnv:
    - { name: S3_BUCKET_NAME, value: "$S3_BUCKET" }
# Frontend Node 24: undici honors HTTP(S)_PROXY only with NODE_USE_ENV_PROXY=1 (else SSR->Zitadel times out, 500).
# ORIGIN: TLS terminated at upstream LB (Traefik sees http) -> SvelteKit would build an http:// redirect_uri
# that Zitadel rejects. Force the public https origin so redirect_uri matches the registered one.
intricFrontendApp:
  extraEnv:
    - { name: NODE_USE_ENV_PROXY, value: "1" }
    - { name: ORIGIN, value: "https://${FRONTEND_HOST}" }
postgresql: { enabled: true, auth: { username: "postgres", database: "postgres" }, persistence: { size: 20Gi } }
s3: { enabled: true, persistence: { size: 20Gi } }
redis: { enabled: true }
weaviate: { enabled: false }
zitadel:
  enabled: false
  external:
    instanceUrl: "$ZITADEL_URL"
    projectClientId: "$ZITADEL_CLIENT_ID"
    projectId: "$ZITADEL_PROJECT_ID"
    auth: { existingSecret: "${REL}-zitadel" }
zitadelBootstrap: { enabled: false }
encryptionKeys: { existingSecret: "" }
ingress:
  enabled: true
  className: traefik
  frontendHost: "$FRONTEND_HOST"
  backendHost: "$BACKEND_HOST"
  zitadelHost: "zitadel-unused.$FRONTEND_HOST"
EOF
  log "rendered $vals"
  helm status "$REL" -n "$NS" >/dev/null 2>&1 \
    && { log "release exists; upgrading"; helm upgrade "$REL" "$CHART_TGZ" -n "$NS" -f "$vals"; } \
    || helm install "$REL" "$CHART_TGZ" -n "$NS" -f "$vals"
  log "waiting for stateful + app components to be Ready..."
  kc rollout status statefulset/${REL}-postgresql --timeout=300s
  kc rollout status statefulset/${REL}-redis --timeout=300s
  kc rollout status statefulset/${REL}-s3 --timeout=300s
  kc rollout status deploy/${REL}-intric-backend-api-server --timeout=300s
  kc rollout status deploy/${REL}-intric-backend-worker --timeout=300s
  kc rollout status deploy/${REL}-intric-frontend-app --timeout=300s
  # Ignore Terminating (old pods being cleaned up after a rollout restart) and Completed (jobs).
  local notready; notready="$(kc get pods --no-headers | grep -vE 'Running|Completed|Terminating' || true)"
  [ -z "$notready" ] || die "install gate: pods not healthy:\n$notready"
  log "INSTALL GATE OK: all components Ready"
}

# --- Postgres: dump source (offline copy) + restore into chart PG ------------
migrate_db(){
  log "copying old PG data (read-only source) -> $WORK_PG"
  [ -d "$WORK_PG" ] || { cp -a "$OLD_PG" "$WORK_PG"; chcon -R -t container_file_t "$WORK_PG"; }

  log "starting throwaway source-pg on the copy"
  kc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: source-pg, labels: { app: source-pg } }
spec:
  restartPolicy: Never
  securityContext: { runAsUser: 999, runAsGroup: 999 }
  containers:
    - name: pg
      image: ${SRC_PG_IMAGE}
      args: ["postgres"]
      env: [ { name: POSTGRES_PASSWORD, value: "unused-existing-data" } ]
      volumeMounts: [ { name: data, mountPath: /var/lib/postgresql/data } ]
  volumes:
    - name: data
      hostPath: { path: ${WORK_PG}, type: Directory }
YAML
  kc wait --for=condition=Ready pod/source-pg --timeout=180s
  log "source baseline:"
  kc exec source-pg -- psql -U postgres -d postgres -c \
    "select (select version_num from alembic_version) as alembic, (select count(*) from information_schema.tables where table_schema='public') as tbls;"

  log "pg_dump -> $DUMP"
  kc exec source-pg -- pg_dump -Fc -U postgres -d postgres > "$DUMP"
  chcon -t container_file_t "$DUMP"
  log "dump size: $(du -h "$DUMP" | cut -f1)"

  log "quiescing backend + worker"
  kc scale deploy ${REL}-intric-backend-api-server ${REL}-intric-backend-worker --replicas=0

  log "restoring into ${REL}-postgresql (DROP schema public, then pg_restore)"
  confirm "  proceed with restore (destroys the empty target schema)?"
  kc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: pg-restore }
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: ${SRC_PG_IMAGE}
      env:
        - { name: PGHOST, value: ${REL}-postgresql }
        - { name: PGUSER, value: postgres }
        - { name: PGDATABASE, value: postgres }
        - name: PGPASSWORD
          valueFrom: { secretKeyRef: { name: ${REL}-postgresql-auth, key: password } }
      command: ["bash","-c"]
      args:
        - |
          set -e
          until pg_isready -q; do sleep 2; done
          psql -c "CREATE ROLE intric_app LOGIN;" || echo "role exists"
          psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public AUTHORIZATION postgres;"
          pg_restore -v -j 4 --no-owner -d "\$PGDATABASE" /dump/${PROJECT}.dump
          echo RESTORE_DONE
      volumeMounts: [ { name: dump, mountPath: /dump/${PROJECT}.dump } ]
  volumes:
    - name: dump
      hostPath: { path: ${DUMP}, type: File }
YAML
  kc wait --for=condition=Ready pod/pg-restore --timeout=60s 2>/dev/null || true
  log "restore running; following logs to RESTORE_DONE..."
  kc logs -f pg-restore || true
  kc get pod pg-restore -o jsonpath='{.status.phase}' | grep -q Succeeded || die "pg-restore did not succeed — inspect: kubectl -n $NS logs pg-restore"

  log "scaling backend up -> Alembic migrates forward to chart version"
  kc scale deploy ${REL}-intric-backend-api-server --replicas=1
  kc rollout status deploy/${REL}-intric-backend-api-server --timeout=600s
  kc scale deploy ${REL}-intric-backend-worker --replicas=1
  kc rollout status deploy/${REL}-intric-backend-worker --timeout=300s

  # INTEGRITY GATE: compare migrated target vs the still-running source-pg (original data).
  # info_blobs (knowledge) must match exactly; files must be >= source (backend may add 1 default file).
  log "DB integrity gate: source-pg vs target row counts"
  local src_f src_ib tgt_f tgt_ib
  src_f="$(kc exec source-pg -- psql -U postgres -d postgres -tAc 'select count(*) from files' | tr -dc 0-9)"
  src_ib="$(kc exec source-pg -- psql -U postgres -d postgres -tAc 'select count(*) from info_blobs' | tr -dc 0-9)"
  tgt_f="$(kc exec ${REL}-postgresql-0 -- psql -U postgres -d postgres -tAc 'select count(*) from files' | tr -dc 0-9)"
  tgt_ib="$(kc exec ${REL}-postgresql-0 -- psql -U postgres -d postgres -tAc 'select count(*) from info_blobs' | tr -dc 0-9)"
  log "  files: source=$src_f target=$tgt_f | info_blobs: source=$src_ib target=$tgt_ib"
  [ -n "$src_ib" ] && [ "$src_ib" = "$tgt_ib" ] || die "info_blobs mismatch (source=$src_ib target=$tgt_ib) — STOP, investigate"
  [ -n "$src_f" ] && [ "${tgt_f:-0}" -ge "$src_f" ] 2>/dev/null || die "files regressed (source=$src_f target=$tgt_f) — STOP, investigate"
  log "DB INTEGRITY GATE OK (info_blobs match; files >= source)"
  log "DB migration complete"
}

# --- S3: mirror old bucket -> chart RustFS (preserve keys) -------------------
# VALIDATED on canary: source RustFS (matching version) serves the copy; mc mirror over S3 API.
# Target object count must equal the source file count (canary: 1643 = 1643).
migrate_s3(){
  log "copying old S3 data (read-only source) -> $WORK_S3"
  [ -d "$WORK_S3" ] || { cp -a "$OLD_S3" "$WORK_S3"; chcon -R -t container_file_t "$WORK_S3"; }

  log "starting throwaway source-rustfs (matching version) on the copy"
  kc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: source-rustfs, labels: { app: source-rustfs } }
spec:
  restartPolicy: Never
  securityContext: { runAsUser: 0 }
  containers:
    - name: rustfs
      image: ${SRC_S3_IMAGE}
      env:
        - { name: RUSTFS_ACCESS_KEY, valueFrom: { secretKeyRef: { name: ${REL}-env, key: S3_ACCESS_KEY_ID } } }
        - { name: RUSTFS_SECRET_KEY, valueFrom: { secretKeyRef: { name: ${REL}-env, key: S3_SECRET_ACCESS_KEY } } }
      ports: [ { containerPort: 9000 } ]
      volumeMounts: [ { name: data, mountPath: /data } ]
  volumes:
    - name: data
      hostPath: { path: ${WORK_S3}, type: Directory }
---
apiVersion: v1
kind: Service
metadata: { name: source-rustfs }
spec:
  selector: { app: source-rustfs }
  ports: [ { port: 9000, targetPort: 9000 } ]
YAML
  kc wait --for=condition=Ready pod/source-rustfs --timeout=120s

  log "mc mirror (source-rustfs -> ${REL}-s3) bucket ${S3_BUCKET}"
  kc delete pod mc-mirror --ignore-not-found
  kc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: mc-mirror }
spec:
  restartPolicy: Never
  containers:
    - name: mc
      image: ${MC_IMAGE}
      env:
        - { name: SRC_AK, valueFrom: { secretKeyRef: { name: ${REL}-env, key: S3_ACCESS_KEY_ID } } }
        - { name: SRC_SK, valueFrom: { secretKeyRef: { name: ${REL}-env, key: S3_SECRET_ACCESS_KEY } } }
        - { name: DST_AK, valueFrom: { secretKeyRef: { name: ${REL}-s3-auth, key: access-key } } }
        - { name: DST_SK, valueFrom: { secretKeyRef: { name: ${REL}-s3-auth, key: secret-key } } }
      command: ["sh","-c"]
      args:
        - |
          set -e
          mc alias set src http://source-rustfs:9000 "\$SRC_AK" "\$SRC_SK"
          mc alias set dst http://${REL}-s3:9000 "\$DST_AK" "\$DST_SK"
          echo "SOURCE objects: \$(mc ls --recursive src/${S3_BUCKET} | wc -l)"
          mc mirror --overwrite src/${S3_BUCKET} dst/${S3_BUCKET}
          echo "TARGET objects: \$(mc ls --recursive dst/${S3_BUCKET} | wc -l)"
          echo MIRROR_DONE
YAML
  kc wait --for=condition=Ready pod/mc-mirror --timeout=60s 2>/dev/null || true
  kc logs -f mc-mirror || true
  kc get pod mc-mirror -o jsonpath='{.status.phase}' | grep -q Succeeded || die "mc-mirror did not succeed"

  # INTEGRITY GATE: source and target object counts (parsed from the mirror pod's own output) must match.
  local srcn tgtn
  srcn="$(kc logs mc-mirror | awk -F': ' '/^SOURCE objects:/{print $2}' | tr -dc 0-9)"
  tgtn="$(kc logs mc-mirror | awk -F': ' '/^TARGET objects:/{print $2}' | tr -dc 0-9)"
  log "S3 integrity gate: source=$srcn target=$tgtn"
  [ -n "$srcn" ] && [ "$srcn" = "$tgtn" ] || die "S3 object count mismatch (source=$srcn target=$tgtn) — STOP, investigate"
  log "S3 INTEGRITY GATE OK ($tgtn objects mirrored)"
}

# --- verify ------------------------------------------------------------------
verify(){
  log "VERIFY (post-migration; note: table count + alembic CHANGE by design after migrate-forward;"
  log "        row counts of preserved data like files must match the source baseline)"
  kc exec ${REL}-postgresql-0 -- psql -U postgres -d postgres -c \
    "select (select count(*) from files) as files, (select version_num from alembic_version) as alembic, (select count(*) from information_schema.tables where table_schema='public') as tbls;"
  kc get pods
  echo "  S3 objects in target bucket:" >&2
  log "Manual checks: log in at https://${FRONTEND_HOST}, open a migrated document (PG meta + S3 blob), run a chat."
}

# --- cleanup temp migration resources (after sign-off) -----------------------
cleanup(){
  log "cleaning up temp migration pods/services and copies"
  kc delete pod source-pg pg-restore source-rustfs --ignore-not-found
  kc delete svc source-rustfs --ignore-not-found
  confirm "  also remove on-disk copies ($WORK_PG, $WORK_S3, $DUMP)?"
  rm -rf "$WORK_PG" "$WORK_S3" "$DUMP"
}

case "${2:-all}" in
  preflight)  preflight ;;
  prep)       preflight; prep_namespace ;;
  install)    preflight; prep_namespace; install_chart ;;
  db)         preflight; migrate_db ;;
  s3)         preflight; migrate_s3 ;;
  verify)     preflight; verify ;;
  cleanup)    cleanup ;;
  all)        preflight; prep_namespace; install_chart; migrate_db; migrate_s3; verify ;;
  *) die "unknown stage: ${2}. Use: preflight|prep|install|db|s3|verify|cleanup|all" ;;
esac
