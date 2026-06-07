open Alcotest

let unique_env suffix =
  Printf.sprintf "MASC_TEST_KEEPER_TURN_SLOT_TYPES_%d_%s" (Unix.getpid ()) suffix
;;

let test_int_of_env_default_uses_default_when_absent () =
  let name = unique_env "ABSENT" in
  check int "default" 7
    (Keeper_turn_admission_types.int_of_env_default
       ~primary:name
       ~default:7
       ~min_v:1
       ~max_v:10)
;;

let test_int_of_env_default_clamps_bounds () =
  let low = unique_env "LOW" in
  let high = unique_env "HIGH" in
  Unix.putenv low "-10";
  Unix.putenv high "99";
  check int "min clamp" 1
    (Keeper_turn_admission_types.int_of_env_default
       ~primary:low
       ~default:7
       ~min_v:1
       ~max_v:10);
  check int "max clamp" 10
    (Keeper_turn_admission_types.int_of_env_default
       ~primary:high
       ~default:7
       ~min_v:1
       ~max_v:10)
;;

let test_int_of_env_default_uses_default_for_blank_or_invalid () =
  let blank = unique_env "BLANK" in
  let invalid = unique_env "INVALID" in
  Unix.putenv blank "  ";
  Unix.putenv invalid "not-an-int";
  check int "blank default" 7
    (Keeper_turn_admission_types.int_of_env_default
       ~primary:blank
       ~default:7
       ~min_v:1
       ~max_v:10);
  check int "invalid default" 7
    (Keeper_turn_admission_types.int_of_env_default
       ~primary:invalid
       ~default:7
       ~min_v:1
       ~max_v:10)
;;

let () =
  run
    "Keeper_turn_admission_types"
    [ ( "env"
      , [ test_case
            "absent env uses default"
            `Quick
            test_int_of_env_default_uses_default_when_absent
        ; test_case "values clamp to bounds" `Quick test_int_of_env_default_clamps_bounds
        ; test_case
            "blank and invalid env use default"
            `Quick
            test_int_of_env_default_uses_default_for_blank_or_invalid
        ] )
    ]
;;
