# Evidence provenance

Reports listed in [anonymization.json](anonymization.json) contain neutral
organization labels and example locations in place of company-specific
identities, repository names, paths and URLs. Their numeric measurements and
result fields are retained. Treat these as sanitized derivatives: their
identity and location strings do not establish the original deployment.

Screenshots and other binary artifacts are not covered by that textual
transformation. Each individual proof bundle retains its own measurement
scope and limitations.

Retained hash or digest fields describe their original referenced captures;
they are not checksums of the sanitized files committed here.
