(** Cascade_name.t unit tests.

    Post-#19327 (tier/tier-group purge): Cascade_name is a plain string
    alias.  Prefix enforcement removed; [`Invalid_prefix] retained in the
    variant for source compatibility but no longer emitted. *)

open Alcotest

module CN = Cascade_name

let test_round_trip () =
  match CN.of_string "runpod:glm-coding-with-spark" with
  | Ok t ->
    check string "round-trip" "runpod:glm-coding-with-spark" (CN.to_string t)
  | Error _ -> fail "expected Ok for plain provider:model"

let test_whitespace_trimmed () =
  match CN.of_string "  provider:model  " with
  | Ok t -> check string "trimmed" "provider:model" (CN.to_string t)
  | Error _ -> fail "expected Ok after trimming"

let test_empty_string () =
  match CN.of_string "" with
  | Ok _ -> fail "expected Error for empty string"
  | Error `Empty -> ()
  | Error `Invalid_prefix -> fail "expected Empty, got Invalid_prefix"

let test_whitespace_only () =
  match CN.of_string "   " with
  | Ok _ -> fail "expected Error for whitespace-only"
  | Error `Empty -> ()
  | Error `Invalid_prefix -> fail "expected Empty, got Invalid_prefix"

let test_of_string_exn_ok () =
  check string "exn round-trip" "x" (CN.to_string (CN.of_string_exn "x"))

let () =
  Alcotest.run "cascade_name"
    [ ( "valid"
      , [ test_case "round-trip" `Quick test_round_trip
        ; test_case "whitespace trimmed" `Quick test_whitespace_trimmed
        ] )
    ; ( "invalid"
      , [ test_case "empty string" `Quick test_empty_string
        ; test_case "whitespace only" `Quick test_whitespace_only
        ] )
    ; ( "exn"
      , [ test_case "of_string_exn ok" `Quick test_of_string_exn_ok ] )
    ]
