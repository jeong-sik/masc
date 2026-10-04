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

Native server, full TUI typecheck/link, PTY execution, CI and production behavior
were not run. The Python scenarios are authored consumers, not PTY PASS evidence.
Independent source review is recorded separately at the final committed head.
