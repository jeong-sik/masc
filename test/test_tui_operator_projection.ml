open Alcotest

module Projection = Masc_tui_operator_projection

let contains_substring text substring =
  let text_length = String.length text in
  let substring_length = String.length substring in
  let rec loop index =
    if index + substring_length > text_length then false
    else if String.sub text index substring_length = substring then true
    else loop (index + 1)
  in
  loop 0

let string_option_to_json = function
  | Some value -> `String value
  | None -> `Null

let approval_item_json ?(action_type = "namespace_pause")
    ?(target_type = "workspace") ?(target_id = None)
    ?(delegated_tool = "masc_pause")
    ?(expires_at = Some "2026-08-21T12:15:00Z")
    ?(actor = "masc-tui") ?trace_id token =
  let trace_id = Option.value ~default:("trace-" ^ token) trace_id in
  `Assoc
    [ "confirm_token", `String token
    ; "trace_id", `String trace_id
    ; "actor", `String actor
    ; "action_type", `String action_type
    ; "target_type", `String target_type
    ; "target_id", string_option_to_json target_id
    ; "payload", `Assoc [ "reason", `String "operator requested" ]
    ; "delegated_tool", `String delegated_tool
    ; "created_at", `String "2026-08-21T12:00:00Z"
    ; "expires_at", string_option_to_json expires_at
    ]

let default_items () =
  [ approval_item_json "token-pause"
  ; approval_item_json ~action_type:"keeper_probe"
      ~target_type:"keeper" ~target_id:(Some "keeper.one")
      ~delegated_tool:"masc_keeper_status" ~expires_at:None
      "token-probe"
  ]

let snapshot_json ?(actor_filter = Some "masc-tui") ?(filter_active = true)
    ?(visible_count = 2) ?(total_count = 3) ?(hidden_count = 1)
    ?items ?(hidden_actors = Some [ `String "other-agent" ])
    ?(confirm_required_actions = Some [ `Assoc [] ]) () =
  let items = Option.value ~default:(default_items ()) items in
  let optional_field name = Option.map (fun value -> name, `List value) in
  let summary_fields =
    [ Some ("actor_filter", string_option_to_json actor_filter)
    ; Some ("filter_active", `Bool filter_active)
    ; Some ("visible_count", `Int visible_count)
    ; Some ("total_count", `Int total_count)
    ; Some ("hidden_count", `Int hidden_count)
    ; optional_field "hidden_actors" hidden_actors
    ; optional_field "confirm_required_actions" confirm_required_actions
    ]
    |> List.filter_map Fun.id
  in
  `Assoc
    [ ( "pending_confirm_envelope"
      , `Assoc
          [ "items", `List items; "summary", `Assoc summary_fields ] )
    ]

let test_current_contract () =
  match Projection.decode_snapshot (snapshot_json ()) with
  | Error err -> fail err
  | Ok snapshot ->
      check int "visible count" 2 snapshot.aps_visible_count;
      check int "total count" 3 snapshot.aps_total_count;
      check int "hidden count" 1 snapshot.aps_hidden_count;
      check (option string) "actor scope" (Some "masc-tui")
        snapshot.aps_actor_filter;
      check bool "filter active" true snapshot.aps_filter_active;
      (match snapshot.aps_items with
       | pause :: probe :: [] ->
           check string "pause token" "token-pause" pause.ap_token;
           check (option string) "workspace target id" None pause.ap_target_id;
           check (option string) "pause expiry"
             (Some "2026-08-21T12:15:00Z") pause.ap_expires_at;
           check string "payload" {|{"reason":"operator requested"}|}
             (Yojson.Safe.to_string pause.ap_payload);
           check (option string) "keeper target" (Some "keeper.one")
             probe.ap_target_id;
           check (option string) "nullable expiry" None probe.ap_expires_at
       | _ -> fail "expected two approval items")

let test_payload_terminal_projection () =
  let rendered =
    Projection.approval_payload_for_terminal
      (`Assoc
        [ "reason", `String "safe\027]0;owned\007\155\194\155done" ])
  in
  check bool "payload contains no ESC" false (String.contains rendered '\027');
  check bool "payload contains no BEL" false (String.contains rendered '\007');
  check bool "payload contains no raw or encoded C1 byte" false
    (String.contains rendered '\155');
  check bool "raw C1 byte is visible as inert evidence" true
    (contains_substring rendered "\\x9B");
  check bool "UTF-8 C1 code point is visible as inert evidence" true
    (contains_substring rendered "\\u009B")

let test_fails_closed () =
  let malformed =
    [ `Assoc []
    ; `Assoc [ "pending_confirm_envelope", `Null ]
    ; `Assoc
        [ ( "pending_confirm_envelope"
          , `Assoc [ "items", `String "not-a-list"; "summary", `Assoc [] ] )
        ]
    ; snapshot_json ~visible_count:1 ()
    ; snapshot_json ~total_count:4 ()
    ; snapshot_json ~actor_filter:None ()
    ; snapshot_json ~filter_active:false ()
    ; snapshot_json ~visible_count:(-1) ()
    ; snapshot_json
        ~items:
          [ approval_item_json "duplicate"
          ; approval_item_json "duplicate"
          ]
        ()
    ; snapshot_json
        ~items:
          [ approval_item_json "token-pause"
          ; approval_item_json ~actor:"other-agent" "token-probe"
          ]
        ()
    ; snapshot_json ~hidden_actors:None ()
    ; snapshot_json ~hidden_actors:(Some [ `Int 1 ]) ()
    ; snapshot_json ~confirm_required_actions:None ()
    ; snapshot_json ~confirm_required_actions:(Some [ `String "bad" ]) ()
    ]
  in
  List.iteri
    (fun index json ->
      check bool (Printf.sprintf "malformed snapshot %d rejected" index) true
        (Result.is_error (Projection.decode_snapshot json)))
    malformed

let confirm_response ?(status = "ok") ?(decision = "confirm")
    ?(token = "token-pause") ?trace_id ?tool_name ?(include_result = true)
    ?executed_trace_id ?result_status () =
  let trace_id = Option.value ~default:("trace-" ^ token) trace_id in
  let executed_trace_id = Option.value ~default:trace_id executed_trace_id in
  let tool_name = Option.value ~default:"masc_pause" tool_name in
  let fields =
    [ Some ("status", `String status)
    ; Some ("trace_id", `String trace_id)
    ; Some ("decision", `String decision)
    ; Some ("tool_name", `String tool_name)
    ; (if include_result then Some ("result", `Assoc []) else None)
    ; Option.map (fun value -> "result_status", `String value) result_status
    ; Some
        ( "executed_action"
        , approval_item_json ~trace_id:executed_trace_id
            ~delegated_tool:tool_name token )
    ]
    |> List.filter_map Fun.id
  in
  `Assoc fields

let decode_confirm ?(token = "token-pause") decision json =
  Projection.decode_confirm_response ~expected_token:token
    ~expected_decision:decision json

let test_confirm_response_status () =
  (match decode_confirm Projection.Confirm (confirm_response ()) with
   | Ok (Projection.Completed _) -> ()
   | Ok (Projection.Deferred _ | Projection.Execution_failed _) ->
       fail "ok response misclassified"
   | Error err -> fail err);
  (match
     decode_confirm Projection.Confirm (confirm_response ~status:"deferred" ())
   with
   | Ok (Projection.Deferred _) -> ()
   | Ok (Projection.Completed _ | Projection.Execution_failed _) ->
       fail "deferred response misclassified"
   | Error err -> fail err);
  (match
     decode_confirm Projection.Confirm
       (confirm_response ~status:"error" ())
   with
   | Ok (Projection.Execution_failed _) -> ()
   | Ok (Projection.Completed _ | Projection.Deferred _) ->
       fail "execution error misclassified"
   | Error err -> fail err);
  check bool "deny accepted" true
    (Result.is_ok
       (decode_confirm Projection.Deny
          (confirm_response ~decision:"deny" ~include_result:false
             ~result_status:"not_executed" ())));
  List.iter
    (fun json ->
      check bool "non-success status rejected" true
        (Result.is_error (decode_confirm Projection.Confirm json)))
    [ `Assoc [ "status", `String "error"; "message", `String "failed" ]
    ; `Assoc [ "status", `String "unknown" ]
    ; `Assoc []
    ; `Assoc [ "status", `String "ok" ]
    ; confirm_response ~decision:"deny" ()
    ; confirm_response ~token:"other-token" ()
    ; confirm_response ~trace_id:"other-trace"
        ~executed_trace_id:"trace-token-pause" ()
    ; confirm_response ~tool_name:"masc_other" ()
    ; confirm_response ~include_result:false ()
    ]

let test_deny_response_fails_closed () =
  List.iter
    (fun json ->
      check bool "invalid deny response rejected" true
        (Result.is_error (decode_confirm Projection.Deny json)))
    [ confirm_response ~status:"deferred" ~decision:"deny"
        ~include_result:false ~result_status:"not_executed" ()
    ; confirm_response ~decision:"deny" ~include_result:false ()
    ; confirm_response ~decision:"deny" ~include_result:false
        ~result_status:"executed" ()
    ]

let test_approval_flow_rejects_stale_results () =
  let flow, old_generation = Projection.Flow.reserve_refresh Projection.Flow.initial in
  let old_generation = Option.get old_generation in
  let flow, action_generation =
    match Projection.Flow.begin_action flow with
    | Ok value -> value
    | Error `Already_inflight -> fail "first action unexpectedly in flight"
  in
  check bool "pre-action refresh is stale" false
    (Projection.Flow.is_current flow old_generation);
  check bool "action generation is current" true
    (Projection.Flow.is_current flow action_generation);
  let unchanged, refresh = Projection.Flow.reserve_refresh flow in
  check bool "refresh suppressed during action" true (Option.is_none refresh);
  check bool "action remains in flight" true
    (Projection.Flow.action_inflight unchanged);
  let unchanged, owned = Projection.Flow.finish_action flow old_generation in
  check bool "stale completion does not own action" false owned;
  check bool "stale completion cannot clear action" true
    (Projection.Flow.action_inflight unchanged);
  let finished, owned = Projection.Flow.finish_action unchanged action_generation in
  check bool "current completion owns action" true owned;
  check bool "current completion clears action" false
    (Projection.Flow.action_inflight finished)

(* The Gate and held-tool resolve paths in the TUI now take the same
   single-action slot the operator-confirm path takes, so a decision keypress
   arriving while one is still in flight must be refused here rather than
   dispatching a second, duplicate resolve. This locks that guard: a second
   [begin_action] while one is in flight is [`Already_inflight], and only a
   matching [finish_action] admits the next decision. *)
let test_second_action_blocked_while_inflight () =
  let flow, generation =
    match Projection.Flow.begin_action Projection.Flow.initial with
    | Ok value -> value
    | Error `Already_inflight -> fail "first action unexpectedly in flight"
  in
  check bool "first action is in flight" true
    (Projection.Flow.action_inflight flow);
  (match Projection.Flow.begin_action flow with
   | Error `Already_inflight -> ()
   | Ok _ -> fail "second action started while one was in flight");
  let released, owned = Projection.Flow.finish_action flow generation in
  check bool "completion owns and releases the slot" true owned;
  check bool "slot is free after completion" false
    (Projection.Flow.action_inflight released);
  match Projection.Flow.begin_action released with
  | Ok _ -> ()
  | Error `Already_inflight -> fail "next action refused after slot released"

let test_two_key_gate () =
  let armed =
    match
      Projection.approval_gate_transition ~inflight:false ~pending:None
        ~token:"token-pause" ~decision:Projection.Confirm
    with
    | Projection.Gate_arm pending -> pending
    | Projection.Gate_blocked_inflight | Projection.Gate_submit ->
        fail "first key did not arm"
  in
  (match
     Projection.approval_gate_transition ~inflight:false ~pending:(Some armed)
       ~token:"token-pause" ~decision:Projection.Confirm
   with
   | Projection.Gate_submit -> ()
   | Projection.Gate_blocked_inflight | Projection.Gate_arm _ ->
       fail "matching second key did not submit");
  (match
     Projection.approval_gate_transition ~inflight:false ~pending:(Some armed)
       ~token:"token-pause" ~decision:Projection.Deny
   with
   | Projection.Gate_arm pending ->
       check bool "opposite decision re-arms" true
         (pending.paa_decision = Projection.Deny)
   | Projection.Gate_blocked_inflight | Projection.Gate_submit ->
       fail "opposite decision submitted");
  (match
     Projection.approval_gate_transition ~inflight:true ~pending:(Some armed)
       ~token:"token-pause" ~decision:Projection.Confirm
   with
   | Projection.Gate_blocked_inflight -> ()
   | Projection.Gate_arm _ | Projection.Gate_submit ->
       fail "inflight key was not blocked")

let decode_approval_items tokens =
  let items = List.map approval_item_json tokens in
  let count = List.length items in
  match
    Projection.decode_snapshot
      (snapshot_json ~items ~visible_count:count ~total_count:count
         ~hidden_count:0 ())
  with
  | Ok snapshot -> snapshot.aps_items
  | Error err -> fail err

let reconcile ~current_tokens ~cursor next_tokens =
  Projection.reconcile_cursor
    ~current_items:(decode_approval_items current_tokens)
    ~cursor ~next_items:(decode_approval_items next_tokens)

let test_refresh_preserves_selected_token () =
  check int "B moves after newest prepend" 2
    (reconcile ~current_tokens:[ "A"; "B"; "C" ] ~cursor:1
       [ "NEW"; "A"; "B"; "C" ]);
  check int "missing token keeps valid cursor" 1
    (reconcile ~current_tokens:[ "A"; "B"; "C" ] ~cursor:1 [ "A"; "C" ]);
  check int "shrunk list clamps missing token" 0
    (reconcile ~current_tokens:[ "A"; "B"; "C" ] ~cursor:2 [ "A" ]);
  check int "empty list resets cursor" 0
    (reconcile ~current_tokens:[ "A" ] ~cursor:0 []);
  check int "negative cursor is normalized" 0
    (reconcile ~current_tokens:[ "A" ] ~cursor:(-1) [ "A" ])

let () =
  run "tui_operator_projection"
    [ ( "operator approvals"
      , [ test_case "current contract" `Quick test_current_contract
        ; test_case "payload terminal projection" `Quick
            test_payload_terminal_projection
        ; test_case "fails closed" `Quick test_fails_closed
        ; test_case "semantic confirm status" `Quick
            test_confirm_response_status
        ; test_case "deny response fails closed" `Quick
            test_deny_response_fails_closed
        ; test_case "stale request generations" `Quick
            test_approval_flow_rejects_stale_results
        ; test_case "second action blocked while inflight" `Quick
            test_second_action_blocked_while_inflight
        ; test_case "two-key safety gate" `Quick test_two_key_gate
        ; test_case "refresh preserves selected token" `Quick
            test_refresh_preserves_selected_token
        ] )
    ]
