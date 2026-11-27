# Build only in CI. Both stages use the same pinned, multi-architecture image,
# so the compiled checker links against the glibc it runs with.
# The first stage proves Laws.v, extracts the checker and compiles it. A proof
# that fails, a theorem resting on an axiom, Obj.magic in the extraction or a
# checker answer that differs from fixtures/law-cases.out stops the build.
FROM python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b AS prove
RUN apt-get update && apt-get install -y --no-install-recommends coq ocaml-nox \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY wkbl-laws/Laws.v wkbl-laws/Assumptions.v wkbl-laws/Extract.v wkbl-laws/driver.ml ./
COPY wkbl-laws/fixtures/law-cases.tsv wkbl-laws/fixtures/law-cases.out ./
RUN coqc -Q . WkblLaws Laws.v \
    && coqc -Q . WkblLaws Assumptions.v > assumptions.txt \
    && cat assumptions.txt \
    && test "$(grep -c '^Closed under the global context$' assumptions.txt)" = 3 \
    && coqc -Q . WkblLaws Extract.v \
    && ! grep -n 'Obj.magic' laws.ml laws.mli \
    && ocamlopt -c laws.mli laws.ml \
    && ocamlopt -w +a-4-40-41-42-44-45-70 -warn-error +a -c driver.ml \
    && ocamlopt -o wkbl-laws-check laws.cmx driver.cmx \
    && ./wkbl-laws-check < law-cases.tsv > law-cases.actual \
    && diff -u law-cases.out law-cases.actual \
    && { coqc --version; ocamlopt -version; } > BUILD_VERSIONS \
    && sha256sum Laws.v Assumptions.v Extract.v laws.ml laws.mli driver.ml wkbl-laws-check \
       > BUILD_SHA256SUMS

FROM python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b
WORKDIR /addon
COPY protocol.py /protocol.py
COPY wkbl-laws/server.py /addon/server.py
COPY --from=prove /build/wkbl-laws-check /build/BUILD_VERSIONS /build/BUILD_SHA256SUMS /addon/
USER 65534:65534
CMD ["python3", "server.py"]
