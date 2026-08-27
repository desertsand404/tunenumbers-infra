# CLAUDE.md – tunenumbers-infra

Repo-spezifische Details für `tunenumbers-infra/`.
Wird von Claude Code zusätzlich zur `../CLAUDE.md` (Root) gelesen.
Alle Dateien dieses Repos liegen unter `~/tunenumbers/tunenumbers-infra/`.

---

## Repository Overview

Infrastructure-as-Code für tunenumbers.de (Ansible, Helm, k8s Manifests).
Schwester-Repo `tunenumbers-de/` (Astro SSR) nur lesend verwenden.

---

## Deployed Services

| Service        | Namespace    | Subdomain                  | Internal address                                      |
|----------------|--------------|----------------------------|-------------------------------------------------------|
| Astro SSR      | tunenumbers  | tunenumbers.de             | astro-frontend.tunenumbers.svc.cluster.local:4321     |
| Directus CMS   | tunenumbers  | cms.tunenumbers.de         | directus.tunenumbers.svc.cluster.local:8055           |
| PostgreSQL     | tunenumbers  | (internal only)            | postgresql.tunenumbers.svc.cluster.local:5432         |
| MinIO          | tunenumbers  | s3.tunenumbers.de          | minio.tunenumbers.svc.cluster.local:9000              |
| Gitea          | gitea        | git.tunenumbers.de         | gitea.gitea.svc.cluster.local:3000                   |
| Traefik        | kube-system  | (reverse proxy)            | traefik.kube-system.svc.cluster.local                |
| cert-manager   | cert-manager | (internal)                 | –                                                     |

### Monitoring stack — DISABLED

Grafana, Prometheus, Loki and Alloy (namespace `monitoring`) are **switched off**
since 2026-07-06 and the namespace runs zero pods. This is deliberate and is
encoded as `monitoring_enabled: false` in `ansible/vars/main.yml` — read the
comment there before changing anything.

Do not "fix" this by re-running playbook 09 or by scaling the deployments back up.
The three Helm releases are still in status `failed` (`context deadline exceeded`)
and the root cause of the readiness failure was never found. Anything that adds a
`helm upgrade ... --wait` against this namespace must be gated on
`monitoring_enabled`, otherwise it burns a 10-minute timeout and fails the job —
this is exactly what broke the CrowdSec workflow for seven weeks.

---

## Ansible Conventions

### Inventory
- `ansible/inventory/localhost.yml` – single host `localhost` with `ansible_connection: local`
- `ansible/ansible.cfg` – sets inventory, disables host_key_checking, become: true
- All playbooks run **locally on the VPS** (self-hosted runner = same host as k3s)
- **No SSH to remote hosts** – `connection: local` everywhere

### Vars
- `ansible/vars/main.yml` – non-secret config (domain, namespaces, storage paths, resource limits)
- `ansible/vars/secrets.yml` – gitignored, created at runtime in CI from GitHub Secrets
- `ansible/vars/secrets.yml.example` – template, always keep in sync when adding new secrets
- In CI: `secrets.yml` is written inline from `${{ secrets.* }}` and deleted in `always:` step
- Locally: encrypt with `ansible-vault encrypt ansible/vars/secrets.yml`

### Playbook naming
Playbooks are numbered and run in sequence:
  01-k3s.yml, 02-cert-manager.yml, 03-namespaces-storage.yml,
  04-postgresql.yml, 05-minio.yml, 06-directus.yml, 06b-directus-schema.yml,
  07-gitea.yml, 08-astro.yml

New playbooks follow the same pattern: `NN-<component>.yml`.
`site.yml` runs all of them in order.

### kubectl/helm calls in playbooks
Use `ansible.builtin.command` for kubectl/helm.
Use `kubernetes.core.k8s` / `kubernetes.core.helm` for structured tasks.
Always set `environment: KUBECONFIG: "{{ kubeconfig_path }}"` at play level.
`changed_when` must be set explicitly on command tasks.

---

## k8s Manifests Structure

```
k8s-manifests/
├── namespaces.yml
├── storage/
│   ├── pv-<component>.yml
│   └── pvc-<component>.yml
├── postgresql/
│   ├── deployment.yml
│   └── service.yml
├── minio/
│   ├── deployment.yml
│   ├── service.yml
│   ├── ingress.yml
│   └── init-job.yml
├── directus/
│   ├── deployment.yml
│   ├── service.yml
│   └── ingress.yml
├── gitea/
│   ├── deployment.yml
│   ├── service.yml
│   ├── ingress.yml
│   ├── runner-rbac.yml
│   └── runner-deployment.yml
└── astro/
    ├── deployment.yml
    ├── service.yml
    └── ingress.yml
```

Helm-based deployments (cert-manager, monitoring) go under `helm/<component>/`.

---

## Helm Conventions

Values files live in `helm/<component>/<component>-values.yaml`.
Never put secrets in values files – reference existing Kubernetes Secrets.
StorageClass is always `local-path` for PVCs.
All services are `ClusterIP` by default; Traefik IngressRoute handles external access.

---

## Traefik / Ingress

Traefik is installed by k3s. TLS via Let's Encrypt (cert-manager).
App routes (astro, directus, minio, gitea, umami) use standard
`networking.k8s.io/v1 Ingress` with `cert-manager.io/cluster-issuer: letsencrypt-prod`
and `ingressClassName: traefik` — this is the established pattern, keep using it
for new app routes. Grafana is the one exception, using a Traefik `IngressRoute`
(`k8s-manifests/monitoring/grafana-ingressroute.yaml`) — check its apiVersion
before writing new IngressRoutes: `kubectl get ingressroute -A`
(verify between `traefik.io/v1alpha1` and `traefik.containo.us/v1alpha1`).
Every public Ingress should carry the CrowdSec bouncer middleware annotation:
`traefik.ingress.kubernetes.io/router.middlewares: tunenumbers-crowdsec-bouncer@kubernetescrd`

---

## GitHub Actions / CI-CD

### Runners
Two self-hosted runners run as **systemd services directly on the VPS** (same host as k3s).
Runner user: `github-runner`
Runner dir: `/opt/actions-runner`
Kubeconfig for runner: `/home/github-runner/.kube/config`

Always set in workflow jobs:
```yaml
env:
  KUBECONFIG: /home/github-runner/.kube/config
```

### Workflow patterns
| Workflow                  | Trigger                          | Purpose                         |
|---------------------------|----------------------------------|---------------------------------|
| deploy-full.yml           | workflow_dispatch                | Full Ansible site.yml           |
| deploy-manifests.yml      | push to main (k8s-manifests/**) | kubectl apply manifests only    |
| build-push.yml            | push to main (tunenumbers-de)   | Docker build + deploy frontend  |

New monitoring workflow: `deploy-monitoring.yml` triggers on changes to
`helm/monitoring/**`, `kubernetes/monitoring/**`, or its own workflow file.

### Secrets available in GitHub Actions
LETSENCRYPT_EMAIL, PG_PASSWORD, MINIO_ROOT_USER, MINIO_ROOT_PASSWORD,
DIRECTUS_ADMIN_EMAIL, DIRECTUS_ADMIN_PASSWORD, DIRECTUS_SECRET,
GITEA_ADMIN_USER, GITEA_ADMIN_PASSWORD, GITEA_ADMIN_EMAIL,
DOCKER_CONFIG_JSON, GITEA_TOKEN, GITEA_USERNAME,
DIRECTUS_URL, DIRECTUS_STATIC_TOKEN

---

## Resource Budget Reference

Existing services (for capacity planning):

| Component       | CPU Req | CPU Limit | Mem Req | Mem Limit |
|-----------------|---------|-----------|---------|-----------|
| PostgreSQL      | 100m    | 250m      | 256Mi   | 512Mi     |
| MinIO           | 100m    | 250m      | 256Mi   | 512Mi     |
| Directus        | 200m    | 500m      | 256Mi   | 512Mi     |
| Gitea           | 200m    | 500m      | 256Mi   | 512Mi     |
| Gitea Runner    | 200m    | 1000m     | 256Mi   | 1536Mi    |
| Astro (2x)      | 200m    | 400m      | 256Mi   | 512Mi     |
| **Total (approx)** | **1200m** | **2900m** | **1.5Gi** | **4Gi** |

When adding new components, keep total CPU requests under ~2000m and
total memory requests under ~3Gi to leave headroom on the single node.

---

## Storage Layout on Host

| Path              | Size  | Used by    |
|-------------------|-------|------------|
| /data/postgresql  | 5Gi   | PostgreSQL |
| /data/minio       | 15Gi  | MinIO      |
| /data/gitea       | 5Gi   | Gitea      |

New PVs go under `/data/<component>/` with matching PV/PVC manifests in
`k8s-manifests/storage/`. For Helm-based components use `storageClass: local-path`
directly in the values file.

---

## Registry

Container registry: `git.tunenumbers.de` (Gitea Container Registry)
Image naming: `git.tunenumbers.de/tunenumbers/<image-name>:<tag>`
Pull secret name in cluster: `gitea-registry-secret` (namespace: tunenumbers)

---

## Common Commands (for verification steps in docs)

```bash
# Cluster overview
kubectl get nodes
kubectl get pods -A
kubectl get pvc -A

# Tail logs
kubectl logs -n <namespace> deployment/<name> -f --tail=100

# Port-forward for local testing
kubectl port-forward -n <namespace> svc/<name> <local>:<remote>

# Helm
helm list -A
helm repo update

# Ansible (local dev, with vault)
cd ~/tunenumbers/tunenumbers-infra
ansible-playbook ansible/playbooks/<playbook>.yml --ask-vault-pass

# k3s kubeconfig (on VPS)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

---

## What NOT to Do

- Do NOT add SSH-based Ansible connections – everything runs local on the VPS
- Do NOT add a public Ingress without the CrowdSec bouncer middleware annotation (see Traefik / Ingress section)
- Do NOT commit `ansible/vars/secrets.yml` – it's gitignored intentionally
- Do NOT use `NodePort` or `LoadBalancer` service types – all services are ClusterIP
- Do NOT exceed single-node resource budget without noting it explicitly
- Do NOT use `imagePullPolicy: IfNotPresent` for own images – use `Always`
  (Gitea registry uses `:latest` tags that get overwritten)
- Do NOT add a `helm upgrade ... --wait` against the `monitoring` namespace without
  gating it on `monitoring_enabled` – the stack is off, so it can only time out

