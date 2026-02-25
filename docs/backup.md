# Backup & Disaster Recovery — tunenumbers.de

## Overview

Daily encrypted backups via **restic** run as a host-level systemd timer on
the VPS, independent of the k3s cluster health. All critical data is stored
offsite in a configurable restic backend (Hetzner Storage Box, S3, etc.).

**Target RTO (Recovery Time Objective): < 2 hours** on a fresh VPS.
**RPO (Recovery Point Objective): 24 hours** (last nightly backup).

---

## What is backed up

| Component | Source on Host | restic tag | Frequency |
|-----------|---------------|------------|-----------|
| PostgreSQL | `pg_dump` via kubectl | `postgresql` | Daily |
| MinIO | `/data/minio` | `minio` | Daily |
| Gitea | `/data/gitea` | `gitea` | Daily |
| k3s state | `/var/lib/rancher/k3s/server/db` + `tls/` | `k3s` | Daily |
| k8s Secrets | `kubectl get secrets` (all namespaces) | `secrets` | Daily |

**Not backed up (ephemeral by design):**
- Prometheus metrics (14-day retention, re-scrapes on restart)
- Loki logs (7-day retention, new logs collected on restart)
- Grafana state (re-provisioned from ConfigMaps on restart)
- CrowdSec CAPI bans (re-synced from community feed on restart)

---

## Retention policy

| Window | Snapshots kept |
|--------|----------------|
| Daily | 7 |
| Weekly | 4 |
| Monthly | 3 |

---

## Setup

### Prerequisites

Add backup credentials to `ansible/vars/secrets.yml` (never commit this file):

```yaml
# ── Backup (restic) ──────────────────────────────────────────────────────────
# Hetzner Storage Box (SFTP) example:
backup_restic_repository: "sftp:u123456@u123456.your-storagebox.de:/tunenumbers"
# Hetzner Object Storage (S3) example:
# backup_restic_repository: "s3:https://fsn1.your-objectstorage.com/my-bucket"
backup_restic_password: "CHANGE_ME_STRONG_RANDOM_PASSWORD"
# Optional extra env vars (for S3 or custom SFTP):
backup_restic_env_extra: |
  # AWS_ACCESS_KEY_ID="..."
  # AWS_SECRET_ACCESS_KEY="..."
```

For a **Hetzner Storage Box** (recommended):
1. Order a Storage Box at console.hetzner.com
2. Enable SFTP access in the Storage Box settings
3. Add the VPS's root SSH key to the Storage Box authorized keys
4. Use `sftp:u123456@u123456.your-storagebox.de:/tunenumbers` as the repository

For **S3-compatible storage** (Hetzner Object Storage):
1. Create a bucket
2. Create S3 credentials (access key + secret key)
3. Add `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` to `backup_restic_env_extra`

### Deploy

```bash
ansible-playbook ansible/playbooks/11-backup-setup.yml
```

This installs restic, creates the systemd timer, initializes the repository,
and runs the first backup.

---

## Daily operations

All restic commands need the credentials. On the VPS as root:

```bash
source /etc/backup/env   # loads RESTIC_REPOSITORY and RESTIC_PASSWORD
```

Or prefix each command: `source /etc/backup/env && restic <command>`

### Check backup status

```bash
# Next scheduled run
systemctl status backup.timer

# Last run result
systemctl status backup.service

# Full logs from last run
journalctl -u backup.service -n 50 --no-pager

# Watch a running backup
journalctl -u backup.service -f
```

### Trigger a manual backup

```bash
systemctl start backup.service
journalctl -u backup.service -f
```

### List snapshots

```bash
source /etc/backup/env

# All snapshots
restic snapshots

# Snapshots for a specific component
restic snapshots --tag postgresql
restic snapshots --tag minio
restic snapshots --tag gitea

# Latest snapshot details
restic snapshots --tag postgresql --latest 1
```

### Verify backup integrity

```bash
source /etc/backup/env

# Quick check (metadata + spot-checks 5% of data)
restic check --read-data-subset=5%

# Full data verification (slow, run monthly)
restic check --read-data
```

---

## Restore — individual components

### PostgreSQL

```bash
source /etc/backup/env

# 1. Restore the dump file from restic to a temp location
restic restore latest --tag postgresql --target /tmp/pg-restore

# 2. The dump is at /tmp/pg-restore/postgresql-directus.dump
# 3. Scale down Directus (it writes to PostgreSQL)
kubectl scale deployment directus -n tunenumbers --replicas=0

# 4. Drop and recreate the database
kubectl exec -n tunenumbers deployment/postgresql -- \
  sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" psql -U directus -c "DROP DATABASE IF EXISTS directus; CREATE DATABASE directus;"'

# 5. Restore from dump
cat /tmp/pg-restore/postgresql-directus.dump \
  | kubectl exec -i -n tunenumbers deployment/postgresql -- \
      sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore -U directus -d directus'

# 6. Bring Directus back
kubectl scale deployment directus -n tunenumbers --replicas=1

# 7. Verify
kubectl exec -n tunenumbers deployment/postgresql -- \
  sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" psql -U directus -c "\dt"'

# Cleanup
rm -rf /tmp/pg-restore
```

### MinIO

```bash
source /etc/backup/env

# 1. Scale down MinIO
kubectl scale deployment minio -n tunenumbers --replicas=0

# 2. Clear current data
rm -rf /data/minio/*

# 3. Restore
restic restore latest --tag minio --target /

# 4. Start MinIO
kubectl scale deployment minio -n tunenumbers --replicas=1

# 5. Verify (access MinIO console or check via Directus)
```

### Gitea

```bash
source /etc/backup/env

# 1. Scale down Gitea and its runner
kubectl scale deployment gitea -n gitea --replicas=0
kubectl scale deployment gitea-runner -n gitea --replicas=0

# 2. Clear current data
rm -rf /data/gitea/*

# 3. Restore
restic restore latest --tag gitea --target /

# 4. Fix ownership (Gitea runs as uid 1000)
chown -R 1000:1000 /data/gitea

# 5. Start Gitea
kubectl scale deployment gitea -n gitea --replicas=1
kubectl scale deployment gitea-runner -n gitea --replicas=1

# 6. Verify
curl -s https://git.tunenumbers.de | grep -i gitea
```

### k8s Secrets

```bash
source /etc/backup/env

# Restore the secrets YAML
restic restore latest --tag secrets --target /tmp/secrets-restore

# Apply to cluster (review the file first!)
kubectl apply -f /tmp/secrets-restore/k8s-secrets.yaml

rm -rf /tmp/secrets-restore
```

---

## Disaster Recovery — full cluster rebuild

Use this procedure when the VPS is lost or unrecoverable.

**Time estimate: 60–90 minutes**

### Step 1 — Provision new VPS

- Provision on Hetzner Cloud, same region, same size (CX21 or larger)
- Install SSH key, configure WireGuard tunnel
- Verify: `ssh root@<new-ip>` and `ssh root@10.0.0.2` (via WireGuard)

### Step 2 — Restore GitHub Secrets

- Open your password manager where GitHub Secrets are stored
- In the GitHub repository → Settings → Secrets and variables → Actions
- Re-enter all secrets:

  ```
  LETSENCRYPT_EMAIL       PG_PASSWORD
  MINIO_ROOT_USER         MINIO_ROOT_PASSWORD
  DIRECTUS_ADMIN_EMAIL    DIRECTUS_ADMIN_PASSWORD    DIRECTUS_SECRET
  GITEA_ADMIN_USER        GITEA_ADMIN_PASSWORD       GITEA_ADMIN_EMAIL
  DOCKER_CONFIG_JSON      GITEA_TOKEN                GITEA_USERNAME
  DIRECTUS_URL            DIRECTUS_STATIC_TOKEN
  ```

  Also restore the backup secrets:
  ```
  BACKUP_RESTIC_REPOSITORY    BACKUP_RESTIC_PASSWORD    BACKUP_RESTIC_ENV_EXTRA
  ```

### Step 3 — Bootstrap k3s and namespaces

Run phases 1–3 from Ansible (these create the cluster and storage directories):

```bash
# On your local machine or the new VPS (adjust KUBECONFIG if running locally)
ansible-playbook ansible/playbooks/01-k3s.yml
ansible-playbook ansible/playbooks/02-cert-manager.yml
ansible-playbook ansible/playbooks/03-namespaces-storage.yml
```

This creates `/data/postgresql`, `/data/minio`, `/data/gitea` as empty directories.

### Step 4 — Restore data from restic

On the new VPS (as root), install restic and configure credentials:

```bash
# Install restic
curl -fsSL https://github.com/restic/restic/releases/latest/download/restic_linux_amd64.bz2 \
  | bunzip2 > /usr/local/bin/restic && chmod +x /usr/local/bin/restic

# Configure credentials
mkdir -p /etc/backup && chmod 700 /etc/backup
cat > /etc/backup/env << 'EOF'
RESTIC_REPOSITORY="<your-repository>"
RESTIC_PASSWORD="<your-password>"
# add any extra vars (S3 keys, etc.)
EOF
chmod 600 /etc/backup/env
source /etc/backup/env
```

Restore all data volumes:

```bash
source /etc/backup/env

# PostgreSQL dump
restic restore latest --tag postgresql --target /tmp/pg-restore

# MinIO
restic restore latest --tag minio --target /

# Gitea (restore then fix ownership)
restic restore latest --tag gitea --target /
chown -R 1000:1000 /data/gitea
```

### Step 5 — Deploy all services

```bash
# Run phases 4–10 (services deploy against the restored data)
ansible-playbook ansible/playbooks/04-postgresql.yml
```

Wait for PostgreSQL to be ready, then restore the database dump:

```bash
kubectl exec -n tunenumbers deployment/postgresql -- \
  sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" psql -U directus -c "DROP DATABASE IF EXISTS directus; CREATE DATABASE directus;"'

cat /tmp/pg-restore/postgresql-directus.dump \
  | kubectl exec -i -n tunenumbers deployment/postgresql -- \
      sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore -U directus -d directus'

rm -rf /tmp/pg-restore
```

Then run the remaining phases:

```bash
ansible-playbook ansible/playbooks/05-minio.yml
ansible-playbook ansible/playbooks/06-directus.yml
# Skip 06b (schema is in the restored database)
ansible-playbook ansible/playbooks/07-gitea.yml
ansible-playbook ansible/playbooks/08-astro.yml
ansible-playbook ansible/playbooks/09-monitoring.yml
ansible-playbook ansible/playbooks/10-brute-force-protection.yml
ansible-playbook ansible/playbooks/11-backup-setup.yml
```

### Step 6 — Restore k8s secrets (if needed)

```bash
source /etc/backup/env
restic restore latest --tag secrets --target /tmp/secrets-restore
# Review the file, then apply selectively or fully:
kubectl apply -f /tmp/secrets-restore/k8s-secrets.yaml
rm -rf /tmp/secrets-restore
```

### Step 7 — Verify

```bash
kubectl get pods -A                        # all pods Running
curl -I https://tunenumbers.de             # frontend up
curl -I https://cms.tunenumbers.de         # Directus up
curl -I https://git.tunenumbers.de         # Gitea up
curl -I https://monitoring.tunenumbers.de  # Grafana up
```

### Step 8 — Update DNS (if IP changed)

If the new VPS has a different public IP:
- Update the A records for `tunenumbers.de` and all subdomains
- **Recommendation:** Use a Hetzner Floating IP so the IP is preserved across
  VPS replacements and this step is unnecessary.

---

## Reboot behaviour

k3s starts automatically on reboot via systemd. All pods respawn with their
persistent volumes still attached. No manual intervention is required.

**Expected startup sequence and timing after a clean reboot:**

| Time | Event |
|------|-------|
| 0s | VPS kernel boots |
| ~15s | k3s service starts |
| ~30s | k3s node reaches Ready, kube-system pods start (Traefik, CoreDNS) |
| ~45s | PostgreSQL pod starts and passes readiness probe |
| ~60s | MinIO, Gitea, Directus pods start |
| ~90s | Monitoring stack (Prometheus, Loki, Grafana, Alloy) starts |
| ~120s | CrowdSec LAPI + agent start, bouncer re-registers with Traefik |
| ~180s | All services healthy, external traffic accepted |

> Traefik reloads its Let's Encrypt certificates from disk on startup —
> no certificate renewal is triggered by a reboot.

**Verify after reboot:**
```bash
kubectl get pods -A
kubectl get nodes
```

---

## Multi-node guidance

### Current state (single server node)

All persistent data (`/data/postgresql`, `/data/minio`, `/data/gitea`) lives on
the server node. The backup timer runs on the server. No changes needed.

### When adding worker nodes

> **Do this BEFORE joining any worker to the cluster:**

Pin all data-bearing pods to the server node so they cannot migrate to workers:

```yaml
# Add to k8s-manifests/postgresql/deployment.yml,
#       k8s-manifests/minio/deployment.yml,
#       k8s-manifests/gitea/deployment.yml

spec:
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/master: "true"
```

Apply and verify before joining workers:

```bash
kubectl apply -f k8s-manifests/postgresql/deployment.yml
kubectl apply -f k8s-manifests/minio/deployment.yml
kubectl apply -f k8s-manifests/gitea/deployment.yml

# Confirm pods are still on server node
kubectl get pods -n tunenumbers -o wide
kubectl get pods -n gitea -o wide
```

Stateless pods (Astro, Directus, monitoring) can run on workers freely.

**Joining a worker node:**

```bash
# On the server node — get the join token
cat /var/lib/rancher/k3s/server/node-token

# On the worker node
curl -sfL https://get.k3s.io | K3S_URL=https://10.0.0.2:6443 \
  K3S_TOKEN=<token-from-above> sh -
```

After joining, document the worker node's WireGuard IP and hostname in
`ansible/vars/main.yml` for future reference.

### When moving to distributed storage (Longhorn)

When Longhorn is added:
1. Create Longhorn PVCs for PostgreSQL, MinIO, Gitea
2. Migrate data (scale down → copy → scale up on Longhorn PVC)
3. Enable Longhorn's built-in backup to S3
4. Remove `/data/*` hostPath PVs and PVCs
5. Update the backup script: remove the `/data/*` restic steps;
   keep PostgreSQL pg_dump, k3s state, and secrets backups

---

## Key files

| File | Purpose |
|------|---------|
| `/opt/backup/backup.sh` | Backup script (deployed by Ansible) |
| `/etc/backup/env` | Credentials (root-only, not in git) |
| `/etc/systemd/system/backup.service` | Systemd service unit |
| `/etc/systemd/system/backup.timer` | Systemd timer (daily 02:00 UTC) |
| `ansible/playbooks/11-backup-setup.yml` | Ansible playbook to (re)deploy backup |
| `scripts/backup/backup.sh` | Source for the backup script (in git) |
