# Brute-Force Protection — tunenumbers.de

CrowdSec detects and bans IPs with 5+ failed login attempts per 60 seconds
across Directus (CMS), Grafana (monitoring), and Gitea. The admin receives an
email on every new ban. The Security Overview dashboard in Grafana provides
real-time visibility.

---

## Architecture

```
Pod logs (containerd JSON)
        │
  /var/log/pods/…
        │
  CrowdSec Agent (DaemonSet)
   ├── parser-directus.yaml   → extracts IP from pino JSON 401s
   ├── parser-grafana.yaml    → extracts IP from "Invalid username or password"
   └── parser-gitea.yaml      → extracts IP from "Failed authentication"
        │
  CrowdSec LAPI
   ├── scenario-brute-force.yaml  (5 events / 60s → ban 4h)
   ├── profiles.yaml              (ban + email notification)
   └── notification: email_default → admin@tunenumbers.de
        │
  Traefik Bouncer Middleware
   └── Blocks banned IPs at ingress level
```

---

## Checking Active Bans

```bash
# On VPS (as root or with KUBECONFIG set):
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# List all active ban decisions
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli decisions list

# Filter by type
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli decisions list --type ban

# Show CrowdSec metrics (events parsed, decisions, etc.)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli metrics
```

---

## Unblocking an IP

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Unblock a specific IP
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions delete --ip <IP>

# Example:
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions delete --ip 1.2.3.4

# Verify it's removed
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions list
```

---

## Manually Testing the Scenario

**Simulate 5 failed logins against Directus** (replace with the actual admin IP
you want to test from, and do NOT use a production IP):

```bash
# On VPS — send 6 POST /auth/login requests that return 401
for i in $(seq 1 6); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST https://cms.tunenumbers.de/auth/login \
    -H "Content-Type: application/json" \
    -d '{"email":"notexist@test.invalid","password":"wrongpassword"}'
  sleep 5
done

# After the 5th event within 60s, check decisions:
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli decisions list
```

**Check that the parser is matching logs:**

```bash
# Watch CrowdSec agent logs for parsed events
kubectl logs -n crowdsec -l app.kubernetes.io/component=agent --tail=100 -f

# Check parser hit stats
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli metrics | grep -A20 "Acquisition Metrics"
```

---

## Security Dashboard

Open Grafana at https://monitoring.tunenumbers.de and navigate to:
**Security Overview** (folder: tunenumbers Applications)

Panels:
- **Active Bans** — current ban count (stat)
- **Active Bans by Scenario** — table breakdown
- **Login Failures per Minute** — Loki time series per service
- **Active Bans Over Time** — Prometheus time series
- **Unblock History** — CrowdSec LAPI logs matching "deleted decision"
- **CrowdSec Ban Events** — LAPI logs matching new bans

---

## Alert Emails

CrowdSec sends an email to `admin@tunenumbers.de` on every new ban decision.

Subject: `[tunenumbers] IP <IP> banned - brute force`

Body includes: IP, scenario, ban duration, service, and the unblock command.

Grafana also fires a "New IP Banned — Brute Force" alert when
`increase(cs_active_decisions{action="ban"}[5m]) > 0`.

---

## Configuration Files

| File | Purpose |
|------|---------|
| `k8s-manifests/crowdsec/parser-directus.yaml` | Directus parser ConfigMap |
| `k8s-manifests/crowdsec/parser-grafana.yaml` | Grafana parser ConfigMap |
| `k8s-manifests/crowdsec/parser-gitea.yaml` | Gitea parser ConfigMap |
| `k8s-manifests/crowdsec/scenario-brute-force.yaml` | Leaky bucket scenario ConfigMap |
| `k8s-manifests/crowdsec/notification-email.yaml` | Email plugin template + profiles ConfigMap |
| `helm/crowdsec/crowdsec-values.yaml` | CrowdSec Helm values |
| `k8s-manifests/grafana/dashboards/security-overview.json` | Security dashboard JSON |
| `k8s-manifests/grafana/alerts/brute-force-alert.yaml` | Grafana alert rule |
| `helm/monitoring/grafana-values.yaml` | Updated with SMTP + alerts sidecar |
| `helm/monitoring/prometheus-values.yaml` | Updated with CrowdSec scrape job |

---

## Deploying Changes

```bash
# Run the playbook directly (on VPS or from a machine with WireGuard access)
cd ~/tunenumbers/tunenumbers-infra
ansible-playbook ansible/playbooks/10-brute-force-protection.yml

# Or trigger via GitHub Actions workflow_dispatch
# (the playbook is included in site.yml — Phase 10)
```

---

## Troubleshooting

### Parser not matching logs

```bash
# Check agent logs for acquisition errors
kubectl logs -n crowdsec -l app.kubernetes.io/component=agent --tail=100

# Verify parser files are mounted
kubectl exec -n crowdsec -l app.kubernetes.io/component=agent -- \
  ls /etc/crowdsec/parsers/s01-parse/

# Inspect a raw pod log line to verify containerd format
kubectl exec -n crowdsec -l app.kubernetes.io/component=agent -- \
  head -3 /var/log/pods/tunenumbers_directus-*/directus/0.log
```

### Email notifications not arriving

```bash
# Check LAPI logs for notification errors
kubectl logs -n crowdsec deployment/crowdsec-lapi --tail=100 | grep -i email

# Verify the notification config was rendered (init container)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cat /etc/crowdsec/notifications/email.yaml

# Verify smtp-credentials Secret exists in crowdsec namespace
kubectl get secret smtp-credentials -n crowdsec
```

### Decisions not enforced by Traefik

```bash
# Confirm bouncer is registered and healthy
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli bouncers list

# Check Traefik logs for bouncer plugin errors
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=50 | grep -i crowdsec
```
