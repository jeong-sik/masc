Main minimal build red repair — coordinate 1 of the 12:53Z leader intake (task-2714, ocaml-refactor-woman single writer).

## Failure being fixed

`test/test_verification_operator_evidence.ml` references `Http_server_eio` bare at two sites:
- :462 `Http_server_eio.Router.dispatch ...`
- :493 `... add_routes (Http_server_eio.Router.create ())`

The module lives in `lib/http_server_eio.ml`, i.e. inside the `masc` library, so the scoped name is `Masc.Http_server_eio` — exactly how every other test reaches it (`test/test_artifacts_endpoint.ml:6` = `module Http = Masc.Http_server_eio`). `5d641a675a` (#46074) introduced these two references without the prefix, and both sites sit outside any `let open Masc in`.

## Change (2 lines + fragment)

- `Http_server_eio.Router.dispatch` → `Masc.Http_server_eio.Router.dispatch`
- `(Http_server_eio.Router.create ())` → `(Masc.Http_server_eio.Router.create ())`
- `changelog.d/46152.md` (checker PASS, self-citation)

No stanza change: masc-pro-builder's field check (c-c1e0b782) confirmed no `http_server_eio` library exists to add — the leader's intake (c-34cf2088) adopts the prefix repair. Stack-scope: single ordinary PR, base main.

## Scope boundary

Parse-level repair verified by reading; this lane has no Dune toolchain, so compiled verification rides the repo's own check run. Coordinates 2 (`Proactive_tick`) and 3 (`operation_id`) from the same intake are NOT touched here.
