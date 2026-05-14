# Multimodal Artifact Surface Audit — Phase 1

**Date**: 2026-04-30
**Scope**: artifact + hydrator + multimodal HTTP/dashboard layers
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`, PR #12193 / §4.5 in PR #12223)
**Position**: Fifth application of codified pattern (after Dashboard #12202/#12208, Auth #12209/#12217, Server HTTP #12213/#12218, Cascade #12222/Phase 2 sibling).

## 1. Surface

34 files across 4 sub-domains:

| Sub-domain | Files | Notes |
|---|---|---|
| `lib/multimodal/` | core types + hydrator | Artifact GADT (Code/Image/Audio/Doc kinds), provenance DAG |
| `lib/keeper/keeper_multimodal*` | keeper-side hydrator integration | callback-driven |
| `lib/server/server_routes_http_routes_multimodal.ml` | HTTP exposure | dashboard + blob store |
| `lib/shared_types/` | shared payload + metadata types | crossing layer |

Bug Models exist for `MultimodalArtifact` (RFC-Q2-4) and `MultimodalHydrator` (RFC-Q2-5) — Phase 1 work landed in Cycle 22 / Cycle 27.

## 2. Gap taxonomy (Phase 1 candidates with §4.5 predictions)

| Class | Description | Estimate | Phase 2 prediction |
|---|---|---|---|
| C1 | Storage path leak in HTTP error responses | 3–5 | **narrow-confirm** (similar pattern to PR #11080 host-path leak) |
| C2 | Upload size limits for artifact endpoints | 1 module | **narrow-discover** (per #12218: no platform body-limit enforcement; multimodal endpoint should declare its own cap) |
| C3 | Hydrator failure modes — callback silent-skip vs explicit variant | 1 module | **narrow-collapse** (callback contract may be intentionally `unit option`-style) |
| C4 | MIME / Content-Type propagation from artifact GADT kind | HTTP layer | **anchor-falsification** (GADT kind exists, but HTTP layer may serve image/audio as text/plain) |
| C5 | Bug Model coverage (RFC-Q2-4, Q2-5 already exist) | 2 specs | **narrow-confirm** (validation — verify both specs are non-trivial and currently enforced) |

### 2.1 Severity rationale

- **C4 = highest severity**: incorrect Content-Type for image/audio causes browser-side wrong rendering and is a soft security boundary (e.g., serving HTML as audio could mask XSS payloads in some configurations). This is the new flagship anchor-falsification candidate — Phase 1 hypothesizes the GADT kind is "covered" but the kind may not be wired to the HTTP response header.
- **C1 = medium**: per `feedback_b1_host_path_leak_keeper_status_detail` (#11080), path leaks in error responses are a recurring class.
- **C2 = medium**: per Server HTTP routes Phase 2 (#12218) finding that `Http_server_eio` does not enforce body limits; multimodal upload is exactly the kind of route that needs an explicit cap.
- **C3 = low**: callback contract could be by design (None = skip). Phase 2 will confirm intent.

## 3. Recommended ratchets (Phase 4 deferred)

```
multimodal_path_leak_in_error_responses     (DEC, floor TBD)
  Purpose: HTTP error responses from multimodal routes must not
  echo storage paths. Phase 2 enumerates current leaks.

multimodal_upload_size_limit_declared       (INC, floor 0)
  Purpose: explicit body-size cap on multimodal upload
  endpoints. Currently 0 (per #12218 platform finding).

multimodal_mime_correctness                 (INC, floor TBD)
  Purpose: HTTP Content-Type header derived from artifact
  GADT kind. Phase 2 measures current correctness rate.
```

## 4. Phase 2 plan (next PR)

Per §4.5 of the pattern doc, Phase 2 will:

1. **C1 verification** — sample HTTP error returns from multimodal routes; check for `path |> to_string` or sprintf concatenation with storage paths. Confirm or collapse.
2. **C2 verification** — check `lib/server/server_routes_http_routes_multimodal.ml` for body-size cap declaration. Likely confirms gap (no cap → narrow-discover real).
3. **C3 verification** — read hydrator callback signatures. If `unit option` is intentional contract → C3 collapses. If errors silently dropped → C3 stays.
4. **C4 verification** — trace artifact GADT kind through HTTP response construction. Does Content-Type header derive from `kind`? If no → anchor-falsification confirmed.
5. **C5 verification** — read `specs/boundary/MultimodalArtifact.tla` and check whether the Bug Model invariant is actually checked in CI (per `tla-bug-model-ratchet.sh`). Phase 1 estimate vs current enforcement.

## 5. Out-of-scope for Phase 1

- Multimodal dashboard projection (Dashboard observability audit covers it)
- Multimodal HTTP route auth (Server HTTP routes audit covers all routes)
- OCR / transcription pipelines (separate domain)

## 6. Audit chain context

| # | Chain | Codified-pattern invocation |
|---|---|---|
| 1 | OAS↔MASC boundary | source |
| 2 | TLA+ specs gap | second |
| 3 | TLA+ PPX adoption | third |
| 4 | Dashboard observability | first to invoke codified pattern |
| 5 | Auth/credential | second |
| 6 | Server HTTP routes | third |
| 7 | Cascade dispatch | fourth |
| 8 | **Multimodal artifact (this PR)** | fifth |

§4.5 outcome categories are now first-class predictions in Phase 1 framing — this is the second chain (after Cascade #12222) to use them as explicit Phase 1 → Phase 2 commitments.

## 7. References

- PR #12193 / #12223 — 4-phase pattern + §4.5
- PR #12112 (Bug Model RFC-Q2-4 MultimodalArtifact)
- PR #12136 (Bug Model RFC-Q2-5 MultimodalHydrator) — Cycle 27 PR
- PR #11080 — keeper_status_detail host-path leak (C1 precedent)
- PR #12218 — Server HTTP routes Phase 2 (C2 precedent)
- `lib/multimodal/artifact.ml`, `multimodal_hydrator.ml` — primary surface
- `lib/server/server_routes_http_routes_multimodal.ml` — HTTP layer

## 8. Summary table

| Metric | Value |
|---|---|
| Total ml/mli files | ~34 |
| Sub-domains | 4 |
| Gap classes (Phase 1 candidates) | 5 |
| Predicted outcomes | 1 confirm + 1 discover + 1 collapse + 1 anchor-falsification + 1 confirm |
| Recommended ratchets | 3 |
