# CrowdSec — tunenumbers.de

CrowdSec is the intrusion detection and prevention layer for tunenumbers.de.
It runs inside the k3s cluster and blocks malicious IPs at the Traefik ingress.

---

## Architecture

```
Internet
    │
 Traefik (ingress)
    │  crowdsec-bouncer middleware
    │  blocks IPs with active ban decisions
    │
 CrowdSec LAPI                   ← deployment/crowdsec-lapi (namespace: crowdsec)
    ├── Decision store            ← active bans (CAPI + local)
    ├── profiles.yaml             ← ban 4h + email notification on local trigger
    └── email plugin              ← alerts admin@tunenumbers.de on new local ban
    │
 CrowdSec Agent                  ← daemonset/crowdsec-agent (namespace: crowdsec)
    ├── Reads Traefik logs        ← /var/log/containers/traefik-*
    ├── Reads Directus logs       ← /var/log/pods/tunenumbers_directus-*/...
    ├── Reads Grafana logs        ← /var/log/pods/monitoring_grafana-*/...
    └── Reads Gitea logs          ← /var/log/pods/gitea_gitea-*/...
    │
 CAPI (CrowdSec Central API)     ← community threat intelligence feed
    └── ~16 000+ known bad IPs   ← auto-synced, immediately active
```

**Two sources of bans:**
- **CAPI** — CrowdSec's global community blocklist. Synced automatically. These
  cover known exploit scanners, brute-forcers, and crawlers worldwide.
- **Local** — Triggered by our custom scenarios when an IP generates 5+ failed
  logins within 60 seconds on Directus, Grafana, or Gitea.

---

## Installed components

| Component | Version | Details |
|-----------|---------|---------|
| CrowdSec LAPI | v1.7.6 | `deployment/crowdsec-lapi` in `crowdsec` ns |
| CrowdSec Agent | v1.7.6 | `daemonset/crowdsec-agent` in `crowdsec` ns |
| Traefik Bouncer | v1.5.0 | Plugin in Traefik, checks every request |
| Collections | linux, sshd, whitelist-good-actors | Hub collections |
| Custom scenario | `tunenumbers/brute-force` | 5 events / 60s → 4h ban |

---

## Daily operations

All `cscli` commands run inside the LAPI pod. The alias throughout this doc:

```bash
alias cs='kubectl exec -n crowdsec deployment/crowdsec-lapi --'
```

### Check active bans

```bash
# Active bans only (CAPI + local)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli decisions list

# All bans including expired
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli decisions list -a

# Local bans only (triggered by our parsers, not CAPI)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions list --origin local

# Filter by IP
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions list --ip 1.2.3.4

# Summary counts
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli metrics
```

### Unblock an IP

```bash
# Remove a specific ban
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions delete --ip 1.2.3.4

# Remove all local bans (keeps CAPI bans)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions delete --all --origin local
```

### Manually ban an IP

```bash
# Ban for 4 hours (default)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions add --ip 1.2.3.4 --reason "manual block"

# Ban for a specific duration
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual block"
```

---

## Alerts and events

Alerts are the raw detection events. Each alert may produce one or more ban decisions.

```bash
# List recent alerts
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli alerts list

# Show details for a specific alert (use ID from list)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli alerts inspect 42

# Show only alerts from our brute-force scenario
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli alerts list --scenario tunenumbers/brute-force

# Show alerts in the last hour
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli alerts list --since 1h
```

---

## Parsers and scenarios

```bash
# List active parsers (run on the agent)
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli parsers list

# List active scenarios
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli scenarios list

# List installed hub collections
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli collections list
```

Custom parsers for Directus, Grafana, and Gitea are mounted from ConfigMaps:
- `crowdsec-parser-directus` → `/etc/crowdsec/parsers/s01-parse/directus.yaml`
- `crowdsec-parser-grafana` → `/etc/crowdsec/parsers/s01-parse/grafana.yaml`
- `crowdsec-parser-gitea` → `/etc/crowdsec/parsers/s01-parse/gitea.yaml`
- `crowdsec-scenario-brute-force` → `/etc/crowdsec/scenarios/brute-force.yaml`

---

## Bouncer and machines

```bash
# List registered bouncers (should show traefik-bouncer as valid)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli bouncers list

# List registered machines (LAPI + agents)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli machines list
```

---

## Metrics and acquisition

```bash
# Full metrics: decisions, parser hits, acquisition stats
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli metrics

# Check which log files the agent is reading and how many lines were parsed
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli metrics \
  | grep -A30 "Acquisition Metrics"

# Check parser hit rates (Parsed vs Unparsed)
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli metrics \
  | grep -A20 "Parser Metrics"
```

---

## Testing brute-force detection end-to-end

Run from the VPS to avoid banning an external IP you don't control.
The test sends 6 failed logins to Directus within ~50 seconds.

```bash
for i in $(seq 1 6); do
  curl -s -o /dev/null -w "attempt $i: %{http_code}\n" \
    -X POST https://cms.tunenumbers.de/auth/login \
    -H "Content-Type: application/json" \
    -d '{"email":"test@invalid.test","password":"wrongpassword"}'
  sleep 5
done

# Check for a new ban (your VPS IP should appear)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions list --origin local

# Unban yourself when done
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions delete --ip <VPS_IP>
```

A ban email is sent to `admin@tunenumbers.de` for every local trigger.

---

## Hub updates

The CrowdSec hub ships parsers, scenarios, and collections that receive updates.

```bash
# Check for available updates
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli hub update

# Upgrade all hub content
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli hub upgrade

# Install a new collection (example: nginx)
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- \
  cscli collections install crowdsecurity/nginx
```

After installing or upgrading hub content, restart the agent:

```bash
kubectl rollout restart daemonset/crowdsec-agent -n crowdsec
```

---

## Logs

```bash
# LAPI logs (decisions, API, notifications)
kubectl logs -n crowdsec deployment/crowdsec-lapi --tail=100

# Agent logs (parsing, acquisition errors)
kubectl logs -n crowdsec daemonset/crowdsec-agent --tail=100

# Follow live
kubectl logs -n crowdsec deployment/crowdsec-lapi -f
kubectl logs -n crowdsec daemonset/crowdsec-agent -f

# Filter for ban events in LAPI logs
kubectl logs -n crowdsec deployment/crowdsec-lapi --tail=500 \
  | grep -iE "ban|decision|overflow"

# Filter for parser errors in agent logs
kubectl logs -n crowdsec daemonset/crowdsec-agent --tail=500 \
  | grep -iE "error|warn|unparsed"
```

---

## Notification config

Email alerts are sent via `notification@tunenumbers.de` → `admin@tunenumbers.de`
using the SMTP server `smtps.udag.de:465` (SSL/TLS).

The rendered notification config is stored as a k8s Secret:

```bash
# View current email notification config (shows rendered SMTP settings)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cat /etc/crowdsec/notifications/email.yaml

# View current profiles (shows ban duration and notification trigger)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cat /etc/crowdsec/profiles.yaml
```

To update SMTP credentials, patch the `smtp-credentials` Secret in the
`monitoring` namespace, then re-run the Ansible playbook:

```bash
ansible-playbook ansible/playbooks/10-brute-force-protection.yml
```

---

## Troubleshooting

### Bouncer not blocking a banned IP

```bash
# Confirm the bouncer is registered and has a recent API pull
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli bouncers list

# Check Traefik logs for bouncer plugin errors
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=50 \
  | grep -i crowdsec
```

### Parser not matching logs

```bash
# Check acquisition metrics — Lines parsed should be > 0
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- cscli metrics \
  | grep -A30 "Acquisition"

# Verify custom parser files are mounted in the agent
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- \
  ls /etc/crowdsec/parsers/s01-parse/

# Inspect a raw pod log line to verify expected format
kubectl exec -n crowdsec crowdsec-agent-bz7b6 -- \
  head -2 /var/log/pods/tunenumbers_directus-*/directus/0.log
```

### Email notification not arriving

```bash
# Check LAPI logs for notification plugin errors
kubectl logs -n crowdsec deployment/crowdsec-lapi --tail=200 \
  | grep -iE "email|notification|plugin"

# Confirm receiver_emails is set correctly
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  grep receiver_emails /etc/crowdsec/notifications/email.yaml
```

### Pod not starting

```bash
# Check pod status and recent events
kubectl get pods -n crowdsec
kubectl describe pod -n crowdsec -l app.kubernetes.io/component=lapi

# Rollback to last working deployment if needed
kubectl rollout undo deployment/crowdsec-lapi -n crowdsec
```

---

## Key file locations (inside pods)

| File | Location |
|------|----------|
| Main config | `/etc/crowdsec/config.yaml` |
| Profiles (ban rules) | `/etc/crowdsec/profiles.yaml` |
| Acquisition config | `/etc/crowdsec/acquis.yaml` |
| Email notification | `/etc/crowdsec/notifications/email.yaml` |
| Custom parsers | `/etc/crowdsec/parsers/s01-parse/` |
| Custom scenarios | `/etc/crowdsec/scenarios/` |
| Hub content | `/etc/crowdsec/hub/` |
| SQLite database | `/var/lib/crowdsec/data/crowdsec.db` |

---

## Key k8s resources

```bash
# Pods
kubectl get pods -n crowdsec

# Secrets (smtp config, LAPI credentials)
kubectl get secrets -n crowdsec

# ConfigMaps (parsers, scenario, acquisition)
kubectl get configmaps -n crowdsec

# Notification config Secret (contains rendered email.yaml + profiles.yaml)
kubectl get secret crowdsec-notification-config -n crowdsec

# Helm release
helm list -n crowdsec
helm get values crowdsec -n crowdsec
```
