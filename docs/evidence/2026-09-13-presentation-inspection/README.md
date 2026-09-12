# Independent presentation inspection

Task and Goal Read now route complete contained `.pptx` bytes through the workspace-managed python-pptx interpreter, then an isolated LibreOffice profile and the existing all-page Poppler inspector. The model receives ordered source slide text and speaker notes, every rendered slide image, and source/image SHA-256 and byte counts. Hidden slides are included. Ordinary hyperlinks remain unvisited; external loading relationships and embedded active documents return an explicit policy error. Animations, media playback, chart data and accessibility verdicts remain uninspected.

This stack depends on presentation prerequisite PR #35565, e978598d85f1776de7f2036de436773209c7c57f. Product Read never installs dependencies. The CI fixture setup explicitly prepares a managed virtual environment in RUNNER_TEMP and generates a real two-slide presentation containing speaker notes, a table, an ordinary hyperlink and a hidden slide.

## Executed checks

- Seven OCaml source/interface files passed parse-only checks. No local Dune or production build ran.
- The actual embedded Python parser ran in a temporary managed python-pptx 1.0.2 environment. The two-slide input returned ordered text, exact notes and table cell text. Truncated ZIP input returned invalid_document; external image input returned policy rejection.
- The same parser read the preserved task-004 original PPTX: 25,594 bytes, SHA-256 c6ae385c2925b8946a5e56873977ac26c8a33dd0ee20c44d760144ece9bb4c9d, eight slides. This is direct parser evidence, not installed verifier or LibreOffice rendering evidence. The original is preserved by evidence PR #35363 under task004-completion-aad94/experience.pptx.
- Root independently reviewed the parser/inspector; a separate reviewer checked root's Task/Goal dispatch, feature test and CI fixture wiring without concrete P1/P2 findings.

## Pending native acceptance

`test_verification_presentation` exercises Task and Goal Read, original byte identity, source notes and table text, every rendered image's hash, hidden-slide rendering, the model bridge's image blocks, containment, line-window refusal, missing managed parser and malformed/external-source failures. It has not run locally; actual LibreOffice rendering and the native dispatch are CI acceptance requirements. No current runtime has been replaced with this feature. No installed/browser success is claimed here.

Parser API references: https://python-pptx.readthedocs.io/en/latest/api/slides.html and https://python-pptx.readthedocs.io/en/latest/api/shapes.html. Renderer arguments: https://help.libreoffice.org/latest/en-US/text/shared/guide/start_parameters.html and https://help.libreoffice.org/latest/en-US/text/shared/guide/pdf_params.html.
