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
               # TODO: Check version of kubectl and work only for 1.16 and upper
  DELBRK=0     # Don't delete broken API by default
  DELRES=0     # Don't delete inside resources by default
  DELORP=0     # Don't delete orphan resources by default
               # TODO: Change the way to check ofr orphan resources
  DRYRUN=0     # Show the commands to be executed and don't run them
  FORCE=0      # Don't force deletion with kubeclt proxy by default
               # TODO: If in k8s 1.17 or upper, try go get the reason of delayed ns deletion
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
    echo -e "  --delete-all\t\tDelete resources of stuck namespaces and broken API"
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
      --delete-all)
        DELBRK=1
        DELRES=1
        DELORP=1
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

# Check if kubectl is available
  pp t1 "Kubernetes NameSpace Killer"
  pp t2n "Checking if kubectl is configured"
  $K cluster-info >& /dev/null; E=$?
  [ $E -gt 0 ] && pp fail "Check if the kubectl is installed and configured"
  pp ok

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

    # Check if --force is used without --delete-resouce
    pp t3n "Checking compliance of --force option"
    (( $DELRES )) || pp fail "The '--force' option must be used with '--delete-all' or '--delete-resource options'"
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
        if (( $DRYRUN )); then
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
  (( 1-$FOUND )) || (( $DELBRK )) || (( $DELRES )) || (( $DELORP )) || \
  pp t2 ":: Download and run '$G./knsk.sh --help$Y' if you want to delete resources by this script."
  pp t2 ":: Done in $SECONDS seconds.$N"
  exit 0
