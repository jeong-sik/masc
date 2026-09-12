# PDF verification inspection

A real Codex Goal proof read four PNGs but rejected the original exhibition Goal because reading booklet.pdf returned lookup_output_invalid_utf8. A raw PDF string does not prove page count or image content.

The new authority Read path captures the complete contained source, parses Poppler's pdftotext -bbox-layout XHTML with strict Markup.ml XML parsing, and renders every parsed page with pdftoppm -png -singlefile -f N -l N. Both commands read the same private read-only PDF copy. Metadata carries the original byte count/SHA-256, page count, geometry, extracted text, parser diagnostics and each rendered image's byte count/SHA-256. Images are model content, not a claim that the model saw them. The existing image byte policy applies to every page.

`poppler-protocol.json` records an actual local execution of those Poppler commands against the original 102,608-byte booklet, SHA-256 ebabc3f74b44bdd43b3a4aebb2355db7760ab9cb16aa1b785494ac799da6c3eb. It produced three A4 pages and Korean text. All three PNG hashes match the original submitted page renderings byte-for-byte. Malformed PDF input failed with exit 1.

This probe does not execute the OCaml authority or obtain a model verdict. The feature test drives Task and Goal Read roots, full source identity, three rendered pages, malformed input, line-window rejection, root/symlink containment, missing dependencies, and unchanged source bytes. CI is the build and integration execution boundary.

Poppler must be installed on the runtime host (`poppler-utils` on Debian/Ubuntu or `poppler` on macOS). CI and release-test runners install it explicitly. Current portable runtime archives do not bundle Poppler; a successful CI run does not prove a fresh installation has the dependency. Missing tools produce pdf_dependency_unavailable and no fabricated metadata.

Protocol references: [pdftotext](https://manpages.debian.org/bookworm/poppler-utils/pdftotext.1.en.html), [pdftoppm](https://manpages.debian.org/bookworm/poppler-utils/pdftoppm.1.en.html).
