# Expected Proof Markers

This is the **tracked checklist of markers a successful run should emit**. It is
not a record of any run. Do not confuse it with the repo-root `RESULTS.md`, which
the harness generates per `e2e` run, overwrites each time, and which is
gitignored.

This learning sample does not keep dated run transcripts in the module docs.
Run-specific logs and generated summaries belong under `.cache/` and the
repo-root `RESULTS.md` file produced by the harness.

Use this page as the current-state checklist for a successful lab validation.

## Expected Proof Markers

| Area | Success marker |
| --- | --- |
| CPU workspace Ray proof | `CPU_RAY_PROOF_OK` |
| GPU workspace Ray proof | `GPU_RAY_PROOF_OK` |
| CPU build job proof | `CPU_BUILD_JOB_PROOF_OK` |
| GPU train job proof | `GPU_TRAIN_JOB_PROOF_OK` |
| GPU Serve service proof | `GPU_SERVE_SERVICE_PROOF_OK` |
| Standard-image expected failure | `CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK` |
| Custom-image preflight | `CUSTOM_IMAGE_PREFLIGHT_OK` |
| Custom-image build | `CUSTOM_IMAGE_BUILD_OK` |
| Custom-image dependency proof | `CUSTOM_IMAGE_DEPENDENCY_PROOF_OK` |
| Custom-image SBOM | `CUSTOM_IMAGE_SBOM_OK` |
| Custom-image SBOM proof | `CUSTOM_IMAGE_SBOM_PROOF_OK` |
| Custom-image signature | `CUSTOM_IMAGE_SIGN_OK` |
| Custom-image signature verification | `CUSTOM_IMAGE_VERIFY_OK` |
| Image Integrity preflight | `IMAGE_INTEGRITY_PREFLIGHT_OK` |
| Ratify apply | `IMAGE_INTEGRITY_RATIFY_OK` |

### CPU-only deploys

With an empty `TF_VAR_gpu_pool_configs` there is no GPU node pool, so the three
GPU-backed markers — `GPU_RAY_PROOF_OK`, `GPU_TRAIN_JOB_PROOF_OK`, and
`GPU_SERVE_SERVICE_PROOF_OK` — are **not expected**. `proof all` skips those
stages and logs why; every other marker on this page still applies. A run that
skips them is a complete run for that configuration, not a partial one.

## Reading Results

A result is current only for the environment that produced it. Use the generated
`RESULTS.md` at the repo root for a live run, and keep detailed logs under
`.cache/aks-anyscale-sample-harness/runs/` out of the learning modules.
