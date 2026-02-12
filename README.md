# tunenumbers-infra

Infrastructure-as-Code for **tunenumbers.de** — deploys the full stack onto a single K3s node using Ansible and Kubernetes manifests.

## Stack

| Service    | Subdomain              | Purpose                        |
|------------|------------------------|--------------------------------|
| Astro SSR  | tunenumbers.de         | Frontend                       |
| Directus   | cms.tunenumbers.de     | Headless CMS                   |
| MinIO      | s3.tunenumbers.de      | S3-compatible object storage   |
| Gitea      | git.tunenumbers.de     | Git hosting + CI/CD            |
| PostgreSQL | (internal)             | Database for Directus & Gitea  |

## Prerequisites

- **Ansible** >= 2.14 installed locally
- **SSH access** to the target server (key-based)
- A server running Ubuntu 22.04+ or Debian 12+

## Deployment Phases

| # | Playbook                   | What it does                                  |
|---|----------------------------|-----------------------------------------------|
| 1 | `01-k3s.yml`              | Install K3s                                   |
| 2 | `02-cert-manager.yml`     | Install cert-manager + ClusterIssuer          |
| 3 | `03-namespaces-storage.yml` | Create namespaces, PVs, PVCs                |
| 4 | `04-postgresql.yml`       | Deploy PostgreSQL                             |
| 5 | `05-minio.yml`            | Deploy MinIO + init bucket                    |
| 6 | `06-directus.yml`         | Deploy Directus                               |
| 6b| `06b-directus-schema.yml` | Apply Directus schema                         |
| 7 | `07-gitea.yml`            | Deploy Gitea + Actions runner                 |
| 8 | `08-astro.yml`            | Deploy Astro frontend                         |

## Quick Start

```bash
# 1. Copy and fill in secrets
cp ansible/vars/secrets.yml.example ansible/vars/secrets.yml
# Edit secrets.yml with real values, then encrypt:
ansible-vault encrypt ansible/vars/secrets.yml

# 2. Set server connection (or edit inventory/hosts.yml directly)
export SERVER_IP=your.server.ip
export SERVER_USER=deploy

# 3. Run full deployment
cd ansible
ansible-playbook playbooks/site.yml --ask-vault-pass
```

## GitHub Secrets

For CI/CD via GitHub Actions, configure these repository secrets:

| Secret                  | Description                          |
|-------------------------|--------------------------------------|
| `SERVER_IP`             | Target server IP address             |
| `SERVER_USER`           | SSH user on the server               |
| `SSH_PRIVATE_KEY`       | Private SSH key for authentication   |
| `ANSIBLE_VAULT_PASSWORD`| Password to decrypt secrets.yml      |
