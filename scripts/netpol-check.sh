#!/usr/bin/env bash
# Allowed-path NetworkPolicy checks. Complements the netpol-test CronJob, which only
# proves what is blocked from an outsider. Uses KUBECONFIG from the environment.
set -u
fail=0
ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
skip() { echo "skip  $1"; }

# From inside a client pod that has a shell (grafana has curl, prometheus has wget).
in_pod() { # ns selector container url
  local pod; pod=$(kubectl -n "$1" get pod -l "$2" -o name 2>/dev/null | head -1)
  [ -n "$pod" ] || { bad "$1 -> $4 (no pod matches $2)"; return; }
  if kubectl -n "$1" exec "$pod" -c "$3" -- sh -c "command -v curl >/dev/null && curl -sk -o /dev/null --max-time 5 '$4' || wget -qO /dev/null -T 5 --no-check-certificate '$4'" >/dev/null 2>&1
  then ok "$1 -> $4"; else bad "$1 -> $4"; fi
}
in_pod monitoring app.kubernetes.io/name=grafana    grafana    http://monitoring-kube-prometheus-prometheus:9090/-/ready
in_pod monitoring app.kubernetes.io/name=prometheus prometheus http://loki.loki:3100/ready

# alloy -> loki: alloy's image has no shell, and alloy is Loki's only writer, so fresh
# log lines in Loki prove the path. Queried from the prometheus pod (monitoring -> loki is allowed).
ppod=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o name | head -1)
lines=$(kubectl -n monitoring exec "$ppod" -c prometheus -- wget -qO- -T 10 \
  'http://loki.loki:3100/loki/api/v1/query?query=sum(count_over_time({namespace=~".%2B"}[5m]))' 2>/dev/null \
  | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["value"][1])) if r else 0)' 2>/dev/null || echo 0)
if [ "${lines:-0}" -gt 0 ]; then ok "alloy -> loki ($lines lines in last 5m)"; else bad "alloy -> loki (no lines in last 5m)"; fi

# cloudflared -> services: cloudflared's image has no shell; the public hostnames prove the path.
if kubectl get namespace cloudflared >/dev/null 2>&1; then
  for h in argocd.nopsqi.dev/healthz grafana.nopsqi.dev/api/health nopsqi.dev; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$h")
    case "$code" in 2*|3*) ok "cloudflared -> https://$h ($code)" ;; *) bad "cloudflared -> https://$h ($code)" ;; esac
  done
else
  skip "cloudflared checks (namespace absent in this cluster)"
fi
exit $fail
