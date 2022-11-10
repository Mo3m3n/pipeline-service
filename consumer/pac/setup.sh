#!/usr/bin/env bash

# Copyright 2022 The Pipeline Service Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

usage() {

    printf 'Usage: KUBECONFIG="path-to-kubeconfig" KCP_WORKSPACE="root:default:pac" ./setup.sh\n\n'

    # Parameters
    printf "The script accepts the following parameters:\n"
    printf "KUBECONFIG (required): the path to the kubeconfig file used to connect to the cluster where Pipelines as Code will be installed\n"
    printf "KCP_WORKSPACE: Name of the kcp workspace where Pipelines as Code should be deployed. If empty, the target is assumed to be a normal k8s cluster.\n"
}

check_params() {
    KUBECONFIG="${KUBECONFIG:-}"
    KCP_WORKSPACE="${KCP_WORKSPACE:-}"
    if [[ -z "${KUBECONFIG}" ]]; then
        printf "KUBECONFIG environment variable needs to be set\n\n"
        usage
        exit 1
    fi
}

apibindings_install(){
       printf "\nInstalling APIBindings\n"
       printf "======================\n"
       kubectl kcp --kubeconfig "${KUBECONFIG}" workspace use "${KCP_WORKSPACE}"
       kubectl  apply -f  "$parent_path/manifests/apibindings/pipelines-service-compute.yaml"
       kubectl wait --for=condition=Ready=true apibindings.apis.kcp.dev kubernetes
       identityHash=$( kubectl get apibindings.apis.kcp.dev kubernetes -o "jsonpath={.status.boundResources[?(@.resource==\"ingresses\")].schema.identityHash}")
       if [[ -z "$identityHash" ]]; then
         printf "ERROR: Unable to fetch identityHash from kubernetes APIBinding"
       fi;
       sed "s/identityHash:.*/identityHash: $identityHash/" "$parent_path/manifests/apibindings/glbc.yaml" | kubectl apply -f -
       kubectl wait --for=condition=Ready=true apibindings.apis.kcp.dev glbc

}

pac_install() {
    printf "\nInstalling Pipelines as Code\n"
    printf "=============================\n"
    kubectl --kubeconfig "${KUBECONFIG}" apply -k "$parent_path/manifests/deploy"
}

update_admission_webhook_secret(){
    printf "\nUpdate admission webhook secret\n"
    printf "==================================\n"
   # Get generated glbc host
   webhook_glbc_host=$(kubectl --kubeconfig "${KUBECONFIG}" get -n pipelines-as-code ingress pipelines-as-code-webhook -o jsonpath='{.metadata.annotations.kuadrant\.dev/host\.generated}')
   # Patch admission controller webhook to set correct host
   (
   cat <<EOF
spec:
  template:
    spec:
      containers:
        - name: pac-webhook
          env:
            - name: WEBHOOK_SERVICE_NAME
              value: $webhook_glbc_host
EOF
   ) | kubectl --kubeconfig "${KUBECONFIG}" patch -n pipelines-as-code deployment/pipelines-as-code-webhook --patch-file=/dev/stdin
   # Check if webhook cert can be used for glbc host
   while ! check_webhook_cert; do
     kubectl --kubeconfig "${KUBECONFIG}" patch -n pipelines-as-code secrets pipelines-as-code-webhook-certs --patch '{"data":{"server-cert.pem":""}}'
     sleep 2s
   done
}

check_webhook_cert(){
   kubectl --kubeconfig "${KUBECONFIG}" get -n pipelines-as-code secrets pipelines-as-code-webhook-certs -o jsonpath='{.data.server-cert\.pem}' | base64 -d  | openssl x509 -noout -ext subjectAltName | grep -q $webhook_glbc_host
}


parent_path=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
check_params
apibindings_install
pac_install
update_admission_webhook_secret
printf "\nURL of the github webhook:\n"
printf "===========================\n"
printf "https://%s\n"   $(kubectl --kubeconfig "${KUBECONFIG}" get -n pipelines-as-code ingress pipelines-as-code-controller -o jsonpath='{.metadata.annotations.kuadrant\.dev/host\.generated}')
