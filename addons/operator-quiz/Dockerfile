FROM python:3.12-slim
# The host mounts the package directory at /addon, so the image carries only
# the shared protocol module that server.py imports from the parent folder.
COPY protocol.py /protocol.py
WORKDIR /addon
# No USER: the persistent state volume is created root-owned at /state, and
# the host drops every capability and mounts the root file system read-only.
CMD ["python3", "server.py", "--state", "/state"]
