(* Unit tests for the turn-local tool-call accumulator. The persist site reads
   this to fill [append_turn_result ~tool_calls]; before it existed the argument
   was never passed, so history rows carried no tool rows and a reload lost the
   tool timeline the live stream had shown. *)

open Alcotest

module A = Keeper_stream_tool_accum
module S = Agent_core.Llm_provider.Complete_stream_acc

let record_execution_id ?(turn = 0) ?(planned_index = 0) t ~tool_call_id
    ~execution_id =
  A.record_execution_id t ~tool_call_id ~turn ~planned_index ~execution_id
  |> Result.map ignore
;;

let seal_turn ?(turn = 0) ?source_tool_use_count t source_tool_use_ordinals =
  let admitted_tool_sources =
    List.mapi
      (fun planned_index source_tool_use_ordinal ->
         { Agent_core.Hooks.planned_index; source_tool_use_ordinal })
      source_tool_use_ordinals
  in
  let source_tool_use_count =
    Option.value ~default:(List.length source_tool_use_ordinals)
      source_tool_use_count
  in
  let tool_source_map : Agent_core.Hooks.admitted_tool_source_map =
    { admitted_tool_sources; source_tool_use_count }
  in
  match A.seal_turn t ~turn ~tool_source_map with
  | Ok () -> ()
  | Error detail -> fail detail
;;

let tool_call = testable
  (fun fmt (c : Masc.Keeper_chat_store.tool_call) ->
     Format.fprintf fmt "{id=%s; execution=%s; name=%s; args=%s}" c.call_id
       (Option.fold ~none:"-" ~some:Ids.Execution_id.to_string c.execution_id)
       c.call_name c.args)
  (fun (a : Masc.Keeper_chat_store.tool_call) b ->
     String.equal a.call_id b.call_id
     && Option.equal Ids.Execution_id.equal a.execution_id b.execution_id
     && String.equal a.call_name b.call_name
     && String.equal a.args b.args)

let start ~index ~tool_id ~tool_name =
  Agent_core.Types.ContentBlockStart
    { index; content_type = "tool_use"; tool_id; tool_name }

let json_delta ~index fragment =
  Agent_core.Types.ContentBlockDelta
    { index; delta = Agent_core.Types.InputJsonDelta fragment }

let json_snapshot ~index snapshot =
  Agent_core.Types.ContentBlockDelta
    { index; delta = Agent_core.Types.InputJsonSnapshot snapshot }

let stop ~index = Agent_core.Types.ContentBlockStop { index }

let message_start id =
  Agent_core.Types.MessageStart { id; model = "test-model"; usage = None }
;;

let message_stop_reason =
  Agent_core.Types.MessageDelta
    { stop_reason = Some Agent_core.Types.StopToolUse; usage = None }
;;

(* Unlike [start], this does not hardcode content_type = "tool_use" — it
   represents a genuinely non-tool content block (e.g. text/thinking), which
   carries no tool identity because it is not a tool block at all. *)
let non_tool_start ~index ~content_type =
  Agent_core.Types.ContentBlockStart
    { index; content_type; tool_id = None; tool_name = None }

let media_delta ~index data =
  Agent_core.Types.ContentBlockDelta
    { index
    ; delta =
        Agent_core.Types.MediaDelta
          { media_type = "image/png"; source_type = Agent_core.Types.Base64; data }
    }

let test_fragments_concatenate_in_order () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-1") ~tool_name:(Some "WebSearch"));
  A.on_event t (json_delta ~index:0 "{\"query\":");
  A.on_event t (json_delta ~index:0 "\"masc\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "one call with joined args"
    [ { call_id = "call-1"; execution_id = None; call_name = "WebSearch"; args = "{\"query\":\"masc\"}" } ]
    (A.to_tool_calls t)

(* The provider sends a snapshot as the whole argument object, so appending it
   to the fragments already seen would duplicate them. *)
let test_snapshot_replaces_fragments () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-2") ~tool_name:(Some "WebFetch"));
  A.on_event t (json_delta ~index:0 "{\"url\":\"partial");
  A.on_event t (json_snapshot ~index:0 "{\"url\":\"https://example.com\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "snapshot wins"
    [ { call_id = "call-2"; execution_id = None; call_name = "WebFetch"; args = "{\"url\":\"https://example.com\"}" } ]
    (A.to_tool_calls t)

let test_parallel_blocks_keep_provider_order () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-a") ~tool_name:(Some "WebSearch"));
  A.on_event t (start ~index:1 ~tool_id:(Some "call-b") ~tool_name:(Some "WebFetch"));
  A.on_event t (json_delta ~index:1 "{\"b\":1}");
  A.on_event t (json_delta ~index:0 "{\"a\":1}");
  (* Finalize out of order: the result still reads in the order the provider
     opened the blocks, which is the order the transcript renders. *)
  A.on_event t (stop ~index:1);
  A.on_event t (stop ~index:0);
  check (list string) "provider order"
    [ "call-a"; "call-b" ]
    (List.map (fun (c : Masc.Keeper_chat_store.tool_call) -> c.call_id) (A.to_tool_calls t))

let test_log_commit_attaches_canonical_execution_identity () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "provider-call") ~tool_name:(Some "Edit"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  seal_turn t [ 0 ];
  let execution_id = Ids.Execution_id.of_string "exec-canonical" in
  (match record_execution_id t ~tool_call_id:"provider-call" ~execution_id with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list tool_call) "provider and canonical identities remain separate"
    [ { call_id = "provider-call"
      ; execution_id = Some execution_id
      ; call_name = "Edit"
      ; args = "{\"path\":\"a.ml\"}"
      }
    ]
    (A.to_tool_calls t)
;;

let test_unknown_result_identity_is_not_attached_by_position () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "provider-call") ~tool_name:(Some "Edit"));
  A.on_event t (stop ~index:0);
  seal_turn t [ 0 ];
  match
    record_execution_id t ~tool_call_id:"another-call"
      ~execution_id:(Ids.Execution_id.of_string "exec-wrong")
  with
  | Error _ -> ()
  | Ok () -> fail "an unknown provider id was attached by position"
;;

let test_parallel_duplicate_ids_join_by_planned_occurrence () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-duplicate") ~tool_name:(Some "Read"));
  A.on_event t
    (start ~index:1 ~tool_id:(Some "call-duplicate") ~tool_name:(Some "Write"));
  A.on_event t (stop ~index:1);
  A.on_event t (stop ~index:0);
  seal_turn t [ 0; 1 ];
  (* The second call may finish first. Planned occurrence, not provider id,
     selects its exact row. *)
  (match
     record_execution_id ~planned_index:1 t ~tool_call_id:"call-duplicate"
       ~execution_id:(Ids.Execution_id.of_string "exec-second")
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  let first_execution = Ids.Execution_id.of_string "exec-first" in
  (match
     record_execution_id ~planned_index:0 t ~tool_call_id:"call-duplicate"
       ~execution_id:first_execution
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list tool_call) "duplicate provider ids retain exact executions"
    [ { call_id = "call-duplicate"
      ; execution_id = Some first_execution
      ; call_name = "Read"
      ; args = ""
      }
    ; { call_id = "call-duplicate"
      ; execution_id = Some (Ids.Execution_id.of_string "exec-second")
      ; call_name = "Write"
      ; args = ""
      }
    ]
    (A.to_tool_calls t)
;;

let test_later_duplicate_keeps_an_attached_identity () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-reused") ~tool_name:(Some "Read"));
  A.on_event t
    (start ~index:1 ~tool_id:(Some "call-reused") ~tool_name:(Some "Write"));
  A.on_event t (stop ~index:1);
  A.on_event t (stop ~index:0);
  seal_turn t [ 0; 1 ];
  let execution_id = Ids.Execution_id.of_string "exec-first" in
  (match record_execution_id t ~tool_call_id:"call-reused" ~execution_id with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list tool_call) "later reuse cannot revoke the committed join"
    [ { call_id = "call-reused"
      ; execution_id = Some execution_id
      ; call_name = "Read"
      ; args = ""
      }
    ; { call_id = "call-reused"
      ; execution_id = None
      ; call_name = "Write"
      ; args = ""
      }
    ]
    (A.to_tool_calls t)
;;

let test_execution_identity_cannot_be_overwritten () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-once") ~tool_name:(Some "Read"));
  A.on_event t (stop ~index:0);
  seal_turn t [ 0 ];
  let first = Ids.Execution_id.of_string "exec-first" in
  let second = Ids.Execution_id.of_string "exec-second" in
  (match record_execution_id t ~tool_call_id:"call-once" ~execution_id:first with
   | Ok () -> ()
   | Error detail -> fail detail);
  match record_execution_id t ~tool_call_id:"call-once" ~execution_id:second with
  | Error _ -> ()
  | Ok () -> fail "a second result overwrote the canonical execution identity"
;;

let test_provider_id_reuse_in_later_turn_keeps_both_executions () =
  let t = A.create () in
  let first = Ids.Execution_id.of_string "exec-turn-0" in
  let second = Ids.Execution_id.of_string "exec-turn-1" in
  A.on_event t (message_start "message-0");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "reused-provider-id") ~tool_name:(Some "Read"));
  A.on_event t (stop ~index:0);
  A.on_event t message_stop_reason;
  A.on_event t Agent_core.Types.MessageStop;
  seal_turn ~turn:0 t [ 0 ];
  (match
     record_execution_id ~turn:0 ~planned_index:0 t
       ~tool_call_id:"reused-provider-id" ~execution_id:first
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  A.on_event t (message_start "message-1");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "reused-provider-id") ~tool_name:(Some "Write"));
  A.on_event t (stop ~index:0);
  A.on_event t message_stop_reason;
  A.on_event t Agent_core.Types.MessageStop;
  seal_turn ~turn:1 t [ 0 ];
  (match
     record_execution_id ~turn:1 ~planned_index:0 t
       ~tool_call_id:"reused-provider-id" ~execution_id:second
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list tool_call) "provider identity is scoped by streamed turn"
    [ { call_id = "reused-provider-id"
      ; execution_id = Some first
      ; call_name = "Read"
      ; args = ""
      }
    ; { call_id = "reused-provider-id"
      ; execution_id = Some second
      ; call_name = "Write"
      ; args = ""
      }
    ]
    (A.to_tool_calls t)
;;

let test_providerless_call_is_not_execution_authority () =
  let t = A.create () in
  A.on_event t (message_start "message-providerless");
  A.on_event t
    (start ~index:0 ~tool_id:None ~tool_name:(Some "Read"));
  A.on_event t (stop ~index:0);
  (match
     A.seal_turn t ~turn:0
       ~tool_source_map:
         { admitted_tool_sources =
             [ { Agent_core.Hooks.planned_index = 0
               ; source_tool_use_ordinal = 0
               }
             ]
         ; source_tool_use_count = 1
         }
   with
   | Error _ -> ()
   | Ok () -> fail "providerless streamed ToolUse became execution authority");
  check (list tool_call) "providerless call is omitted" [] (A.to_tool_calls t)
;;

let test_blank_provider_message_ids_open_distinct_scopes () =
  let t = A.create () in
  let emit ~turn ~name ~execution =
    let tool_call_id = "call-" ^ execution in
    A.on_event t (message_start "");
    A.on_event t
      (start ~index:0 ~tool_id:(Some tool_call_id) ~tool_name:(Some name));
    A.on_event t (stop ~index:0);
    A.on_event t message_stop_reason;
    A.on_event t Agent_core.Types.MessageStop;
    seal_turn ~turn t [ 0 ];
    match
      record_execution_id ~turn t ~tool_call_id
        ~execution_id:(Ids.Execution_id.of_string execution)
    with
    | Ok () -> ()
    | Error detail -> fail detail
  in
  emit ~turn:0 ~name:"Read" ~execution:"exec-blank-message-0";
  emit ~turn:1 ~name:"Write" ~execution:"exec-blank-message-1";
  check (list string) "blank provider message ids do not collapse turns"
    [ "exec-blank-message-0"; "exec-blank-message-1" ]
    (A.to_tool_calls t
     |> List.filter_map (fun (call : Masc.Keeper_chat_store.tool_call) ->
       Option.map Ids.Execution_id.to_string call.execution_id))
;;

let test_invalid_tool_start_poisons_the_provider_scope () =
  let t = A.create () in
  A.on_event t (message_start "message-invalid-first");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "invalid") ~tool_name:None);
  A.on_event t (stop ~index:0);
  A.on_event t
    (start ~index:1 ~tool_id:(Some "valid") ~tool_name:(Some "Read"));
  A.on_event t (stop ~index:1);
  (match
     A.seal_turn t ~turn:0
       ~tool_source_map:
         { admitted_tool_sources =
             [ { Agent_core.Hooks.planned_index = 0
               ; source_tool_use_ordinal = 0
               }
             ]
         ; source_tool_use_count = 1
         }
   with
   | Error _ -> ()
   | Ok () -> fail "a later call escaped the invalid provider scope");
  check (list tool_call) "invalid scope persists no tool rows" [] (A.to_tool_calls t)
;;

let test_open_message_start_replay_keeps_scope_and_fragments () =
  let t = A.create () in
  A.on_event t (message_start "message-replay-open");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "provider-open") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t (message_start "message-replay-open");
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  seal_turn t [ 0 ];
  let execution_id = Ids.Execution_id.of_string "exec-open-replay" in
  (match
     record_execution_id t ~tool_call_id:"provider-open" ~execution_id
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list tool_call) "replayed prelude stays in the original scope"
    [ { call_id = "provider-open"
      ; execution_id = Some execution_id
      ; call_name = "Read"
      ; args = "{\"path\":\"a.ml\"}"
      }
    ]
    (A.to_tool_calls t)
;;

let test_full_message_replay_is_quarantined () =
  let t = A.create () in
  let emit_message () =
    A.on_event t (message_start "message-full-replay");
    A.on_event t
      (start ~index:0 ~tool_id:(Some "provider-full") ~tool_name:(Some "Read"));
    A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
    A.on_event t (stop ~index:0);
    A.on_event t message_stop_reason;
    A.on_event t Agent_core.Types.MessageStop
  in
  emit_message ();
  emit_message ();
  (match A.seal_turn t ~turn:0 ~tool_source_map:{ admitted_tool_sources = [];
                                                   source_tool_use_count = 1 } with
   | Error _ -> ()
   | Ok () -> fail "a block start after stop became execution authority");
  check (list tool_call) "closed occurrence replay is omitted" []
    (A.to_tool_calls t)
;;

let test_blank_message_id_replays_unsealed_scope () =
  let open_replay = A.create () in
  A.on_event open_replay (message_start "");
  A.on_event open_replay
    (start ~index:0 ~tool_id:(Some "blank-open") ~tool_name:(Some "Read"));
  A.on_event open_replay (json_delta ~index:0 "{\"path\":");
  A.on_event open_replay (message_start "");
  A.on_event open_replay (json_delta ~index:0 "\"a.ml\"}");
  A.on_event open_replay (stop ~index:0);
  seal_turn open_replay [ 0 ];
  check (list tool_call) "blank open replay retains its fragments"
    [ { call_id = "blank-open"
      ; execution_id = None
      ; call_name = "Read"
      ; args = "{\"path\":\"a.ml\"}"
      }
    ]
    (A.to_tool_calls open_replay);
  let full_replay = A.create () in
  let emit () =
    A.on_event full_replay (message_start "");
    A.on_event full_replay
      (start ~index:0 ~tool_id:(Some "blank-full") ~tool_name:(Some "Read"));
    A.on_event full_replay (json_delta ~index:0 "{}");
    A.on_event full_replay (stop ~index:0);
    A.on_event full_replay message_stop_reason;
    A.on_event full_replay Agent_core.Types.MessageStop
  in
  emit ();
  emit ();
  (match
     A.seal_turn full_replay ~turn:0
       ~tool_source_map:{ admitted_tool_sources = []; source_tool_use_count = 1 }
   with
   | Error _ -> ()
   | Ok () -> fail "blank full replay became execution authority");
  check int "blank full replay is quarantined" 0
    (List.length (A.to_tool_calls full_replay))
;;

let test_blank_message_id_does_not_cross_runtime_attempts () =
  let t = A.create () in
  A.start_runtime_attempt t;
  A.on_event t (message_start "");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "blank-attempt") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"stale");
  A.start_runtime_attempt t;
  A.on_event t (message_start "");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "blank-attempt") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"fresh.ml\"}");
  A.on_event t (stop ~index:0);
  seal_turn t [ 0 ];
  let execution_id = Ids.Execution_id.of_string "exec-fresh-attempt" in
  (match
     record_execution_id t ~tool_call_id:"blank-attempt" ~execution_id
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list tool_call) "failed-attempt fragments are not reused"
    [ { call_id = "blank-attempt"
      ; execution_id = Some execution_id
      ; call_name = "Read"
      ; args = "{\"path\":\"fresh.ml\"}"
      }
    ]
    (A.to_tool_calls t)
;;

let test_runtime_attempt_restarts_agent_core_turn_coordinates () =
  let t = A.create () in
  A.start_runtime_attempt t;
  A.on_event t
    (start ~index:0 ~tool_id:(Some "attempt-first") ~tool_name:(Some "Read"));
  A.on_event t (stop ~index:0);
  seal_turn ~turn:0 t [ 0 ];
  A.start_runtime_attempt t;
  A.on_event t
    (start ~index:0 ~tool_id:(Some "attempt-second") ~tool_name:(Some "Write"));
  A.on_event t (stop ~index:0);
  seal_turn ~turn:0 t [ 0 ];
  let execution_id = Ids.Execution_id.of_string "exec-second-attempt" in
  (match
     record_execution_id ~turn:0 t ~tool_call_id:"attempt-second" ~execution_id
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list (option string)) "only the active attempt owns the turn coordinate"
    [ None; Some "exec-second-attempt" ]
    (A.to_tool_calls t
     |> List.map (fun (call : Masc.Keeper_chat_store.tool_call) ->
       Option.map Ids.Execution_id.to_string call.execution_id))
;;

let test_committed_message_replay_is_quarantined () =
  let t = A.create () in
  let emit_message () =
    A.on_event t (message_start "message-committed-replay");
    A.on_event t
      (start ~index:0 ~tool_id:(Some "provider-committed") ~tool_name:(Some "Read"));
    A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
    A.on_event t (stop ~index:0);
    A.on_event t message_stop_reason;
    A.on_event t Agent_core.Types.MessageStop
  in
  emit_message ();
  emit_message ();
  (match
     A.seal_turn t ~turn:0
       ~tool_source_map:{ admitted_tool_sources = []; source_tool_use_count = 1 }
   with
   | Error _ -> ()
   | Ok () -> fail "committed replay became execution authority");
  check (list tool_call) "committed replay is quarantined" [] (A.to_tool_calls t)
;;

let test_producer_occurrence_cannot_settle_twice () =
  let t = A.create () in
  A.on_event t (message_start "message-0");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "provider-a") ~tool_name:(Some "Read"));
  A.on_event t
    (start ~index:1 ~tool_id:(Some "provider-b") ~tool_name:(Some "Write"));
  A.on_event t (stop ~index:0);
  A.on_event t (stop ~index:1);
  seal_turn ~turn:0 t [ 0; 1 ];
  (match
     record_execution_id ~turn:0 ~planned_index:0 t
       ~tool_call_id:"provider-a"
       ~execution_id:(Ids.Execution_id.of_string "exec-a")
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  match
    record_execution_id ~turn:0 ~planned_index:0 t
      ~tool_call_id:"provider-b"
      ~execution_id:(Ids.Execution_id.of_string "exec-b")
  with
  | Error _ -> ()
  | Ok () -> fail "one Agent Core occurrence settled two provider calls"
;;

let test_admission_source_ordinal_survives_unknown_middle_call () =
  let t = A.create () in
  A.on_event t
    (start ~index:1 ~tool_id:(Some "provider-read") ~tool_name:(Some "Read"));
  A.on_event t
    (start ~index:4 ~tool_id:(Some "provider-unknown") ~tool_name:(Some "Unknown"));
  A.on_event t
    (start ~index:7 ~tool_id:(Some "provider-write") ~tool_name:(Some "Write"));
  List.iter (fun index -> A.on_event t (stop ~index)) [ 1; 4; 7 ];
  (* Agent Core admitted Read and Write, so planned 1 retains pre-admission
     ToolUse ordinal 2 even though the middle call never executes. *)
  seal_turn ~source_tool_use_count:3 t [ 0; 2 ];
  let execution_id = Ids.Execution_id.of_string "exec-write" in
  (match
     record_execution_id ~planned_index:1 t ~tool_call_id:"provider-write"
       ~execution_id
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  check
    (list (option string))
    "only the exact surviving occurrence receives the canonical id"
    [ None; None; Some "exec-write" ]
    (A.to_tool_calls t
     |> List.map (fun (call : Masc.Keeper_chat_store.tool_call) ->
       Option.map Ids.Execution_id.to_string call.execution_id))
;;

let test_official_turn_without_sources_stays_delivery_only () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "official-call") ~tool_name:(Some "Read"));
  A.on_event t (stop ~index:0);
  (match A.close_turn_without_sources t ~turn:0 with
   | Ok () -> ()
   | Error detail -> fail detail);
  (match
     record_execution_id t ~tool_call_id:"official-call"
       ~execution_id:(Ids.Execution_id.of_string "exec-unavailable")
   with
   | Error _ -> ()
   | Ok () -> fail "an unavailable official-client source mapping was guessed");
  check
    (list (option string))
    "delivery evidence remains visible without a canonical join"
    [ None ]
    (A.to_tool_calls t
     |> List.map (fun (call : Masc.Keeper_chat_store.tool_call) ->
       Option.map Ids.Execution_id.to_string call.execution_id))
;;

let test_official_close_still_validates_stream_integrity () =
  let unfinalized = A.create () in
  A.on_event unfinalized
    (start ~index:0 ~tool_id:(Some "open") ~tool_name:(Some "Read"));
  (match A.close_turn_without_sources unfinalized ~turn:0 with
   | Error _ -> ()
   | Ok () -> fail "official close accepted an unfinalized streamed tool");
  let quarantined = A.create () in
  let emit args =
    A.on_event quarantined
      (start ~index:0 ~tool_id:(Some "replay") ~tool_name:(Some "Read"));
    A.on_event quarantined (json_delta ~index:0 args);
    A.on_event quarantined (stop ~index:0)
  in
  emit "{\"path\":\"a.ml\"}";
  emit "{\"path\":\"b.ml\"}";
  (match A.close_turn_without_sources quarantined ~turn:0 with
   | Error _ -> ()
   | Ok () -> fail "official close accepted a quarantined occurrence")
;;

let test_pre_admission_tool_inventory_is_exact () =
  let source_map ~count admitted_tool_sources :
      Agent_core.Hooks.admitted_tool_source_map =
    { admitted_tool_sources; source_tool_use_count = count }
  in
  let missing = A.create () in
  (match A.seal_turn missing ~turn:0 ~tool_source_map:(source_map ~count:1 []) with
   | Error _ -> ()
   | Ok () -> fail "a missing streamed ToolUse satisfied the typed inventory");
  let extra = A.create () in
  A.on_event extra
    (start ~index:0 ~tool_id:(Some "extra") ~tool_name:(Some "Read"));
  A.on_event extra (stop ~index:0);
  (match A.seal_turn extra ~turn:0 ~tool_source_map:(source_map ~count:0 []) with
   | Error _ -> ()
   | Ok () -> fail "an extra streamed ToolUse satisfied an empty inventory");
  let all_rejected = A.create () in
  A.on_event all_rejected
    (start ~index:0 ~tool_id:(Some "rejected") ~tool_name:(Some "Unknown"));
  A.on_event all_rejected (stop ~index:0);
  (match
     A.seal_turn all_rejected ~turn:0
       ~tool_source_map:(source_map ~count:1 [])
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  check int "all-rejected delivery evidence remains exact" 1
    (List.length (A.to_tool_calls all_rejected))
;;

let test_closed_tool_start_is_quarantined () =
  let t = A.create () in
  let emit args =
    A.on_event t
      (start ~index:0 ~tool_id:(Some "replay-call") ~tool_name:(Some "Read"));
    A.on_event t (json_delta ~index:0 args);
    A.on_event t (stop ~index:0)
  in
  emit "{\"path\":\"a.ml\"}";
  emit "{\"path\":\"b.ml\"}";
  (match A.take_protocol_errors t with
   | [ kind, occurrence, detail ] ->
     check string "typed quarantine kind" "tool_start_duplicate_index"
       (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
     check int "quarantine scope" 0 occurrence.stream_scope;
     check int "quarantine block" 0 occurrence.block_index;
     check (option string) "provider correlation is not invented" None
       occurrence.provider_message_id;
     check string "exact closed-start diagnostic"
       "tool block start arrived after stop at stream_scope=0 block_index=0"
       detail
   | errors -> failf "expected one typed protocol error, got %d" (List.length errors));
  check (list tool_call) "drifted replay is not persisted" [] (A.to_tool_calls t)
;;

let test_canonical_execution_cannot_own_two_stream_occurrences () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-a") ~tool_name:(Some "Read"));
  A.on_event t
    (start ~index:1 ~tool_id:(Some "call-b") ~tool_name:(Some "Write"));
  A.on_event t (stop ~index:0);
  A.on_event t (stop ~index:1);
  seal_turn t [ 0; 1 ];
  let execution_id = Ids.Execution_id.of_string "exec-shared" in
  (match record_execution_id t ~tool_call_id:"call-a" ~execution_id with
   | Ok () -> ()
   | Error detail -> fail detail);
  match
    record_execution_id ~planned_index:1 t ~tool_call_id:"call-b" ~execution_id
  with
  | Error _ -> ()
  | Ok () -> fail "one canonical execution owned two streamed occurrences"
;;

let test_seal_rejects_unfinalized_tool_block () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "open-call") ~tool_name:(Some "Read"));
  let tool_source_map : Agent_core.Hooks.admitted_tool_source_map =
    { admitted_tool_sources =
        [ { Agent_core.Hooks.planned_index = 0; source_tool_use_ordinal = 0 } ]
    ; source_tool_use_count = 1
    }
  in
  match A.seal_turn t ~turn:0 ~tool_source_map with
  | Error _ -> ()
  | Ok () -> fail "an open stream block became execution authority"
;;

let test_failure_drops_finalized_unsealed_scope () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "unsealed-call") ~tool_name:(Some "Read"));
  A.on_event t (json_snapshot ~index:0 {|{"path":"partial.ml"}|});
  A.on_event t (stop ~index:0);
  check int "visible before failure" 1 (List.length (A.to_tool_calls t));
  check (list tool_call) "unsealed failure row is quarantined" []
    (A.to_tool_calls_for_failure t)
;;

let test_failure_preserves_sealed_scope () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "sealed-call") ~tool_name:(Some "Read"));
  A.on_event t (json_snapshot ~index:0 {|{"path":"committed.ml"}|});
  A.on_event t (stop ~index:0);
  seal_turn t [ 0 ];
  check (list tool_call) "sealed execution evidence survives outer failure"
    [ { call_id = "sealed-call"
      ; execution_id = None
      ; call_name = "Read"
      ; args = {|{"path":"committed.ml"}|}
      }
    ]
    (A.to_tool_calls_for_failure t)
;;

let test_failure_snapshot_keeps_only_prior_sealed_scopes () =
  let t = A.create () in
  A.start_runtime_attempt t;
  A.on_event t
    (start ~index:0 ~tool_id:(Some "prior-call") ~tool_name:(Some "Read"));
  A.on_event t (json_snapshot ~index:0 {|{"path":"prior.ml"}|});
  A.on_event t (stop ~index:0);
  seal_turn t [ 0 ];
  A.start_runtime_attempt t;
  A.on_event t
    (start ~index:0 ~tool_id:(Some "failed-call") ~tool_name:(Some "Write"));
  A.on_event t (json_snapshot ~index:0 {|{"path":"failed.ml"}|});
  A.on_event t (stop ~index:0);
  check (list string) "only prior sealed evidence is persisted"
    [ "prior-call" ]
    (A.to_tool_calls_for_failure t
     |> List.map (fun (call : Masc.Keeper_chat_store.tool_call) -> call.call_id))
;;

let test_fallback_quarantines_prior_unsealed_finalized_scope () =
  let t = A.create () in
  A.start_runtime_attempt t;
  A.on_event t
    (start ~index:0 ~tool_id:(Some "abandoned-call") ~tool_name:(Some "Read"));
  A.on_event t (json_snapshot ~index:0 {|{"path":"abandoned.ml"}|});
  A.on_event t (stop ~index:0);
  A.start_runtime_attempt t;
  A.on_event t
    (start ~index:0 ~tool_id:(Some "fallback-call") ~tool_name:(Some "Write"));
  A.on_event t (json_snapshot ~index:0 {|{"path":"fallback.ml"}|});
  A.on_event t (stop ~index:0);
  check (list tool_call) "neither unsealed candidate survives final failure" []
    (A.to_tool_calls_for_failure t)
;;

let test_failure_preserves_official_closed_scope () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "official-call") ~tool_name:(Some "Read"));
  A.on_event t (json_snapshot ~index:0 {|{"path":"official.ml"}|});
  A.on_event t (stop ~index:0);
  (match A.close_turn_without_sources t ~turn:0 with
   | Ok () -> ()
   | Error detail -> fail detail);
  check (list string) "official closed evidence survives outer failure"
    [ "official-call" ]
    (A.to_tool_calls_for_failure t
     |> List.map (fun (call : Masc.Keeper_chat_store.tool_call) -> call.call_id))
;;

let test_duplicate_start_before_payload_is_idempotent () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-replayed") ~tool_name:(Some "Read"));
  A.on_event t (start ~index:0 ~tool_id:(Some "call-replayed") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "empty duplicate start is idempotent"
    [ { call_id = "call-replayed"; execution_id = None; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let test_duplicate_start_after_payload_is_quarantined () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-ambiguous") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-ambiguous") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  (match A.take_protocol_errors t with
   | [ kind, occurrence, _ ] ->
     check string "typed ambiguous-start kind" "tool_start_duplicate_index"
       (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
     check int "ambiguous start scope" 0 occurrence.stream_scope;
     check int "ambiguous start block" 0 occurrence.block_index
   | errors -> failf "expected one typed protocol error, got %d" (List.length errors));
  check (list tool_call) "ambiguous repeated start is omitted" [] (A.to_tool_calls t)
;;

let test_replayed_completed_block_is_quarantined () =
  let t = A.create () in
  A.on_event t (start ~index:1 ~tool_id:(Some "call-complete") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:1 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:1);
  (* A same-attempt start after stop has no authoritative replay epoch. *)
  A.on_event t (start ~index:1 ~tool_id:(Some "call-complete") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:1 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:1);
  check (list tool_call) "completed replay is quarantined" [] (A.to_tool_calls t)

let test_parallel_blocks_with_same_call_id_stay_delivery_only () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-duplicate") ~tool_name:(Some "Read"));
  A.on_event t (start ~index:1 ~tool_id:(Some "call-duplicate") ~tool_name:(Some "Write"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (json_delta ~index:1 "{\"path\":\"b.ml\"}");
  A.on_event t (stop ~index:1);
  A.on_event t (stop ~index:0);
  check (list tool_call) "both ambiguous occurrences remain visible"
    [ { call_id = "call-duplicate"; execution_id = None; call_name = "Read"; args = "{\"path\":\"a.ml\"}" }
    ; { call_id = "call-duplicate"; execution_id = None; call_name = "Write"; args = "{\"path\":\"b.ml\"}" }
    ]
    (A.to_tool_calls t)

let test_tool_call_id_is_preserved_before_persistence () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some " call-trimmed ")
       ~tool_name:(Some " Read "));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "persisted id remains the opaque provider identity"
    [ { call_id = " call-trimmed "; execution_id = None; call_name = "Read"; args = "{\"path\":\"a.ml\"}" } ]
    (A.to_tool_calls t)

let test_replay_identity_is_compared_before_trimming () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-raw") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t
    (start ~index:0 ~tool_id:(Some " call-raw ") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "whitespace identity drift conflicts like live bridge"
    [] (A.to_tool_calls t)

let test_conflicting_start_cannot_reopen_until_stop () =
  let t = A.create () in
  A.start_runtime_attempt t;
  A.on_event t (start ~index:0 ~tool_id:(Some "call-a") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}" );
  (* A conflicting identity invalidates this provider block. A later start at
     the same index must not turn the original fragments into a new call. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-b") ~tool_name:(Some "Write"));
  A.on_event t (start ~index:0 ~tool_id:(Some "call-c") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"c.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "conflicted block is dropped" [] (A.to_tool_calls t);
  (* Stop closes the malformed block but does not make its protocol index
     reusable inside the same response. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-d") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"d.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "later block after stop remains dropped" []
    (A.to_tool_calls t);
  A.start_runtime_attempt t;
  A.on_event t (start ~index:0 ~tool_id:(Some "call-e") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"e.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "new attempt may reuse the index"
    [ { call_id = "call-e"; execution_id = None; call_name = "Read"; args = "{\"path\":\"e.ml\"}" } ]
    (A.to_tool_calls t)

(* A tool name is required to render the occurrence. Provider call id is not:
   planned occurrence carries the canonical join. *)
let test_block_without_tool_name_is_dropped () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call") ~tool_name:None);
  A.on_event t (json_delta ~index:0 "{}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "identityless block dropped" [] (A.to_tool_calls t)

(* MessageStop without a preceding stop reason is terminal-incomplete in the
   canonical producer. It may close local buffers, but cannot become durable
   tool authority. *)
let test_message_stop_without_reason_is_not_tool_authority () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-3") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t Agent_core.Types.MessageStop;
  check (list tool_call) "incomplete terminal omits the tool" [] (A.to_tool_calls t)

let test_non_tool_events_are_ignored () =
  let t = A.create () in
  A.on_event t (non_tool_start ~index:0 ~content_type:"text");
  A.on_event t (json_delta ~index:0 "{\"ignored\":true}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "no calls" [] (A.to_tool_calls t)

let test_identity_free_non_tool_start_quarantines_active_tool () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-active") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t (non_tool_start ~index:0 ~content_type:"text");
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "different non-tool header voids the active call" []
    (A.to_tool_calls t)

(* content_type = "tool_use" with no id/name is the malformed-tool-typed case
   the bridge tombstones (Tool_start_missing_identity). Like every non-identical
   header at an occupied index, it also quarantines an active tool. *)
let test_malformed_tool_use_start_invalidates_active_tool () =
  let t = A.create () in
  A.on_event t
    (start ~index:0 ~tool_id:(Some "call-active") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (start ~index:0 ~tool_id:None ~tool_name:None);
  A.on_event t (stop ~index:0);
  check (list tool_call) "malformed tool-use start drops the active call" []
    (A.to_tool_calls t)

(* Fresh evidence beyond the malformed-start review: a valid tool start
   arrives at the same index a malformed tool-use start already tombstoned,
   before that block's own terminator. The bridge keeps the index
   Invalid_tool_block until its stop and never emits Tool_call_start for the
   later valid start; the collector must not open a fresh block either. *)
let test_valid_start_after_malformed_tool_use_on_same_index_is_dropped () =
  let t = A.create () in
  A.start_runtime_attempt t;
  A.on_event t (start ~index:0 ~tool_id:None ~tool_name:None);
  A.on_event t (start ~index:0 ~tool_id:(Some "call-e") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"e.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "valid start after malformed tool-use start is dropped" []
    (A.to_tool_calls t);
  (* Stop closes the malformed producer block but cannot reuse its index. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-f") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"f.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "index remains closed after malformed block's stop" []
    (A.to_tool_calls t);
  A.start_runtime_attempt t;
  A.on_event t (start ~index:0 ~tool_id:(Some "call-g") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"g.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "new attempt resets malformed occupancy"
    [ { call_id = "call-g"; execution_id = None; call_name = "Read"; args = "{\"path\":\"g.ml\"}" } ]
    (A.to_tool_calls t)

let test_invalid_tool_starts_are_ignored () =
  let t = A.create () in
  (* Blank tool_id or tool_name *)
  A.on_event t (start ~index:0 ~tool_id:(Some "   ") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  (* Non-tool content type carrying identity *)
  A.on_event t (Agent_core.Types.ContentBlockStart
    { index = 1; content_type = "text"; tool_id = Some "call-x"; tool_name = Some "Read" });
  A.on_event t (json_delta ~index:1 "{\"path\":\"b.ml\"}");
  A.on_event t
    (start ~index:1 ~tool_id:(Some "call-y") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:1 "{\"path\":\"y.ml\"}");
  A.on_event t (stop ~index:1);
  check (list tool_call) "invalid starts ignored" [] (A.to_tool_calls t)

(* Canonical streams announce media first. The accumulator still reserves a
   bare MediaDelta index as a defense for direct callers, so malformed input
   cannot create a reload-only tool row. *)
let test_tool_start_on_media_occupied_index_is_dropped () =
  let t = A.create () in
  A.start_runtime_attempt t;
  A.on_event t (media_delta ~index:0 "iVBORw0KGgo=");
  A.on_event t (start ~index:0 ~tool_id:(Some "call-m") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"a.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "tool start on media index dropped" [] (A.to_tool_calls t);
  (* The stop closes the media block but the protocol index remains occupied. *)
  A.on_event t (start ~index:0 ~tool_id:(Some "call-n") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"b.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "index remains closed after media stop" []
    (A.to_tool_calls t);
  A.start_runtime_attempt t;
  A.on_event t (start ~index:0 ~tool_id:(Some "call-o") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":\"c.ml\"}");
  A.on_event t (stop ~index:0);
  check (list tool_call) "new attempt may reuse media index"
    [ { call_id = "call-o"; execution_id = None; call_name = "Read"; args = "{\"path\":\"c.ml\"}" } ]
    (A.to_tool_calls t)

let test_media_delta_on_active_tool_block_quarantines_the_call () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-t") ~tool_name:(Some "Read"));
  A.on_event t (json_delta ~index:0 "{\"path\":");
  A.on_event t (media_delta ~index:0 "iVBORw0KGgo=");
  A.on_event t (json_delta ~index:0 "\"a.ml\"}");
  A.on_event t (stop ~index:0);
  (match A.take_protocol_errors t with
   | [ kind, occurrence, _ ] ->
     check string "typed media mismatch" "tool_delta_invalid_kind"
       (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
     check int "media mismatch scope" 0 occurrence.stream_scope;
     check int "media mismatch block" 0 occurrence.block_index
   | errors -> failf "expected one typed protocol error, got %d" (List.length errors));
  check (list tool_call) "tool block with stray media is omitted" []
    (A.to_tool_calls t)

let test_input_delta_after_stop_quarantines_the_call () =
  let t = A.create () in
  A.on_event t (start ~index:0 ~tool_id:(Some "call-late") ~tool_name:(Some "Read"));
  A.on_event t (json_snapshot ~index:0 "{\"path\":\"before.ml\"}");
  A.on_event t (stop ~index:0);
  A.on_event t (json_snapshot ~index:0 "{\"path\":\"after.ml\"}");
  (match A.take_protocol_errors t with
   | [ kind, occurrence, _ ] ->
     check string "typed late args" "tool_args_without_start"
       (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
     check int "late args scope" 0 occurrence.stream_scope;
     check int "late args block" 0 occurrence.block_index
   | errors -> failf "expected one typed protocol error, got %d" (List.length errors));
  check (list tool_call) "late args quarantine the closed occurrence" []
    (A.to_tool_calls t)

let test_producer_and_keeper_reject_ambiguous_tool_inputs_together () =
  let fixtures =
    [ ( "start after payload"
      , [ start ~index:0 ~tool_id:(Some "cross-start") ~tool_name:(Some "Read")
        ; json_delta ~index:0 "{\"path\":"
        ; start ~index:0 ~tool_id:(Some "cross-start") ~tool_name:(Some "Read")
        ; json_delta ~index:0 "\"after.ml\"}"
        ; stop ~index:0
        ; Agent_core.Types.MessageDelta
            { stop_reason = Some Agent_core.Types.StopToolUse; usage = None }
        ] )
    ; ( "args after stop"
      , [ start ~index:0 ~tool_id:(Some "cross-stop") ~tool_name:(Some "Read")
        ; json_snapshot ~index:0 "{\"path\":\"before.ml\"}"
        ; stop ~index:0
        ; json_snapshot ~index:0 "{\"path\":\"after.ml\"}"
        ; Agent_core.Types.MessageDelta
            { stop_reason = Some Agent_core.Types.StopToolUse; usage = None }
        ] )
    ; ( "different message start"
      , [ message_start "message-a"
        ; start ~index:0 ~tool_id:(Some "cross-message") ~tool_name:(Some "Read")
        ; json_delta ~index:0 "{\"path\":"
        ; message_start "message-b"
        ] )
    ]
  in
  List.iter
    (fun (label, events) ->
       let producer = S.create_stream_acc () in
       let keeper = A.create () in
       List.iter
         (fun event ->
            S.accumulate_event producer event;
            A.on_event keeper event)
         events;
       (match S.finalize_stream_acc producer with
        | Error _ -> ()
        | Ok _ -> fail (label ^ ": producer accepted ambiguous tool input"));
       let tool_source_map : Agent_core.Hooks.admitted_tool_source_map =
         { admitted_tool_sources =
             [ { Agent_core.Hooks.planned_index = 0
               ; source_tool_use_ordinal = 0
               }
             ]
         ; source_tool_use_count = 1
         }
       in
       match A.seal_turn keeper ~turn:0 ~tool_source_map with
       | Error _ -> ()
       | Ok () -> fail (label ^ ": keeper accepted ambiguous tool input"))
    fixtures
;;

let () =
  run "Keeper_stream_tool_accum"
    [ ( "accumulation"
      , [ test_case "fragments concatenate in order" `Quick test_fragments_concatenate_in_order
        ; test_case "snapshot replaces fragments" `Quick test_snapshot_replaces_fragments
        ; test_case "parallel blocks keep provider order" `Quick test_parallel_blocks_keep_provider_order
        ; test_case "duplicate start before payload is idempotent" `Quick
            test_duplicate_start_before_payload_is_idempotent
        ; test_case "duplicate start after payload is quarantined" `Quick
            test_duplicate_start_after_payload_is_quarantined
        ; test_case "replayed completed block is quarantined" `Quick
            test_replayed_completed_block_is_quarantined
        ; test_case "parallel duplicate ids remain delivery-only" `Quick
            test_parallel_blocks_with_same_call_id_stay_delivery_only
        ; test_case "tool call id stays opaque before persistence" `Quick
            test_tool_call_id_is_preserved_before_persistence
        ; test_case "replay identity compares raw provider values" `Quick
            test_replay_identity_is_compared_before_trimming
        ; test_case "conflicting start stays closed until new attempt" `Quick
            test_conflicting_start_cannot_reopen_until_stop
        ; test_case "block without tool name is dropped" `Quick
            test_block_without_tool_name_is_dropped
        ; test_case "MessageStop without reason is not tool authority" `Quick
            test_message_stop_without_reason_is_not_tool_authority
        ; test_case "non-tool events are ignored" `Quick test_non_tool_events_are_ignored
        ; test_case "identity-free non-tool start quarantines active tool" `Quick
            test_identity_free_non_tool_start_quarantines_active_tool
        ; test_case "malformed tool-use start invalidates active tool" `Quick
            test_malformed_tool_use_start_invalidates_active_tool
        ; test_case "valid start stays dropped until malformed stop" `Quick
            test_valid_start_after_malformed_tool_use_on_same_index_is_dropped
        ; test_case "invalid tool starts are ignored" `Quick test_invalid_tool_starts_are_ignored
        ; test_case "tool start on media-occupied index is dropped" `Quick
            test_tool_start_on_media_occupied_index_is_dropped
        ; test_case "media delta on active tool block quarantines the call" `Quick
            test_media_delta_on_active_tool_block_quarantines_the_call
        ; test_case "input delta after stop quarantines the call" `Quick
            test_input_delta_after_stop_quarantines_the_call
        ; test_case "producer and keeper reject ambiguous inputs together" `Quick
            test_producer_and_keeper_reject_ambiguous_tool_inputs_together
        ] )
    ; ( "execution identity"
      , [ test_case "log commit attaches canonical id" `Quick
            test_log_commit_attaches_canonical_execution_identity
        ; test_case "unknown provider id is not positional" `Quick
            test_unknown_result_identity_is_not_attached_by_position
        ; test_case "parallel duplicate ids use planned occurrence" `Quick
            test_parallel_duplicate_ids_join_by_planned_occurrence
        ; test_case "later duplicate preserves an earlier join" `Quick
            test_later_duplicate_keeps_an_attached_identity
        ; test_case "canonical id cannot be overwritten" `Quick
            test_execution_identity_cannot_be_overwritten
        ; test_case "later turn may reuse provider id" `Quick
            test_provider_id_reuse_in_later_turn_keeps_both_executions
        ; test_case "providerless call is not execution authority" `Quick
            test_providerless_call_is_not_execution_authority
        ; test_case "blank provider message ids open new scopes" `Quick
            test_blank_provider_message_ids_open_distinct_scopes
        ; test_case "invalid tool start poisons provider scope" `Quick
            test_invalid_tool_start_poisons_the_provider_scope
        ; test_case "open MessageStart replay keeps scope" `Quick
            test_open_message_start_replay_keeps_scope_and_fragments
        ; test_case "full message replay is quarantined" `Quick
            test_full_message_replay_is_quarantined
        ; test_case "blank message id replays unsealed scope" `Quick
            test_blank_message_id_replays_unsealed_scope
        ; test_case "blank message id cannot cross runtime attempts" `Quick
            test_blank_message_id_does_not_cross_runtime_attempts
        ; test_case "runtime attempt restarts turn coordinates" `Quick
            test_runtime_attempt_restarts_agent_core_turn_coordinates
        ; test_case "committed MessageStart replay is quarantined" `Quick
            test_committed_message_replay_is_quarantined
        ; test_case "producer occurrence settles once" `Quick
            test_producer_occurrence_cannot_settle_twice
        ; test_case "unknown middle call keeps source ordinal" `Quick
            test_admission_source_ordinal_survives_unknown_middle_call
        ; test_case "pre-admission inventory is exact" `Quick
            test_pre_admission_tool_inventory_is_exact
        ; test_case "official turn without sources stays delivery-only" `Quick
            test_official_turn_without_sources_stays_delivery_only
        ; test_case "official close validates stream integrity" `Quick
            test_official_close_still_validates_stream_integrity
        ; test_case "canonical execution owns one stream occurrence" `Quick
            test_canonical_execution_cannot_own_two_stream_occurrences
        ; test_case "unfinalized tool block cannot seal" `Quick
            test_seal_rejects_unfinalized_tool_block
        ; test_case "failure drops finalized unsealed scope" `Quick
            test_failure_drops_finalized_unsealed_scope
        ; test_case "failure preserves sealed scope" `Quick
            test_failure_preserves_sealed_scope
        ; test_case "failure keeps only prior sealed scopes" `Quick
            test_failure_snapshot_keeps_only_prior_sealed_scopes
        ; test_case "fallback quarantines prior unsealed finalized scope" `Quick
            test_fallback_quarantines_prior_unsealed_finalized_scope
        ; test_case "failure preserves official closed scope" `Quick
            test_failure_preserves_official_closed_scope
        ] )
    ; ( "replay integrity"
      , [ test_case "closed tool start is quarantined" `Quick
            test_closed_tool_start_is_quarantined
        ] )
    ]
