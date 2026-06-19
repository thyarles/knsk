#!/usr/bin/env bash

# ----------------------------------------------------------------------------
#
# backup-yaml.sh
#
# Backup Kubernetes namespace resources to clean, re-applicable YAML files.
#
# Usage:
#   ./backup-yaml.sh <namespace>   — backup a single namespace
#   ./backup-yaml.sh               — backup all non-system namespaces (asks confirmation)
#
#                                                          thyarles@gmail.com
#
# ----------------------------------------------------------------------------

# Variables
  C='\e[96m'   # Cyan
  M='\e[95m'   # Magenta
  B='\e[94m'   # Blue
  Y='\e[93m'   # Yellow
  G='\e[92m'   # Green
  R='\e[91m'   # Red
  A='\e[90m'   # Gray
  S='\e[0m'    # Reset
  N='\n'       # New line

  OUTDIR="knsk_backup/$(date +%Y%m%d_%Hh%M)"
  NS_ARG=""
  OUTDIR_ARG=""
  SAVED=0
  SKIPPED=0

  # Resource kinds to always skip (ephemeral, auto-generated, or controller-reconstructed)
  SKIP_KINDS="^(Binding|Endpoints|EndpointSlice|Event|Lease|ControllerRevision|ReplicationController|PodMetrics|NodeMetrics)$"

  # System namespaces excluded from a full-cluster backup
  SYS_NS="^(kube-system|kube-public|kube-node-lease)$"

  # yq expression that strips all k8s-managed fields so the YAML is safe for 'kubectl apply'
  YQ_DEL='del(.status, .metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp, .metadata.deletionTimestamp, .metadata.deletionGracePeriodSeconds, .metadata.selfLink, .metadata.managedFields, .metadata.ownerReferences, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])'

# Function to format and print messages
  pp () {
    case $1 in
      t1    ) local _t="${2:-}"
              local _vis; _vis=$(printf '%s' "$_t" | sed 's/\x1b\[[0-9;]*m//g')
              local _line; _line=$(printf '%.0s═' $(seq 1 "${#_vis}"))
              echo -e "$N$G  $_t"
              echo -e "  $_line$S"                                  ;;
      t2    ) echo -e "$N$Y  ${2:-}$S"                              ;;
      t2n   ) local _t="${2:-}"
              local _vis; _vis=$(printf '%s' "$_t" | sed 's/\x1b\[[0-9;]*m//g')
              local _pad=$(( 54 - ${#_vis} )); [[ $_pad -lt 2 ]] && _pad=2
              local _dots; _dots=$(printf '%.0s.' $(seq 1 "$_pad"))
              echo -ne "$N  $Y:: $_t $A$_dots$S"                   ;;
      t3    ) echo -e  "   $Y> ${2:-}$S"                            ;;
      t3n   ) echo -ne "   $Y> ${2:-}$A...$S"                       ;;
      t3d   ) echo -e  "     $A${2:-}$S"                            ;;
      t4    ) echo -e  "      $Y> ${2:-}$S"                         ;;
      t4n   ) echo -ne "      $Y> ${2:-}$A...$S"                    ;;
      t4d   ) echo -e  "        $A${2:-}$S"                         ;;
      sep   ) echo -e  "$N$A  $(printf '%.0s:' $(seq 1 70))$S"      ;;
      ok    ) echo -e  "$G ok$S"                                    ;;
      nfound) echo -e  "$G not found$S"                             ;;
      saved ) echo -e  "$G saved$S"                                 ;;
      skip  ) echo -e  "$A skipped$S"                               ;;
      error ) echo -e  "$R error$S"                                 ;;
      fail  ) echo -e  "$R fail$S$N$R$N${2:-}.$S$N"; exit 1         ;;
    esac
  }

# Map a Kind name to its kubectl short name (for display only)
  short_kind () {
    case "$1" in
      ConfigMap)               echo "cm"     ;;
      Deployment)              echo "deploy" ;;
      DaemonSet)               echo "ds"     ;;
      StatefulSet)             echo "sts"    ;;
      ReplicaSet)              echo "rs"     ;;
      Job)                     echo "job"    ;;
      CronJob)                 echo "cj"     ;;
      Service)                 echo "svc"    ;;
      ServiceAccount)          echo "sa"     ;;
      PersistentVolume)        echo "pv"     ;;
      PersistentVolumeClaim)   echo "pvc"    ;;
      HorizontalPodAutoscaler) echo "hpa"    ;;
      PodDisruptionBudget)     echo "pdb"    ;;
      NetworkPolicy)           echo "netpol" ;;
      Ingress)                 echo "ing"    ;;
      StorageClass)            echo "sc"     ;;
      Pod)                     echo "po"     ;;
      Secret)                  echo "secret" ;;
      *)                       echo "$1"     ;;
    esac
  }

# Fetch, clean and save all resources of one kind inside a namespace
  backup_kind () {
    local NS="$1" KIND="$2" RESOURCE="$3"
    local NAMES
    NAMES=$(kubectl get "$RESOURCE" -n "$NS" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    [ -z "$NAMES" ] && return

    while IFS= read -r NAME; do
      [ -z "$NAME" ] && continue

      # Skip auto-generated resources by kind + name rules
      if [[ "$KIND" == "Secret" ]]; then
        local STYPE
        STYPE=$(kubectl get secret "$NAME" -n "$NS" -o jsonpath='{.type}' 2>/dev/null)
        [[ "$STYPE" == "kubernetes.io/service-account-token" ]] && { (( SKIPPED++ )) || true; continue; }
      fi
      [[ "$KIND" == "ConfigMap"      && "$NAME" == "kube-root-ca.crt" ]] && { (( SKIPPED++ )) || true; continue; }
      [[ "$KIND" == "ServiceAccount" && "$NAME" == "default"           ]] && { (( SKIPPED++ )) || true; continue; }
      # Skip Pods and ReplicaSets that are managed by a controller; back up standalone ones
      if [[ "$KIND" == "Pod" || "$KIND" == "ReplicaSet" ]]; then
        local OWNER
        OWNER=$(kubectl get "$RESOURCE" "$NAME" -n "$NS" \
          -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
        [ -n "$OWNER" ] && { (( SKIPPED++ )) || true; continue; }
      fi

      local DISP_KIND; DISP_KIND=$(short_kind "$KIND")
      pp t2n "$DISP_KIND/$NAME"
      local OUTFILE="$OUTDIR/$NS/$KIND-$NAME.yaml"
      # PVCs: also strip spec.volumeName so the claim is not bound to a non-existent PV on restore
      local YQ_EXPR="$YQ_DEL"
      [[ "$KIND" == "PersistentVolumeClaim" ]] && YQ_EXPR="${YQ_DEL} | del(.spec.volumeName)"
      kubectl get "$RESOURCE" "$NAME" -n "$NS" -o yaml 2>/dev/null | \
        yq "$YQ_EXPR" > "$OUTFILE" 2>/dev/null
      if [ -s "$OUTFILE" ]; then
        pp saved
        (( SAVED++ )) || true
      else
        rm -f "$OUTFILE"
        pp error
      fi
    done <<< "$NAMES"
  }

# Fetch PersistentVolumes that are bound to a specific namespace (cluster-scoped resource)
  backup_pvs () {
    local NS="$1"
    local PV_NAMES
    PV_NAMES=$(kubectl get pv \
      -o custom-columns='NAME:.metadata.name,NS:.spec.claimRef.namespace' \
      --no-headers 2>/dev/null | awk -v ns="$NS" '$2 == ns {print $1}')
    [ -z "$PV_NAMES" ] && return

    while IFS= read -r PV_NAME; do
      [ -z "$PV_NAME" ] && continue
      pp t2n "pv/$PV_NAME"
      local OUTFILE="$OUTDIR/$NS/PersistentVolume-$PV_NAME.yaml"
      # Strip spec.claimRef so the PV becomes Available (not Bound) on restore
      kubectl get pv "$PV_NAME" -o yaml 2>/dev/null | \
        yq "${YQ_DEL} | del(.spec.claimRef)" > "$OUTFILE" 2>/dev/null
      if [ -s "$OUTFILE" ]; then
        pp saved
        (( SAVED++ )) || true
      else
        rm -f "$OUTFILE"
        pp error
      fi
      pp t3d "PersistentVolumes (cluster-scoped, bound to $NS)"
    done <<< "$PV_NAMES"
  }

# Save the Namespace object itself (prefixed 00- so it sorts first on restore)
  backup_namespace () {
    local NS="$1"
    local OUTFILE="$OUTDIR/$NS/00-Namespace-$NS.yaml"
    pp t2n "ns/$NS"
    kubectl get namespace "$NS" -o yaml 2>/dev/null | \
      yq "$YQ_DEL" > "$OUTFILE" 2>/dev/null
    if [ -s "$OUTFILE" ]; then
      pp saved
      (( SAVED++ )) || true
    else
      rm -f "$OUTFILE"
      pp error
    fi
  }

# Header
  pp t1 "Kubernetes Namespace Backup"

# Parse arguments
  while (( "$#" )); do
    case $1 in
      --outdir|-o)
        shift
        [ -z "${1:-}" ] && pp fail "--outdir requires a path argument"
        OUTDIR_ARG="$1"
        shift
      ;;
      -*)
        pp fail "Unknown option '$1'. Usage: $(basename $0) [namespace] [--outdir|-o <path>]"
      ;;
      *)
        [ -n "$NS_ARG" ] && pp fail "Only one namespace can be specified at a time"
        NS_ARG="$1"
        shift
      ;;
    esac
  done
  [ -n "$OUTDIR_ARG" ] && OUTDIR="$OUTDIR_ARG"

# Check for kubectl
  pp t2n "Checking if kubectl is configured"
  kubectl cluster-info >& /dev/null || pp fail "kubectl is not installed or not configured"
  pp ok

# Check for yq v4
  pp t2n "Checking for yq v4"
  command -v yq >& /dev/null || \
    pp fail "yq is not installed. Get it at https://github.com/mikefarah/yq/releases"
  YQ_VER=$(yq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
  [ "${YQ_VER:-0}" -lt 4 ] && \
    pp fail "yq v4+ is required (found: $(yq --version 2>/dev/null)). Get it at https://github.com/mikefarah/yq/releases"
  pp ok

# Determine which namespaces to back up
  if [ -n "$NS_ARG" ]; then
    pp t2n "Validating namespace $Y$NS_ARG$S"
    kubectl get namespace "$NS_ARG" >& /dev/null || pp fail "Namespace '$NS_ARG' not found in the cluster"
    pp ok
    NAMESPACES="$NS_ARG"
  else
    echo -e "$N   $R  Warning:$S $YA full-cluster backup may expose sensitive data in Secrets and ConfigMaps.$S"
    echo -e "     $ASystem namespaces (kube-system, kube-public, kube-node-lease) will be excluded.$S"
    echo -ne "$N   ${Y}  Continue? [y/N] ${S}"
    read -r CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "$N     ${A}Aborted.$S$N"; exit 0; }
    NAMESPACES=$(kubectl get namespaces \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
      tr ' ' '\n' | grep -Ev "$SYS_NS")
  fi

# Back up each namespace
  for NS in $NAMESPACES; do
    pp t2 "Saving namespace $G$NS"
    mkdir -p "$OUTDIR/$NS"
    backup_namespace "$NS"

    # Discover all namespaced resource types dynamically — no hardcoded list
    while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      RESOURCE=$(echo "$LINE" | awk '{print $1}')
      KIND=$(echo     "$LINE" | awk '{print $NF}')
      echo "$KIND" | grep -qE "$SKIP_KINDS" && continue
      backup_kind "$NS" "$KIND" "$RESOURCE"
    done < <(kubectl api-resources --namespaced=true --verbs=list --no-headers 2>/dev/null | \
               awk '{print $1, $NF}' | sort -u)

    # Also grab PersistentVolumes bound to this namespace (they are cluster-scoped)
    backup_pvs "$NS"
  done

# Summary
  pp sep
  pp t2 "Saved   ${G}$SAVED${S}${Y} resource(s) to ${G}${OUTDIR}/${S}"
  pp t2 "Skipped ${A}$SKIPPED${S}${Y} auto-generated resource(s)"
  (( SAVED > 0 )) && pp t2 "Restore ${G}kubectl apply -f ${OUTDIR}/<namespace>/${Y}" || true
  echo
