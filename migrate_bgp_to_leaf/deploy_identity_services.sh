#!/usr/bin/env bash
# =============================================================================
# deploy_identity_services.sh  —  run once on master
# -----------------------------------------------------------------------------
# Replaces the four ai-training deployments (param-server, trainer, inference,
# data-loader) with identity-aware versions. The new pods run a tiny Python
# HTTP server that echoes:
#
#   body:    "<service> [pod=<pod-name> node=<node-name>]: <static-message>"
#   headers: X-Pod-Name, X-Node-Name, X-Service-Name
#
# The existing Services and their VIPs are PRESERVED — we only update the
# Deployments. VIPs stay the same (192.168.100.0..3), so the frontend's
# routes + validation scripts don't need any changes.
#
# After running this, trigger_training.sh will automatically pick up
# pod identity from headers and show a "pod distribution" table in
# its summary.
# =============================================================================

set -euo pipefail

readonly NS="ai-training"

# ---- preflight --------------------------------------------------------------
kubectl get ns "$NS" >/dev/null || { echo "ns $NS not found"; exit 1; }
command -v kubectl >/dev/null    || { echo "kubectl not found"; exit 1; }

echo "Current state of $NS namespace:"
echo
echo "  Services:"
kubectl get svc -n "$NS" -o custom-columns='NAME:.metadata.name,VIP:.status.loadBalancer.ingress[0].ip,SELECTOR:.spec.selector' --no-headers | sed 's/^/    /'
echo
echo "  Deployments:"
kubectl get deploy -n "$NS" --no-headers | sed 's/^/    /' || echo "    (none)"
echo

read -rp "Replace these deployments with identity-aware ones? [y/N] " ans
[[ "${ans,,}" == "y" ]] || { echo "cancelled"; exit 0; }

# ---- apply manifest ---------------------------------------------------------
kubectl apply -n "$NS" -f - <<'MANIFEST'
apiVersion: v1
kind: ConfigMap
metadata:
  name: identity-server
data:
  server.py: |
    import http.server, socketserver, os, socket, sys

    HOSTNAME = socket.gethostname()
    NODE     = os.environ.get('NODE_NAME', 'unknown')
    SVC      = os.environ.get('SERVICE_NAME', 'unknown')
    MSG      = os.environ.get('SERVICE_MESSAGE', 'ok')
    BODY     = f"{SVC} [pod={HOSTNAME} node={NODE}]: {MSG}\n"

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type',   'text/plain')
            self.send_header('X-Pod-Name',     HOSTNAME)
            self.send_header('X-Node-Name',    NODE)
            self.send_header('X-Service-Name', SVC)
            self.end_headers()
            self.wfile.write(BODY.encode())
        def log_message(self, *a): pass

    class TS(socketserver.ThreadingMixIn, http.server.HTTPServer):
        allow_reuse_address = True
        daemon_threads      = True

    print(f"[{SVC}] pod={HOSTNAME} node={NODE} listening on :8080", file=sys.stderr, flush=True)
    TS(('', 8080), H).serve_forever()
MANIFEST

# ---- generate + apply the four Deployments ----------------------------------
# Each deployment has 3 replicas spread across nodes by anti-affinity so the
# LB distribution table in the test is actually interesting.
deploy_one() {
  local name="$1" msg="$2"
  kubectl apply -n "$NS" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  labels: {app: $name}
spec:
  replicas: 3
  selector: {matchLabels: {app: $name}}
  template:
    metadata: {labels: {app: $name}}
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector: {matchLabels: {app: $name}}
              topologyKey: kubernetes.io/hostname
      containers:
      - name: server
        image: python:3-alpine
        command: [python3, /config/server.py]
        env:
        - {name: SERVICE_NAME,    value: "$name"}
        - {name: SERVICE_MESSAGE, value: "$msg"}
        - {name: NODE_NAME,       valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
        ports:
        - {containerPort: 8080, name: http}
        readinessProbe:
          httpGet: {path: /, port: 8080}
          periodSeconds: 2
          failureThreshold: 2
        volumeMounts:
        - {name: config, mountPath: /config}
      volumes:
      - name: config
        configMap:
          name: identity-server
          defaultMode: 0555
EOF
}

deploy_one  param-server  "gradients synced"
deploy_one  trainer       "epoch=42 loss=0.023"
deploy_one  inference     "tps=1240 p99=12ms"
deploy_one  data-loader   "batch=256 shards=32"

# ---- wait for pods + show final state ---------------------------------------
echo
echo "Waiting for pods to become Ready..."
for d in param-server trainer inference data-loader; do
  kubectl wait -n "$NS" --for=condition=available --timeout=120s "deployment/$d" \
    && echo "  ✓ $d" || echo "  ✗ $d"
done

echo
echo "Final state:"
kubectl get pods -n "$NS" -o wide
echo
kubectl get endpoints -n "$NS"
echo
echo "Done. Run trigger_training.sh on the frontend to see per-pod request distribution."
