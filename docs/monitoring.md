# Monitoring Stack - tunenumbers.de

## Architektur

Alloy laeuft als DaemonSet und sammelt Node-Metriken sowie Pod-Logs.
Metriken werden via remote_write an Prometheus gepusht.
Logs werden an Loki gepusht. Grafana liest von beiden Datasources.
Externer Zugriff ausschliesslich ueber Grafana unter monitoring.tunenumbers.de via Traefik.

```
  Nodes/Pods
      |
      v
  +----------+  remote_write  +------------+
  |  Alloy   |--------------->| Prometheus |
  | DaemonSet|                +------------+
  |          |  loki push     +------------+
  |          |--------------->|    Loki    |
  +----------+                +------------+
                                     |
                              +------+------+
                              |   Grafana   | <-- https://monitoring.tunenumbers.de
                              +-------------+
```

## Komponenten

| Komponente         | Chart                              | Version  | Namespace  |
|--------------------|------------------------------------|----------|------------|
| Prometheus         | prometheus-community/prometheus    | 25.27.0  | monitoring |
| Loki               | grafana/loki (SingleBinary)        | 6.6.4    | monitoring |
| Grafana            | grafana/grafana                    | 8.3.4    | monitoring |
| Alloy              | grafana/alloy (DaemonSet)          | 0.9.1    | monitoring |
| kube-state-metrics | (via prometheus chart)             | -        | monitoring |

## Ressourcen-Budget

| Komponente         | CPU Req | CPU Limit | Mem Req | Mem Limit |
|--------------------|---------|-----------|---------|-----------|
| Alloy (per node)   | 100m    | 300m      | 128Mi   | 256Mi     |
| Prometheus         | 200m    | 500m      | 512Mi   | 1Gi       |
| Loki               | 100m    | 300m      | 256Mi   | 512Mi     |
| Grafana            | 100m    | 300m      | 128Mi   | 256Mi     |
| kube-state-metrics | 10m     | 100m      | 64Mi    | 128Mi     |
| **Total**          | **510m**| **1500m** | **1088Mi** | **2176Mi** |

## Retention

- Prometheus: 14 Tage (10Gi PVC)
- Loki: 7 Tage / 168h (10Gi PVC)
- Grafana: 1Gi PVC

## Initial Setup (einmalig, vor erstem Deployment)

```bash
# Namespace anlegen
kubectl apply -f k8s-manifests/monitoring/namespace.yaml

# Grafana Admin-Secret erstellen (Passwort wählen!)
kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='SECURE_PASSWORD_HERE' \
  -n monitoring
```

Erst danach den GitHub Actions Workflow triggern oder manuell ausführen:

```bash
ansible-playbook ansible/playbooks/deploy-monitoring.yml -v
```

## Verifikation

```bash
# Pod-Status
kubectl get pods -n monitoring -w

# PVCs
kubectl get pvc -n monitoring

# Prometheus Targets (port-forward)
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# open http://localhost:9090/targets - alle Targets sollten UP sein

# Loki Health
kubectl port-forward -n monitoring svc/loki 3100:3100
curl http://localhost:3100/ready

# Loki Test-Query
curl -G http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={namespace="tunenumbers"}' \
  --data-urlencode 'limit=5'

# Alloy DaemonSet
kubectl get ds -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=50

# Grafana erreichbar
curl -I https://monitoring.tunenumbers.de

# Admin-Passwort anzeigen
kubectl get secret grafana-admin-secret -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

## Wartung

### Log Retention
Loki: 7 Tage (168h), Compactor laeuft automatisch.

```bash
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=loki -o jsonpath='{.items[0].metadata.name}') \
  -- du -sh /var/loki/
```

### Prometheus Storage
Retention: 14 Tage, PVC: 10Gi.

```bash
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}') \
  -- df -h /data
```

### Helm Chart Updates

```bash
helm repo update
helm list -n monitoring
# Version in helm/monitoring/*-values.yaml anpassen -> push -> CI/CD deployt
```

### Restart

```bash
kubectl rollout restart deployment -n monitoring grafana
kubectl rollout restart deployment -n monitoring prometheus-server
kubectl rollout restart statefulset -n monitoring loki
kubectl rollout restart daemonset -n monitoring alloy
```

## Troubleshooting

### Alloy sammelt keine Logs
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy | grep -i error
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=alloy -o jsonpath='{.items[0].metadata.name}') \
  -- ls /var/log/pods/
```

### Prometheus scrapet nicht
```bash
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# http://localhost:9090/targets
```

### Grafana nicht erreichbar
```bash
kubectl get ingressroute -n monitoring
kubectl describe ingressroute grafana -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50
```

### Loki meldet keine Daten in Grafana
```bash
# Loki-Readiness prüfen
kubectl port-forward -n monitoring svc/loki 3100:3100
curl http://localhost:3100/ready

# Alloy -> Loki Verbindung prüfen
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy | grep -i loki
```
