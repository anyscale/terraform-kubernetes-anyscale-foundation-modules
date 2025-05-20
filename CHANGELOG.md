## 0.4.2 (Released)
FEATURES:

BUG FIXES:

BREAKING CHANGES:

NOTES:
- Update Azure example README title

BUG FIXES:

BREAKING CHANGES:

NOTES:
- Update Azure example for latest Anyscale CLI.

## 0.4.0 (Released)
FEATURES:
- Add Azure example for new AKS cluster

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.3.5 (Released)
FEATURES:
- Add node_group_gpu_types option to dynamically define GPU nodegroups

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.3.4 (Released)
FEATURES:

BUG FIXES:
- Fix gpu t4/l4 labels and taints

BREAKING CHANGES:

NOTES:

## 0.3.3 (Released)
FEATURES:

BUG FIXES:
- Fix node_location to work with zonal gke cluster

BREAKING CHANGES:

NOTES:

## 0.3.2 (Released)
FEATURES:

BUG FIXES:
- Add validation to gke_cluster_name

BREAKING CHANGES:

NOTES:

## 0.3.1 (Released)
FEATURES:

BUG FIXES:

BREAKING CHANGES:
- Refactor of gke examples

NOTES:

## 0.3.0 (Released)
FEATURES:
- Update GKE Example to make Filestore optional

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.2.2 (Released)
FEATURES:

BUG FIXES:
- GKE new_cluster - Add implicit depends_on for IAM binding

BREAKING CHANGES:


NOTES:

## 0.2.1 (Released)
FEATURES:
- New example for deploying Anyscale Operator on a new GKE cluster

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.2.0 (Released)
FEATURES:

BUG FIXES:

BREAKING CHANGES:
- Refactored of AWS EKS Examples. These new examples **WILL** replace your existing EKS Cluster.

NOTES:

## 0.1.10 (Released)
FEATURES:

BUG FIXES:
- Examples to use remote links
- ALB Controller fix for EKS examples

BREAKING CHANGES:

NOTES:

## 0.1.9 (Released)
FEATURES:

BUG FIXES:

BREAKING CHANGES:

NOTES:
- General Cleanup

## 0.1.8 (Released)
FEATURES:
- AWS EKS Public update for changes to the Anyscale Helm Chart

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.1.7 (Released)
FEATURES:

BUG FIXES:

BREAKING CHANGES:

NOTES:
- Remove warning note about EKS Private

## 0.1.6 (Released)
FEATURES:
- Updates to support latest version of Anyscale Operator Helm chart.

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.1.5 (Released)
FEATURES:

BUG FIXES:
- GKE - Existing Cluster Example - Remove var for existing VPC

BREAKING CHANGES:

NOTES:

## 0.1.4 (Released)
FEATURES:

BUG FIXES:
- GKE - Existing Cluster Example

BREAKING CHANGES:

NOTES:

## 0.1.3 (Released)
FEATURES:
- GKE - Existing Cluster Example

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.1.2 (Released)
FEATURES:
- GKE - Existing Cluster Example - Initial Commit

BUG FIXES:

BREAKING CHANGES:

NOTES:

## 0.1.1 (Released)
FEATURES:

BUG FIXES:
- Switches the EKS Node Group tolerances from ANY to ON_DEMAND as taints must be unique to a tuple of (key, effect) in EKS.

BREAKING CHANGES:

NOTES:
- Currently only tested with AWS EKS. Examples and testing for GCP GKE still to be completed.


## 0.1.0 (Released)
FEATURES:
- Initial Kubernetes Anyscale Terraform Module release

BUG FIXES:

BREAKING CHANGES:

NOTES:
- Currently only tested with AWS EKS. Examples and testing for GCP GKE still to be completed.
