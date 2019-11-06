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

set -u

# Set variable for kubectl
k=kubectl

# Test if kubectl is configured 
$k cluster-info > /dev/null 2>&1
error=$?

if [ $error -gt 0 ]; then
  echo "Error: can't execute kubectl on this machine."
  exit 1
fi

# Get stuck namespaces
namespace=$($k get ns 2>/dev/null | grep Terminating | cut -f1 -d ' ')

# If exist namespace in Terminating mode, get access token and start the kubectl proxy
if [ "x$namespace" != "x" ]; then

  # Get access token 
  t=$($k -n default describe secret $($k -n default get secrets | grep default | cut -f1 -d ' ') | grep -E '^token' | cut -f2 -d':' | tr -d '\t' | tr -d ' ')
  error=$?

  if [ $error -gt 0 ]; then
    echo "Error: can't get the token."
    exit 1
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
  echo "No namespace in Terminating status found."
  exit 0
fi

# Remove stuck namespaces
for n in $namespace
do
  echo -n "Deleting $n... "
  j=/tmp/$n.json
  $k get ns $n -o json > $j 
  sed -i s/\"kubernetes\"//g $j 
  curl -s -o $j.log -X PUT --data-binary @$j http://localhost:8001/api/v1/namespaces/$n/finalize -H "Content-Type: application/json" --header "Authorization: Bearer $t" --insecure
  sleep 5
  echo "done!"
done

# Kill kubectl proxy
kill $k_pid 
