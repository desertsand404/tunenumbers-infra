#!/usr/bin/env bash
# /opt/backup/backup.sh — tunenumbers.de backup script
# Deployed by ansible/playbooks/11-backup-setup.yml
# Runs daily via systemd timer (backup.timer)
# Logs go to systemd journal: journalctl -u backup.service

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
ENV_FILE="/etc/backup/env"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
DUMP_DIR="/tmp/backup-$$"
LOG_PREFIX="[backup]"

# ── Load credentials ──────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "$LOG_PREFIX ERROR: credentials file not found: $ENV_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

export RESTIC_REPOSITORY
export RESTIC_PASSWORD
# Optional: S3 / Storage Box environment variables are also sourced from ENV_FILE

export KUBECONFIG

log() { echo "$LOG_PREFIX $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# ── Cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
  rm -rf "$DUMP_DIR"
  log "Temp dir cleaned up."
}
trap cleanup EXIT

mkdir -p "$DUMP_DIR"

# ═════════════════════════════════════════════════════════════════════════════
# Step 1 — PostgreSQL (pg_dump via kubectl exec, piped directly to restic)
# ═════════════════════════════════════════════════════════════════════════════
log "Starting PostgreSQL backup..."

# pg_dump uses the POSTGRES_PASSWORD env var already set inside the container.
# -Fc = custom format (compressed, selective restore possible)
kubectl exec -n tunenumbers deployment/postgresql -- \
  sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump -h 127.0.0.1 -U directus -Fc directus' \
  | restic backup \
      --stdin \
      --stdin-filename "postgresql-directus.dump" \
      --tag postgresql \
      --tag "$(date -u +%Y-%m-%d)"

log "PostgreSQL backup complete."

# ═════════════════════════════════════════════════════════════════════════════
# Step 2 — MinIO object storage (/data/minio)
# ═════════════════════════════════════════════════════════════════════════════
log "Starting MinIO backup..."

restic backup /data/minio \
  --tag minio \
  --tag "$(date -u +%Y-%m-%d)" \
  --exclude "*.tmp"

log "MinIO backup complete."

# ═════════════════════════════════════════════════════════════════════════════
# Step 3 — Gitea (/data/gitea)
# SQLite uses WAL mode — safe to backup while running.
# ═════════════════════════════════════════════════════════════════════════════
log "Starting Gitea backup..."

restic backup /data/gitea \
  --tag gitea \
  --tag "$(date -u +%Y-%m-%d)" \
  --exclude "*.tmp" \
  --exclude "*/log/*.log"

log "Gitea backup complete."

# ═════════════════════════════════════════════════════════════════════════════
# Step 4 — k3s cluster state (SQLite DB + TLS certs)
# Only relevant for fast cluster restore. Not required for full DR
# (k3s can be reinstalled from scratch via Ansible).
# ═════════════════════════════════════════════════════════════════════════════
log "Starting k3s state backup..."

restic backup \
  /var/lib/rancher/k3s/server/db \
  /var/lib/rancher/k3s/server/tls \
  --tag k3s \
  --tag "$(date -u +%Y-%m-%d)" \
  --exclude "*.tmp" \
  --exclude "*.lock" 2>/dev/null || \
  log "WARN: k3s state backup skipped or partial (non-fatal)"

log "k3s state backup complete."

# ═════════════════════════════════════════════════════════════════════════════
# Step 5 — Kubernetes secrets export
# Exports all non-system secrets across critical namespaces.
# restic encrypts the output — safe to store.
# ═════════════════════════════════════════════════════════════════════════════
log "Starting k8s secrets backup..."

{
  for ns in tunenumbers gitea monitoring crowdsec; do
    echo "---"
    echo "# Namespace: $ns"
    kubectl get secrets -n "$ns" \
      --field-selector 'type!=kubernetes.io/service-account-token' \
      -o yaml 2>/dev/null || true
  done
} | restic backup \
      --stdin \
      --stdin-filename "k8s-secrets.yaml" \
      --tag secrets \
      --tag "$(date -u +%Y-%m-%d)"

log "k8s secrets backup complete."

# ═════════════════════════════════════════════════════════════════════════════
# Step 6 — Prune old snapshots (retention policy)
# 7 daily · 4 weekly · 3 monthly
# ═════════════════════════════════════════════════════════════════════════════
log "Running restic forget and prune..."

restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  --prune

log "Prune complete."

# ═════════════════════════════════════════════════════════════════════════════
# Step 7 — Integrity check (quick: spot-checks subset of data)
# ═════════════════════════════════════════════════════════════════════════════
log "Running restic check..."
restic check --read-data-subset=5%

log "Backup run finished successfully."
