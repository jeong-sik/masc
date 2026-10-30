# Published Artifact Opt-In External Sharing Evidence (2026-10-27)

## Scope & Provenance

- **Branch**: `feat/published-artifact-capability-share` (PR [#46354](https://github.com/jeong-sik/masc/pull/46354))
- **Date**: 2026-10-27
- **Sanitization Notice**: All captures in this bundle use a synthetic fixture report (`artifact-0123456789abcdef0123456789abcdef`, author `keeper`, workspace `/workspace/masc`) so no operator credentials, host paths, or internal documents are stored in version control.

## Retained Captures

1. [`dashboard-external-readonly.png`](./dashboard-external-readonly.png)
   - Unauthenticated external reader navigating to `#workspace?section=artifacts&artifact=artifact-0123456789abcdef0123456789abcdef` when `shared = true`.
   - Renders `SharedArtifactObservation` (`외부 공유 열람` badge, read-only document view, and Word/PPTX/PDF/source export controls) without exposing the workspace catalog.
2. [`dashboard-operator-share-toggle.png`](./dashboard-operator-share-toggle.png)
   - Authenticated operator view in `ArtifactReader` showing the `외부 공유 켜기` / `외부 공유 중` toggle button (`POST /api/v1/published-artifact-shares`) and clipboard confirmation (`외부 공유를 켜고 링크를 복사했습니다.`).
3. [`tui-resources-external-share.png`](./tui-resources-external-share.png)
   - TUI `Resources` split-pane detail view (`bin/masc_tui_render_resources.ml`, `bin/masc_tui_resource_document.ml`, `bin/masc_tui.ml`) showing the `· [외부 공유중]` header badge and `External sharing: enabled (P: revoke)` metadata line.

## Verification Commands

- `pnpm --dir dashboard test src/api/published-artifacts.test.ts src/components/published-artifacts/artifacts-authority.test.ts` (20 passed)
- `pnpm --dir dashboard build` (exit 0)
- Unverified locally per `<execution_protocol>`: full OCaml `dune build` / `dune runtest` (delegated to GitHub Actions CI).
