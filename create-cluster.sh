#!/usr/bin/sudo bash
set -o errexit

# set cluster name
cluster_name='localcluster'

# create registry container unless it already exists
reg_name='registrynoauth'
reg_port='5000'

echo " >>> Checking local registry already running or starting"
running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  echo " >>> Starting local registry"
  docker run \
    -d --restart=always -p "${reg_port}:5000" --name "${reg_name}" \
    registry:2
fi
echo " >>> Local registry ready"

# create a cluster with the local registry enabled in containerd
cat <<EOF | kind create cluster --name ${cluster_name} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:${reg_port}"]
EOF

# connect the registry to the cluster network
echo " >>> Connecting local registry to ${cluster_name} network"
docker network connect "kind" "${reg_name}"

echo " >>> Annotate cluster nodes to the local registry"
for node in $(kind get nodes --name ${cluster_name}); do
  kubectl annotate node "${node}" "kind.x-k8s.io/registry=localhost:${reg_port}";
done

# install openfaas
echo " >>> Starting to install openfaas"
arkade install openfaas

echo " >>> Rolling out deploy/gateway (this could take a while......)"
kubectl rollout status -n openfaas deploy/gateway

echo " >>> Port forwarding svc/gateway on port 8080"
kubectl port-forward -n openfaas svc/gateway 8080:8080 &

# install and configure openfaas command line client
faascli_installed=$(faas-cli version)
if [[ "${faascli_installed}" =~ 'faas-cli: command not found' ]]; then
  echo " >>> Installing faas-cli"
  curl -SLsf https://cli.openfaas.com | sudo sh
fi

echo " >>> Logging in faas-cli in ${cluster_name}"
PASSWORD=$(kubectl get secret -n openfaas basic-auth -o jsonpath="{.data.basic-auth-password}" | base64 --decode; echo)
echo -n $PASSWORD | faas-cli login --username admin --password-stdin

echo "#################################"
echo " >>> Your environment is ready!"
echo "#################################"