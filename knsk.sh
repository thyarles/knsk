#!/usr/bin/env bash

# ----------------------------------------------------------------------------
#
# knsk.sh
#
# This script delete Kubernetes' namespaces that stuck in Terminanting status
#
#                                                          thyarles@gmail.com
#
# ----------------------------------------------------------------------------

# Log file
  LOG="knsk-$(date +%s).log"
  
# Welcome message
  echo -e '\nKubernetes Namespace killer [knsk]' | tee $LOG

# Help
  function help () {
    echo -e "
    $(basename $0) [options]

    --kubectl {bin}     Where is the kubectl [default to whereis kubectl]
    --not-dry-run       Execute the commands for real (take care with it)
    --skip-tls          --insecure-skip-tls-verify on kubectl call
    --delete-broken     Delete broken API found in your Kubernetes cluster
    --delete-stuck      Delete stuck resources found in your stuck namespaces
    --delete-orphan     Delete orphan resources found in your cluster
    --delete-all        Delete resources of stuck namespaces and broken API
    --force             Force deletion of stuck namespaces even if a clean deletion fail
    --port {number}     Up kubectl proxy on this port, default is 8765
    --timeout {number}  Max time (in seconds) to wait for Kubectl commands (default = 15)
    --no-color          All output without colors (useful for scripts)
    --kubeconfig {path} The path to a custom kubeconfig.yaml file (useful for scripts)\n"
    exit 1
  }

# Format output messages
  function section () {
    local MSG=$1
    echo -e "\n::: $MSG\n" | tee -a $LOG
  }

  function ok () {
    local MSG=$1
    echo -e "    [✓] $MSG"  | tee -a $LOG
  }

  function warn () {
    local MSG=$1
    echo -e "    [!] $MSG"  | tee -a $LOG
  }

  function pad () {
    local MSG=$1
    echo -e "     -  $MSG"  | tee -a $LOG
  }

  function fix () {
    local CMD=$1
    echo -ne "     -  fixing... "  | tee -a $LOG
    timeout $TIMEOUT $CMD %>> $LOG ; E=$?
    checkSuccess $E
  }

  function err () {
    local MSG=$1
    local FIX=$2
    local ERR=$3
    section "Error"  | tee -a $LOG
    echo -e "    [✗] $MSG"  | tee -a $LOG
    pad "try this: $FIX\n"  | tee -a $LOG
    exit $ERR
  }

# Util functions
  function isNumber () {
    local NUMBER=$1
    [ "$NUMBER" -eq "$NUMBER" ] 2>/dev/null || err "$NUMBER must be a number" "$(basename $0) --help" 1
  }

  function fileExists () {
    local FILE=$1
    [[ -f $FILE ]] || err "$FILE not found" "Check if the file exists" 1
  }

  function isExecutable () {
    local FILE=$1
    [[ -x $FILE ]] || err "$FILE not executable" "fix: chmod +x $FILE" 1
  }

  function checkSuccess () {
    local STATUS=$1
    [[ $STATUS -eq 0 ]] && echo "✓ success"
    [[ $STATUS -ne 0 ]] && echo "✗ failed [check the $LOG]"
  }

  function checkVersion () {
    local KUBECTL_VERSION="$($KUBECTL version --client --short | grep -E -e "v1.19" -e "v1.2")"
    [[ -n $KUBECTL_VERSION ]] || err "kubectl must be v1.19+" "fix: upgrade your kubectl" 1
    ok "$KUBECTL_VERSION"
  }

  function checkCluster () {
    local CLUSTER_INFO="$(TERM=dumb $KUBECTL cluster-info | head -1)"
    [[ -n $CLUSTER_INFO ]] || err "The cluster is not reachable" 1
    ok "$CLUSTER_INFO"
  }

  function checkKubectl () {
    [[ -z $KUBECTL ]] && err "kubectl not found" "$(basename $0) --kubectl /path/kubectl" 1
    fileExists $KUBECTL
    isExecutable $KUBECTL
    ok "kubectl to be used $KUBECTL"
    checkVersion
    checkCluster
  }

# Set default setup
  KUBECTL=$(which kubectl)    # Define kubectl location
  DEL_BROKEN_API=false        # Don't delete broken API
  DEL_STUCK=false             # Don't delete inside resources
  DEL_ORPHAN=false            # Don't delete orphan resources
  NOT_DRY_RUN=false           # Show the commands to be executed instead of run it
  FORCE=false                 # Don't force deletion with kubeclt proxy by default
  PROXY_PORT=8765             # Port to up kubectl proxy
  TIMEOUT=15                  # Timeout to wait for kubectl command responses
  ETCD_WAIT=60                # Time to wait Kubernetes do clean deletion

# Display help
  set +u
  [[ $1 == '--help' || $1 == '-h' ]] && help
  set -u

# Check for parameters
  [[ $# -gt 0 ]] && section 'Check parameters' 
  while (( "$#" )); do
    case $1 in
      --kubectl)
        shift
        ok "Set kubectl to $KUBECTL"
        KUBECTL=$1
        shift
      ;;
      --not-dry-run)
        NOT_DRY_RUN=true
        ok "Set not dry run"
        # If CI env, avoid confirmation
        set +u
        if [[ -z $CI ]]; then
          pad "are you sure about it?"
          pad "Press ENTER to continue, CTRL+C to cancel"
          read
        fi
        set -u
        shift
      ;;
      --skip-tls)
        KUBECTL="$KUBECTL --insecure-skip-tls-verify"
        ok "Set insecure tls"
        shift
      ;;
      --delete-broken)
        ok "Set delete broken API"
        DEL_BROKEN_API=true
        shift
      ;;
      --delete-stuck)
        ok "Set delete stuck reources"
        DEL_STUCK=true
        shift
      ;;
      --delete-orphan)
        ok "Set delete orphan reources"
        DEL_ORPHAN=true
        shift
      ;;
      --delete-all)
        ok "Set delete broken API, stuck, and orphan reources"
        DEL_BROKEN_API=true
        DEL_STUCK=true
        DEL_ORPHAN=true
        shift
      ;;
      --force)
        ok "Set force = true"
        FORCE=true
        shift
      ;;
      --port)
        shift
        ok "Set kubectl proxy port = $1"
        isNumber $1
        PROXY_PORT=$1
        shift
      ;;
      --timeout)
        shift
        ok "Set timeout to $1 seconds"
        isNumber $1
        TIME=$1
        shift
      ;;
      --kubeconfig)
        shift
        ok "Set kubeconfig to $1"
        fileExists $1
        KUBECTL="$KUBECTL --kubeconfig $1"
        shift
      ;;
      *)
        warn $1
        err "Invalid parameter" "$(basename $0) --help" 2
    esac
  done

# Check kubectl and cluster
  section "Check Kubernetes cluster"
  checkKubectl

# Check for broken APIs [https://github.com/kubernetes/kubernetes/issues/60807#issuecomment-524772920]
  section "Check broken APIs"
  CHECK=$($KUBECTL get --show-kind apiservice | grep False | awk '{print $1}')
  if [[ -z $CHECK ]]; then
    ok "Broken APIs not found"
  else
    for API in $CHECK; do
      warn "Broken: $API"
      CMD="$KUBECTL delete apiservice $API"
      pad "to fix: $CMD"
      if $DEL_BROKEN_API && $NOT_DRY_RUN; then fix $CMD; fi
    done  
  fi

# Check for stuck namespaces
  section "Check stuck namespaces"
  CHECK=$($KUBECTL get --show-kind ns | grep Terminating | awk '{print $1}')
  if [[ -z $CHECK ]]; then
    ok "Stuck namespaces not found"
  else
    # Show short list
    for NS in $CHECK; do warn "Stuck: $NS"; done
    # Find resources related
    # for NS in $CHECK; do
    #   section "Processing namespace $NS"
    #   # Get all resources availabe on the cluster
    #   AUX_CMD="$KUBECTL api-resources --verbs=list --namespaced -o name | xargs | sed s/\ /\,/g)"
    #   # Get resources related to the stuck namepsace avoiding warns messages
    #   RES_CMD="$KUBECTL -n $NS get --show-kind --no-headers $($AUX_CMD) 2>/dev/null"
    #   # Save the list on a variable
    #   RESOURCES=$($RES_CMD | awk '{print $1}')
    #   if [[ $RESOURCES != "" ]]; then
    #     # TODO: continue from here
    #   fi
  fi

  section "Done in $SECONDS seconds"

  exit 100

  pp t2n "Checking for stuck namespaces"
  NSS=$($K get ns 2>/dev/null | grep Terminating | cut -f1 -d ' ')
  if [ "x$NSS" == "x" ]; then
    pp nfound
  else
    pp found
    for NS in $NSS; do
      pp t3n "Checking resources in namespace $R$NS$S"
      RESS=$($K api-resources --verbs=list --namespaced -o name 2>/dev/null | \
           xargs -P 0 -n 1 $K get -n $NS --no-headers=true --show-kind=true 2>/dev/null | \
           grep -v Cancelling | cut -f1 -d ' ')
      if [ "x$RESS" == "x" ]; then
        pp nfound
      else
        pp found
        for RES in $RESS; do
          pp t4n $RES
          if (( $DEL_STUCK )); then
            CMD1="timeout $TIME $K -n $NS --grace-period=0 --force=true delete $RES"
            CMD2="timeout $TIME $K -n $NS patch $RES --type json \
            --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]'"
            if (( $DRY_RUN )); then
              pp dryrun
              pp t4d "$CMD1"
              pp t4d "$CMD2"
            else
              CLEAN=1
              # Try to delete by delete command
              $CMD1 >& /dev/null; E=$?
              if [ $E -gt 0 ]; then
                # Try to delete by patching
                bash -c "${CMD2}" >& /dev/null; E=$?
                if [ $E -gt 0 ]; then pp error; else pp del; fi
              else
                pp del
              fi
            fi
          else
            pp skip
          fi
        done
      fi
    done
    [ $CLEAN -gt 0 ] && timer $WAIT "resources deleted, waiting to see if Kubernetes do a clean namespace deletion"
  fi

# Search for stuck resources in cluster
  pp t2n "Checking for stuck resources in the cluster"
  ORS=$($K api-resources --verbs=list --namespaced -o name 2>/dev/null | \
      xargs -P 0 -n 1 $K get -A --show-kind --no-headers 2>/dev/null | grep Terminating)
  OLD_IFS=$IFS; IFS=$'\n'
  if [ "x$ORS" = "x" ]; then
    pp nfound
  else
    pp found
    for OR in $ORS; do
      NOS=$(echo $OR | tr -s ' ' | cut -d ' ' -f1)
      NRS=$(echo $OR | tr -s ' ' | cut -d ' ' -f2)
      pp t3n "Stuck -> $R$NRS$S$Y on namespace $R$NOS$S"
      if (( $DEL_STUCK )); then
        CMD1="timeout $TIME $K -n $NOS --grace-period=0 --force=true delete $NRS"
        CMD2="timeout $TIME $K -n $NOS patch $NRS --type json \
            --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]'"
        if (( $DRY_RUN )); then
          pp dryrun
          pp t3d "$CMD1"
          pp t3d "$CMD2"
        else
          CLEAN=1
          # Try to delete by delete command
          $CMD1 >& /dev/null; E=$?
          if [ $E -gt 0 ]; then
            # Try to delete by patching
            bash -c "${CMD2}" >& /dev/null; E=$?
            if [ $E -gt 0 ]; then pp error; else pp del; fi
          else
            pp del
          fi
        fi
      else
        pp skip
      fi
    done
  fi
  IFS=$OLD_IFS
  [ $CLEAN -gt 0 ] && timer $WAIT "resources deleted, waiting to Kubernetes sync"

# Search for orphan resources in the cluster
  pp t2n "Checking for orphan resources in the cluster"
  ORS=$($K api-resources --verbs=list --namespaced -o name 2>/dev/null | \
      xargs -P 0 -n 1 $K get -A --no-headers -o custom-columns=NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name 2>/dev/null)
  OLD_IFS=$IFS; IFS=$'\n'; PRINTED=0
  NSS=$($K get ns --no-headers 2>/dev/null | cut -f1 -d ' ')  # All existing mamespaces
  for OR in $ORS; do
    NOS=$(echo $OR | tr -s ' ' | cut -d ' ' -f1)
    KND=$(echo $OR | tr -s ' ' | cut -d ' ' -f2)
    NRS=$(echo $OR | tr -s ' ' | cut -d ' ' -f3)
    # Check if the resource belongs an existent namespace
    NOTOK=1; for NS in $NSS; do [[ $NS = *$NOS* ]] && NOTOK=0; done
    if (( $NOTOK )); then
      (( $PRINTED )) || pp found && PRINTED=1
      pp t3n "Found $R$KND/$NRS$S$Y on deleted namespace $R$NOS$S"
      if (( $DEL_ORPHAN )); then
        CMD1="timeout $TIME $K -n $NOS --grace-period=0 --force=true delete $KND/$NRS"
        CMD2="timeout $TIME $K -n $NOS patch $KND/$NRS --type json \
            --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]'"
        if (( $DRY_RUN )); then
          pp dryrun
          pp t3d "$CMD1"
          pp t3d "$CMD2"
        else
          CLEAN=1
          # Try to delete by delete command
          $CMD1 >& /dev/null; E=$?
          if [ $E -gt 0 ]; then
            # Try to delete by patching
            bash -c "${CMD2}" >& /dev/null; E=$?
            if [ $E -gt 0 ]; then pp error; else pp del; fi
          else
            pp del
          fi
        fi
      else
        pp skip
      fi
    fi
  done
  (( $PRINTED )) || pp nfound
  IFS=$OLD_IFS
  [ $CLEAN -gt 0 ] && timer $WAIT "resources deleted, waiting to Kubernetes sync"

# Search for resisted stuck namespaces and force deletion if --force is passed
  if (( $FORCE )); then

    pp t2 "Forcing deletion of stuck namespaces"

    # Check if --force is used without --delete-resouce
    pp t3n "Checking compliance of --force option"
    (( $DEL_STUCK )) || pp fail "The '--force' option must be used with '--delete-all' or '--delete-resource options'"
    pp ok

    # Try to get the access token
    pp t3n "Getting the access token to force deletion"
    TOKEN=$($K -n default describe secret \
          $($K -n default get secrets | grep default | cut -f1 -d ' ') | \
          grep -E '^token' | cut -f2 -d':' | tr -d '\t' | tr -d ' '); E=$?
    [ $E -gt 0 ] && pp fail "Unable to get the token to force a deletion"
    pp ok

    # Try to up the kubectl proxy
    pp t3n "Starting kubectl proxy"
    $K proxy --accept-hosts='^localhost$,^127\.0\.0\.1$,^\[::1\]$' -p $KPORT  >> /tmp/proxy.out 2>&1 &
    E=$?; KPID=$!
    [ $E -gt 0 ] && pp fail "Unable start a proxy, check if the port '$KPORT' is free. Change it by passing '--port number' flag"
    pp ok

    # Force namespace deletion
    pp t3n "Checking for resisted stuck namespaces to force deletion"
    NSS=$($K get ns 2>/dev/null | grep Terminating | cut -f1 -d ' ')
    if [ "x$NSS" == "x" ]; then
      pp nfound
    else
      pp found
      for NS in $NSS; do
        pp t4n "Forcing deletion of $NS"
        TMP=/tmp/$NS.json
        $K get ns $NS -o json > $TMP 2>/dev/null
        if [[ "$OSTYPE" == "darwin"* ]]; then
          sed -i '' "s/\"kubernetes\"//g" $TMP
        else
          sed -i s/\"kubernetes\"//g $TMP
        fi
        CMD="curl -s -o $TMP.log -X PUT --data-binary @$TMP http://localhost:$KPORT/api/v1/namespaces/$NS/finalize \
                  -H \"Content-Type: application/json\" --header \"Authorization: Bearer $TOKEN\" --insecure"
        if (( $DRY_RUN )); then
          pp dryrun
          pp t4d "$CMD"
        else
          $CMD; sleep 5
          pp ok
        fi
      done
    fi

    # Close the proxy
    pp t3n "Stopping kubectl proxy"
    kill $KPID; E=$?
    wait $KPID 2>/dev/null
    if [ $E -gt 0 ]; then pp error; else pp ok; fi
  fi

# End of script
  (( 1-$FOUND )) || (( $DEL_BROKEN_API )) || (( $DEL_STUCK )) || (( $DEL_ORPHAN )) || \
  pp t2 ":: Download and run '$G./knsk.sh --help$Y' if you want to delete resources by this script."
  pp t2 ":: Done in $SECONDS seconds.$N"
  exit 0
