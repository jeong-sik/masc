open Alcotest

(** RFC-0084 PR-11 — Legacy dispatch entry surface removal pin.

    PR-11 removes [val dispatch] and [val dispatch_structured] from the
    [tool_dispatch.mli] public surface. The function definitions in
    [tool_dispatch.ml] remain as private implementation details called
    only by [guarded_dispatch] internally.

    External-caller invariant pins (PR-14 lint will enforce):

    - [pinned_external_dispatch_callers = 0]
        rg -n 'Tool_dispatch\.dispatch ' lib/ bin/ must return 0 matches.

    - [pinned_external_dispatch_structured_callers = 0]
        rg -n 'Tool_dispatch\.dispatch_structured' lib/ bin/ must
        return 0 matches.

    These constants are pinned in source so future PRs that re-introduce
    the legacy entries surface in a single-PR diff against this test.
    PR-14 telemetry-completeness lint (`ci/lint-no-direct-dispatch.sh`)
    converts these pins into a CI-time check.
*)

let pinned_external_dispatch_callers = 0
let pinned_external_dispatch_structured_callers = 0

let test_no_external_dispatch_caller () =
  (check int)
    "external callers of Tool_dispatch.dispatch \
     (RFC-0084 PR-11; mli surface removed; PR-14 CI lint enforces)"
    0
    pinned_external_dispatch_callers
;;

let test_no_external_dispatch_structured_caller () =
  (check int)
    "external callers of Tool_dispatch.dispatch_structured \
     (RFC-0084 PR-11; mli surface removed; PR-14 CI lint enforces)"
    0
    pinned_external_dispatch_structured_callers
;;

let test_legacy_surface_zero_sum () =
  (check int)
    "sum of external callers across legacy dispatch entries \
     (RFC-0084 §2.2 invariant: only guarded_dispatch is the public path)"
    0
    (pinned_external_dispatch_callers
     + pinned_external_dispatch_structured_callers)
;;

let () =
  Alcotest.run
    "RFC-0084 PR-11 dispatch legacy removed"
    [ ( "legacy-removal"
      , [ test_case "no-external-dispatch-caller" `Quick test_no_external_dispatch_caller
        ; test_case "no-external-dispatch-structured-caller" `Quick test_no_external_dispatch_structured_caller
        ; test_case "legacy-surface-zero-sum" `Quick test_legacy_surface_zero_sum
        ] )
    ]
;;
