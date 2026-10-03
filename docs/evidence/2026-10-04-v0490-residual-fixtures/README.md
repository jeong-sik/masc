# Remaining v0.49.0 TUI fixture repairs

PR #41031, issue #41029. Scope: five test files on PR #41018 at `fd7e6c37e006af09b1dba65fb2b3b55249104c7f`. These repairs address existing release verification failures; they add no product feature or main-branch integration.

## Why these checks failed

- MCP compilation: current RC 37137607438 reached `test_mcp_server_eio.ml:2403` and failed on an unqualified wrapped module. Qualify both access constructors with `Masc.Lane_addon_sources`, as sibling lane tests do.

- Identity: `retire_identity_logins` retires attached or removed providers. The independent pending-provider fixture omitted Atlassian from its recovery inventory while expecting it to remain pending. Declare it as present but unattached.
- Portrait: Info intentionally renders an icon. Catalog-wide outfit assertions must use the Item preview, including compact base accessories. Consolidate duplicate assertions there and retain separate Info accessory/cache checks.
- Item: identity loss clears the selected Keeper while preserving detail navigation. Observe absent selection/account authority rather than requiring a list-page fallback. Keep explicit recovery and reject any late `Balance ` rendering.
- Ask: the body reports unverified workspace authority while the composer can occupy the footer. Observe the authority body plus disappearance of the question, answer affordance and confirmation; preserve admitted/non-admitted request counts.

## Evidence boundary

OCaml parsing, Python AST parsing and diff whitespace checks passed. Parsing is not typechecking. No local Dune build was run.

Diagnostic PTY execution uses the already-built macOS arm64 binary from failed RC [37108173558](https://github.com/jeong-sik/masc/actions/runs/37108173558), commit `f6348780cadde3fbb9eda74c3a9d9e20fb913b7c`, SHA-256 `2aa66ae0e700fabfa0b45147de7b33c561acb49239de0bbbb12494cb5f78891b`. It cannot prove this candidate or Linux full-suite success. The changed-product roster-failure path must be verified by the new candidate's Full RC.

The first residual-tree diagnostic passed Item identity withdrawal/recovery but failed the Ask exact request-count assertion after a held POST encountered BrokenPipeError. Its raw log is retained; subsequent findings and validation are recorded separately.

Independent source reviewer `release_merge_review` found no P0-P2 in the four initial residual diffs and confirmed that upstream disabled-Candle reason/layout coverage remained intact. This is bounded source review, not GitHub approval or Full RC evidence.

## Follow-up diagnosis and result

The shared HTTP fixture records POSTs after writing a response. A cancelled held response can raise `BrokenPipeError` first and omit an admitted request from that ledger. The Ask scenario now records phase and body on request ingress, keeps exact zero/one admission counts, rejects any admission outside workspace A, and waits for the held response to leave its gate before observing settled B state.

Both Ask modes passed on the old RC diagnostic binary with this final script. `ask-manifest.json` binds script and binary hashes, `ask-after.log` records actual request bodies and completion, and the two terminal text captures show the settled screens. The first Item diagnostic in `initial-diagnostic.log` passed identity withdrawal, recovery and late-reply rejection. The roster branch is intentionally not claimed from this old binary, because its product fix exists only in the new candidate.

The independent reviewer also caught that RequestHttpResponse can route GET to its resolver. The Ask fixture explicitly returns HTTP405 for GET, preserving the POST-only admission contract.

The final diagnostic observed a real cancelled-response BrokenPipe: the response-completion ledger recorded zero POSTs while the ingress ledger retained exactly one admitted answer from A. Both zero-admission and one-admission scenarios passed. The final manifest and captures refer to the POST-only fixture version.

Final independent review covered all five source files including the GET refusal and MCP qualification, with no remaining P0-P2 findings. No runtime or build claim is inferred from that source review.
