(* RFC-0232 P2: producer-typed turn outcome.

   The reply payload's [turn_outcome] field is the only carrier of the
   checkpoint/visible/no-visible distinction; the legacy "Continuation
   checkpoint saved;" prefix sniff is deleted.  These tests pin:
   - the closed label codec (round-trip, unknown -> None),
   - the stop_reason -> outcome mapping (single mapping site),
   - response_text-aware result-surface classification,
   - payload decode policy: absent/malformed/unknown fails closed,
   - prefix deadness: checkpoint-shaped reply TEXT alone never
     classifies as a checkpoint. *)

open Alcotest

module TO = Masc.Keeper_turn_outcome
module Ops = Masc.Keeper_tool_surface_ops
module Stream = Server_routes_http_keeper_stream
module Response_text = Masc.Keeper_agent_run_response_text

(* [direct_reply_terminal_error] answers with a cause, not a sentence
   (RFC-0454 D2); these cases only assert whether there is one. *)
let summary_of_cause cause =
  Keeper_request_failure.summary { Keeper_request_failure.cause }
;;

let outcome : TO.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (TO.to_label t))
    TO.equal

let all =
  [ TO.Visible_reply
  ; TO.Continuation_checkpoint
  ; TO.Terminal_effect_settled
  ; TO.Awaiting_gate_approval
  ; TO.No_visible_reply
  ]

let test_label_round_trip () =
  List.iter
    (fun t ->
      check (option outcome) "of_label (to_label t) = Some t"
        (Some t)
        (TO.of_label (TO.to_label t)))
    all

(* The label below is on disk in chat lanes written before a Gate deferral
   stopped ending the turn, and the store is append-only, so nothing retires
   those rows. Its constructor was renamed and no turn produces it any more;
   what still has to hold is that the string decodes, because both readers
   reject an unknown label rather than skipping the row.

   The round-trip test above cannot carry this. It asks whether [to_label]
   and [of_label] agree with each other, which stays true when a rename moves
   both together and takes the disk rows out from under them. This asks for
   the string itself. *)
let test_parked_call_label_still_decodes () =
  check (option outcome) "the outcome a pre-change lane holds"
    (Some TO.Awaiting_gate_approval)
    (TO.of_label "external_effect_pending");
  check string "and it goes back out unchanged" "external_effect_pending"
    (TO.to_label TO.Awaiting_gate_approval);
  let row =
    `List
      [ `Assoc
          [ ("t", `String "status")
          ; ("kind", `String "external_effect_pending")
          ]
      ]
  in
  match Masc.Keeper_chat_blocks.blocks_of_yojson row with
  | Some
      [ Masc.Keeper_chat_blocks.Status
          { kind = Masc.Keeper_chat_blocks.Awaiting_gate_approval }
      ] ->
    ()
  | Some _ | None ->
    fail "a status block from a pre-change lane no longer decodes"

let test_unknown_label_is_none () =
  List.iter
    (fun label ->
      check (option outcome) label None (TO.of_label label))
    [ ""; "completed"; "checkpoint"; "Visible_reply"; "VISIBLE_REPLY" ]

let test_of_stop_reason () =
  let request : Agent_core.Error.input_required =
    { request_id = "outcome-input-1"
    ; participant_name = None
    ; question = "Which repository?"
    ; schema = None
    ; timeout_s = None
    ; created_at = 1_000.0
    }
  in
  check outcome "completed -> visible" TO.Visible_reply
    (TO.of_stop_reason Runtime_agent.Completed);
  check outcome "chat yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_to_operation_queued { turns_used = 2 }));
  check outcome "durable stimulus yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_to_durable_stimulus { turns_used = 2 }));
  check outcome "repeated tool yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_after_repeated_tool_call
          { turns_used = 2
          ; tool_name = "keeper_tasks_list"
          ; repeated_count = 3
          }));
  check outcome "repeated assistant text yield -> checkpoint"
    TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_after_repeated_assistant_text
          { turns_used = 2; repeated_count = 3 }));
  check outcome "typed input required -> visible" TO.Visible_reply
    (TO.of_stop_reason
       (Runtime_agent.InputRequired { turns_used = 2; request }))

let test_of_result_surface () =
  check outcome "completed with text -> visible" TO.Visible_reply
    (TO.of_result_surface ~response_text:"done" Runtime_agent.Completed);
  check outcome "completed with empty text -> no visible reply"
    TO.No_visible_reply
    (TO.of_result_surface ~response_text:"   " Runtime_agent.Completed)

let test_progress_post_keeps_typed_continuation () =
  let receipt = Masc.Keeper_tool_execution.Surface_post_completed
    Masc.Keeper_surface_post.To_dashboard in
  let finish stop_reason state =
    Masc.Keeper_agent_run.For_testing.finalize_turn_surface
      ~response_text:"Progress posted; remaining work is retained."
      ~stop_reason state in
  let posted = Masc.Keeper_tools_agent_core.Terminal_effect_completed receipt in
  List.iter (fun stop_reason ->
    match finish stop_reason posted with
    | Ok (turn_outcome, retained_receipt) ->
      check outcome "a posted progress update cannot complete a yielded operation"
        TO.Continuation_checkpoint turn_outcome;
      check bool "delivery evidence survives alongside continuation" true
        (retained_receipt = Some receipt)
    | Error error -> fail (Agent_core.Error.to_string error))
    [ Runtime_agent.Yielded_to_operation_queued { turns_used = 1 }
    ; Runtime_agent.Yielded_to_durable_stimulus { turns_used = 1 }
    ; Runtime_agent.Yielded_after_repeated_tool_call
        { turns_used = 1; tool_name = "probe"; repeated_count = 3 }
    ; Runtime_agent.Yielded_after_repeated_assistant_text
        { turns_used = 1; repeated_count = 3 }
    ];
  (match finish Runtime_agent.Completed posted with
   | Ok (turn_outcome, retained_receipt) ->
     check outcome "completed operation keeps terminal delivery" TO.Terminal_effect_settled turn_outcome;
     check bool "terminal delivery retains receipt" true (retained_receipt = Some receipt)
   | Error error -> fail (Agent_core.Error.to_string error));
  let failed = Masc.Keeper_tools_agent_core.Terminal_effect_failed
    { failure_class = Tool_result.Runtime_failure
    ; effect_disposition = Tool_result.Proven_post_effect
    ; detail = Keeper_terminal_effect_detail.Output_artifact_unstored { message = "disk unavailable" }
    } in
  match finish (Runtime_agent.Yielded_to_operation_queued { turns_used = 1 }) failed with
  | Error error ->
    (match Keeper_internal_error.classify_masc_internal_error error with
     | Some (Keeper_internal_error.Terminal_effect_failed
         { failure_class = Tool_result.Runtime_failure
         ; effect_disposition = Tool_result.Proven_post_effect
         ; detail = Keeper_terminal_effect_detail.Output_artifact_unstored { message }
         }) -> check string "terminal failure retains its cause" "disk unavailable" message
     | Some _ | None -> fail "cooperative handoff changed terminal failure authority")
  | Ok _ -> fail "cooperative handoff hid a terminal delivery failure"
;;

let test_external_effect_completed_has_no_direct_reply_error () =
  let payload_json =
    `Assoc
      [ TO.wire_key, `String (TO.to_label TO.Terminal_effect_settled)
      ; "reply", `String ""
      ]
  in
  check (option string) "terminal surface delivery is already visible" None
    (Option.map summary_of_cause
       (Stream.For_testing.direct_reply_terminal_error (Some payload_json) ""))

let test_canonical_payload_carries_delivery_target () =
  let turn_ref = Ids.Turn_ref.make ~trace_id:"post-target" ~absolute_turn:3 in
  let body_for outcome target_json =
    `Assoc
      ([ "reply", `String ""
       ; TO.wire_key, `String (TO.to_label outcome)
       ; TO.turn_ref_wire_key, Ids.Turn_ref.to_yojson turn_ref
       ]
       @ target_json)
    |> Yojson.Safe.to_string
  in
  let body_with = body_for TO.Terminal_effect_settled in
  (match
     Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id
       (body_with
          [ ( Masc.Keeper_surface_post.delivery_target_wire_key
            , `Assoc [ "kind", `String "dashboard" ] )
          ])
   with
   | Ok canonical ->
     (match canonical.external_effect_target with
      | Some Masc.Keeper_surface_post.Delivered_to_dashboard -> ()
      | Some _ | None ->
        fail "dashboard delivery target was not decoded from the payload")
   | Error error ->
     fail
       (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
          error));
  (* The outcome and the receipt come from the same terminal_effect_state
     (keeper_agent_run.ml), so a completed external effect always serializes
     its target. A payload claiming the outcome without one is rejected rather
     than projected as a null destination. *)
  (match
     Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id
       (body_with [])
   with
   | Error (Server_routes_http_keeper_stream.Missing_payload_field field) ->
     check string "the missing field is named" "external_effect_target" field
   | Error other ->
     fail
       (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
          other)
   | Ok _ ->
     fail "External_effect_completed without a target must be rejected");
  (* Absence is the ordinary shape for every other outcome. *)
  (match
     Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id
       (body_for TO.Visible_reply [])
   with
   | Ok canonical ->
     (match canonical.external_effect_target with
      | None -> ()
      | Some _ -> fail "a visible reply carries no delivery target")
   | Error error ->
     fail
       (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
          error));
  (* The other direction: a target on an outcome that completed no external
     effect is rejected, so [Some] alone proves the outcome. *)
  (match
     Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id
       (body_for TO.Visible_reply
          [ ( Masc.Keeper_surface_post.delivery_target_wire_key
            , `Assoc [ "kind", `String "dashboard" ] )
          ])
   with
   | Error (Stream.Invalid_external_effect_target _) -> ()
   | Error error ->
     fail
       (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
          error)
   | Ok _ -> fail "a delivery target on a visible reply must reject the payload");
  match
    Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id
      (body_with
         [ ( Masc.Keeper_surface_post.delivery_target_wire_key
           , `Assoc [ "kind", `String "telegram" ] )
         ])
  with
  | Error (Stream.Invalid_external_effect_target _) -> ()
  | Error error ->
    fail
      (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
         error)
  | Ok _ -> fail "unknown delivery target kind must reject the payload"

let test_external_effect_status_survives_server_projection () =
  (* No stop reason maps here any more -- a Gate deferral parks the call and
     the turn keeps running.  The outcome is still written by lanes recorded
     before that change, so the server projection has to carry it. *)
  let turn_outcome = TO.Awaiting_gate_approval in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"gate-ack" ~absolute_turn:2 in
  let body =
    `Assoc
      [ "reply", `String ""
      ; TO.wire_key, `String (TO.to_label turn_outcome)
      ; TO.turn_ref_wire_key, Ids.Turn_ref.to_yojson turn_ref
      ]
    |> Yojson.Safe.to_string
  in
  match
    Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id body
  with
  | Error error ->
    fail
      (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
         error)
  | Ok canonical ->
    check outcome "server preserves typed Gate wait" TO.Awaiting_gate_approval
      canonical.turn_outcome;
    check string "server keeps control status out of reply text" "" canonical.visible_reply;
    check (option string) "server accepts typed control status without prose"
      None
      (Option.map summary_of_cause
         (Stream.For_testing.direct_reply_terminal_error
            (Some canonical.payload_json)
            canonical.visible_reply));
    match
      Stream.For_testing.queued_delivery_outcome_of_turn_ref
        (Some canonical.turn_ref)
    with
    | Stream.Delivered { outcome_ref } ->
      check string "typed Gate wait keeps the exact turn ref"
        (Ids.Turn_ref.to_string turn_ref)
        outcome_ref
    | Stream.Failed _ ->
      fail "typed Gate wait did not remain deliverable for a queued turn"

let test_visible_caption_and_media_persist_as_complete_body () =
  let media = Masc.Keeper_chat_blocks.Image { src = "/media/generated.png"; cap = None } in
  let actual = Stream.For_testing.persisted_reply_blocks
      ~reply:"caption" ~turn_outcome:TO.Visible_reply (Some [media]) in
  let expected = Some (Masc.Keeper_chat_blocks.parse_text_to_blocks "caption" @ [media]) in
  check bool "caption and media survive the same durable body" true (actual = expected)

let test_external_effect_status_becomes_persisted_chat_block () =
  match
    Stream.For_testing.persisted_reply_blocks ~reply:""
      ~turn_outcome:TO.Awaiting_gate_approval
      None
  with
  | Some
      [ Masc.Keeper_chat_blocks.Status
          { kind = Masc.Keeper_chat_blocks.Awaiting_gate_approval }
      ] ->
    ()
  | Some _ -> fail "typed Gate wait persisted the wrong block shape"
  | None -> fail "typed Gate wait did not persist a status block"

let test_continuation_status_becomes_persisted_chat_block () =
  match
    Stream.For_testing.persisted_reply_blocks ~reply:""
      ~turn_outcome:TO.Continuation_checkpoint
      None
  with
  | Some
      [ Masc.Keeper_chat_blocks.Status
          { kind = Masc.Keeper_chat_blocks.Continuation_checkpoint }
      ] ->
    ()
  | Some _ -> fail "typed continuation persisted the wrong block shape"
  | None -> fail "typed continuation did not persist a status block"

let test_terminal_effect_defer_kinds_remain_distinct () =
  let expect_yield label state expected =
    match Masc.Keeper_agent_run.terminal_effect_boundary_decision state with
    | Ok (Runtime_agent.Yield actual) ->
      check string label expected
        (match actual with
         | Runtime_agent.Durable_stimulus_waiting -> "durable_stimulus_waiting"
         | Runtime_agent.Operation_queued -> "operation_queued"
         | Runtime_agent.Repeated_tool_call _ -> "repeated_tool_call"
         | Runtime_agent.Repeated_assistant_text _ -> "repeated_assistant_text"
         | Runtime_agent.Terminal_tool_completed -> "terminal_tool_completed")
    | Ok Runtime_agent.Continue -> fail (label ^ " unexpectedly continued")
    | Error error -> fail (label ^ ": " ^ Agent_core.Error.to_string error)
  in
  expect_yield
    "generic deferred tool preserves existing checkpoint"
    Masc.Keeper_tools_agent_core.Deferred_tool_result
    "durable_stimulus_waiting";
  (* A Gate deferral parks one call and nothing has run yet, so the turn keeps
     going. The host replays the parked call once the approval resolves. *)
  match
    Masc.Keeper_agent_run.terminal_effect_boundary_decision
      Masc.Keeper_tools_agent_core.External_effect_deferred
  with
  | Ok Runtime_agent.Continue -> ()
  | Ok (Runtime_agent.Yield _) -> fail "a parked external effect ended the turn"
  | Error error ->
    fail ("parked external effect: " ^ Agent_core.Error.to_string error)

let test_applied_gate_replay_seeds_terminal_settlement () =
  let output_ref =
    match
      Tool_output.make_artifact_ref
        ~sha256:(String.make 64 'a')
        ~bytes:2
        ~preview:""
        ~mime:"application/json"
    with
    | Ok output_ref -> output_ref
    | Error error -> fail (Tool_output.make_error_to_string error)
  in
  let receipt =
    Masc.Keeper_tool_execution.Surface_post_completed
      (Masc.Keeper_surface_post.To_discord { channel_id = "D-approved" })
  in
  let replay_delivery : Masc.Keeper_tools_agent_core.gate_replay_delivery =
    { approval_id = "approval-terminal"
    ; outcome =
        Masc.Keeper_gate_replay.Applied
          { operation = "connector_post"
          ; output_ref
          ; journal = Masc.Keeper_gate_replay.Replay_journal_recorded
          }
    ; terminal_effect_receipt = Some receipt
    }
  in
  let state =
    Masc.Keeper_tools_agent_core_bundle.For_testing.initial_terminal_effect_state
      (Some replay_delivery)
  in
  (match state with
   | Masc.Keeper_tools_agent_core.Terminal_effect_completed
       (Masc.Keeper_tool_execution.Surface_post_completed
          (Masc.Keeper_surface_post.To_discord { channel_id })) ->
     check string "receipt keeps the approved target" "D-approved" channel_id
   | ( Masc.Keeper_tools_agent_core.Terminal_effect_open
     | Masc.Keeper_tools_agent_core.Deferred_tool_result
     | Masc.Keeper_tools_agent_core.External_effect_deferred
     | Masc.Keeper_tools_agent_core.Terminal_effect_completed _
     | Masc.Keeper_tools_agent_core.Terminal_effect_failed _ ) ->
     fail "applied connector replay did not seed terminal completion");
  let non_terminal_replay =
    { replay_delivery with
      outcome =
        Masc.Keeper_gate_replay.Applied
          { operation = "network_read"
          ; output_ref
          ; journal = Masc.Keeper_gate_replay.Replay_journal_recorded
          }
    ; terminal_effect_receipt = None
    }
  in
  (match
     Masc.Keeper_tools_agent_core_bundle.For_testing.initial_terminal_effect_state
       (Some non_terminal_replay)
   with
   | Masc.Keeper_tools_agent_core.Terminal_effect_open -> ()
   | ( Masc.Keeper_tools_agent_core.Deferred_tool_result
     | Masc.Keeper_tools_agent_core.External_effect_deferred
     | Masc.Keeper_tools_agent_core.Terminal_effect_completed _
     | Masc.Keeper_tools_agent_core.Terminal_effect_failed _ ) ->
     fail "non-terminal Gate replay acquired a terminal boundary");
  match Masc.Keeper_agent_run.terminal_effect_boundary_decision state with
  | Ok (Runtime_agent.Yield Runtime_agent.Terminal_tool_completed) -> ()
  | Ok Runtime_agent.Continue ->
    fail "applied connector replay re-entered ordinary visible delivery"
  | Ok (Runtime_agent.Yield _) ->
    fail "applied connector replay selected the wrong yield boundary"
  | Error error -> fail (Agent_core.Error.to_string error)

let tool_call ?(input = Some "input") ?(output = Some "output") ?typed_outcome tool_name
    : Masc.Keeper_agent_result.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; execution_outcome = Tool_result.Ok
  ; typed_outcome
  ; latency_ms = 1.
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint = input
  ; output_fingerprint = output
  }

let digest tool_name input output_text =
  match
    Masc.Keeper_tool_progress_identity.digest_tool_io ~tool_name ~input ~output_text ()
  with
  | Some { Masc.Keeper_tool_progress_identity.input_fingerprint; output_fingerprint } ->
    input_fingerprint, output_fingerprint
  | None -> fail "digest_tool_io refused the fixture"
;;

let test_explicit_native_boundary_reasons () =
  let decide yield_requested = Masc.Keeper_agent_run.For_testing.native_tool_boundary
    ~repetition_execution:None
    ~terminal_effect_state:Masc.Keeper_tools_agent_core.Terminal_effect_open
    ~yield_requested in
  check bool "open effect state continues" true (decide None = Ok Runtime_agent.Continue);
  check bool "no host request continues" true
    (decide (Some (fun () -> Ok None)) = Ok Runtime_agent.Continue);
  check bool "queued operation still yields" true
    (decide (Some (fun () -> Ok (Some
       { Masc.Keeper_agent_run.reason = Masc.Keeper_agent_run.Operation_queued })))
      = Ok (Runtime_agent.Yield Runtime_agent.Operation_queued));
  (match decide (Some (fun () -> Error "authoritative queue unavailable")) with
   | Error (Agent_core.Error.Internal _) -> ()
   | Ok _ | Error _ -> fail "authoritative queue failure was hidden")
;;

let test_tool_io_digest_is_keyed_on_the_bytes () =
  let input = `Assoc [ ("argv", `List [ `String "status" ]) ] in
  let body = "{\"ok\":true,\"rows\":3}" in
  let first = digest "masc_status" input body in
  check
    (pair string string)
    "the same question gets the same answer"
    first
    (digest "masc_status" input body);
  (* The purge shape: same tool, same input, body replaced. *)
  let cleared = digest "masc_status" input "[tool result cleared]" in
  check
    bool
    "a replaced body is not answered from the old one"
    false
    (String.equal (snd first) (snd cleared));
  check
    string
    "and the input side is untouched by that"
    (fst first)
    (fst cleared);
  let other_input = `Assoc [ ("argv", `List [ `String "list" ]) ] in
  check
    bool
    "a different input is not answered from the old one"
    false
    (String.equal (fst first) (fst (digest "masc_status" other_input body)));
  (* The fingerprints are of the payload: [digest_tool_input] and
     [digest_tool_output] both take the tool name and both ignore it, and the
     repeated-call check compares the name separately as its own field of
     [tool_call_detail]. The memo still keys on it, because a memo is keyed on
     what its function is asked, not on which of those arguments the function
     happens to read today. *)
  check
    (pair string string)
    "the tool name is not part of the fingerprint"
    first
    (digest "keeper_tasks_list" input body)
;;

let test_page_cursor_distinguishes_repeated_input_without_log_leak () =
  let input cursor =
    `Assoc [ "query", `String "voices"; "next_page_token", `String cursor ]
  in
  check bool "different pages keep different opaque identity" false
    (String.equal
       (fst (digest "masc_voices_list" (input "page-a") "{}"))
       (fst (digest "masc_voices_list" (input "page-b") "{}")));
  let logged =
    input "page-a"
    |> Masc.Observability_redact.redact_json_value
    |> Masc.Observability_redact.redact_json_strings
  in
  check string "the observability cursor remains masked"
    {|{"query":"voices","next_page_token":"[REDACTED]"}|}
    (Yojson.Safe.to_string logged);
  let nested_secret cursor =
    `Assoc [ "client_secret_v2", `Assoc [ "next_page_token", `String cursor ] ]
  in
  check string "a secret-bearing parent cannot restore its cursor-shaped child"
    (fst (digest "masc_voices_list" (nested_secret "opaque-a") "{}"))
    (fst (digest "masc_voices_list" (nested_secret "opaque-b") "{}"))
;;

let test_confirmation_tokens_distinguish_actions_without_log_leak () =
  let input token =
    `Assoc [ "confirm_token", `String token; "decision", `String "confirm" ] in
  let token index = Printf.sprintf "00000000-0000-0000-0000-%012d" index in
  check bool "different pending actions keep different opaque identity" false
    (String.equal
       (fst (digest "masc_operator_confirm" (input (token 0)) "{}"))
       (fst (digest "masc_operator_confirm" (input (token 1)) "{}")));
  check (option string) "confirmation tokens stay masked in tool logs"
    (Some {|{"confirm_token":"[REDACTED]","decision":"confirm"}|})
    (Option.map Yojson.Safe.to_string
       (Masc.Observability_redact.redacted_tool_input_json
          ~tool_name:"masc_operator_confirm" (input (token 0))));
  check string "other tools do not give credentials action identity"
    (fst (digest "other_tool" (input (token 0)) "{}"))
    (fst (digest "other_tool" (input (token 1)) "{}"));
  let nested index = `Assoc ["client_secret_v2", input (token index)] in
  check string "nested secret fields do not get action identity"
    (fst (digest "masc_operator_confirm" (nested 0) "{}"))
    (fst (digest "masc_operator_confirm" (nested 1) "{}"))
;;

let test_tool_io_digest_keeps_similar_calls_apart () =
  let shared = String.make 1024 'a' in
  let calls =
    List.init 40 (fun index ->
      let name = Printf.sprintf "tool_%d" (index mod 3) in
      let input = `Assoc [ ("argv", `String (string_of_int index)) ] in
      let body = shared ^ "|" ^ string_of_int index in
      name, input, body)
  in
  let answers = List.map (fun (n, i, b) -> digest n i b) calls in
  let distinct = List.sort_uniq compare (List.map snd answers) in
  check int "each body has its own output fingerprint" 40 (List.length distinct);
  List.iter2
    (fun (name, input, body) expected ->
      check (pair string string) "the second pass agrees" expected (digest name input body))
    (List.rev calls)
    (List.rev answers)
;;

(* Past the byte cap the oldest entries are dropped. A dropped answer has to
   be recomputed, and recomputing it has to give what it gave before. *)
let test_tool_io_digest_survives_eviction () =
  let input = `Assoc [ ("argv", `String "first") ] in
  let body = "{\"ok\":true,\"first\":1}" in
  let first = digest "masc_status" input body in
  (* Only their size matters: past the preview cut these all fingerprint
     alike, but each is its own key and each key is counted. *)
  let filler = String.make 262_144 'f' in
  List.iter
    (fun index ->
      ignore
        (digest
           "filler_tool"
           (`Assoc [ ("argv", `String (string_of_int index)) ])
           (filler ^ string_of_int index)))
    (List.init 44 Fun.id);
  check
    (pair string string)
    "an evicted answer is recomputed, not lost or changed"
    first
    (digest "masc_status" input body)
;;

(* A new invocation reports only calls actually executed in that invocation. *)
let test_checkpoint_history_is_not_current_tool_execution () =
  let module Acc = Masc.Keeper_run_tools_hook_accumulator in
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "history-probe" ]) |> Result.get_ok
  in
  let acc =
    Acc.create ~meta
      ~tool_surface:
        { turn_lane = Masc.Keeper_agent_tool_surface.Lane_text_only
        ; config_root = "fixture"
        ; runtime_config_path = Some "fixture/runtime.toml"
        }
  in
  check int "a resumed no-tool invocation has no executed calls" 0
    (List.length acc.tool_calls);
  acc.tool_calls <- [ tool_call "Execute" ];
  check int "only this invocation's executed call is reported" 1
    (List.length acc.tool_calls)
;;

let test_history_memo_answers_a_purged_body_from_its_new_bytes () =
  let input = `Assoc [ ("argv", `List [ `String "status" ]) ] in
  let history_memo = Masc.Keeper_tool_progress_identity.History_memo.create () in
  let walk body =
    match
      Masc.Keeper_tool_progress_identity.digest_history_pairs history_memo
        [ { tool_name = "masc_status"; input; output_text = body } ]
    with
    | [ Some { Masc.Keeper_tool_progress_identity.output_fingerprint; _ } ] -> output_fingerprint
    | _ -> fail "expected one fingerprinted history pair"
  in
  let live body =
    match
      Masc.Keeper_tool_progress_identity.digest_tool_io
        ~tool_name:"masc_status"
        ~input
        ~output_text:body ()
    with
    | Some { Masc.Keeper_tool_progress_identity.output_fingerprint; _ } -> output_fingerprint
    | None -> fail "digest_tool_io refused the fixture"
  in
  let body = "{\"ok\":true,\"rows\":3}" in
  let first = walk body in
  check string "a walk answers what the live hook answers" (live body) first;
  check string "the next walk answers the same" first (walk body);
  let cleared = walk "[tool result cleared]" in
  check bool "a purged body is not answered from the old one" false (String.equal first cleared);
  check string "and it is answered from its own bytes" (live "[tool result cleared]") cleared
;;

let test_seed_stops_where_a_yield_already_judged () =
  let pairs = List.init 5 (fun i -> tool_call ~input:(Some (string_of_int i)) "Read") in
  let names calls =
    List.map (fun (c : Masc.Keeper_agent_result.tool_call_detail) ->
      Option.value ~default:"" c.input_fingerprint) calls
  in
  check (list string) "nothing judged seeds everything, newest first"
    [ "0"; "1"; "2"; "3"; "4" ]
    (names (Masc.Keeper_repetition_judged.seed_beyond ~judged:0 pairs));
  check (list string) "the oldest judged pairs drop off the tail"
    [ "0"; "1"; "2" ]
    (names (Masc.Keeper_repetition_judged.seed_beyond ~judged:2 pairs));
  check (list string) "judged at the length seeds nothing" []
    (names (Masc.Keeper_repetition_judged.seed_beyond ~judged:5 pairs));
  check (list string) "a history cut shorter than the boundary seeds nothing" []
    (names (Masc.Keeper_repetition_judged.seed_beyond ~judged:9 pairs))
;;

let test_judged_boundary_rides_the_context () =
  let module Judged = Masc.Keeper_repetition_judged in
  let module Context = Agent_core.Context in
  let held context =
    Context.get_scoped context Context.Session Judged.context_key
  in
  let record context history_pairs =
    Judged.record context { history_generation = Judged.Initial; history_pairs; ledger_frontier = Keeper_tool_call_index.empty_frontier } in
  let restore ~source ~target =
    Judged.restore ~source ~target |> Result.map (fun boundary -> boundary.Judged.history_pairs) in
  let source = Context.create_sync () in
  let target = Context.create_sync () in
  (match restore ~source ~target with
   | Ok 0 -> ()
   | Ok n -> failf "a context holding no record read as %d judged" n
   | Error error -> fail (Judged.error_to_string error));
  check bool "no record leaves the target without one" true (Option.is_none (held target));
  record source 5;
  (match restore ~source ~target with
   | Ok 5 -> ()
   | Ok n -> failf "the recorded boundary read as %d" n
   | Error error -> fail (Judged.error_to_string error));
  check bool "the boundary rides into the run's context" true
    (Option.equal ( = ) (held source) (held target));
  (* A yield on a lane that persists no checkpoint records into the live
     context only. The durable count behind it must not pull the boundary
     back down: restore keeps the larger. *)
  record target 7;
  (match restore ~source ~target with
   | Ok 7 -> ()
   | Ok n -> failf "the live boundary was pulled back to %d" n
   | Error error -> fail (Judged.error_to_string error));
  check bool "and the live context keeps its own" true
    (Option.equal ( = ) (Some (`Assoc [ ("history_generation", `Null); ("history_pairs", `Int 7); ("ledger_frontier", `List []) ])) (held target));
  (* When the durable count is the larger, it is what the run's context
     ends up holding. *)
  record source 9;
  (match restore ~source ~target with
   | Ok 9 -> ()
   | Ok n -> failf "the durable boundary read as %d" n
   | Error error -> fail (Judged.error_to_string error));
  check bool "the run's context is raised to it" true
    (Option.equal ( = ) (held source) (held target));
  let malformed = Context.create_sync () in
  Context.set_scoped malformed Context.Session Judged.context_key
    (`Assoc [ ("history_pairs", `String "five") ]);
  match restore ~source:malformed ~target:(Context.create_sync ()) with
  | Error (Judged.Invalid_record _) -> ()
  | Ok n -> failf "a record that does not decode read as %d rather than an error" n
;;

let test_autonomous_yield_boundary_contract () =
  let module F = Masc.Keeper_agent_run.For_testing in
  let chat : Masc.Keeper_agent_run.yield_request =
    { reason = Masc.Keeper_agent_run.Operation_queued }
  in
  let durable_stimulus : Masc.Keeper_agent_run.yield_request =
    { reason =
        Masc.Keeper_agent_run.Durable_stimulus_waiting
          { pending_count = 1
          ; head = None
          ; head_age_sec = 0.
          ; kinds = [ Keeper_event_queue.Bootstrap ]
          }
    }
  in
  (match F.runtime_yield_reason chat with
    | Runtime_agent.Operation_queued -> ()
    | Runtime_agent.Durable_stimulus_waiting
    | Runtime_agent.Repeated_tool_call _
   | Runtime_agent.Repeated_assistant_text _
   | Runtime_agent.Terminal_tool_completed ->
     fail "chat request mapped to the durable reason");
  (match F.runtime_yield_reason durable_stimulus with
    | Runtime_agent.Durable_stimulus_waiting -> ()
    | Runtime_agent.Operation_queued
   | Runtime_agent.Repeated_tool_call _
   | Runtime_agent.Repeated_assistant_text _
   | Runtime_agent.Terminal_tool_completed ->
     fail "durable request mapped to the chat reason");
  check bool "repeated exact call yield preserves its evidence" true
    (match
       Runtime_agent.For_testing.stop_reason_of_cooperative_yield
         ~turns_used:8
         (Runtime_agent.Repeated_tool_call
            { tool_name = "keeper_tasks_list"; repeated_count = 3 })
     with
     | Runtime_agent.Yielded_after_repeated_tool_call
         { turns_used = 8
         ; tool_name = "keeper_tasks_list"
         ; repeated_count = 3
         } ->
       true
     | Runtime_agent.Completed
     | Runtime_agent.Yielded_to_operation_queued _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.Yielded_after_repeated_tool_call _
     | Runtime_agent.Yielded_after_repeated_assistant_text _
     | Runtime_agent.InputRequired _ ->
       false);
  check bool "repeated assistant text yield preserves its evidence" true
    (match
       Runtime_agent.For_testing.stop_reason_of_cooperative_yield
         ~turns_used:8
         (Runtime_agent.Repeated_assistant_text { repeated_count = 3 })
     with
     | Runtime_agent.Yielded_after_repeated_assistant_text
         { turns_used = 8; repeated_count = 3 } ->
       true
     | Runtime_agent.Completed
     | Runtime_agent.Yielded_to_operation_queued _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.Yielded_after_repeated_tool_call _
     | Runtime_agent.Yielded_after_repeated_assistant_text _
     | Runtime_agent.InputRequired _ ->
       false);
  check bool "terminal tool yield settles as completion" true
    (match
       Runtime_agent.For_testing.stop_reason_of_cooperative_yield
         ~turns_used:3
         Runtime_agent.Terminal_tool_completed
     with
     | Runtime_agent.Completed -> true
     | Runtime_agent.Yielded_to_operation_queued _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.Yielded_after_repeated_tool_call _
     | Runtime_agent.Yielded_after_repeated_assistant_text _
     | Runtime_agent.InputRequired _ -> false)

let test_terminal_externalization_failure_contract () =
  let classify =
    Masc.Keeper_tools_agent_core_bundle.For_testing.terminal_externalization_failure
  in
  let error : Masc.Tool_bridge.externalization_error =
    { kind = Masc.Tool_bridge.Artifact_storage_failure
    ; message = "disk unavailable"
    }
  in
  List.iter
    (fun state ->
       check bool "non-completed state remains authoritative" true
         (Option.is_none (classify state error)))
    [ Masc.Keeper_tools_agent_core.Terminal_effect_open
    ; Masc.Keeper_tools_agent_core.Deferred_tool_result
    ; Masc.Keeper_tools_agent_core.External_effect_deferred
    ; Masc.Keeper_tools_agent_core.Terminal_effect_failed
        { failure_class = Tool_result.Workflow_rejection
        ; effect_disposition = Tool_result.Proven_pre_effect
        ; detail =
            Keeper_terminal_effect_detail.Tool_failed
              { internal_tool_name = "fixture"; message = "original failure" }
        }
    ];
  let completed =
    Masc.Keeper_tools_agent_core.Terminal_effect_completed
      (Masc.Keeper_tool_execution.Surface_post_completed
         Masc.Keeper_surface_post.To_dashboard)
  in
  (match classify completed error with
   | Some
       { failure_class = Tool_result.Runtime_failure
       ; effect_disposition = Tool_result.Proven_post_effect
       ; detail = Keeper_terminal_effect_detail.Output_artifact_unstored { message }
       } ->
     check string "storage failure message is retained" "disk unavailable" message
   | Some _ | None ->
     fail "completed terminal effect did not become proven post-effect failure");
  (* An output over its inline budget is not a storage failure. *)
  match
    classify
      completed
      { kind = Masc.Tool_bridge.Inline_budget_exceeded
      ; message = "inline tool output exceeds descriptor budget (9 > 8 bytes)"
      }
  with
  | Some
      { effect_disposition = Tool_result.Proven_post_effect
      ; detail = Keeper_terminal_effect_detail.Output_over_inline_budget { message }
      ; _
      } ->
    check string "budget failure message is retained"
      "inline tool output exceeds descriptor budget (9 > 8 bytes)" message
  | Some _ | None ->
    fail "an over-budget completed output was not recorded as an inline budget failure"

let payload fields = Some (`Assoc fields)

let decoded_exn payload =
  match TO.of_reply_payload payload with
  | Ok outcome -> outcome
  | Error error -> fail (TO.decode_error_to_string error)

let check_decode_error label expected payload =
  match TO.of_reply_payload payload with
  | Error actual -> check bool label true (actual = expected)
  | Ok actual ->
    failf "%s: unexpectedly decoded %s" label (TO.to_label actual)

let test_payload_decode () =
  check_decode_error "no payload fails closed" TO.Payload_missing None;
  check_decode_error "field absent fails closed" TO.Turn_outcome_missing
    (payload [ ("reply", `String "hi") ]);
  check outcome "checkpoint label" TO.Continuation_checkpoint
    (decoded_exn
       (payload [ (TO.wire_key, `String "continuation_checkpoint") ]));
  check outcome "visible label" TO.Visible_reply
    (decoded_exn
       (payload [ (TO.wire_key, `String "visible_reply") ]));
  check outcome "completed external effect label" TO.Terminal_effect_settled
    (decoded_exn
       (payload [ (TO.wire_key, `String "external_effect_completed") ]));
  check outcome "no visible reply label" TO.No_visible_reply
    (decoded_exn
       (payload [ (TO.wire_key, `String "no_visible_reply") ]));
  check_decode_error "unknown label fails closed"
    (TO.Turn_outcome_unknown "deferred")
    (payload [ (TO.wire_key, `String "deferred") ]);
  check_decode_error "duplicate label fails closed" TO.Turn_outcome_duplicate
    (payload
       [ (TO.wire_key, `String "visible_reply")
       ; (TO.wire_key, `String "no_visible_reply")
       ]);
  check_decode_error "non-string label fails closed" TO.Turn_outcome_not_string
    (payload [ (TO.wire_key, `Int 1) ]);
  check_decode_error "non-object payload fails closed" TO.Payload_not_object
    (Some (`List []))

let checkpoint_text =
  "Continuation checkpoint saved; keeper remains scheduled for the next \
   cycle."

(* The reply text no longer participates in classification: a reply that
   *looks* like the synthetic notice but is declared visible stays
   visible, and the declared checkpoint suppresses regardless of text. *)
let test_prefix_is_dead () =
  check outcome "checkpoint-shaped text, declared visible"
    TO.Visible_reply
    (decoded_exn
       (payload
          [ ("reply", `String checkpoint_text);
            (TO.wire_key, `String "visible_reply")
          ]));
  check outcome "ordinary text, declared checkpoint"
    TO.Continuation_checkpoint
    (decoded_exn
       (payload
         [ ("reply", `String "all done");
           (TO.wire_key, `String "continuation_checkpoint")
          ]));
  check outcome "ordinary text, declared no visible reply"
    TO.No_visible_reply
    (decoded_exn
       (payload
          [ ("reply", `String "all done");
            (TO.wire_key, `String "no_visible_reply")
          ]))

let turn_ref_t : Ids.Turn_ref.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (Ids.Turn_ref.to_string t))
    Ids.Turn_ref.equal

(* RFC-0233 §7: the consumer-side decode of the turn join key the keeper
   minted into the reply payload.  Parse, don't repair — absent and
   malformed both decode to None; of_string splits on the LAST '#'. *)
let test_turn_ref_payload_decode () =
  check (option turn_ref_t) "no payload -> None" None
    (TO.turn_ref_of_reply_payload None);
  check (option turn_ref_t) "field absent -> None" None
    (TO.turn_ref_of_reply_payload (payload [ ("reply", `String "hi") ]));
  check (option turn_ref_t) "valid join key decodes"
    (Some
       (Ids.Turn_ref.make ~trace_id:"trace-1780648779957-00000"
          ~absolute_turn:4071))
    (TO.turn_ref_of_reply_payload
       (payload
          [ (TO.turn_ref_wire_key, `String "trace-1780648779957-00000#4071") ]));
  check (option turn_ref_t) "inner '#' splits on the last separator"
    (Some (Ids.Turn_ref.make ~trace_id:"weird#trace" ~absolute_turn:12))
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "weird#trace#12") ]));
  check (option turn_ref_t) "no separator -> None (never repaired)" None
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "no-separator") ]));
  check (option turn_ref_t) "non-int suffix -> None" None
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "trace#abc") ]));
  check (option turn_ref_t) "non-string field -> None" None
    (TO.turn_ref_of_reply_payload (payload [ (TO.turn_ref_wire_key, `Int 5) ]))

let test_queued_delivery_requires_exact_turn_ref () =
  let check_failed label payload_json =
    match
      payload_json
      |> TO.turn_ref_of_reply_payload
      |> Stream.For_testing.queued_delivery_outcome_of_turn_ref
    with
    | Stream.Failed { kind = Stream.Missing_turn_ref; detail } ->
        check bool (label ^ " has diagnostic detail") true
          (String.trim detail <> "")
    | Stream.Failed _ | Stream.Delivered _ ->
        fail (label ^ " must fail with Missing_turn_ref")
  in
  check_failed "missing turn_ref"
    (payload [ ("reply", `String "hi") ]);
  check_failed "malformed turn_ref"
    (payload
       [ ("reply", `String "hi")
       ; (TO.turn_ref_wire_key, `String "not-a-turn-ref")
       ]);
  let valid =
    payload
      [ ("reply", `String "hi")
      ; (TO.turn_ref_wire_key, `String "trace-queued#42")
      ]
  in
  match
    valid
    |> TO.turn_ref_of_reply_payload
    |> Stream.For_testing.queued_delivery_outcome_of_turn_ref
  with
  | Stream.Delivered { outcome_ref } ->
      check string "valid turn_ref is preserved exactly"
        "trace-queued#42" outcome_ref
  | Stream.Failed _ ->
    fail "valid turn_ref must produce Delivered"

let test_terminal_commit_error_cannot_become_delivery_success () =
  let persist_error = "terminal transcript fsync failed" in
  match
    Stream.For_testing.committed_delivery_outcome
      ~turn_ref:None
      (Error persist_error)
  with
  | Error observed -> check string "operation commit preserves typed Error" persist_error observed
  | Ok _ -> fail "operation commit was downgraded to delivery success"

let spoken_row name ~turn_outcome ~spoken expected =
  match Stream.For_testing.control_turn_delivery ~turn_outcome ~spoken with
  | `Assistant_row observed -> check string name expected observed
  | `Tool_calls_only -> fail (name ^ ": the keeper's words were dropped")

(* Pending control boundaries retain the response while execution continues.
   Completed terminal tools own their delivery instead. *)
let test_control_turn_keeps_spoken_words () =
  let words = "    첫 줄\n    둘째 줄  \n\n" in
  spoken_row "continuation checkpoint keeps the words"
    ~turn_outcome:Masc.Keeper_turn_outcome.Continuation_checkpoint
    ~spoken:(Some words) words;
  spoken_row "pending external effect keeps the words"
    ~turn_outcome:Masc.Keeper_turn_outcome.Awaiting_gate_approval
    ~spoken:(Some words) words

let test_terminal_tool_owns_public_reply () =
  let diagnostic = "I should explain the operator's intent before ending the turn." in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"terminal-tool-ownership" ~absolute_turn:5 in
  let receipt_key = Masc.Keeper_surface_post.delivery_target_wire_key in
  let source_payload =
    `Assoc
      [ "reply", `String diagnostic
      ; TO.wire_key, `String (TO.to_label TO.Terminal_effect_settled)
      ; TO.turn_ref_wire_key, Ids.Turn_ref.to_yojson turn_ref
      ; receipt_key, `Assoc [ "kind", `String "dashboard" ]
      ]
  in
  let body = Yojson.Safe.to_string source_payload in
  let canonical =
    match Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id body with
    | Ok canonical -> canonical
    | Error error ->
      fail (Stream.canonical_reply_payload_error_to_string error)
  in
  check string "source diagnostics remain intact" diagnostic
    Yojson.Safe.Util.(source_payload |> member "reply" |> to_string);
  check outcome "settled ownership is preserved" TO.Terminal_effect_settled
    canonical.turn_outcome;
  check string "terminal Reply_details source contains no second reply" ""
    canonical.visible_reply;
  check string "HTTP polling contains no second reply" ""
    Yojson.Safe.Util.(Yojson.Safe.from_string canonical.poll_body |> member "reply" |> to_string);
  check bool "delivery receipt remains available" true
    (canonical.external_effect_target = Some Masc.Keeper_surface_post.Delivered_to_dashboard);
  let ordinary_body =
    `Assoc
      [ "reply", `String diagnostic
      ; TO.wire_key, `String (TO.to_label TO.Visible_reply)
      ; TO.turn_ref_wire_key, Ids.Turn_ref.to_yojson turn_ref
      ]
    |> Yojson.Safe.to_string
  in
  (match Stream.For_testing.canonical_reply_payload_of_body
           ~redact_text:Fun.id ordinary_body with
   | Ok ordinary ->
     check string "identical words remain public for a reply-owned outcome"
       diagnostic ordinary.visible_reply
   | Error error -> fail (Stream.canonical_reply_payload_error_to_string error));
  (* Even an unprojected source string cannot bypass the persistence decision. *)
  (match Stream.For_testing.control_turn_delivery
           ~turn_outcome:canonical.turn_outcome ~spoken:(Some diagnostic) with
   | `Tool_calls_only -> ()
   | `Assistant_row _ -> fail "terminal tool delivery manufactured another assistant row");
  match Masc.Keeper_chat_blocks.connector_projection
          ~turn_outcome:canonical.turn_outcome ~reply:(Some diagnostic) with
  | Masc.Keeper_chat_blocks.Connector_no_visible_reply -> ()
  | _ -> fail "connector and HTTP disagree on terminal tool reply ownership"

let test_wordless_control_turn_delivery () =
  (* A wordless checkpoint still writes its row: the typed status block is the
     row's content. A wordless completed effect writes no row at all, because
     its tool-call record is the whole of what the turn did. *)
  spoken_row "wordless checkpoint still writes a row"
    ~turn_outcome:Masc.Keeper_turn_outcome.Continuation_checkpoint
    ~spoken:None "";
  spoken_row "wordless pending effect still writes a row"
    ~turn_outcome:Masc.Keeper_turn_outcome.Awaiting_gate_approval
    ~spoken:None "";
  match
    Stream.For_testing.control_turn_delivery
      ~turn_outcome:Masc.Keeper_turn_outcome.Terminal_effect_settled
      ~spoken:None
  with
  | `Tool_calls_only -> ()
  | `Assistant_row _ ->
    fail "a wordless completed effect must not manufacture an assistant row"

let test_media_only_queued_reply_uses_delivery_path () =
  match
    Stream.For_testing.empty_reply_delivery_plan
      ~has_visible_blocks:true
      ~has_tool_calls:false
  with
  | `Visible_blocks -> ()
  | `Tool_calls_only | `Failure ->
    fail "media-only queued reply must use the delivered assistant path"

let test_media_continuation_uses_assistant_delivery_path () =
  (* A continuation with accumulated media still persists one assistant row:
     the typed status block leads and the media blocks survive. *)
  let media =
    Masc.Keeper_chat_blocks.Image { src = "/media/generated.png"; cap = None }
  in
  match
    Stream.For_testing.persisted_reply_blocks ~reply:""
      ~turn_outcome:TO.Continuation_checkpoint
      (Some [ media ])
  with
  | Some
      [ Masc.Keeper_chat_blocks.Status
          { kind = Masc.Keeper_chat_blocks.Continuation_checkpoint }
      ; Masc.Keeper_chat_blocks.Image { src = "/media/generated.png"; cap = None }
      ] ->
    ()
  | Some _ ->
    fail "media continuation dropped or reordered the persisted blocks"
  | None -> fail "media continuation did not persist a status block"

let test_continuation_status_uses_assistant_delivery_path () =
  (* Real invariant behind the stream call site: for
     [Continuation_checkpoint], [persisted_reply_blocks] always returns
     [Some] with the status block leading, so the turn always takes the
     assistant-reply persist path — never a tool-calls-only or user-only
     path — regardless of media or direct-delivery checkpoint state. *)
  List.iter
    (fun media_blocks ->
       match
         Stream.For_testing.persisted_reply_blocks ~reply:""
           ~turn_outcome:TO.Continuation_checkpoint media_blocks
       with
       | Some
           (Masc.Keeper_chat_blocks.Status
              { kind = Masc.Keeper_chat_blocks.Continuation_checkpoint }
            :: _) ->
         ()
       | Some _ ->
         fail "continuation status block must lead the persisted blocks"
       | None ->
         fail
           "continuation without visible blocks would miss the assistant \
            delivery path")
    [ None
    ; Some
        [ Masc.Keeper_chat_blocks.Image
            { src = "/media/generated.png"; cap = None }
        ]
    ]

let body fields = `Assoc fields

let test_direct_reply_visible_text () =
  let check_ok label expected json =
    match Ops.direct_reply_visible_text json with
    | Ok actual -> check (option string) label expected actual
    | Error error ->
      failf "%s: %s" label (Ops.direct_reply_decode_error_to_string error)
  in
  let check_error label expected json =
    match Ops.direct_reply_visible_text json with
    | Ok _ -> failf "%s: expected decode error" label
    | Error error ->
      check string label expected
        (Ops.direct_reply_decode_error_to_string error)
  in
  check_ok "declared checkpoint -> None" None
    (body
       [ ("reply", `String checkpoint_text);
         ("turn_outcome", `String "continuation_checkpoint")
       ]);
  check_ok "declared no visible reply -> None" None
    (body
       [ ("reply", `String "all done");
         ("turn_outcome", `String "no_visible_reply")
       ]);
  check_error
    "missing outcome is a direct-reply contract error"
    "keeper reply payload is missing turn_outcome"
    (body [ ("reply", `String checkpoint_text) ]);
  check_ok "declared visible -> reply text" (Some "all done")
    (body
       [ ("reply", `String "all done");
         ("turn_outcome", `String "visible_reply")
       ]);
  let spaced_reply = "    첫 줄\n    둘째 줄  \n\n" in
  check_ok "visible reply keeps indentation and paragraph breaks" (Some spaced_reply)
    (body
       [ ("reply", `String spaced_reply);
         ("turn_outcome", `String "visible_reply")
       ]);
  check_ok "empty reply -> None" None
    (body
       [ ("reply", `String "   ");
         ("turn_outcome", `String "visible_reply")
       ]);
  check_error
    "visible outcome without reply is a direct-reply contract error"
    "keeper reply payload is missing reply for visible_reply"
    (body [ ("turn_outcome", `String "visible_reply") ])

let test_connector_projection_keeps_external_wait_typed () =
  match
    Masc.Keeper_chat_blocks.connector_projection
      ~turn_outcome:TO.Awaiting_gate_approval
      ~reply:(Some "assistant preface that must not survive")
  with
  | Connector_status { kind = Awaiting_gate_approval } -> ()
  | Connector_status { kind = Continuation_checkpoint }
  | Connector_text _ | Connector_no_visible_reply ->
    fail "external-effect wait must remain a typed connector status"

let test_connector_projection_keeps_continuation_typed () =
  match
    Masc.Keeper_chat_blocks.connector_projection
      ~turn_outcome:TO.Continuation_checkpoint
      ~reply:(Some "assistant preface that must not survive")
  with
  | Connector_status { kind = Continuation_checkpoint } -> ()
  | Connector_status { kind = Awaiting_gate_approval }
  | Connector_text _ | Connector_no_visible_reply ->
    fail "continuation checkpoint must remain a typed connector status"

let test_connector_projection_suppresses_completed_external_effect () =
  match
    Masc.Keeper_chat_blocks.connector_projection
      ~turn_outcome:TO.Terminal_effect_settled
      ~reply:None
  with
  | Connector_no_visible_reply -> ()
  | Connector_status _ | Connector_text _ ->
    fail "completed external effect must not emit a duplicate connector reply"

let test_direct_reply_projection_keeps_external_wait_typed () =
  match
    Ops.direct_reply_projection
      (body
         [ ("reply", `String "assistant preface that must not survive")
         ; ("turn_outcome", `String "external_effect_pending")
         ])
  with
  | Ok (Connector_status { kind = Awaiting_gate_approval }) -> ()
  | Ok (Connector_status { kind = Continuation_checkpoint })
  | Ok (Connector_text _ | Connector_no_visible_reply) ->
    fail "direct reply collapsed external-effect wait into silence"
  | Error error ->
    fail (Ops.direct_reply_decode_error_to_string error)

(* A reply the provider did not stream is published as deltas cut from the
   stored reply, and Discord and Slack post those deltas joined. The joined
   chunks must be the reply: a whitespace-only chunk between two paragraphs
   used to be dropped, so "\n\n" arrived as "\n". *)
let test_reply_chunks_join_back_to_the_reply () =
  let long_line = String.concat " " (List.init 60 (fun i -> Printf.sprintf "단어%d" i)) in
  let replies =
    [ "첫 문단입니다.\n\n둘째 문단."
    ; "Done!\n\n\nNext?\n\nLast."
    ; "코드:\n\n```\nlet x = 1\n\n\nlet y = 2\n```\n"
    ; "  앞 공백. 뒤 공백.  "
    ; "\n\n"
    ; long_line ^ ".\n\n" ^ long_line
    ; ""
    ]
  in
  List.iter
    (fun reply ->
       let chunks = Server_routes_http_keeper_stream.split_keeper_reply_chunks reply in
       check string (Printf.sprintf "joined chunks of %S" reply) reply (String.concat "" chunks);
       check bool (Printf.sprintf "no empty chunk in %S" reply) false
         (List.exists (String.equal "") chunks))
    replies;
  check (list string) "a paragraph break is its own chunk, not dropped"
    [ "첫 문단입니다."; "\n"; "\n둘째 문단." ]
    (Server_routes_http_keeper_stream.split_keeper_reply_chunks "첫 문단입니다.\n\n둘째 문단.")
;;

let () =
  run "keeper_turn_outcome"
    [
      ( "codec",
        [
          test_case "native stops use explicit lifecycle reasons" `Quick test_explicit_native_boundary_reasons;
        test_case "label round trip" `Quick test_label_round_trip;
          test_case "unknown label is None" `Quick test_unknown_label_is_none;
          test_case "the parked-call label still decodes" `Quick
            test_parked_call_label_still_decodes;
        ] );
      ( "mapping",
        [
          test_case "of_stop_reason" `Quick test_of_stop_reason;
          test_case "of_result_surface" `Quick test_of_result_surface;
          test_case "posted progress retains cooperative continuation" `Quick
            test_progress_post_keeps_typed_continuation;
          test_case "completed external effect has no direct reply error" `Quick
            test_external_effect_completed_has_no_direct_reply_error;
          test_case "external effect status survives server projection" `Quick
            test_external_effect_status_survives_server_projection;
          test_case "canonical payload carries the delivery target" `Quick
            test_canonical_payload_carries_delivery_target;
          test_case "external effect status becomes persisted chat block" `Quick
            test_external_effect_status_becomes_persisted_chat_block;
          test_case "terminal effect defer kinds remain distinct" `Quick
            test_terminal_effect_defer_kinds_remain_distinct;
          test_case "applied Gate replay seeds terminal settlement" `Quick
            test_applied_gate_replay_seeds_terminal_settlement;
          test_case "checkpoint history is not current execution" `Quick
            test_checkpoint_history_is_not_current_tool_execution;
          test_case "history memo answers a purged body from its new bytes" `Quick
            test_history_memo_answers_a_purged_body_from_its_new_bytes;
          test_case "page cursors retain identity while logs mask them" `Quick
            test_page_cursor_distinguishes_repeated_input_without_log_leak;
          test_case "confirmation tokens retain action identity while logs mask them" `Quick
            test_confirmation_tokens_distinguish_actions_without_log_leak;
          test_case "tool io digest is keyed on the bytes" `Quick
            test_tool_io_digest_is_keyed_on_the_bytes;
          test_case "tool io digest keeps similar calls apart" `Quick
            test_tool_io_digest_keeps_similar_calls_apart;
          test_case "tool io digest survives eviction" `Quick
            test_tool_io_digest_survives_eviction;
          test_case "the seed stops where a yield already judged" `Quick
            test_seed_stops_where_a_yield_already_judged;
          test_case "the judged boundary rides the context" `Quick
            test_judged_boundary_rides_the_context;
          test_case "autonomous yield boundary contract" `Quick
            test_autonomous_yield_boundary_contract;
          test_case "terminal externalization failure contract" `Quick
            test_terminal_externalization_failure_contract;
        ] );
      ( "payload_decode",
        [
          test_case "decode policy" `Quick test_payload_decode;
          test_case "prefix is dead" `Quick test_prefix_is_dead;
          test_case "turn_ref decode (parse, don't repair)" `Quick
            test_turn_ref_payload_decode;
          test_case "queued delivery requires exact turn_ref" `Quick
            test_queued_delivery_requires_exact_turn_ref;
          test_case "terminal commit error cannot become delivery success" `Quick
            test_terminal_commit_error_cannot_become_delivery_success;
          test_case "control turn keeps the keeper's words" `Quick
            test_control_turn_keeps_spoken_words;
          test_case "terminal tool owns the public reply" `Quick
            test_terminal_tool_owns_public_reply;
          test_case "wordless control turn delivery" `Quick
            test_wordless_control_turn_delivery;
          test_case "media-only queued reply uses delivery path" `Quick
            test_media_only_queued_reply_uses_delivery_path;
          test_case "media continuation uses assistant delivery path" `Quick
            test_media_continuation_uses_assistant_delivery_path;
          test_case "continuation status uses assistant delivery path" `Quick
            test_continuation_status_uses_assistant_delivery_path;
          test_case "visible caption and media form a complete durable body" `Quick
            test_visible_caption_and_media_persist_as_complete_body;
          test_case "continuation status persists as a chat block" `Quick
            test_continuation_status_becomes_persisted_chat_block;
        ] );
      ( "direct_reply",
        [
          test_case "direct_reply_visible_text" `Quick
            test_direct_reply_visible_text;
          test_case "connector projection keeps external wait typed" `Quick
            test_connector_projection_keeps_external_wait_typed;
          test_case "connector projection keeps continuation typed" `Quick
            test_connector_projection_keeps_continuation_typed;
          test_case "connector projection suppresses completed effect" `Quick
            test_connector_projection_suppresses_completed_external_effect;
          test_case "direct reply keeps external wait typed" `Quick
            test_direct_reply_projection_keeps_external_wait_typed;
        ] );
      ( "reply chunks",
        [
          test_case "joined chunks equal the reply" `Quick
            test_reply_chunks_join_back_to_the_reply;
        ] );
    ]
