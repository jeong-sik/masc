---
status: reference
last_verified: 2026-08-10
code_refs:
  - packages/agent_core/lib
---

# Agent Core specifications

`packages/agent_core/` was imported into MASC by `eaddf336b6` (#27619), which
brought 589 `.ml`/`.mli` files across. The specifications that govern that code
stayed in `jeong-sik/oas`, which is now `archived: true` — so between #27619 and
this directory there was no in-tree spec for the imported subtree, and RFC
discovery over `docs/rfc/` returned nothing for it.

These files are those specifications, moved to sit beside the code they govern.

## Layout

| Path | Holds |
|---|---|
| `rfc/` | 24 RFCs governing provider, capability, tool, and streaming behaviour |
| `design/` | design notes for boundaries that are still live |
| `provider-capabilities-spec.md` | capability axis definitions |
| `provider-catalog.md`, `capability-manifest.md` | catalog and manifest formats |
| `architecture.md`, `api-stability.md` | library shape and stability commitments |
| `custom-providers.md`, `multi-endpoint-setup.md` | integration guides |
| `EVENT-CATALOG.md`, `RUNTIME-OUTPUT-SCHEMA-INDEX.md` | event and output schema indexes |
| `schemas/`, `schema-surfaces/` | machine-readable schema surfaces |

## What was deliberately left in the archive

`docs/archive/` (superseded RFCs and retired TLA+ models), `docs/_audit/`
(point-in-time coverage evidence from 2026-05), and `docs/migrations/`
(upgrade notes for the standalone package, which no longer has consumers now
that the library is embedded). Those describe states that no longer exist;
carrying them here would reproduce dead context.

## Status fields are not filtered

An RFC here may be Withdrawn or Superseded. Those are kept because they record
what was considered and why it was rejected, which is the part a later proposal
needs. Read the status header before citing one as current.
