#!/bin/bash

## https://github.com/kubernetes/kubernetes/issues/24873#issuecomment-416189335

i=$((0))
for n in $(kubectl get -o=custom-columns=NAMESPACE:.metadata.namespace,KIND:.kind,NAME:.metadata.name pv,pvc,configmap,ingress,service,secret,deployment,statefulset,hpa,job,cronjob --all-namespaces | grep -v 'secrets/default-token')
do
    if (( $i < 1 )); then
        namespace=$n
        i=$(($i+1))
        if [[ "$namespace" == "PersistentVolume" ]]; then
            kind=$n
            i=$(($i+1))
        fi
    elif (( $i < 2 )); then
        kind=$n
        i=$(($i+1))
    elif (( $i < 3 )); then
        name=$n
        i=$((0))
        if [[ "$namespace" != "NAMESPACE" ]]; then
            if [[ "$namespace" = "<none>" ]]; then 
                namespace="_PVs"
            fi
            mkdir -p $namespace
            yaml=$((kubectl get $kind -o=yaml $name -n $namespace ) 2>/dev/null)
            if [[ $kind != 'Secret' || $yaml != *"type: kubernetes.io/service-account-token"* ]]; then
                echo "Saving ${namespace}/${kind}.${name}.yaml"
                kubectl get $kind -o=yaml $name -n $namespace > $namespace/$kind.$name.yaml
            fi
        fi
    fi
done
