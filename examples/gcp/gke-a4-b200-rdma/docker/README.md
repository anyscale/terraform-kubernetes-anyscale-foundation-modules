# GCP RDMA/UCCL Docker layer

These Dockerfiles, env, and scripts build the GCP A4/B200 RDMA + UCCL/DeepEP container
layer (the image is not yet published; build it from here).

The default GCP validation flow does **not** require a prebuilt image — it runs Ray pods on
`nvcr.io/nvidia/pytorch:25.04-py3` and compiles UCCL in the pods at runtime
(`scripts/install-uccl-in-ray-workers.sh`). Build an image here only if you want to prebake
UCCL/DeepEP; then push it to a registry your cluster can pull and set `ray.image` in
`../helm/gke-b200-rdma-addons/values.yaml` to that image.

Build:

```bash
BASE_IMAGE=nvcr.io/nvidia/pytorch:25.04-py3 IMAGE=<your-registry>/gcp-rdma-uccl:dev bash scripts/build_image.sh
```

Or with Cloud Build (set `PROJECT`, `_REGION`, repository, image, and tag explicitly):

```bash
gcloud builds submit --config cloudbuild.yaml --substitutions=_IMAGE=<region>-docker.pkg.dev/<project>/<repo>/gcp-rdma-uccl:dev .
```

Notes:

- UCCL v0.1.1 needs DMA-BUF compiled into `uccl.ep` (a guarded `#define USE_DMABUF`), not
  just exported at runtime; the build applies this patch.
- `env/` and `scripts/` are also copied into running pods by the validation flow, so keep
  them in sync with this layer.
