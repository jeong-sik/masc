# Unreachable Agent Core history ladder removal — #38062

After the explicit input-owner split, every durable Keeper attempt has checked
continuity and every program-owned completion review preserves its original
evidence. The absent-continuity Agent Core block-eviction/halving path therefore
has no production caller. Remove that path, its retry vocabulary, the dedicated
`Keeper_carried_range` module, ledger front mutation, halving helper and their
old tests. The typed size-refusal predicate now describes its actual use.

Remove the corresponding unproducible carried-origin constructors, JSON encoder
cases and fresh forecast DTO decoder/renderer cases together. `of_records`
reconstructs a `Turn_record` seed from the actual response-observed range; it
does not decode those origin strings from persisted history. The observed
ledger itself, its digest witnesses and its live `observe` helpers remain.

The live history boundary resend, current-tool demotion and Memory capacity
reprojection retain their existing bodies and authority checks. Their retained
native test sources include the Memory receipt failure nested through both
boundary resend and current-tool demotion: the original error survives, only
one provider attempt runs, and all later mutation/retry callbacks are fenced.
These native tests were source-reviewed, not executed.

The forecast test still checks that configured marks cannot mutate the actual
observed ledger/front. It no longer invokes the unused eviction module to
manufacture a hypothetical decision. Old layout/wording tests were not added.
The runtime template comment now describes the actual remaining configuration
and forecast metadata rather than a deleted driver function.

Executed wire-boundary checks and syntax checks are recorded in adjacent
receipts. They are narrower than full-project typing, native integration,
provider transport, an installed binary or visible UI, none of which were run
for this unit. Independent current-head GitHub review remains separate.

Relates to #38062; the full issue remains open. Global marks declaration,
loader/validator/template removal and live configuration transition remain
subject to RFC §13.7 and Librarian §7(라)/I4. Official-client capacity recovery
still has live callers and is not retired by this unreachable Agent Core cleanup.

## Executed checks

- `execution.json`: **23 assertions PASS**, strict bytecode compilation with no
  warnings. The actual origin encoder, actual TUI decoder, their types and
  scalar helpers are extracted without dependency or algorithm ports. The
  cases cover 12 current origin round trips and 11 rejected retired/unknown or
  malformed inputs. `fragments.json` and `source-manifest.json` bind the exact
  working-tree bytes; the receipt identifies its parent commit separately.
- `syntax.json`: all **15 surviving changed OCaml files** passed strict
  syntax-only parsing. This does not resolve the project module/type graph.
- Whitespace check and configuration TOML parsing passed. The latter checks a
  comment-only change; it does not establish deployed configuration validity.

The source/codec results do not claim execution of the retained native recovery
suite or a live UI. With OCaml 5.5.1, ocamlfind and Yojson installed, reproduce
from the repository root using an owned output directory:

```sh
opam exec -- python3 docs/evidence/2026-10-23-history-ladder-removal/verify_origin_boundary.py \
  --repo . --output /tmp/history-origin-boundary-check
```
