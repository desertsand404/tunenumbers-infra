# tunenumbers-infra

Infrastructure-as-Code for **tunenumbers.de** — deploys the full stack onto a single K3s node using Ansible and Kubernetes manifests.

## Stack

| Service    | Subdomain              | Purpose                        |
|------------|------------------------|--------------------------------|
| Astro SSR  | tunenumbers.de         | Frontend                       |
| Directus   | cms.tunenumbers.de     | Headless CMS                   |
| MinIO      | s3.tunenumbers.de      | S3-compatible object storage   |
| Gitea      | git.tunenumbers.de     | Git hosting + CI/CD            |
| Umami      | stats.tunenumbers.de   | Web Analytics                  |
| PostgreSQL | (internal)             | Database for Directus & Gitea  |

## Prerequisites

- A Hetzner Cloud VPS running Ubuntu 22.04+ or Debian 12+
- Two self-hosted GitHub Actions runners registered and running as systemd services on the VPS
- GitHub repository secrets configured (see [GitHub Secrets](#github-secrets) below)

No local tooling required — Ansible and kubectl run on the VPS via the self-hosted runner.
Ansible is installed automatically by the workflow if not already present.

## Deployment Phases

| # | Playbook                     | What it does                                  |
|---|------------------------------|-----------------------------------------------|
| 1 | `01-k3s.yml`                | Install K3s                                   |
| 2 | `02-cert-manager.yml`       | Install cert-manager + ClusterIssuer          |
| 3 | `03-namespaces-storage.yml` | Create namespaces, PVs, PVCs                  |
| 4 | `04-postgresql.yml`         | Deploy PostgreSQL                             |
| 5 | `05-minio.yml`              | Deploy MinIO + init bucket                    |
| 6 | `06-directus.yml`           | Deploy Directus                               |
| 6b| `06b-directus-schema.yml`   | Apply Directus schema                         |
| 7 | `07-gitea.yml`              | Deploy Gitea + Actions runner                 |
| 8 | `08-astro.yml`              | Deploy Astro frontend                         |
| 9 | `09-crowdsec-traefik.yml`   | Deploy CrowdSec + Traefik bouncer (security)  |
| 12| `12-umami.yml`              | Deploy Umami Analytics                         |

`site.yml` runs phases 1–12 in sequence (except phase 9 which is run separately).

## Quick Start

### Full deployment (via GitHub Actions)

Trigger the **Full Deployment** workflow from the Actions tab:

```
Actions → Full Deployment → Run workflow
```

This runs `ansible-playbook ansible/playbooks/site.yml` on the self-hosted runner.

### Manifests-only deployment

Push changes to `k8s-manifests/**` on `main` — the **Deploy Manifests Only** workflow
triggers automatically and applies the updated manifests via `kubectl`.

### Local run (on the VPS directly)

```bash
# 1. Copy and fill in secrets
cp ansible/vars/secrets.yml.example ansible/vars/secrets.yml
# Edit secrets.yml with real values, then optionally encrypt:
ansible-vault encrypt ansible/vars/secrets.yml

# 2. Run full deployment (from the repo root on the VPS)
ansible-playbook ansible/playbooks/site.yml --ask-vault-pass
```

## GitHub Secrets

Configure these repository secrets for CI/CD:

| Secret                    | Description                                   |
|---------------------------|-----------------------------------------------|
| `LETSENCRYPT_EMAIL`       | Email for Let's Encrypt certificate issuance  |
| `PG_PASSWORD`             | PostgreSQL admin password                     |
| `MINIO_ROOT_USER`         | MinIO root username                           |
| `MINIO_ROOT_PASSWORD`     | MinIO root password                           |
| `DIRECTUS_ADMIN_EMAIL`    | Directus admin email                          |
| `DIRECTUS_ADMIN_PASSWORD` | Directus admin password                       |
| `DIRECTUS_SECRET`         | Directus JWT secret                           |
| `DIRECTUS_URL`            | Directus public URL                           |
| `DIRECTUS_STATIC_TOKEN`   | Directus static API token                     |
| `GITEA_ADMIN_USER`        | Gitea admin username                          |
| `GITEA_ADMIN_PASSWORD`    | Gitea admin password                          |
| `GITEA_ADMIN_EMAIL`       | Gitea admin email                             |
| `GITEA_TOKEN`             | Gitea API token (for registry auth)           |
| `GITEA_USERNAME`          | Gitea username (for registry auth)            |
| `DOCKER_CONFIG_JSON`      | Docker config JSON for Gitea registry pull    |
| `UMAMI_DB_PASSWORD`       | Umami PostgreSQL user password                |
| `UMAMI_APP_SECRET`        | Umami application secret                      |
