# Skill instructions browser verification

Verified CI-built source `9f7b5fc32e72b9bf81bef0899132f1dbc82bdcaf`, run
34397624075, artifact 10122207036. Every downloaded asset hash matched its
manifest before the browser loaded it. The backend remained the live 0.35.1
server; this is preview evidence, not deployment evidence.

One catalog-row click loaded the actual revision-bound `background-snapshot`
SKILL.md without opening the editor. Three live source reads (desktop, fresh
mobile page, retry) matched the selected reference and all 766 UTF-8 bytes:
SHA-256 `5834d5fcb80ea47898add0e940dd7866679fea9f7e8c2eb3003663abb6493b0b`.
An injected HTTP503 showed an unavailable message and no source text; retry
then restored the exact live source. Only the existing source-read POST was
permitted; other POSTs and WebSockets were blocked.

Desktop, focused mobile reader and unavailable screenshots were visually
inspected. The mobile reader fits the 390px viewport (x45.25, width305.5), wraps
inside its 306px client area and is keyboard focusable. The harness focuses the
reader and presses Home before mobile capture, then also captures the reader
itself. Neither source text nor its request credential is copied into JSON
receipts; receipts retain reference and SHA-256 only.

The earlier `browser-before-mobile-fix` screenshots preserve the finding that
document overflow=false did not establish a usable reader: the wide table
clipped the source. That mobile evidence is explicitly unaccepted. The product
width fix and source-specific geometry checks address that finding.
