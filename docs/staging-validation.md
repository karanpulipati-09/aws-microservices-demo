Staging validation commands

This document lists exact commands to run (CI or manually) when the EKS cluster and ArgoCD are available.

1) Helm lint & template (local, no cluster required)

# frontend
helm lint ./helm/frontend -f ./helm/frontend/values-staging.yaml
helm template frontend ./helm/frontend -f ./helm/frontend/values-staging.yaml --namespace staging

# api
helm lint ./helm/api -f ./helm/api/values-staging.yaml
helm template api ./helm/api -f ./helm/api/values-staging.yaml --namespace staging

2) ArgoCD (when argocd server + CLI configured)

# show differences between Git and cluster
argocd app diff frontend --local ./helm/frontend --values ./helm/frontend/values-staging.yaml
argocd app diff api --local ./helm/api --values ./helm/api/values-staging.yaml

# sync if diffs are acceptable
argocd app sync frontend
argocd app sync api

3) Kubernetes runtime checks

# pods healthy
kubectl get pods -n frontend
kubectl get pods -n api

# check logs for restarts/crashes
kubectl describe pods -n frontend
kubectl describe pods -n api

# from a running frontend pod, verify connectivity to api service
POD=$(kubectl get pods -n frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n frontend -it ${POD} -- curl -sS http://api-api:3000/health

4) TLS / headers verification (when ALB DNS is known)

# verify TLS and security headers (HSTS, CSP)
curl -I https://<ALB_DNS_NAME>

# expect headers:
# Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
# Content-Security-Policy: default-src 'self'; ...

Notes
- The EKS cluster in this workspace is currently not reachable; run the above commands in CI after the cluster is provisioned by GitHub Actions.
- Prometheus + Alertmanager (kube-prometheus-stack) is the recommended place for pod-level alerts (restarts, crashloops). CloudWatch alarms are added for ALB, RDS, and state access as a cross-account fallback.
