(** What [/health?full=1]'s [overall_status] is answerable for.

    Each case pins one edge of the derivation that replaced the eight
    hand-named sections (#34893). The rule is: a section is rolled up when it
    is cached and its [status] parses as a grade. *)

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

(* The three the operator-action cases below read. [status_lines] reads the
   fourth, which answers a different question. *)
let summary ?sections ?runtime_startup_degradation ?keeper_config_schema_status
    ?keeper_config_schema_blocking ?keeper_config_schema_terminal_reason
    ?keeper_config_operator_action_required () =
  let r =
    rollup ?sections ?runtime_startup_degradation ?keeper_config_schema_status
      ?keeper_config_schema_blocking ?keeper_config_schema_terminal_reason
      ?keeper_config_operator_action_required ()
  in
  (r.R.overall_status, r.R.operator_action_required, r.R.operator_action_reasons)

let status_lines ?sections ?runtime_startup_degradation ?keeper_config_schema_status
    ?keeper_config_schema_blocking ?keeper_config_schema_terminal_reason
    ?keeper_config_operator_action_required () =
  let r =
    rollup ?sections ?runtime_startup_degradation ?keeper_config_schema_status
      ?keeper_config_schema_blocking ?keeper_config_schema_terminal_reason
      ?keeper_config_operator_action_required ()
  in
  r.R.overall_status_reasons

let section name status = (name, `Assoc [ "status", `String status ])

let test_cached_grade_moves_the_status () =
  let status, action, reasons =
    summary ~sections:[ section "keeper_event_queue" "degraded" ] ()
  in
  check string "a degraded cached section is the overall status" "degraded" status;
  (* Degraded ranks 2 and [requires_operator_action] is rank >= 3, so the
     status moves and no reason is raised. An operator watching the rollup for
     reasons alone would not see this one, which is what the status field is
     for. *)
  check bool "degraded alone raises no operator action" false action;
  check (list string) "degraded alone raises no reason" [] reasons

let test_error_grade_raises_a_reason () =
  let status, action, reasons =
    summary
      ~sections:
        [ ( "keeper_fleet_safety"
          , `Assoc [ "status", `String "error"; "blocker", `String "no owner" ] )
        ]
      ()
  in
  check string "an errored section is the overall status" "error" status;
  check bool "an errored section needs an operator" true action;
  check (list string) "the blocker is the reason, prefixed"
    [ "keeper_fleet_safety:no owner" ] reasons

(* #34894: keeper_event_queue reports a paused-dead backlog in status_reasons
   and leaves it out of the actionable ones, because a keeper the operator
   paused is their own standing decision. Before this, the gate opening for
   the recoverable backlog carried the paused-dead line up with it. *)
let test_declared_action_reasons_are_the_ones_carried () =
  let _, action, reasons =
    summary
      ~sections:
        [ ( "keeper_event_queue"
          , `Assoc
              [ "status", `String "degraded"
              ; "operator_action_required", `Bool true
              ; ( "status_reasons"
                , `List
                    [ `String "recoverable_backlog=105"
                    ; `String "runnable_backlog=33"
                    ; `String "paused_dead_backlog=41"
                    ] )
              ; ( "operator_action_reasons"
                , `List [ `String "recoverable_backlog=105" ] )
              ] )
        ]
      ()
  in
  check bool "the section still needs an operator" true action;
  check (list string) "only the declared reason reaches the operator list"
    [ "keeper_event_queue:recoverable_backlog=105" ] reasons

(* A section that declares none is not silenced: the gate is open, so what is
   happening is what the operator gets. *)
let test_a_section_declaring_no_action_reasons_falls_back () =
  let _, _, reasons =
    summary
      ~sections:
        [ ( "keeper_reaction_ledger"
          , `Assoc
              [ "status", `String "error"
              ; "status_reasons", `List [ `String "reaction_ledger_pending_stimulus" ]
              ; "operator_action_reasons", `List []
              ] )
        ]
      ()
  in
  check (list string) "status_reasons carry when none are declared"
    [ "keeper_reaction_ledger:reaction_ledger_pending_stimulus" ] reasons

let test_status_reasons_win_over_the_fallback () =
  let _, _, reasons =
    summary
      ~sections:
        [ ( "keeper_owner"
          , `Assoc
              [ "status", `String "error"
              ; "blocker", `String "ignored"
              ; "status_reasons", `List [ `String "first"; `String "second" ]
              ] )
        ]
      ()
  in
  check (list string) "every declared reason is carried, prefixed"
    [ "keeper_owner:first"; "keeper_owner:second" ] reasons

(* The cache boundary is the rollup's reach. [overall_status] is itself cached,
   so it is computed in the snapshot pass, and a section the probe pass
   supplies fresh is not there to be read. schedule_runner is one of those:
   this is why naming it in the rollup would not have worked (#34893). *)
let test_an_uncached_section_is_not_reached () =
  let status, action, reasons =
    summary ~sections:[ section "schedule_runner" "error" ] ()
  in
  check string "an uncached section does not move the status" "ok" status;
  check bool "an uncached section raises no action" false action;
  check (list string) "an uncached section raises no reason" [] reasons

(* [Health_status.of_string] folds an unrecognised word to [Unknown], which
   ranks alongside [Degraded]. Were the rollup to read a cached section
   reporting a state name, a listening socket would rank as a troubled
   subsystem. The parse is what keeps them apart. *)
let test_a_state_name_is_not_a_grade () =
  let status, _, reasons =
    summary ~sections:[ section "keeper_owner" "active" ] ()
  in
  check string "a state name does not move the status" "ok" status;
  check (list string) "a state name raises no reason" [] reasons

(* The section the hand-named list left out. Cached, grade-bearing, and in the
   payload since it was added. *)
let test_observability_artifacts_are_rolled_up () =
  let status, _, _ =
    summary ~sections:[ section "keeper_observability_artifacts" "degraded" ] ()
  in
  check string "keeper_observability_artifacts reaches the rollup" "degraded" status

let test_waiting_inventory_fault_is_cached_and_rolled_up () =
  check bool "inventory belongs to background snapshot" true
    (R.is_cached "keeper_waiting_inventory");
  let status, action, reasons =
    summary ~sections:
      [ "keeper_waiting_inventory", `Assoc
          [ "status", `String "degraded"
          ; "operator_action_required", `Bool true
          ; "status_reasons", `List [ `String "schedule_primary_unusable" ]
          ] ] ()
  in
  check string "disk divergence affects overall status" "degraded" status;
  check bool "recovery repair is actionable" true action;
  check (list string) "stable cause survives rollup"
    [ "keeper_waiting_inventory:schedule_primary_unusable" ] reasons

let test_memory_dependency_failure_reaches_overall_health () =
  check bool "Memory dependencies share the background cache" true
    (R.is_cached "keeper_memory_execution");
  let status, action, reasons = summary ~sections:
    ["keeper_memory_execution", `Assoc ["status",`String "degraded";
      "operator_action_required",`Bool true;
      "status_reasons",`List [`String "addon_unattached"]]] () in
  check string "Memory unavailability is not green" "degraded" status;
  check bool "missing dependency needs operator configuration" true action;
  check (list string) "cause is joined into health" ["keeper_memory_execution:addon_unattached"] reasons

let test_memory_original_attention_reaches_overall_health () =
  check bool "original outcome attention survives the background cache" true
    (R.is_cached "keeper_memory_attention");
  let status, action, reasons = summary ~sections:
    ["keeper_memory_attention", `Assoc ["status",`String "degraded";
      "operator_action_required",`Bool true;
      "operator_action_reasons",`List [`String "keeper-a:librarian_attention_required"]]] () in
  check string "a serving worker does not hide unresolved originals" "degraded" status;
  check bool "outcome uncertainty reaches the operator" true action;
  check (list string) "the Keeper and original outcome remain named"
    ["keeper_memory_attention:keeper-a:librarian_attention_required"] reasons

(* Most cached fields are not sections: keeper_fibers is an int, and
   keeper_config_errors a list. A field with no status says nothing about
   health and must not arrive as unknown. *)
let test_a_field_without_a_status_is_skipped () =
  let status, action, reasons =
    summary
      ~sections:[ ("keeper_fibers", `Int 3); ("keeper_config_errors", `List []) ]
      ()
  in
  check string "a field with no status does not move the status" "ok" status;
  check bool "a field with no status raises no action" false action;
  check (list string) "a field with no status raises no reason" [] reasons

(* Rolled up and not cached: the value the response carries comes from the
   probe pass, and this is the copy that is judged. *)
let test_startup_degradation_is_rolled_up_outside_the_cache () =
  let status, _, reasons =
    summary
      ~runtime_startup_degradation:
        (`Assoc
           [ "status", `String "error"
           ; "terminal_reason", `String "runtime absent"
           ])
      ()
  in
  check string "startup degradation is the overall status" "error" status;
  check (list string) "its terminal reason is carried"
    [ "runtime_startup_degradation:runtime absent" ] reasons

(* #34895: the gate is rank >= 3 plus Unknown, so a section at Warning with
   operator_action_required=false raised the grade and left no line anywhere.
   #34781 made that exact combination the normal one for a queue holding only
   runnable backlog. *)
let test_a_warning_section_leaves_a_line_without_demanding_action () =
  let sections =
    [ ( "keeper_event_queue"
      , `Assoc
          [ "status", `String "warning"
          ; "operator_action_required", `Bool false
          ; "status_reasons", `List [ `String "runnable_backlog=18" ]
          ] )
    ]
  in
  let status, action, reasons = summary ~sections () in
  check string "the grade still rises" "warning" status;
  check bool "and still demands nothing" false action;
  check (list string) "so the operator list stays empty" [] reasons;
  check (list string) "and the grade is explained"
    [ "keeper_event_queue:runnable_backlog=18" ]
    (status_lines ~sections ())

(* A cached section: dashboard_surface would have been the natural example and
   is the wrong one, because the rollup cannot see it at all -- it is
   probe-only, which is the fact the .mli spells out. Naming it here made this
   case fail on nothing. *)
let test_a_section_with_no_reasons_is_named_by_its_status () =
  check (list string) "the status stands in for a missing reason"
    [ "keeper_identity_drift:unavailable" ]
    (status_lines
       ~sections:[ section "keeper_identity_drift" "unavailable" ]
       ())

let test_an_ok_section_leaves_no_line () =
  check (list string) "an ok section explains nothing" []
    (status_lines ~sections:[ section "keeper_owner" "ok" ] ())

let test_every_raised_section_leaves_a_line () =
  check (list string) "each one, in section order"
    [ "keeper_owner:degraded"; "keeper_event_queue:blocked" ]
    (status_lines
       ~sections:
         [ section "keeper_owner" "degraded"; section "keeper_event_queue" "blocked" ]
       ())

let test_the_worst_grade_wins () =
  let status, _, _ =
    summary
      ~sections:
        [ section "keeper_owner" "ok"
        ; section "keeper_event_queue" "degraded"
        ; section "keeper_reaction_ledger" "blocked"
        ]
      ()
  in
  check string "the worst cached grade is the overall status" "blocked" status

(* RFC-0484 §3.2: the typesafeai section and what the rollup carries of it. *)
module Client = Masc.Typesafeai_client
module Typesafeai_health = Server_typesafeai_health

let typesafe : Client.destination_id =
  { destination_uri = "https://api.typesafe.ai/v1/systemone"; model = "jev-latest" }
;;

let openrouter : Client.destination_id =
  { destination_uri = "https://openrouter.ai/api/v1/systemone"; model = "~typesafe/jev-latest" }
;;

(* 2026-11-04T06:45:51Z, the first 402 of the 11-04 outage. *)
let out_of_credit =
  Client.Refusing
    { since = 1793774751.; last_at = 1793775000.; last = Client.Payment_required; last_answer_at = None }
;;

let section_status json = Yojson.Safe.Util.(json |> member "status" |> to_string)
let section_list name json = Yojson.Safe.Util.(json |> member name |> to_list |> filter_string)

let test_typesafeai_section_grades_its_destinations () =
  let section configured outcomes = Typesafeai_health.section_json ~configured ~outcomes in
  check string "a lane with nothing to ask is not graded" "disabled"
    (section_status (section (Error Masc.Typesafeai_config.Lane_disabled) []));
  check string "no destination asked yet" "idle"
    (section_status (section (Ok (typesafe, [])) []));
  let spent = section (Ok (typesafe, [])) [ typesafe, out_of_credit ] in
  check string "every destination refusing" "degraded" (section_status spent);
  check (list string) "only the operator can add credit"
    [ "payment_required https://api.typesafe.ai/v1/systemone since=2026-11-04T06:45:51Z" ]
    (section_list "operator_action_reasons" spent);
  let covered =
    section (Ok (typesafe, [ openrouter ]))
      [ typesafe, out_of_credit; openrouter, Client.Answered { at = 1793775001. } ]
  in
  check string "a fallback still answering" "warning" (section_status covered);
  check int "the spent account is still the operator's to fix" 1
    (List.length (section_list "operator_action_reasons" covered));
  let busy =
    section (Ok (typesafe, []))
      [ typesafe
      , Client.Refusing { since = 1.; last_at = 2.; last = Client.Server_error; last_answer_at = None } ]
  in
  check (list string) "a 5xx asks nothing of the operator" []
    (section_list "operator_action_reasons" busy);
  check (list string) "but says what is happening"
    [ "server_error https://api.typesafe.ai/v1/systemone" ] (section_list "status_reasons" busy);
  check (list string) "a destination the table no longer names is left out" []
    (section_list "status_reasons" (section (Ok (openrouter, [])) [ typesafe, out_of_credit ]))
;;

let test_typesafeai_payment_refusal_reaches_the_operator () =
  let section = Typesafeai_health.section_json ~configured:(Ok (typesafe, [])) ~outcomes:[ typesafe, out_of_credit ] in
  let _, required, reasons = summary ~sections:[ "typesafeai", section ] () in
  check bool "the operator is asked to act" true required;
  check (list string) "the rollup names the section and the destination"
    [ "typesafeai:payment_required https://api.typesafe.ai/v1/systemone since=2026-11-04T06:45:51Z" ]
    reasons
;;

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
    (R.is_cached "operator_actions" && List.mem "operator_actions" R.operator_field_names);
  let changed = match A.to_json action with
    | `Assoc fields -> `Assoc (("keeper_id", `String "different-keeper") :: List.remove_assoc "keeper_id" fields)
    | _ -> Alcotest.fail "the action is an object" in
  check bool "a changed target cannot borrow the original diagnostic" true
    (Result.is_error (A.of_json changed));
  let failed = A.memory_attention ~keeper:"keeper-a" ~durable:None
      ~admission:(Some (P.Admission_failed "pass refused")) ~measured_at:None in
  check bool "a failed admission pass survives the operator-action wire" true
    (match A.of_json (A.to_json failed) with Ok held -> A.equal held failed | Error _ -> false)

let test_queue_action_preserves_ambiguous_ownership () =
  let module A = Masc.Operator_action_reason in
  let owner name count = `Assoc ["keeper_name",`String name; "pending_count",`Int count] in
  let observed = A.queue_keepers ~count:10 (`List [owner "keeper-a" 4;owner "keeper-b" 6]) in
  check bool "complete aggregate retains both targets" true
    (observed = Some ["keeper-a",4;"keeper-b",6]);
  check bool "duplicate owners do not choose an arbitrary target" true
    (A.queue_keepers ~count:10 (`List [owner "keeper-a" 4;owner "keeper-a" 6]) = None);
  check bool "partial ownership does not prove an aggregate target" true
    (A.queue_keepers ~count:10 (`List [owner "keeper-a" 4]) = None);
  let action = A.shutdown_fenced_backlog ~count:10 ~keepers:None ~complete:false in
  check bool "unknown ownership and incomplete observation survive the wire" true
    (match A.of_json (A.to_json action) with Ok held -> A.equal action held | Error _ -> false)

let () =
  run
    "server_health_rollup"
    [ ( "reach"
      , [ test_case "a cached grade moves the status" `Quick
            test_cached_grade_moves_the_status
        ; test_case "typed original observation survives rollup" `Quick
            test_typed_original_observation_survives_rollup
        ; test_case "queue action preserves ambiguous ownership" `Quick
            test_queue_action_preserves_ambiguous_ownership
        ; test_case "an uncached section is not reached" `Quick
            test_an_uncached_section_is_not_reached
        ; test_case "observability artifacts are rolled up" `Quick
            test_observability_artifacts_are_rolled_up
        ; test_case "waiting inventory fault is cached and rolled up" `Quick
            test_waiting_inventory_fault_is_cached_and_rolled_up
        ; test_case "Memory dependency failure reaches overall health" `Quick
            test_memory_dependency_failure_reaches_overall_health
        ; test_case "original Memory outcome attention reaches overall health" `Quick
            test_memory_original_attention_reaches_overall_health
        ; test_case "startup degradation is rolled up outside the cache" `Quick
            test_startup_degradation_is_rolled_up_outside_the_cache
        ] )
    ; ( "grades"
      , [ test_case "a warning section leaves a line without demanding action"
            `Quick test_a_warning_section_leaves_a_line_without_demanding_action
        ; test_case "a section with no reasons is named by its status" `Quick
            test_a_section_with_no_reasons_is_named_by_its_status
        ; test_case "an ok section leaves no line" `Quick
            test_an_ok_section_leaves_no_line
        ; test_case "every raised section leaves a line" `Quick
            test_every_raised_section_leaves_a_line
        ; test_case "a state name is not a grade" `Quick
            test_a_state_name_is_not_a_grade
        ; test_case "a field without a status is skipped" `Quick
            test_a_field_without_a_status_is_skipped
        ; test_case "the worst grade wins" `Quick test_the_worst_grade_wins
        ] )
    ; ( "reasons"
      , [ test_case "an error grade raises a reason" `Quick
            test_error_grade_raises_a_reason
        ; test_case "declared action reasons are the ones carried" `Quick
            test_declared_action_reasons_are_the_ones_carried
        ; test_case "a section declaring no action reasons falls back" `Quick
            test_a_section_declaring_no_action_reasons_falls_back
        ; test_case "status_reasons win over the fallback" `Quick
            test_status_reasons_win_over_the_fallback
        ] )
    ; ( "typesafeai"
      , [ test_case "the section grades its destinations" `Quick
            test_typesafeai_section_grades_its_destinations
        ; test_case "a payment refusal reaches the operator" `Quick
            test_typesafeai_payment_refusal_reaches_the_operator
        ] )
    ]
;;
