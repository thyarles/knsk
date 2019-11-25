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

echo "\nknsk\tThis script tries to kill stucked namespaces\n"
echo -n "\t- Testing if kubectl is configured... "
$k cluster-info > /dev/null 2>&1; error=$?
if [ $error -gt 0 ]; then
  echo "error, I can't execute kubectl on this machine!\n"
  exit 1
else
  echo "ok!\n"
fi

echo -n "\t- Checking for namespaces with 'Terminating' status... "
  namespace=$($k get ns 2>/dev/null | grep Terminating | cut -f1 -d ' ')
  namespace="testea default testeb"
  if [ "x$namespace" != "x" ]; then echo "found!"

    # Found namespaces in Terminating mode, listen it
    # Cheking what can be wrong
    
    # Check if any namespaced pendencies that blocks namespace deletion
    # It is a clean deletion, as suggested by https://github.com/kubernetes/kubernetes/issues/60807#issuecomment-524772920
    echo -n "\n\t- Cheking if exists any apiservice unavailable... "
    apiservices=$($k get apiservice | grep False | cut -f1 -d ' ')  
    if [ "x$apiservices" != "x" ]; then echo "found!"
      echo "\n\t  ==>\tPlease, verifiy if the resources bellow can be deleted.\n"
      echo "\t\tIf so, delete the resourses, wait 5 minutes, and run this script again. To delete, run: \n"
      for apiservice in $apiservices; do echo "\t\t$k delete $apiservice "; done
      echo "\n\t\tif you want to force the deletion whitout delete the bad apiresources (not recommended),"
      echo "\t\tplease, call this script with the flag --force."
    else 
      echo "not found!"
    fi

    # Finding all resources that still exist in namespace
    for n in $namespace; do 
    
      echo -n "\n\t  => Cheking resources in namespace $n... "
      resources=$($k api-resources --verbs=list --namespaced -o name | \
                  xargs -n 1 $k get -n $n --no-headers=true --show-kind=true 2>/dev/null | \
                  cut -f1 -d ' ')
      if [ "x$resources" != "x" ]; then echo "found!"
        echo "\n\t  ==>\tPlease, verifiy if the resources bellow can be deleted.\n"
        echo "\t\tIf so, delete the resourses, wait 5 minutes, and run this script again. To delete, run: \n"
        for resource in $resources; do echo "\t\t$k -n $n delete $resource "; done
        echo "\n\t\tif you want to force the deletion whitout delete these resources (not recommended),"
        echo "\t\tplease, call this script with the flag --force."
      else 
        echo "not found!"
      fi                  

    done

    # Try to get the access token
    echo -n "\n\t- Getting the access token... "
      t=$($k -n default describe secret \
        $($k -n default get secrets | grep default | cut -f1 -d ' ') | \
        grep -E '^token' | cut -f2 -d':' | tr -d '\t' | tr -d ' '); error=$?

      if [ $error -gt 0 ]; then 
        echo "error, I can't get the token!\n"
        exit 1
      else
        echo "ok!\n"
      fi

  # start the kubeclt proxy
  $k proxy > /dev/null 2>&1 &
  error=$?
  k_pid=$!

  if [ $error -gt 0 ]; then
    echo "Error: can't up the kubectl proxy."
    exit 1
  fi

else
  # No namespace in Terminating status found
  echo "not found!"
  exit 0
fi

# Remove stuck namespaces
for n in $namespace
do
  echo -n "Deleting $n... "
  j=/tmp/$n.json
  # $k get ns $n -o json > $j
  # sed -i s/\"kubernetes\"//g $j
  # curl -s -o $j.log -X PUT --data-binary @$j http://localhost:8002/api/v1/namespaces/$n/finalize -H "Content-Type: application/json" --header "Authorization: Bearer $t" --insecure
  sleep 5
  echo "done!"
done

# Kill kubectl proxy
kill $k_pid

