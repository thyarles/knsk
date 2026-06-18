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

# Variables
  set -u       # Ensure declaration of variables before use it
  K='kubectl'  # Short for kubectl
  DELBRK=0     # Don't delete broken API by default
  DELRES=0     # Don't delete inside resources by default
  DELORP=0     # Don't delete orphan resources by default
  DELWHK=0     # Don't delete broken webhooks by default
  DRYRUN=0     # Show the commands to be executed and don't run them
  FORCE=0      # Don't force deletion of stuck namespaces by default
  CLEAN=0      # Start clean flag
  FOUND=0      # Start found flag
  KPORT=8765   # Default port to up kubectl proxy
  TIME=15      # Default timeout to wait for kubectl command responses
  WAIT=60      # Default time to wait Kubernetes do clean deletion
  C='\e[96m'   # Cyan
  M='\e[95m'   # Magenta
  B='\e[94m'   # Blue
  Y='\e[93m'   # Yellow
  G='\e[92m'   # Green
  R='\e[91m'   # Red
  A='\e[90m'   # Gray
  S='\e[0m'    # Reset
  N='\n'       # New line

# Function to show help
  show_help () {
    echo -e "\n$(basename $0) [options]\n"
    echo -e "  --dry-run\t\tShow what will be executed instead of execute it (use with '--delete-*' options)"
    echo -e "  --skip-tls\t\tSet --insecure-skip-tls-verify on kubectl call"
    echo -e "  --delete-api\t\tDelete broken API found in your Kubernetes cluster"
    echo -e "  --delete-resource\tDelete stuck resources found in your stuck namespaces"
    echo -e "  --delete-orphan\tDelete orphan resources found in your cluster"
    echo -e "  --delete-webhook\tDelete broken admission webhooks blocking namespace deletion"
    echo -e "  --delete-all\t\tDelete resources of stuck namespaces, broken API and broken webhooks"
    echo -e "  --force\t\tForce deletion of stuck namespaces even if a clean deletion fail"
    echo -e "  --port {number}\tUp kubectl proxy on this port, default is 8765"
    echo -e "  --timeout {number}\tMax time (in seconds) to wait for Kubectl commands (default = 15)"
    echo -e "  --no-color\t\tAll output without colors (useful for scripts)"
    echo -e "  --kubeconfig {path}\tThe path to a custom kubeconfig.yaml file (useful for scripts)"
    echo -e "  -h --help\t\tShow this help\n"
    exit 0
  }

# Check for parameters
  while (( "$#" )); do
    case $1 in
      --dry-run)
        DRYRUN=1
        shift
      ;;
      --skip-tls)
        K=$K" --insecure-skip-tls-verify"
        shift
      ;;
      --delete-api)
        DELBRK=1
        shift
      ;;
      --delete-resource)
        DELRES=1
        shift
      ;;
      --delete-orphan)
        DELORP=1
        shift
      ;;
      --delete-webhook)
        DELWHK=1
        shift
      ;;
      --delete-all)
        DELBRK=1
        DELRES=1
        DELORP=1
        DELWHK=1
        shift
      ;;
      --force)
        FORCE=1
        shift
      ;;
      --port)
        shift
        # Check if the port is a number
        [ "$1" -eq "$1" ] 2>/dev/null || show_help
        KPORT=$1
        shift
      ;;
      --timeout)
        shift
        # Check if the time is a number
        [ "$1" -eq "$1" ] 2>/dev/null || show_help
        TIME=$1
        shift
      ;;
      --no-color)
        C=''; M=''; B=''; Y=''; G=''; R=''; S=''; A=''
        shift
      ;;
      --kubeconfig)
        shift
        # Check if the kubeconfig exists
        [ ! -f "$1" ] && show_help
        K="${K} --kubeconfig $1"
        shift
      ;;
      *) show_help
    esac
  done

# Function to format and print messages
  pp () {
    # First argument is the type of message
    # Second argument is the message
    case $1 in
      t1    ) echo  -e "$N$G$2$S"                        ;;
      t2    ) echo  -e "$N$Y$2$S"                        ;;
      t3    ) echo  -e "$Y.: $2"                         ;;
      t4    ) echo  -e "$Y   > $2"                       ;;
      t2n   ) echo -ne "$N$Y$2...$S"                     ;;
      t3n   ) echo -ne "$Y.: $2...$S"                    ;;
      t3d   ) echo  -e "$A   $2"                         ;;
      t4n   ) echo -ne "$Y   > $2...$S"                  ;;
      t4d   ) echo  -e "$A     $2$S"                     ;;
      ok    ) echo  -e "$G ok$S"                         ;;
      found ) echo  -e "$C found$S"; FOUND=1             ;;
      nfound) echo  -e "$G not found$S"                  ;;
      dryrun) echo  -e "$M dry-run$S"                    ;;
      del   ) echo  -e "$G deleted$S"                    ;;
      skip  ) echo  -e "$C deletion skipped$S"           ;;
      error ) echo  -e "$R error$S"                      ;;
      fail  ) echo  -e "$R fail$S$N$R$N$2.$S$N"
              exit 1
    esac
  }

# Function to sleep for a while
  timer () {
    OLD_IFS="$IFS"; IFS=:; set -- $*; SECS=$1; MSG=$2
    while [ $SECS -gt 0 ]; do
      sleep 1 &
      printf "\r.: $Y$MSG$S... $G%02d:%02d$S" $(( (SECS/60)%60)) $((SECS%60))
      SECS=$(( $SECS - 1 ))
      wait
    done
    printf "\r.: $Y$MSG...$G ok      $S$N"
    set -u; IFS="$OLD_IFS"; export CLEAN=0
  }

# Check if kubectl is available and get its version
  pp t1 "Kubernetes NameSpace Killer"
  pp t2n "Checking if kubectl is configured"
  $K cluster-info >& /dev/null; E=$?
  [ $E -gt 0 ] && pp fail "Check if the kubectl is installed and configured"
  pp ok

# Check kubectl client version (minimum 1.20 recommended)
  pp t2n "Checking kubectl version"
  KVER=$($K version --client 2>/dev/null | grep -o '[Vv][0-9][0-9]*\.[0-9][0-9]*' | head -1 | tr -d 'Vv')
  KMAJ=$(echo "$KVER" | cut -d. -f1)
  KMIN=$(echo "$KVER" | cut -d. -f2 | tr -d '+')
  if [ -z "$KVER" ]; then
    echo -e " ${Y}(unable to detect version)${S}"
  elif [ "${KMAJ:-0}" -lt 1 ] || ( [ "${KMAJ:-0}" -eq 1 ] && [ "${KMIN:-0}" -lt 20 ] ); then
    echo -e " ${R}($KVER — upgrade to 1.20+ recommended)${S}"
  else
    echo -e " ${G}($KVER)${S}"
  fi

# Check for broken APIs
  pp t2n "Checking for unavailable apiservices"
  APIS=$($K get apiservice | grep False | cut -f1 -d ' ')
  # More info in https://github.com/kubernetes/kubernetes/issues/60807#issuecomment-524772920
  if [ "x$APIS" == "x" ]; then
    pp nfound  # Nothing found, go on
  else
    pp found   # Something found, let's deep in
    for API in $APIS; do
      pp t3n "Broken -> $R$API$S"
      if (( $DELBRK )); then
        CMD="timeout $TIME $K delete apiservice $API"
        if (( $DRYRUN )); then
          pp dryrun
          pp t3d "$CMD"
        else
          CLEAN=1
          $CMD >& /dev/null; E=$?
          if [ $E -gt 0 ]; then pp error; else pp del; fi
        fi
      else
        pp skip
      fi
    done
    [ $CLEAN -gt 0 ] && timer $WAIT "apiresources deleted, waiting to see if Kubernetes does a clean namespace deletion"
  fi

# Check for broken admission webhooks (a leading cause of stuck namespaces in k8s 1.20+)
  pp t2n "Checking for broken admission webhooks"
  WHKS=$( { $K get validatingwebhookconfigurations -o custom-columns='NAME:.metadata.name,NS:.webhooks[*].clientConfig.service.namespace,SVC:.webhooks[*].clientConfig.service.name,FAIL:.webhooks[*].failurePolicy' --no-headers 2>/dev/null; \
             $K get mutatingwebhookconfigurations   -o custom-columns='NAME:.metadata.name,NS:.webhooks[*].clientConfig.service.namespace,SVC:.webhooks[*].clientConfig.service.name,FAIL:.webhooks[*].failurePolicy' --no-headers 2>/dev/null; } )
  OLD_IFS=$IFS; IFS=$'\n'; WHK_BROKEN=0
  while IFS= read -r WHK_LINE; do
    [ -z "$WHK_LINE" ] && continue
    WHK_NAME=$(echo "$WHK_LINE" | tr -s ' ' | cut -d ' ' -f1)
    WHK_NS=$(echo   "$WHK_LINE" | tr -s ' ' | cut -d ' ' -f2)
    WHK_SVC=$(echo  "$WHK_LINE" | tr -s ' ' | cut -d ' ' -f3)
    WHK_FAIL=$(echo "$WHK_LINE" | tr -s ' ' | cut -d ' ' -f4)
    # Skip webhooks that use a URL instead of a service reference
    [ "$WHK_SVC" = "<none>" ] && continue
    [ -z "$WHK_SVC" ] && continue
    # Check if the backend service exists
    $K get service "$WHK_SVC" -n "$WHK_NS" >& /dev/null; E=$?
    if [ $E -gt 0 ]; then
      WHK_BROKEN=1
      FOUND=1
      if [ "$WHK_FAIL" = "Fail" ]; then
        pp t3 "Broken (failurePolicy=Fail) -> $R$WHK_NAME$S$Y (svc: $R$WHK_NS/$WHK_SVC$S$Y — $R$Y blocks deletions$S$Y)"
      else
        pp t3 "Broken -> $R$WHK_NAME$S$Y (svc: $R$WHK_NS/$WHK_SVC$S$Y not found)"
      fi
      if (( $DELWHK )); then
        # Detect whether it is validating or mutating
        $K get validatingwebhookconfiguration "$WHK_NAME" >& /dev/null && WHK_TYPE="validatingwebhookconfiguration" || WHK_TYPE="mutatingwebhookconfiguration"
        CMD="timeout $TIME $K delete $WHK_TYPE $WHK_NAME"
        if (( $DRYRUN )); then
          pp dryrun
          pp t3d "$CMD"
        else
          CLEAN=1
          $CMD >& /dev/null; E=$?
          if [ $E -gt 0 ]; then pp error; else pp del; fi
        fi
      else
        pp skip
      fi
    fi
  done <<< "$WHKS"
  (( $WHK_BROKEN )) || echo -e "${G} not found${S}"
  IFS=$OLD_IFS
  [ $CLEAN -gt 0 ] && timer $WAIT "broken webhooks deleted, waiting to see if Kubernetes does a clean namespace deletion"

# Search for resources in stuck namespaces
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
          if (( $DELRES )); then
            CMD1="timeout $TIME $K -n $NS --grace-period=0 --force=true delete $RES"
            CMD2="timeout $TIME $K -n $NS patch $RES --type json \
            --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]'"
            if (( $DRYRUN )); then
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
      if (( $DELRES )); then
        CMD1="timeout $TIME $K -n $NOS --grace-period=0 --force=true delete $NRS"
        CMD2="timeout $TIME $K -n $NOS patch $NRS --type json \
            --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]'"
        if (( $DRYRUN )); then
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
      if (( $DELORP )); then
        CMD1="timeout $TIME $K -n $NOS --grace-period=0 --force=true delete $KND/$NRS"
        CMD2="timeout $TIME $K -n $NOS patch $KND/$NRS --type json \
            --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]'"
        if (( $DRYRUN )); then
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

    # Check if --force is used without --delete-resource
    pp t3n "Checking compliance of --force option"
    (( $DELRES )) || pp fail "The '--force' option must be used with '--delete-all' or '--delete-resource' options"
    pp ok

    # Check for python3 (needed for JSON manipulation)
    pp t3n "Checking for python3"
    python3 --version >& /dev/null || pp fail "python3 is required for --force but was not found"
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
        TMP=$(mktemp /tmp/knsk-XXXXXX.json)
        CMD="$K replace --raw /api/v1/namespaces/$NS/finalize -f $TMP"
        if (( $DRYRUN )); then
          pp dryrun
          pp t4d "# Get namespace JSON, clear spec.finalizers, then:"
          pp t4d "$CMD"
        else
          # Modern method: kubectl replace --raw (works on k8s 1.20+, no proxy or token needed)
          $K get namespace "$NS" -o json 2>/dev/null | \
            python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" \
            > "$TMP" 2>/dev/null
          $CMD >& /dev/null; E=$?
          if [ $E -gt 0 ]; then
            # Fallback: kubectl proxy + curl (for clusters older than 1.20)
            pp t4n "Modern method failed, trying legacy proxy method"
            KPID=0
            TOKEN=""
            # Try modern token generation first (k8s 1.24+), then fall back to secret lookup
            TOKEN=$($K create token default -n default 2>/dev/null) || \
            TOKEN=$($K -n default get secrets -o jsonpath='{.items[?(@.type=="kubernetes.io/service-account-token")].data.token}' 2>/dev/null | \
                    python3 -c "import sys,base64; d=sys.stdin.read().strip(); print(base64.b64decode(d).decode())" 2>/dev/null)
            if [ -z "$TOKEN" ]; then
              pp error
              pp t4d "Could not obtain a token — namespace $NS may need manual cleanup"
            else
              $K proxy --accept-hosts='^localhost$,^127\.0\.0\.1$,^\[::1\]$' -p $KPORT >> /tmp/knsk-proxy.out 2>&1 &
              KPID=$!; sleep 2
              $K get ns "$NS" -o json 2>/dev/null | \
                python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" \
                > "$TMP" 2>/dev/null
              curl -s -X PUT --data-binary "@$TMP" \
                "http://localhost:$KPORT/api/v1/namespaces/$NS/finalize" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $TOKEN" --insecure >& /dev/null; E=$?
              kill $KPID 2>/dev/null; wait $KPID 2>/dev/null
              if [ $E -gt 0 ]; then pp error; else pp ok; fi
            fi
          else
            pp ok
          fi
          rm -f "$TMP"
        fi
      done
    fi
  fi

# End of script
  (( 1-$FOUND )) || (( $DELBRK )) || (( $DELRES )) || (( $DELORP )) || \
  pp t2 ":: Download and run '$G./knsk.sh --help$Y' if you want to delete resources by this script."
  pp t2 ":: Done in $SECONDS seconds.$N"
  exit 0
