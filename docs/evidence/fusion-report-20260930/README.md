# Preserved Fusion report preview evidence

These are two existing historical MCP stdio fixture/browser bundles. This merge
copies their bytes and checks their recorded hashes; it does not regenerate or
claim new screenshots, native execution, or production evidence.

- The files in this directory and `../../design/fusion-report-preview.html`
  retain the canonical judge-content bundle from commit
  `d203cefe0f74d0e3251cabdc0c7554a59a5f5476`. The Board headline is separate from
  `meta.judge.resolved_answer`.
- `parent-b7a26f08/` preserves the differing parent bundle from commit
  `b7a26f0868ff2cbb2cdc059b9fd67cb13c8254d4`, including its HTML as `preview.html`.
  That historical fixture put report content in Board `body`; it is retained
  for provenance, not as the current producer contract.

Each `preview-checks.json` records the SHA256 of its HTML, `composition.json`,
and named screenshot files. Original receipts are unchanged. The archived HTML
originally lived at `docs/design/fusion-report-preview.html` in the parent commit.
