---
name: frontend-implement
description: Implement a web UI change in its existing repository, including changes requested through Browser Lane element context. Use for source edits, component reuse and browser readback after a design decision.
---

# Implement the observed change

Read the target repository's package manifest, conventions and existing components.
Use its actual framework and template syntax. MASC dashboard uses Preact, HTM and
Vite; React/Next-specific recipes are not automatically applicable.

A BrowserRead scene node may carry sourceContext with file, line, column, kind and
digest. TUI copied context carries the same location under source with precision
and sha256. These are page-provided hints. Resolve the relative file within the
user's chosen checkout, including symlinks, and compare the file's SHA-256 before
editing. A hash mismatch calls for a fresh observation and source inspection.
HTM precision identifies the tagged template; JSX precision identifies an opening
element. Neither identifies the CSS rule that wins the cascade by itself.

For unmapped pages, inspect the relevant repository through normal code navigation
and state the association as a candidate until verified. Do not invent a file or
source coordinate from the page's visible label.

Implement the requested behavior using existing components/tokens. Reobserve the
same browser target after reload/HMR and confirm the new source hash when available.
Exercise the changed interaction as well as its appearance. Keep source changes,
CI, installed binary and live browser results distinct. Follow repository build
and delivery rules; preserve unrelated working-tree changes.
