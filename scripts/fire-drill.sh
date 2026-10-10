#!/usr/bin/env bash
# Creates a pod that is OOM-killed repeatedly, waits for ContainerRestarting to fire
# in Alertmanager, cleans up. ~12 minutes: 4 restarts inside the 1h window, then for: 10m.
set -u
NS=drill; TIMEOUT=${TIMEOUT:-1500}; PF=
cleanup() { kubectl delete namespace $NS --ignore-not-found --wait=false >/dev/null 2>&1; [ -n "$PF" ] && kill $PF 2>/dev/null; }
trap cleanup EXIT

kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<YAML | kubectl -n $NS apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: oom }
spec:
  replicas: 1
  selector: { matchLabels: { app: oom } }
  template:
    metadata: { labels: { app: oom } }
    spec:
      containers:
        - name: oom
          image: busybox:1.37
          command: ["sh", "-c", "head -c 50M /dev/zero | tail"]
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 20Mi } }
YAML

kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 19093:9093 >/dev/null 2>&1 &
PF=$!; sleep 3
start=$(date +%s)
while :; do
  firing=$(curl -s "http://127.0.0.1:19093/api/v2/alerts?filter=alertname%3DContainerRestarting&filter=namespace%3D$NS&active=true" \
           | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  restarts=$(kubectl -n $NS get pod -l app=oom -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
  el=$(( $(date +%s) - start ))
  echo "t=${el}s restarts=${restarts:-0} firing=${firing:-0}"
  if [ "${firing:-0}" != "0" ]; then echo "PASS: ContainerRestarting fired after ${el}s"; exit 0; fi
  if [ $el -ge $TIMEOUT ]; then echo "FAIL: no alert after ${el}s"; exit 1; fi
  sleep 30
done
