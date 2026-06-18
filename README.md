# knsk — Kubernetes Namespace Killer

A battle-tested toolkit for dealing with **stuck namespaces** and backing up Kubernetes resources.

- **`knsk.sh`** — diagnoses and kills namespaces stuck in `Terminating` state
- **`backup.sh`** — backs up any namespace to clean, `kubectl apply`-ready YAML files

> Requires `kubectl` ≥ 1.20 and `python3`. `backup.sh` additionally requires [`yq` v4](https://github.com/mikefarah/yq/releases).

---

## knsk.sh — Namespace Killer

### What it detects

Running without flags performs a **read-only diagnosis** and reports:

| Check | What it finds |
|---|---|
| Unavailable API services | Aggregated APIs that are down and blocking namespace cleanup |
| **Broken admission webhooks** *(new)* | Validating/Mutating webhooks whose backend Service is missing — a leading cause of stuck namespaces in k8s 1.20+ |
| Stuck namespaces | Namespaces in `Terminating` state and the resources blocking them |
| Stuck cluster resources | Resources in `Terminating` state across all namespaces |
| Orphan resources | Resources that belong to a namespace that no longer exists |

### Quick start

```bash
# Clone and run (diagnosis only — no changes made)
git clone https://github.com/thyarles/knsk.git
cd knsk && chmod +x knsk.sh
./knsk.sh

# See what commands would run without executing them
./knsk.sh --dry-run --delete-all --force

# Fix everything automatically
./knsk.sh --delete-all --force
```

### Options

```
knsk.sh [options]

  --dry-run               Show what will be executed instead of executing it
  --skip-tls              Set --insecure-skip-tls-verify on all kubectl calls
  --delete-api            Delete broken API services
  --delete-resource       Delete stuck resources inside stuck namespaces
  --delete-orphan         Delete orphan resources found in the cluster
  --delete-webhook        Delete broken admission webhooks blocking namespace deletion
  --delete-all            All of the above combined
  --force                 Force-finalize namespaces that survive --delete-all
  --port {number}         kubectl proxy port for legacy fallback (default: 8765)
  --timeout {number}      Max seconds to wait for kubectl responses (default: 15)
  --no-color              Plain output, no ANSI colors (useful in CI/scripts)
  --kubeconfig {path}     Path to a custom kubeconfig file
  -h --help               Show this help
```

### How `--force` works

`--force` clears the `spec.finalizers` on any namespace that is still stuck after all other steps. It requires `--delete-all` or `--delete-resource` to be set alongside it.

**Modern method (k8s 1.20+):** Uses `kubectl replace --raw /api/v1/namespaces/<name>/finalize` — no proxy, no token required.

**Legacy fallback:** If the above fails, falls back to `kubectl proxy` + `curl`. Token retrieval tries `kubectl create token` (k8s 1.24+) first, then falls back to SA secret lookup for older clusters.

---

## backup.sh — Namespace Backup

Exports every resource in a namespace to individual YAML files, stripped of all Kubernetes-managed fields, so they can be re-applied to a fresh namespace with a single command.

### Quick start

```bash
chmod +x backup.sh

# Back up a single namespace
./backup.sh my-app

# Back up all non-system namespaces (asks for confirmation)
./backup.sh

# Use a custom output directory
./backup.sh my-app --outdir /mnt/backups
./backup.sh my-app -o /mnt/backups

# Restore
kubectl apply -f knsk_backup/20260618_17h00/my-app/
```

### Output structure

```
knsk_backup/
└── 20260618_17h00/          ← timestamp, never overwritten
    └── my-app/
        ├── Deployment-api.yaml
        ├── Service-api.yaml
        ├── ConfigMap-app-config.yaml
        ├── Secret-app-secrets.yaml
        ├── PersistentVolumeClaim-data.yaml
        ├── PersistentVolume-pvc-xxx.yaml   ← cluster-scoped, included when bound to this namespace
        └── ...
```

### What gets stripped

The following fields are removed from every exported resource so that `kubectl apply` works cleanly on a fresh cluster:

`status` · `metadata.uid` · `metadata.resourceVersion` · `metadata.generation` · `metadata.creationTimestamp` · `metadata.deletionTimestamp` · `metadata.managedFields` · `metadata.ownerReferences` · `metadata.selfLink` · `metadata.annotations[kubectl.kubernetes.io/last-applied-configuration]`

### What gets skipped

Resources that are ephemeral or auto-reconstructed by Kubernetes are excluded:

- **Kinds:** `Event`, `Endpoints`, `EndpointSlice`, `Pod`, `ReplicaSet`, `Lease`, `ControllerRevision`, `ReplicationController`
- **Secrets** of type `kubernetes.io/service-account-token`
- The auto-generated `default` ServiceAccount
- The injected `kube-root-ca.crt` ConfigMap
- System namespaces: `kube-system`, `kube-public`, `kube-node-lease` (full-cluster mode)

### Options

```
backup.sh [namespace] [options]

  namespace               Namespace to back up. Omit to back up all non-system namespaces.
  --outdir, -o <path>     Write output to this directory instead of the default knsk_backup/<timestamp>/
```

### Requirements

| Tool | Required by | Install |
|---|---|---|
| `kubectl` | both scripts | https://kubernetes.io/docs/tasks/tools/ |
| `python3` | `knsk.sh --force` | pre-installed on most systems |
| `yq` v4 | `backup.sh` | `brew install yq` · [GitHub releases](https://github.com/mikefarah/yq/releases) |

---

## Issues & contributions

If **knsk** doesn't work for your cluster, open an issue — stuck namespace reproduction cases are always welcome.
