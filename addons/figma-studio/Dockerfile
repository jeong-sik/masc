FROM python:3.12-slim
WORKDIR /addon
COPY figma-studio/ /addon/
# The host mounts a fresh root-owned volume with volume-nocopy at /state.
# Isolation (read-only rootfs, no network/capabilities) is enforced by the host.
CMD ["python3", "server.py"]
