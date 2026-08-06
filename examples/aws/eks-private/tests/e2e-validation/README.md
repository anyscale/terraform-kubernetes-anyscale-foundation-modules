# e2e-validation overlay

> **This directory is for the e2e validation harness only. Skip it for normal use of the eks-private example.**

The customer-facing `eks-private` example keeps `endpoint_public_access = false` so the EKS API endpoint is reachable only from inside the VPC (VPN, bastion, in-cluster jobs). That is the intended posture for production.

The e2e harness runs from outside the VPC and needs API server access. Rather than expose a `validation_test_mode` toggle in the example itself (which is easy to enable by accident in a real deployment), we ship that behavior here as a [Terraform override file] the harness opts into explicitly.

## What the harness does

1. Copy `_override.tf.example` to the eks-private example root as `_override.tf`:

   ```shell
   cp examples/aws/eks-private/tests/e2e-validation/_override.tf.example \
      examples/aws/eks-private/_override.tf
   ```

2. Replace the `<runner-cidr>` placeholder in the copied file with the runner's public IP / CIDR (e.g. `203.0.113.42/32`).

3. `terraform init && terraform apply` from `examples/aws/eks-private/`.

4. Run the validation steps (`./generated/deploy.sh`, plus whatever else the harness covers).

5. `terraform destroy`, then **remove `_override.tf`** so the working tree returns to the customer-facing state.

The override merges into the existing `module "eks"` block in `eks.tf` and flips `endpoint_public_access = true` with the supplied CIDR allowlist. No other behavior changes.

[Terraform override file]: https://developer.hashicorp.com/terraform/language/files/override
