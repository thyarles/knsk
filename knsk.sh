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

set -eu

# Set variables
k=kubectl
t=$($k -n default describe secret $($k -n default get secrets | grep default | cut -f1 -d ' ') | grep -E '^token' | cut -f2 -d':' | tr -d '\t' | tr -d ' ') || echo Error to get the token

# Get stuck namespaces
namespace=$($k get ns | grep Terminating | cut -f1 -d ' ')

if [ x$namespace != x ]; then
  # start the kubeclt proxy
  $k proxy > /dev/null 2>&1 &
  k_pid=$!
  echo $k_pid
else
  echo No namespage in Terminating status found.
  exit 0
fi

# Remove stuck namespaces
for n in $namespace
do
  echo "Force finish of $n... "
  j=/tmp/$n.json
  $k get ns $n -o json > $j 
  sed -i s/\"kubernetes\"//g $j 
  curl -s -o $j.log -X PUT --data-binary @$j http://localhost:8001/api/v1/namespaces/$n/finalize -H "Content-Type: application/json" --header "Authorization: Bearer $t" --insecure
  sleep 5
  echo -n "done!"
done

# Kill kubectl proxy
kill $k_pid 
