# ArgoCD + GitOps Concepts

## 1. What is GitOps?
Git is the single source of truth. You don't push to the cluster — you push to Git, and an agent inside the cluster pulls and applies. Audit trail = Git history.

---

## 2. Push-based vs Pull-based CD

```
Push (traditional GHA):  Pipeline → kubectl/helm → cluster
Pull (GitOps/ArgoCD):    Git change → ArgoCD inside cluster → syncs itself
```

Pull is safer — no external tool needs cluster credentials.

---

## 3. ArgoCD Application CRD

The core object. Links a Git repo path to a cluster namespace.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: frontend
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/karanpulipati-09/aws-microservices-demo
    targetRevision: main
    path: helm/frontend
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- `source` — Git repo + path + branch
- `destination` — which cluster + namespace
- `syncPolicy` — auto or manual

---

## 4. Sync vs Health

| Status | Question it answers | Values |
|---|---|---|
| **Sync** | Does cluster match Git? | Synced / OutOfSync |
| **Health** | Are pods actually healthy? | Healthy / Degraded / Progressing |

Both must be green for a successful deploy.

---

## 5. Auto-sync + Self-heal + Prune

- **Auto-sync** — ArgoCD applies changes automatically when Git changes
- **Self-heal** — if someone manually changes the cluster (`kubectl edit`), ArgoCD reverts it back to Git state
- **Prune** — if you delete a resource from Git, ArgoCD deletes it from the cluster too

---

## 6. App of Apps Pattern

One ArgoCD Application that manages other Applications. Used when you have many services.

```
root-app (ArgoCD Application)
  → frontend Application
  → api Application
  → postgres Application
```

One Git commit can update all apps at once.

---

## 7. Rollback

```bash
# GitOps rollback = git revert
git revert <commit>  # reverts values.yaml to old image tag
git push             # ArgoCD detects → syncs → old pods restored
```

No special ArgoCD command needed — Git history IS your rollback history.

---

## 8. ArgoCD vs Flux

| | ArgoCD | Flux |
|---|---|---|
| UI | Yes (rich dashboard) | No (CLI-focused) |
| Popularity | Higher (interviews) | Common in enterprise |
| Multi-cluster | Yes | Yes |
| Learning curve | Easier | Steeper |

ArgoCD is more commonly asked about in interviews.

---

## 9. How does ArgoCD detect changes?

- Polls Git repo every **3 minutes** by default
- OR **Git webhook** → instant notification on push (faster)
- Compares live cluster state vs desired state in Git (3-way diff)

---

## 10. Why no kubeconfig needed in CI with GitOps?

ArgoCD runs **inside** the cluster. It pulls from Git — no external system needs cluster access. CI only needs Git write access (to update values.yaml). Much smaller attack surface.

```
Traditional:  CI needs kubeconfig + cluster credentials → security risk
GitOps:       CI needs only Git write access → ArgoCD handles the rest
```

---

## Our Project Flow

```
Developer pushes code
    │
    ▼
ci-build-push.yml
  → builds frontend + api images
  → pushes to ECR with tag (short git SHA)
    │
    ▼
deploy.yml (updated for GitOps)
  → updates image.tag in helm/frontend/values.yaml
  → updates image.tag in helm/api/values.yaml
  → git commit + push to main
    │
    ▼
ArgoCD (running in EKS, watching main branch)
  → detects values.yaml changed (OutOfSync)
  → runs helm upgrade automatically
  → pods rolling update
  → reports Synced + Healthy ✅
```
