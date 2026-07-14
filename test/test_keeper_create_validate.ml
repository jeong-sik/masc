(** Typed pre-boot validation for [masc_keeper_create_from_persona]. *)

open Masc

module Runtime = Keeper_tool_persona_runtime

let pp_error formatter error =
  Runtime.create_validation_errors_to_json [ error ]
  |> Yojson.Safe.to_string
  |> Format.pp_print_string formatter

let validation_error = Alcotest.testable pp_error ( = )
let validation_errors = Alcotest.list validation_error

let valid_args =
  `Assoc
    [ "name", `String "valid-name"
    ; "goal", `String "do the thing"
    ; "mention_targets", `List [ `String "valid-name" ]
    ]

let check_validation_error expected json =
  match Runtime.validate_resolved_keeper_create_json json with
  | Ok () -> Alcotest.fail "validation unexpectedly passed"
  | Error actual -> Alcotest.check validation_errors "typed errors" expected actual

let test_missing_fields () =
  check_validation_error
    [ Runtime.Required Runtime.Keeper_name
    ; Runtime.Required Runtime.Initial_goal
    ; Runtime.Required Runtime.Mention_targets
    ]
    (`Assoc [])

let test_valid_args_decisions () =
  Alcotest.(check bool)
    "validation passes"
    true
    (Result.is_ok (Runtime.validate_resolved_keeper_create_json valid_args));
  Alcotest.(check bool)
    "dry run previews ready"
    true
    (Runtime.decide_resolved_keeper_create ~dry_run:true valid_args
     = Runtime.Preview Runtime.Ready);
  Alcotest.(check bool)
    "real create proceeds"
    true
    (Runtime.decide_resolved_keeper_create ~dry_run:false valid_args
     = Runtime.Proceed)

let test_invalid_name () =
  let invalid_name = "bad name/with sep" in
  check_validation_error
    [ Runtime.Invalid_keeper_name invalid_name ]
    (`Assoc
       [ "name", `String invalid_name
       ; "goal", `String "goal"
       ; "mention_targets", `List [ `String "target" ]
       ])

let test_malformed_fields () =
  let errors =
    [ Runtime.Invalid_json_type Runtime.Initial_goal
    ; Runtime.Invalid_mention_target
        { index = 1; reason = Runtime.Expected_string }
    ; Runtime.Invalid_mention_target
        { index = 2; reason = Runtime.Empty_string }
    ]
  in
  let json =
    `Assoc
      [ "name", `String "valid-name"
      ; "goal", `Int 1
      ; "mention_targets", `List [ `String "target"; `Null; `String " " ]
      ]
  in
  check_validation_error errors json;
  Alcotest.(check bool)
    "dry run exposes typed rejection"
    true
    (Runtime.decide_resolved_keeper_create ~dry_run:true json
     = Runtime.Preview (Runtime.Not_ready errors));
  Alcotest.(check bool)
    "real create rejects before boot"
    true
    (Runtime.decide_resolved_keeper_create ~dry_run:false json
     = Runtime.Reject errors)

let test_empty_mention_target () =
  check_validation_error
    [ Runtime.Invalid_mention_target
        { index = 0; reason = Runtime.Empty_string }
    ]
    (`Assoc
       [ "name", `String "valid-name"
       ; "goal", `String "goal"
       ; "mention_targets", `List [ `String "  " ]
       ])

let test_error_json () =
  let actual =
    Runtime.create_validation_errors_to_json
      [ Runtime.Required Runtime.Initial_goal
      ; Runtime.Invalid_mention_target
          { index = 2; reason = Runtime.Empty_string }
      ]
  in
  let expected =
    `List
      [ `Assoc
          [ "code", `String "initial_goal_required"
          ; "field", `String "goal"
          ; "message", `String "goal is required"
          ]
      ; `Assoc
          [ "code", `String "mention_target_empty"
          ; "field", `String "mention_targets"
          ; ( "message"
            , `String "mention_targets entries must be non-empty strings" )
          ; "index", `Int 2
          ]
      ]
  in
  Alcotest.(check string)
    "stable structured error boundary"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string actual)

let () =
  Alcotest.run
    "keeper_create_validate"
    [ ( "validation"
      , [ Alcotest.test_case "missing fields" `Quick test_missing_fields
        ; Alcotest.test_case "valid decisions" `Quick test_valid_args_decisions
        ; Alcotest.test_case "invalid name" `Quick test_invalid_name
        ; Alcotest.test_case "malformed fields" `Quick test_malformed_fields
        ; Alcotest.test_case "empty mention target" `Quick test_empty_mention_target
        ; Alcotest.test_case "structured error json" `Quick test_error_json
        ] )
    ]
