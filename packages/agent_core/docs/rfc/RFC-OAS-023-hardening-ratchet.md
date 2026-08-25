# RFC-OAS-023: Production Hardening Ratchet

**Status**: Draft
**Date**: 2026-06-27
**Scope**: `.ci/hardening-baseline.json`, `.ci/hardening-ratchet-config.json`, `scripts/hardening-ratchet.sh`, `.github/workflows/code-smell-ratchet.yml`
**One sentence**: Lock selected production-hardening debt metrics against a stored baseline so pull requests can only decrease or hold the counts.

## 0. Summary

This RFC adds a hardening companion to RFC-OAS-022's existing monotone-decrease ratchet. It does not create a second required workflow. The existing `Code Smell Ratchet` workflow runs both scripts and applies the same `RATCHET-WAIVED: <reason>` pull-request escape hatch.

The hardening script is deliberately narrower than a general linter:

- It scans tracked runtime OCaml source configured in `.ci/hardening-ratchet-config.json`.
- It strips OCaml comments while preserving string and character literals before matching.
- It fails on repository-resolution, UTF-8 decoding, or unterminated comment/string states.
- It has a self-test corpus that guards known false positives: comment contents, string literals with comment delimiters, user-facing error strings, legitimate `assert false` proof arms, and env-boundary paths.

## 1. Metrics

The baseline stores these metrics:

| metric | meaning | removal target |
| --- | --- | --- |
| `local_workspace_path_literals` | String literals that contain configured local home/workspace prefixes such as `/Users/`, `/home/`, or `~/`. | Target zero. New local developer paths require `RATCHET-WAIVED` with a sunset plan. |
| `direct_env_reads` | Direct `Sys.getenv`, `Sys.getenv_opt`, `Sys.unsafe_getenv`, `Unix.getenv`, or `Unix.getenv_opt` reads in runtime source. | Reduce by routing runtime configuration through explicit env/config boundary modules. |
| `direct_env_reads_outside_env_boundary` | Direct env reads outside paths listed in `.ci/hardening-ratchet-config.json`. | Target zero outside `envBoundaryPaths`. |
| `exception_message_classifiers` | Source shapes that classify by exception message text, such as `classify_by_message`, `String.lowercase_ascii msg`, or `has_substr msg`. Plain user-facing string literals like `"timeout"` are not counted. | Target zero after typed `Unix_error` / Eio / `http_error` classifiers replace message inspection. |
| `heuristic_markers` | Runtime source identifiers that explicitly mark untyped heuristic behavior. Comments and string literals are stripped before matching. | Target zero for routing/provider behavior that should be typed or catalog-backed. New heuristic code requires `RATCHET-WAIVED` with a sunset plan. |
| `workaround_markers` | Runtime source identifiers that explicitly mark workaround behavior. Comments and string literals are stripped before matching. | Target zero for permanent runtime workaround debt. Temporary additions require `RATCHET-WAIVED` with a sunset issue/RFC. |
| `model_id_string_classifiers_outside_catalog` | Direct `String.lowercase_ascii`, `String.starts_with`, `String.ends_with`, `String.contains`, or `String.equal` classification on `model`/`model_id` outside configured catalog/capability boundary files. | Keep model-id classification in catalog/capability SSOT modules; scattered provider/model matching is RFC-OAS-029 drift. |
| `stub_markers` | Runtime stubs such as `Not_implemented` and `failwith "not implemented"`. `assert false` is excluded because it is a common OCaml proof idiom for unreachable arms. | Target zero. |
| `wildcard_silent_defaults` | Line-leading catch-all arms that collapse to permissive defaults like `None`, `[]`, `Ok`, `true`, `false`, `()`, or `""`. | Reduce by replacing permissive catch-all defaults with typed/default-explicit handling. |

## 2. Workflow Semantics

The existing `.github/workflows/code-smell-ratchet.yml` is the only ratchet workflow.

- On pull requests, it runs `scripts/ci-code-smell-ratchet.sh --check`, `scripts/hardening-ratchet.sh --self-test`, and `scripts/hardening-ratchet.sh --check`.
- If any ratchet fails, the workflow fails unless the PR body contains a line beginning with `RATCHET-WAIVED:`.
- On `push` to `main`, no waiver is honored. A regression must be fixed or rebaselined by a follow-up PR.

`--rebaseline` refuses to run off `main` unless `ALLOW_REBASELINE_OFF_MAIN=1` is explicitly set. The override is intended for draft-PR review and fixture regeneration only; the normal baseline update path is main-only.

## 3. Configuration SSOT

`.ci/hardening-ratchet-config.json` defines scanner policy:

- runtime source roots and suffixes;
- excluded path parts for tests, examples, and fixtures;
- explicit env/config boundary file paths;
- explicit model string-classifier boundary file paths;
- forbidden local-path prefixes;
- max example count;
- per-metric removal targets.

Changing metric scope or boundary paths requires updating this RFC and the config in the same PR.

## 4. False-Positive Guardrails

The script's `--self-test` mode guards these cases before any CI check result is enforced:

- `Sys.getenv_opt` inside comments is not counted.
- `(*` / `*)` inside normal OCaml strings are preserved and do not corrupt scanning.
- Plain user-facing error strings such as `"connection refused"` are not counted as exception-message classifiers.
- Model-id string classifiers are allowed only in configured catalog/capability boundary paths.
  The opaque exact-identity owner [lib/llm_provider/model_id.ml] is part of that
  boundary; it validates and compares complete identifiers but performs no
  family, provider, prefix, or endpoint inference.
- `assert false` is not counted as a stub marker.
- Env reads in configured env boundary files count only toward `direct_env_reads`, not `direct_env_reads_outside_env_boundary`.

The scanner is not a replacement for typed compiler analysis. If a future metric needs semantic certainty beyond lexical source shapes, it should move to a compiler-libs or generated-artifact analyzer before becoming gating.

## 5. Current Baseline

The initial baseline is generated by:

```bash
ALLOW_REBASELINE_OFF_MAIN=1 scripts/hardening-ratchet.sh --rebaseline
```

During normal operation, rebaseline on `main` only:

```bash
scripts/hardening-ratchet.sh --rebaseline
```

Pull requests should prefer reducing the current count. If a temporary increase is unavoidable, the PR body must include:

```text
RATCHET-WAIVED: <reason and sunset issue/RFC>
```

## 6. Non-Goals

- This RFC does not attempt to classify every security or reliability issue.
- This RFC does not make regex or lexical scanning authoritative for typed runtime behavior.
- This RFC does not add a second required ratchet workflow.
