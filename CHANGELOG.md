# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Gitea**: Upgrade 1.26.2 → 1.27.2 — fixes CVE-2026-60004 (CVSS 9.8, CISA KEV,
  actively exploited): unauthenticated RCE via the diffpatch API through Git hook
  installation, affecting 1.17 up to < 1.27.1

### Bugfixes

- **Gitea**: Add `GITEA__security__REVERSE_PROXY_TRUSTED_PROXIES` to the deployment —
  was applied manually in-cluster but missing from the manifest, so any `kubectl apply`
  would drop it and break real client-IP resolution for CrowdSec and rate limiting
- **CrowdSec**: `Deploy CrowdSec / Brute-force Protection` has failed on every run
  since 2026-07-06. Playbook 10 ended with two `helm upgrade --wait --timeout 10m0s`
  calls against Grafana and Prometheus, which cannot succeed while the monitoring
  stack is scaled to zero. Both are now gated behind `monitoring_enabled`

### Changed

- **Monitoring**: Encode the disabled state of the Grafana/Prometheus/Loki/Alloy
  stack in the repo via `monitoring_enabled: false` in `ansible/vars/main.yml`.
  The stack has been off since 2026-07-06 — the grafana, loki and prometheus Helm
  upgrades failed in sequence with `context deadline exceeded` and the workloads
  were then scaled to zero by hand. That decision lived only in the cluster and
  was invisible to the repo, so every deploy tried to undo it. While the flag is
  false, playbook 09 ends immediately and playbook 10 skips its Grafana/Prometheus
  Helm upgrades. Dashboard and alert-rule ConfigMaps are still applied — they are
  inert data and keep the definitions current for a later re-enable.
  The releases `grafana` (rev 47), `loki` (rev 34) and `prometheus` (rev 38)
  remain in Helm status `failed`; the underlying readiness failure was never
  diagnosed and needs to be before the flag is flipped back

## [1.1.0] – 2026-03-05

### Features

- **Umami**: Self-hosted web analytics at stats.tunenumbers.de (replaces custom Directus tracking)

### Bugfixes

- **Grafana**: Fix alert email recipient — add `resetOnStart` to ensure provisioned contact point overwrites stale DB entry

## [1.0.0] – 2026-02-24

### Infrastructure

- **Platform**: Hetzner Cloud VPS, single-node (IP: 49.13.95.244)
- **Kubernetes**: k3s single-node cluster; kubeconfig at `/etc/rancher/k3s/k3s.yaml`
- **Ingress**: Traefik (bundled with k3s) as reverse proxy; all services exposed via
  `IngressRoute` (Traefik CRD); TLS termination at the edge
- **TLS**: cert-manager with Let's Encrypt ACME; `ClusterIssuer` for all subdomains
- **Storage class**: `local-path` (k3s default) for all PVCs; host paths under `/data/`
- **Security**: CrowdSec intrusion-prevention system + Traefik bouncer plugin

### Services

| Service     | Namespace    | Subdomain                  | Internal address                                      |
|-------------|--------------|----------------------------|-------------------------------------------------------|
| Astro SSR   | tunenumbers  | tunenumbers.de             | `astro-frontend.tunenumbers.svc.cluster.local:4321`   |
| Directus    | tunenumbers  | cms.tunenumbers.de         | `directus.tunenumbers.svc.cluster.local:8055`         |
| PostgreSQL  | tunenumbers  | (internal only)            | `postgresql.tunenumbers.svc.cluster.local:5432`       |
| MinIO       | tunenumbers  | s3.tunenumbers.de          | `minio.tunenumbers.svc.cluster.local:9000`            |
| Gitea       | gitea        | git.tunenumbers.de         | `gitea.gitea.svc.cluster.local:3000`                  |

Storage allocations: PostgreSQL 5 Gi (`/data/postgresql`), MinIO 15 Gi (`/data/minio`),
Gitea 5 Gi (`/data/gitea`).

### CI/CD

- **Runner setup**: Two self-hosted GitHub Actions runners running as systemd services
  directly on the VPS — the same host as the k3s cluster. Runner user: `github-runner`.
  Kubeconfig: `/home/github-runner/.kube/config`. No SSH to remote hosts; all operations
  are local.
- **Secrets handling**: `ansible/vars/secrets.yml` is written inline from GitHub Secrets
  at workflow start and removed in an `always:` cleanup step — never committed to the repo.

| Workflow               | Trigger                                          | Purpose                                          |
|------------------------|--------------------------------------------------|--------------------------------------------------|
| `deploy-full.yml`      | `workflow_dispatch`                              | Full Ansible `site.yml` (all phases)             |
| `deploy-manifests.yml` | Push to `main` (`k8s-manifests/**`) or dispatch  | Apply `kubectl` manifests without running Ansible phases |
| `test-runner.yml`      | `workflow_dispatch`                              | Verify runner health, k3s nodes, and cluster state |

### Ansible

All playbooks use `connection: local` — Ansible runs directly on the VPS via the
self-hosted runner, not via SSH to a remote host. Secrets are managed with
`ansible-vault` for local runs; in CI they are injected from GitHub Secrets.

| Playbook                     | Purpose                                                  |
|------------------------------|----------------------------------------------------------|
| `01-k3s.yml`                | Install and configure k3s                                |
| `02-cert-manager.yml`       | Install cert-manager + Let's Encrypt `ClusterIssuer`     |
| `03-namespaces-storage.yml` | Create Kubernetes namespaces, PersistentVolumes, PVCs    |
| `04-postgresql.yml`         | Deploy PostgreSQL (namespace: `tunenumbers`)             |
| `05-minio.yml`              | Deploy MinIO + create initial bucket                     |
| `06-directus.yml`           | Deploy Directus CMS                                      |
| `06b-directus-schema.yml`   | Apply Directus schema / collections                      |
| `07-gitea.yml`              | Deploy Gitea + Gitea Actions runner                      |
| `08-astro.yml`              | Deploy Astro SSR frontend                                |
| `09-crowdsec-traefik.yml`   | Deploy CrowdSec + Traefik bouncer (run separately)       |
| `site.yml`                  | Master playbook — runs phases 01 through 08 in order     |

[1.0.0]: https://github.com/desertsand404/tunenumbers-infra/releases/tag/v1.0.0
