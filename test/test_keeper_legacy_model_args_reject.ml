(** Regression: [reject_legacy_model_args] inverted-presence bug.

    [Json_util.assoc_member_opt] returns [None] for an absent key. The prior
    [| _ -> true] arm classified that [None] as "present", so a request that
    omitted all three legacy keys — e.g. the bare [{ "name" : ... }] that base
    autoboot materialization passes through [masc_keeper_up] — was rejected
    with "legacy keeper model args removed for masc_keeper_up: models,
    allowed_models, active_model", blocking [base] from booting (observed live
    2026-06-01 ~01:05 KST).

    Behaviour contract this test pins:
      absent OR explicit-null  -> Ok ()    (not supplied)
      present with a value     -> Error    (legacy arg, rejected) *)

open Masc_mcp

let is_ok = function Ok () -> true | Error _ -> false

let reject args =
  Keeper_meta_contract.reject_legacy_model_args ~tool_name:"masc_keeper_up" args

(* The exact shape keeper_runtime autoboot passes to handle_keeper_up. *)
let test_bare_name_accepted () =
  Alcotest.(check bool)
    "bare {name} (no legacy model key) must be accepted — regression: base \
     autoboot was rejected"
    true
    (is_ok (reject (`Assoc [ ("name", `String "base") ])))

let test_empty_args_accepted () =
  Alcotest.(check bool)
    "empty object must be accepted"
    true
    (is_ok (reject (`Assoc [])))

let test_explicit_null_accepted () =
  Alcotest.(check bool)
    "legacy keys present but explicitly null must be accepted"
    true
    (is_ok
       (reject
          (`Assoc
            [ ("name", `String "k")
            ; ("models", `Null)
            ; ("allowed_models", `Null)
            ; ("active_model", `Null)
            ])))

let test_real_value_rejected () =
  Alcotest.(check bool)
    "a legacy key supplied with a real value must still be rejected"
    false
    (is_ok (reject (`Assoc [ ("name", `String "k"); ("active_model", `String "gpt-x") ])))

let test_real_list_value_rejected () =
  Alcotest.(check bool)
    "models supplied as a non-empty list must still be rejected"
    false
    (is_ok
       (reject (`Assoc [ ("models", `List [ `String "a"; `String "b" ]) ])))

let () =
  Alcotest.run "keeper_legacy_model_args_reject"
    [ ( "reject_legacy_model_args"
      , [ Alcotest.test_case "bare {name} accepted" `Quick test_bare_name_accepted
        ; Alcotest.test_case "empty args accepted" `Quick test_empty_args_accepted
        ; Alcotest.test_case "explicit null accepted" `Quick test_explicit_null_accepted
        ; Alcotest.test_case "real string value rejected" `Quick test_real_value_rejected
        ; Alcotest.test_case "real list value rejected" `Quick test_real_list_value_rejected
        ] )
    ]
