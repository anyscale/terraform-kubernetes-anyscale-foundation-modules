#!/usr/bin/env bash
set -euo pipefail

GVNIC_NETWORK=${GVNIC_NETWORK:?Set GVNIC_NETWORK to the extra gVNIC network name}
GVNIC_SUBNET=${GVNIC_SUBNET:?Set GVNIC_SUBNET to the extra gVNIC subnet name}
RDMA_NETWORK=${RDMA_NETWORK:?Set RDMA_NETWORK to the RDMA network name}
RDMA_SUBNET_PREFIX=${RDMA_SUBNET_PREFIX:?Set RDMA_SUBNET_PREFIX to the RDMA subnet name prefix}

cat <<EOF
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: gvnic-1
spec:
  vpc: ${GVNIC_NETWORK}
  vpcSubnet: ${GVNIC_SUBNET}
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: gvnic-1
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: gvnic-1
  type: Device
EOF

for n in $(seq 0 7); do
  cat <<EOF
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: rdma-${n}
spec:
  vpc: ${RDMA_NETWORK}
  vpcSubnet: ${RDMA_SUBNET_PREFIX}-${n}
  deviceMode: RDMA
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: rdma-${n}
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: rdma-${n}
  type: Device
EOF
done

