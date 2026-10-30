# Build context contains the Linux worker executable from the repository CI build.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libffi8 libgmp10 libpq5 libsqlite3-0 libssl3t64 libzstd1 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY masc-msx-addon-worker /usr/local/bin/masc-msx-addon-worker
WORKDIR /addon
CMD ["/usr/local/bin/masc-msx-addon-worker", "--base-path", "/state"]
