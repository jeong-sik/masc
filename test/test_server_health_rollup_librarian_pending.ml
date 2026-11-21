(** What [/health?full=1]'s [overall_status] is answerable for.

    Each case pins one edge of the derivation that replaced the eight
    hand-named sections (#34893). The rule is: a section is rolled up when the
    rollup lists it and its [status] parses as a grade. *)

open Alcotest
module R = Server_health_rollup

let rollup ?(sections = []) ?(runtime_startup_degradation = `Assoc [])
    ?(keeper_config_schema_status = "ok") ?(keeper_config_schema_blocking = false)
    ?(keeper_config_schema_terminal_reason = "")
    ?(keeper_config_operator_action_required = false) () =
  R.operator_summary
    ~sections
    ~runtime_startup_degradation
    ~keeper_config_schema_status
    ~keeper_config_schema_blocking
    ~keeper_config_schema_terminal_reason
    ~keeper_config_operator_action_required

let test_typed_original_observation_survives_rollup () =
  let module A = Masc.Operator_action_reason in
  let module P = Masc.Keeper_librarian_pending in
  let worker : P.worker =
    {installation_id="original-installation"; request_id="original-request"; wait=P.Missing_after_dispatch} in
  let action = A.memory_attention ~keeper:"keeper-a" ~durable:(Some (P.Worker worker))
      ~admission:None ~measured_at:(Some 123.) in
  let r = rollup ~sections:["keeper_memory_attention", `Assoc
    ["status", `String "degraded"; "operator_action_required", `Bool true;
     "operator_action_reasons", `List [`String action.reason];
     "operator_actions", `List [A.to_json action]]] () in
  check bool "original request, Keeper and observation clock survive" true
    (match r.R.operator_actions with [held] -> A.equal held action | _ -> false);
  check (list string) "raw diagnostics derive from the same item"
    [A.diagnostic action] r.operator_action_reasons;
  check bool "the structured collection is copied into the cheap health probe" true
    (List.mem "operator_actions" R.operator_field_names);
  let changed = match A.to_json action with
    | `Assoc fields -> `Assoc (("keeper_id", `String "different-keeper") :: List.remove_assoc "keeper_id" fields)
    | _ -> Alcotest.fail "the action is an object" in
  check bool "a changed target cannot borrow the original diagnostic" true
    (Result.is_error (A.of_json changed));
  let failed = A.memory_attention ~keeper:"keeper-a" ~durable:None
      ~admission:(Some (P.Admission_failed "pass refused")) ~measured_at:None in
  check bool "a failed admission pass survives the operator-action wire" true
    (match A.of_json (A.to_json failed) with Ok held -> A.equal held failed | Error _ -> false)

let () =
  run
    "server_health_rollup_librarian_pending"
    [ ( "reach"
      , [ test_case "typed original observation survives rollup" `Quick
            test_typed_original_observation_survives_rollup
        ] )
    ]
;;
