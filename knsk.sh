#!/bin/sh

# ----------------------------------------------------------------------------
#
# knsk.sh
#
# This script delete Kubernetes' namespaces that stuck in Terminanting status
#
#                                                          thyarles@gmail.com
#
# ----------------------------------------------------------------------------

# Ensure declaration of variables before use it
set -u

# Short for kubectl
k=kubectl

# Clean flag
clean=0

# Found flag
found=0

# Check if kubectl are available
echo "\nKubernetes namespace killer\n"
echo -n "- Testing if kubectl is configured... "
$k cluster-info > /dev/null 2>&1; error=$?

if [ $error -gt 0 ]; then
  echo "failed!"
  echo "\n  Please, check if your kubeclt is installed and configured.\n"
  exit 1
else
  echo "ok!\n"
fi

# Try clean deletion first, as suggested by https://github.com/kubernetes/kubernetes/issues/60807#issuecomment-524772920
echo -n "- Cheking for unavailable apiservices... "
apiservices=$($k get apiservice | grep False | cut -f1 -d ' ')  

if [ "x$apiservices" != "x" ]; then echo "found:\n"

  for a in $apiservices; do echo "  -- $a (not available)"; done
  
  echo -n "\n  Should I delete it for you (yes/[no])? > "; read action; echo ""

  if [ "x$action" != "xyes" ]; then

    echo "\tOk, the right way is delete not available apiservices resources, check it on"
    echo "\thttps://github.com/kubernetes/kubernetes/issues/60807#issuecomment-524772920\n"
    echo "\tIf you want to delete by yourself later, run:\n"
    for a in $apiservices; do echo "\t$k delete apiservice $a"; done
    echo 

  else

    # Set clean action
    clean=1
    for a in $apiservices; do 
      echo -n "  >> Deleting $a... "
      $k delete apiservice $a > /dev/null 2>&1; error=$?
      if [ $error -gt 0 ]; then
        echo "failed!"
      else
        echo "ok!"
      fi
    done

  fi
else 
  # Not found apiservices to delete
  echo "not found!\n"
fi

if [ $clean -gt 0 ]; then
  # As apiresouces was deleted, set a timer to see if Kubernetes do a clean deletion of stucked namespaces
  OLD_IFS="$IFS"; IFS=:; echo
  set -- $*; secs=300
  while [ $secs -gt 0 ]; do
    sleep 1 &
    printf "\r- apiresources deleted, waiting 5 minutes to see if Kubernetes do a clean namespace deletion... %02d:%02d" $(( (secs/60)%60)) $((secs%60))
    secs=$(( $secs - 1 ))
    wait
  done
  printf "\r- apiresources deleted, waiting 5 minutes to see if Kubernetes do a clean namespace deletion... ok!  " 
  set -u; IFS="$OLD_IFS"; echo "\n"; clean=0
fi

# Looking for stucked namespaces
echo -n "- Checking for namespaces in Terminating status... "
namespace=$($k get ns 2>/dev/null | grep Terminating | cut -f1 -d ' ')

if [ "x$namespace" != "x" ]; then echo "found!\n"

  # Set the flag
  found=1

  # Finding all resources that still exist in namespace
  for n in $namespace; do

    echo -n "  -- Cheking resources in namespace $n... "

    resources=$($k api-resources --verbs=list --namespaced -o name 2>/dev/null | \
                xargs -n 1 $k get -n $n --no-headers=true --show-kind=true 2>/dev/null | \
                grep -v Cancelling | cut -f1 -d ' ')

    if [ "x$resources" != "x" ]; then echo "found!\n"
      
      # Delete namespace pedding resources
      for r in $resources; do echo "     --- $r"; done
      echo -n "\n     Should I delete it for you (yes/[no])? > "; read action; echo ""

      if [ "x$action" != "xyes" ]; then
        echo "\tOk, the right way is delete not available apiservices resources, check it on"
        echo "\thttps://github.com/kubernetes/kubernetes/issues/60807#issuecomment-524772920\n"
      else
        # Set the flag
        clean=1
        for r in $resources; do
          echo -n "     >> Deleting $r... "
          $k -n $n --grace-period=0 --force=true delete $r > /dev/null 2>&1; error=$?
          if [ $error -gt 0 ]; then 
            echo "failed!"
          else
            echo "ok!"
          fi
        done   
        echo
      fi
    else 
      echo "not found!\n"
    fi  
  done 
else

  # No namespace in Terminating mode found
  echo "not found!\n"

fi

if [ $clean -gt 0 ]; then
  # As resources was deleted, set a timer to see if Kubernetes do a clean deletion of stucked namespaces
  OLD_IFS="$IFS"; IFS=:
  set -- $*; secs=60
  while [ $secs -gt 0 ]; do
    sleep 1 &
    printf "\r- Waiting a minute to see if Kubernetes do a clean namespace deletion... %02d:%02d" $(( (secs/60)%60)) $((secs%60))
    secs=$(( $secs - 1 ))
    wait
  done
  printf "\r- Waiting a minutes to see if Kubernetes do a clean namespace deletion... ok!  " 
  set -u; IFS="$OLD_IFS"; echo "\n"; clean=0
fi

# If flag found is setted, check again for stucked namespaces
if [ $found -gt 0 ]; then

  echo -n "- Checking again for namespaces in Terminating status... "
  namespace=$($k get ns 2>/dev/null | grep Terminating | cut -f1 -d ' ')
  
  if [ "x$namespace" != "x" ]; then echo "found!\n"

    # Try to get the access token
    echo -n "  -- Getting the access token to force deletion... "
    t=$($k -n default describe secret \
      $($k -n default get secrets | grep default | cut -f1 -d ' ') | \
      grep -E '^token' | cut -f2 -d':' | tr -d '\t' | tr -d ' '); error=$?

    if [ $error -gt 0 ]; then 
      echo "failed!\n"
      exit 1
    else
      echo "ok!\n"
    fi

    # Start the kubeclt proxy
    echo -n "  -- Starting kubectl proxy... "
    $k proxy > /dev/null 2>&1 &
    error=$?; k_pid=$!

    if [ $error -gt 0 ]; then 
      echo "failed!\n"
      exit 1
    else
      echo "ok!\n"
    fi

    # Forcing namespace deletion
    for n in $namespace; do
      echo -n "  >> Forcing deletion of $n... "
      j=/tmp/$n.json
      $k get ns $n -o json > $j 2>/dev/null
      sed -i s/\"kubernetes\"//g $j
      curl -s -o $j.log -X PUT --data-binary @$j http://localhost:8002/api/v1/namespaces/$n/finalize -H "Content-Type: application/json" --header "Authorization: Bearer $t" --insecure
      sleep 5
      echo "ok!"
    done

    # Kill kubectl proxy
    echo -n "\n  -- Stopping kubectl proxy... "
    kill $k_pid

    if [ $error -gt 0 ]; then 
      echo "failed!\n"
      exit 1
    else
      echo "ok!\n"
    fi
  else
    echo "not found!\n"
  fi
fi

echo "Done! Please, check if your stucked namespace was deleted!\n"