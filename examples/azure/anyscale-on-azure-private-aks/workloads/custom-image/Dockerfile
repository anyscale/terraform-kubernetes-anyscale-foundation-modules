ARG ANYSCALE_BASE_IMAGE=docker.io/anyscale/ray:2.55.1-slim-py312-cu129
FROM ${ANYSCALE_BASE_IMAGE}

COPY requirements-custom-image.txt /tmp/requirements-custom-image.txt
RUN python -m pip install --no-cache-dir -r /tmp/requirements-custom-image.txt \
    && python -c "import anyscale, onnxruntime, ray; print('CUSTOM_IMAGE_DEPENDENCY_OK')"