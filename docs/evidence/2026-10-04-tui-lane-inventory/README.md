# Common Lane inventory TUI evidence

The production decoder and display module passed 12 focused scenarios under
OCaml 5.5.1. `isolated_inventory_check.py` copies actual production files and
extracts unchanged exact/phase decoder blocks; its only generated modules are
namespace aliases. `inventory-check-provenance.json` hashes those sources and
extracts. This is not a complete Masc or TUI link.

The actual declaration session module passed 4 isolated navigation scenarios;
`declaration-path-check.json` records source hashes and commands. Five authored
Python fixture payloads also passed the actual production inventory decoder;
`fixture_wire_check.ml`, the input corpus and its log retain that check.

Run the focused decoder check from the checkout:

```sh
opam exec --switch=5.5.1 -- python3 docs/evidence/2026-10-04-tui-lane-inventory/isolated_inventory_check.py
```

At the original isolated-evidence head, native server, full TUI typecheck/link,
PTY execution, CI and production behavior were not run. Those historical
artifacts remain isolated evidence, rather than current linked-TUI proof.


## Current parent integration and local verification (2026-10-04)

The integration includes parent `e6f576349f9d54242148d7d3b95e20202256c86c`.
A focused repository-wrapper build linked the actual TUI and four touched native
test targets under OCaml 5.5.1. Inventory (12), declaration path (4), and MSX
load (16) tests passed. The complete keys target passed 121 of 124 cases; its
three Config failures are tracked by #41165; a separate repair is proposed in #41177.
Their assertion bodies are byte-identical to the parent and main; this target
is not reported as a complete PASS.

The first-live-read MSX failure was reproduced with only the retry branch
disabled: a visible initial 503 stayed failed after the fixture recovered,
without closing the view or injecting a key. Enabling the guarded read retry
passed the same recovery flow. Earlier namespace/interface compile failures
and fixture-startup failures are separate from that behavior RED.

The final linked TUI SHA-256 is
`249e5e908a883ea30dad4c70b5c5e836f48a593ddbec5262b2df6a3fc1e9ba87`.
Against this binary, the four inventory PTY flows passed (60 and 80 columns,
exact/browser/machine/declaration/retained-worker destinations, and MSX recovery),
as did the runtime surface, four lane-editor routing/filter flows, and two
model-source read-isolation flows. Fixtures verify the actual GET callbacks,
exact selected identities, and absence of inspection mutations. An unfocused
Lanes overview now owns its `i`/`d` inspection keys before composer dispatch;
a focused composer retains ordinary text input.

Ruff passed for the changed Python consumers. Pyright reports the unchanged
11 loose fixture-shape diagnostics in the inventory file and 14 in the lane
editor; the runtime keyboard consumer has none. There is no full-suite, CI,
release, deployed-server, or production-readiness claim. Historical copied
source ledgers above remain pinned to their original source.
