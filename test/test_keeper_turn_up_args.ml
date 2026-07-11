open Alcotest
open Masc

let test_resolve_mention_targets_uses_fallback_when_absent () =
  check
    (list string)
    "fallback targets"
    [ "existing" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:None
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let test_resolve_mention_targets_preserves_explicit_clear () =
  check
    (list string)
    "explicit clear"
    []
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:(Some [])
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let test_resolve_mention_targets_normalizes_explicit_values () =
  check
    (list string)
    "deduped explicit targets"
    [ "alpha"; "beta" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:(Some [ " alpha "; ""; "beta"; "alpha" ])
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

(* RFC-0334 W3 census (#23837): a target configured pre-prefixed with '@'
   used to build a never-matching "@@name" search needle in the board-signal
   matcher. Normalizing here (strip '@', lowercase) at write time closes
   that gap regardless of how the operator typed the target. *)
let test_resolve_mention_targets_strips_leading_at_and_lowercases () =
  check
    (list string)
    "leading '@' stripped, case-folded, deduped across variants"
    [ "albini" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:(Some [ "@Albini"; "@@albini"; " ALBINI " ])
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let test_resolve_mention_targets_normalizes_fallback () =
  check
    (list string)
    "fallback targets are normalized too"
    [ "sangsu" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:None
       ~fallback_targets:[ "@Sangsu" ]
       ~name:"keeper-a")

let () =
  run
    "keeper_turn_up_args"
    [ ( "mention_targets"
      , [ test_case
            "absent mention_targets uses fallback"
            `Quick
            test_resolve_mention_targets_uses_fallback_when_absent
        ; test_case
            "explicit empty mention_targets clears"
            `Quick
            test_resolve_mention_targets_preserves_explicit_clear
        ; test_case
            "explicit mention_targets normalize and dedupe"
            `Quick
            test_resolve_mention_targets_normalizes_explicit_values
        ; test_case
            "leading '@' stripped and lowercased"
            `Quick
            test_resolve_mention_targets_strips_leading_at_and_lowercases
        ; test_case
            "fallback targets normalized"
            `Quick
            test_resolve_mention_targets_normalizes_fallback
        ] )
    ]
;;
