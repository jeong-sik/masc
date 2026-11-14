(* The keeper loop's tool rows reach the chat store (#33127).

   A continuation turn that follows an approval replay runs its tools in the
   keeper loop, where no writer appended tool rows: the chat surface showed
   the approval's lifecycle rows and then nothing until the next utterance.
   These cases drive [Keeper_loop_tool_projection] with the same raw stream
   events and hook observations the run hands it, then read the chat store
   back. *)

open Alcotest
module P = Masc.Keeper_loop_tool_projection
module K = Masc.Keeper_chat_store
module H = Masc.Keeper_hooks_agent_core
module E = Masc.Keeper_chat_events
module D = Keeper_chat_delivery_identity
module R = Masc.Keeper_gate_replay

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

(* The directory exists before [f] runs: the blob store that holds the replay
   artifacts of the fixture never creates its ownership root. *)
let with_base_dir prefix f =
  let base_dir = Filename.temp_dir (prefix ^ "-") "" in
  Fun.protect
    ~finally:(fun () ->
      try remove_tree base_dir with
      | Sys_error _ | Unix.Unix_error _ -> ())
    (fun () -> f base_dir)
;;

let keeper_name = "loop-projection-fixture"

let start ~index ~tool_id ~tool_name =
  Agent_core.Types.ContentBlockStart
    { index; content_type = "tool_use"; tool_id = Some tool_id; tool_name = Some tool_name }
;;

let json_snapshot ~index snapshot =
  Agent_core.Types.ContentBlockDelta
    { index; delta = Agent_core.Types.InputJsonSnapshot snapshot }
;;

let stop ~index = Agent_core.Types.ContentBlockStop { index }

let turn_collected ordinals =
  let admitted_tool_sources =
    List.mapi
      (fun planned_index source_tool_use_ordinal ->
         { Agent_core.Hooks.planned_index; source_tool_use_ordinal; name_resolution = Agent_core.Hooks.Registered_name })
      ordinals
  in
  H.Turn_collected
    { turn = 0
    ; tool_source_map =
        { Agent_core.Hooks.admitted_tool_sources
        ; source_tool_use_count = List.length ordinals
        }
    }
;;

let attempt_started ~lane_attempt_index =
  H.Runtime_attempt_started
    { runtime_id = "fixture.runtime"
    ; lane_attempt_index
    ; checkpoint_owner = Runtime_execution.Masc_agent_core
    }
;;

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-fixture" ~absolute_turn:7

let unwrap = function Ok value -> value | Error detail -> fail detail

let prepared_model ?(suffix = "") ?(user_message = "Continue.") ~base_dir approval_ids =
  let inputs = List.map (fun approval_id ->
    let resolution : Keeper_event_queue.hitl_resolution =
      { approval_id; decision = Keeper_event_queue.Hitl_approved
      ; channel = Keeper_continuation_channel.unrouted "projection fixture" } in
    let output_ref = R.For_testing.persist_replay_artifact ~base_path:base_dir
      (approval_id ^ suffix) |> unwrap in
    let outcome = R.Applied
      { operation = "filesystem_write"; output_ref; journal = R.Replay_journal_recorded } in
    R.resolution_input ~resolution
      ~replay_delivery:(Some (approval_id, { R.outcome; terminal_effect_receipt = None }))
    |> Result.map_error R.resolution_input_error_to_string |> unwrap) approval_ids in
  R.compose_model_message ~base_path:base_dir ~user_message ~inputs
;;

let prepared ?(owner = turn_ref) ?(approvals = [ "approval-a"; "approval-b" ])
    ~base_dir () =
  let t = P.create () in
  P.bind_prepared_inputs t ~turn_ref:owner (prepared_model ~base_dir approvals);
  t
;;

let persist ?(turn_failed = false) ?(owner = turn_ref) t ~base_dir =
  (P.persist_continuation t ~base_dir ~keeper_name ~turn_ref:owner ~turn_failed).P.outcome
;;

let rows ~base_dir =
  K.load_all_result ~base_dir ~keeper_name
  |> Result.map_error K.strict_decode_error_to_string |> unwrap
;;

let tools ~base_dir = rows ~base_dir |> List.filter (fun row -> K.Role.equal row.K.role K.Role.Tool)
let path ~base_dir = K.chat_path ~base_dir ~keeper_name
let bytes ~base_dir = In_channel.with_open_bin (path ~base_dir) In_channel.input_all
let replace_bytes ~base_dir contents = Out_channel.with_open_bin (path ~base_dir)
  (fun channel -> output_string channel contents)

let expect_appended = function
  | P.Projected (K.Appended _) -> ()
  | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason)
  | P.Projected (K.Already_present _) | P.Nothing_to_project -> fail "expected a new projection"
;;

let expect_binding_drop = function
  | P.Projection_dropped (P.Input_binding_unavailable _) -> ()
  | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason)
  | P.Projected _ | P.Nothing_to_project -> fail "unproved input association was accepted"
;;

let expect_append_drop = function
  | P.Projection_dropped (P.Append_failed _) -> ()
  | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason)
  | P.Projected _ | P.Nothing_to_project -> fail "conflicting stored association was accepted"
;;

(* One sealed tool call with its canonical execution identity. *)
let feed_one_sealed_call t =
  P.on_event t (start ~index:0 ~tool_id:"call-1" ~tool_name:"Edit");
  P.on_event t (json_snapshot ~index:0 {|{"path":"lib/a.ml"}|});
  P.on_event t (stop ~index:0);
  P.on_tool_stream_observation t (turn_collected [ 0 ])
;;

let test_continuation_rows_land_once () =
  with_base_dir "keeper-loop-projection-lands" (fun base_dir ->
    let t = prepared ~base_dir () in
    feed_one_sealed_call t;
    let key = D.Autonomous_turn turn_ref in
    let persisted =
      P.persist_continuation t ~base_dir ~keeper_name ~turn_ref
        ~turn_failed:false
    in
    check int "a clean stream quarantines nothing" 0 (List.length persisted.P.quarantined);
    check int "a delivery-only row has no execution to commit" 0
      (List.length persisted.P.committed_ownerships);
    (match persisted.P.outcome with
     | P.Projected (K.Appended _) -> ()
     | P.Projected (K.Already_present _) -> fail "first append reported as already present"
     | P.Nothing_to_project -> fail "a sealed call projected nothing"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    (match tools ~base_dir with
     | [ row ] ->
       check bool "tool role" true (K.Role.equal row.role K.Role.Tool);
       check (option string) "tool name" (Some "Edit") row.tool_call_name;
       check string "args are the row content" {|{"path":"lib/a.ml"}|} row.content;
       check bool "delivery-only: no canonical execution identity" true
         (Option.is_none row.execution_id);
       check bool "turn ref of the continuation turn" true
         (Option.equal Ids.Turn_ref.equal (Some turn_ref) row.turn_ref);
       (match row.delivery_provenance with
        | Some { delivery_key; transcript_slot } ->
          check bool "common tools belong to the actual turn" true
            (Keeper_chat_delivery_identity.delivery_key_equal key delivery_key);
          check bool "slot is the store-owned delivery ordinal" true
            (Keeper_chat_delivery_identity.transcript_slot_equal
               (Keeper_chat_delivery_identity.Tool_delivery { ordinal = 0 })
               transcript_slot)
        | None -> fail "row carries no delivery provenance")
     | rows -> fail (Printf.sprintf "expected one tool row, got %d" (List.length rows)));
    (match persist t ~base_dir with
     | P.Projected (K.Already_present _) -> ()
     | P.Projected (K.Appended _) -> fail "a second persist appended the rows again"
     | P.Nothing_to_project -> fail "second persist saw no rows"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    check int "one binding and one tool row" 2 (List.length (rows ~base_dir)))
;;

let test_rejected_mapping_drops_the_projection () =
  with_base_dir "keeper-loop-projection-rejected" (fun base_dir ->
    let t = prepared ~base_dir () in
    (* An open block is not execution authority: sealing over it is rejected. *)
    P.on_event t (start ~index:0 ~tool_id:"open-call" ~tool_name:"Read");
    P.on_event t (json_snapshot ~index:0 {|{"path":"partial.ml"}|});
    P.on_tool_stream_observation t (turn_collected [ 0 ]);
    (match persist t ~base_dir with
     | P.Projection_dropped (P.Mapping_rejected _) -> ()
     | P.Projection_dropped (P.Input_binding_unavailable _ | P.Append_failed _) ->
       fail "rejected mapping reported under another reason"
     | P.Projected _ -> fail "rejected mapping still projected rows"
     | P.Nothing_to_project -> fail "rejected mapping reported as nothing to project");
    check int "no row" 0 (List.length (K.load ~base_dir ~keeper_name)))
;;

let test_no_tool_calls_projects_nothing () =
  with_base_dir "keeper-loop-projection-empty" (fun base_dir ->
    let t = P.create () in
    P.on_tool_stream_observation t (turn_collected []);
    (match persist t ~base_dir with
     | P.Nothing_to_project -> ()
     | P.Projected _ -> fail "a turn without tool calls projected rows"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    check int "no row" 0 (List.length (K.load ~base_dir ~keeper_name)))
;;

let test_failed_turn_keeps_only_sealed_evidence () =
  with_base_dir "keeper-loop-projection-failed" (fun base_dir ->
    let t = prepared ~base_dir () in
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:0);
    feed_one_sealed_call t;
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:1);
    P.on_event t (start ~index:0 ~tool_id:"failed-call" ~tool_name:"Write");
    P.on_event t (json_snapshot ~index:0 {|{"path":"failed.ml"}|});
    P.on_event t (stop ~index:0);
    (match persist ~turn_failed:true t ~base_dir with
     | P.Projected (K.Appended _) -> ()
     | P.Projected (K.Already_present _) -> fail "first append reported as already present"
     | P.Nothing_to_project -> fail "sealed evidence projected nothing"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    (match tools ~base_dir with
     | [ row ] -> check (option string) "only the sealed call" (Some "Edit") row.tool_call_name
     | rows -> fail (Printf.sprintf "expected the sealed row only, got %d" (List.length rows))))
;;

let test_missing_or_changed_preparation_drops_only_projection () =
  with_base_dir "keeper-loop-projection-binding" (fun base_dir ->
    let missing = P.create () in
    feed_one_sealed_call missing;
    expect_binding_drop (persist missing ~base_dir);
    List.iter (fun mutate ->
      let t = prepared ~base_dir () in
      (* The first boundary only opens attempt 0; turn ordinals restart at the
         next one, so the second attempt's turn 0 is not a resealing. *)
      P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:0);
      feed_one_sealed_call t;
      mutate t;
      P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:1);
      feed_one_sealed_call t;
      expect_binding_drop (persist t ~base_dir))
      [ (fun t -> P.bind_prepared_inputs t ~turn_ref
          (prepared_model ~base_dir [ "approval-b"; "approval-a" ]))
      ; (fun t -> P.bind_prepared_inputs t
          ~turn_ref:(Ids.Turn_ref.make ~trace_id:"other" ~absolute_turn:7)
          (prepared_model ~base_dir [ "approval-a"; "approval-b" ])) ];
    let t = prepared ~base_dir () in
    feed_one_sealed_call t;
    expect_binding_drop (persist t ~base_dir
      ~owner:(Ids.Turn_ref.make ~trace_id:"other" ~absolute_turn:7));
    check int "no unproved row was appended" 0 (List.length (rows ~base_dir)))
;;

(* A rejection belongs to the attempt that produced it. The next attempt
   boundary quarantines that attempt's rows, so a clean second attempt is
   projected on its own. *)
let test_a_new_attempt_clears_the_previous_rejection () =
  with_base_dir "keeper-loop-projection-attempt-reset" (fun base_dir ->
    let t = prepared ~base_dir () in
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:0);
    P.on_event t (start ~index:0 ~tool_id:"open-call" ~tool_name:"Read");
    P.on_event t (json_snapshot ~index:0 {|{"path":"partial.ml"}|});
    P.on_tool_stream_observation t (turn_collected [ 0 ]);
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:1);
    feed_one_sealed_call t;
    (match persist t ~base_dir with
     | P.Projected (K.Appended _) -> ()
     | P.Projected (K.Already_present _) -> fail "first append reported as already present"
     | P.Nothing_to_project -> fail "the clean attempt projected nothing"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    (match tools ~base_dir with
     | [ row ] -> check (option string) "only the clean attempt's call" (Some "Edit") row.tool_call_name
     | rows -> fail (Printf.sprintf "expected the clean attempt's row only, got %d" (List.length rows))))
;;

(* A delta that arrives after its block stopped is quarantined by the
   collector. The chat lane's live bridge reports those as they happen; the
   loop lane has no bridge, so the projection hands them back with the
   outcome instead of leaving the turn short with nothing saying so. *)
let test_a_quarantined_row_is_reported () =
  with_base_dir "keeper-loop-projection-quarantine" (fun base_dir ->
    let t = prepared ~base_dir () in
    P.on_event t (start ~index:0 ~tool_id:"call-1" ~tool_name:"Edit");
    P.on_event t (json_snapshot ~index:0 {|{"path":"lib/a.ml"}|});
    P.on_event t (stop ~index:0);
    P.on_event t (json_snapshot ~index:0 {|{"path":"late.ml"}|});
    P.on_tool_stream_observation t (turn_collected [ 0 ]);
    let persisted =
      P.persist_continuation t ~base_dir ~keeper_name ~turn_ref
        ~turn_failed:false
    in
    (match persisted.P.quarantined with
     | [] -> fail "the late delta was not reported"
     | errors ->
       check bool "the late delta is reported against its block" true
         (List.exists
            (fun (kind, (occurrence : E.tool_stream_occurrence), _) ->
               kind = E.Tool_args_without_start && occurrence.block_index = 0)
            errors));
    (match persisted.P.outcome with
     | P.Projected (K.Appended _) -> fail "a quarantined row was projected"
     | P.Projected (K.Already_present _) | P.Nothing_to_project | P.Projection_dropped _ -> ());
    check int "no row" 0 (List.length (K.load ~base_dir ~keeper_name)))
;;

(* The same approvals can continue in a later actual turn. Their common
   tool rows must neither overwrite the earlier turn nor be copied per approval. *)
let test_turns_share_inputs_without_sharing_tool_ownership () =
  with_base_dir "keeper-loop-projection-turn-owners" (fun base_dir ->
    let first = prepared ~base_dir () in
    feed_one_sealed_call first;
    expect_appended (persist first ~base_dir);
    let first_bytes = bytes ~base_dir in
    (match persist first ~base_dir with
     | P.Projected (K.Already_present _) -> ()
     | _ -> fail "the same turn was not idempotent");
    check string "retry keeps exact stored bytes" first_bytes (bytes ~base_dir);
    let later = Ids.Turn_ref.make ~trace_id:"trace-fixture" ~absolute_turn:8 in
    let second = prepared ~base_dir ~owner:later () in
    feed_one_sealed_call second;
    expect_appended (persist second ~base_dir ~owner:later);
    check int "each turn stores one binding and one common tool" 4
      (List.length (rows ~base_dir));
    check (list (option string)) "actual turn ownership is retained"
      [ Some (Ids.Turn_ref.to_string turn_ref); Some (Ids.Turn_ref.to_string later) ]
      (List.map (fun row -> Option.map Ids.Turn_ref.to_string row.K.turn_ref) (tools ~base_dir)))
;;

let test_input_conflicts_leave_the_transcript_unchanged () =
  with_base_dir "keeper-loop-projection-input-conflict" (fun base_dir ->
    let first = prepared ~base_dir () in
    feed_one_sealed_call first;
    expect_appended (persist first ~base_dir);
    let before = bytes ~base_dir in
    List.iter (fun model ->
      let t = P.create () in
      P.bind_prepared_inputs t ~turn_ref model;
      feed_one_sealed_call t;
      expect_append_drop (persist t ~base_dir);
      check string "conflict appends no bytes" before (bytes ~base_dir))
      [ prepared_model ~base_dir [ "approval-b"; "approval-a" ]
      ; prepared_model ~base_dir ~suffix:"changed result" [ "approval-a"; "approval-b" ] ];
    let same = P.create () in
    P.bind_prepared_inputs same ~turn_ref
      (prepared_model ~base_dir ~user_message:"A new base cue." [ "approval-a"; "approval-b" ]);
    feed_one_sealed_call same;
    (match persist same ~base_dir with
     | P.Projected (K.Already_present _) -> ()
     | _ -> fail "a base cue must not change canonical approval input association");
    check string "equivalent retry keeps the transcript" before (bytes ~base_dir))
;;

let test_binding_only_turn_is_stored_and_hidden_from_presentation () =
  with_base_dir "keeper-loop-projection-binding-only" (fun base_dir ->
    let t = prepared ~base_dir () in
    expect_appended (persist t ~base_dir);
    let stored = rows ~base_dir in
    check int "strict history retains the binding" 1 (List.length stored);
    check bool "binding is internal" true
      (match (List.hd stored).K.delivery_provenance with
       | Some { transcript_slot = D.Autonomous_input_binding inputs; _ } ->
         List.map (fun (input : D.approval_input_binding) -> D.Request_id.to_string input.approval_id)
           inputs = [ "approval-a"; "approval-b" ]
       | _ -> false);
    check bool "presentation has no fabricated visible row" true (K.to_json_array stored = `List []);
    let before = bytes ~base_dir in
    (match persist t ~base_dir with
     | P.Projected (K.Already_present _) -> ()
     | _ -> fail "binding-only retry must be idempotent");
    check string "binding-only retry writes nothing" before (bytes ~base_dir))
;;

let test_malformed_existing_association_is_not_repaired () =
  List.iter (fun corrupt ->
    with_base_dir "keeper-loop-projection-corrupt-binding" (fun base_dir ->
      let first = prepared ~base_dir () in
      feed_one_sealed_call first;
      expect_appended (persist first ~base_dir);
      let lines = String.split_on_char '\n' (bytes ~base_dir) |> List.filter ((<>) "") in
      let changed = match lines with
        | [ binding; tool ] -> corrupt binding tool
        | _ -> fail "fixture must contain one binding and one tool" in
      replace_bytes ~base_dir changed;
      expect_append_drop (persist first ~base_dir);
      check string "inconsistent association is preserved for diagnosis" changed (bytes ~base_dir)))
    [ (fun _binding tool -> tool ^ "\n")
    ; (fun binding tool -> binding ^ "\n" ^ binding ^ "\n" ^ tool ^ "\n") ]
;;

let test_unrelated_writers_cannot_poison_an_autonomous_owner () =
  with_base_dir "keeper-loop-projection-public-writers" (fun base_dir ->
    let delivery_key = D.Autonomous_turn turn_ref in
    (match K.append_user_message_once ~base_dir ~keeper_name ~delivery_key ~content:"wrong owner" () with
     | Error _ -> () | Ok _ -> fail "user writer bypassed the autonomous binding");
    let failure : K.Settled_failure.t =
      { delivery_key; content = "wrong failure"; route = Lazy.from_val K.Row_route.none } in
    (match K.append_settled_failures_once ~base_dir ~keeper_name [ (), failure ] with
     | Ok [ (), Error _ ] -> ()
     | Error detail -> fail detail
     | _ -> fail "batch failure writer bypassed the autonomous binding");
    let t = prepared ~base_dir () in
    feed_one_sealed_call t;
    expect_appended (persist t ~base_dir);
    check int "only the valid binding and tool are stored" 2 (List.length (rows ~base_dir)))
;;

let test_owned_rows_report_the_actual_turn_once () =
  with_base_dir "keeper-loop-projection-owned" (fun base_dir ->
    let execution_id = Ids.Execution_id.of_string "exec-owned-1" in
    let t = prepared ~base_dir () in
    P.on_event t (start ~index:0 ~tool_id:"call-1" ~tool_name:"Edit");
    P.on_event t (json_snapshot ~index:0 {|{"path":"lib/a.ml"}|});
    P.on_event t (stop ~index:0);
    P.on_tool_stream_observation t
      (H.Official_tool_result { block_index = 0; tool_call_id = "call-1"; execution_id });
    P.on_tool_stream_observation t (turn_collected [ 0 ]);
    let persisted = P.persist_continuation t ~base_dir ~keeper_name ~turn_ref ~turn_failed:false in
    expect_appended persisted.P.outcome;
    (match persisted.P.committed_ownerships with
     | [ (delivery_key, ownership) ] ->
       check bool "ownership is under the actual turn" true
         (D.delivery_key_equal (D.Autonomous_turn turn_ref) delivery_key);
       check bool "ownership names the execution" true
         (Ids.Execution_id.equal execution_id ownership.K.execution_id);
       check int "ownership position" 0 ownership.K.ordinal
     | _ -> fail "expected one actual execution ownership");
    let retry = P.persist_continuation t ~base_dir ~keeper_name ~turn_ref ~turn_failed:false in
    check int "an existing execution is not announced again" 0 (List.length retry.P.committed_ownerships))
;;

let test_partial_projection_announces_only_added_execution_slots () =
  with_base_dir "keeper-loop-projection-owned-prefix" (fun base_dir ->
    let input_binding = (prepared_model ~base_dir [ "approval-a"; "approval-b" ]).R.approval_input_bindings
      |> unwrap in
    let call id : K.tool_call =
      { call_id = "call-" ^ id; execution_id = Some (Ids.Execution_id.of_string id)
      ; call_name = "Read"; args = "{}" } in
    let append tool_calls = K.append_autonomous_tool_calls_once ~base_dir ~keeper_name ~turn_ref
      ~input_binding ~tool_calls () |> unwrap in
    let _, first = append [ call "exec-a" ] in
    check int "first execution is newly committed" 1 (List.length first);
    let _, added = append [ call "exec-a"; call "exec-b" ] in
    check (list string) "an existing prefix is not newly announced"
      [ "exec-b" ] (List.map (fun (ownership : K.tool_ownership) ->
        Ids.Execution_id.to_string ownership.execution_id) added);
    let before = bytes ~base_dir in
    let _, retry = append [ call "exec-a"; call "exec-b" ] in
    check int "exact retry commits no execution" 0 (List.length retry);
    check string "exact retry keeps stored bytes" before (bytes ~base_dir))
;;

let test_binding_only_page_preserves_its_physical_cursor () =
  with_base_dir "keeper-loop-projection-page" (fun base_dir ->
    K.append_user_message ~base_dir ~keeper_name ~content:"Earlier request" ();
    let t = prepared ~base_dir () in
    expect_appended (persist t ~base_dir);
    let page ?cursor () = K.load_history_page_result ~base_dir ~keeper_name ?cursor ~max_total:1 ()
      |> Result.map_error Masc.Keeper_chat_history_page.error_to_string |> unwrap in
    let latest = page () in
    check bool "the latest physical binding page has no visible row" true
      (K.to_json_array latest.K.history_messages = `List []);
    let cursor = match latest.K.next_cursor with
      | Some cursor -> cursor | None -> fail "hidden binding lost the older history cursor" in
    let older = page ~cursor () in
    check int "the original request remains reachable" 1 (List.length older.K.history_messages);
    check string "the older request is unchanged" "Earlier request" (List.hd older.K.history_messages).K.content;
    check bool "the physical prefix is exhausted" true (Option.is_none older.K.next_cursor))
;;

let test_candidate_validation_precedes_existing_slot_shortcuts () =
  let module A = Masc.Keeper_chat_store_append_once in
  with_base_dir "keeper-loop-projection-candidate-identity" (fun base_dir ->
    let t = prepared ~base_dir () in
    feed_one_sealed_call t;
    expect_appended (persist t ~base_dir);
    let before = bytes ~base_dir in
    let candidate line : A.append_once_line =
      let fields = Yojson.Safe.from_string line |> Yojson.Safe.Util.to_assoc in
      let provenance = D.delivery_provenance_of_fields fields |> unwrap |> Option.get in
      { transcript_slot = provenance.transcript_slot
      ; row_id = List.assoc "id" fields |> Yojson.Safe.Util.to_string
      ; line = Lazy.from_val line } in
    let binding, tool = match String.split_on_char '\n' before |> List.filter ((<>) "")
        |> List.map candidate with
      | [ binding; tool ] -> binding, tool
      | _ -> fail "expected one real binding and one tool candidate" in
    let wrong_owner =
      let fields = Yojson.Safe.from_string (Lazy.force tool.A.line) |> Yojson.Safe.Util.to_assoc in
      { tool with A.line = Lazy.from_val (Yojson.Safe.to_string
          (`Assoc (("turn_ref", `String "other-turn#7") :: List.remove_assoc "turn_ref" fields))) } in
    let other_binding = match binding.A.transcript_slot with
      | D.Autonomous_input_binding inputs ->
        { binding with A.transcript_slot = D.Autonomous_input_binding (List.rev inputs) }
      | _ -> fail "expected a prepared binding candidate" in
    List.iter (fun candidates ->
      (match A.append_lines_once (path ~base_dir) ~delivery_key:(D.Autonomous_turn turn_ref)
          ~result_slot:binding.A.transcript_slot candidates with
       | Error _ -> () | Ok _ -> fail "invalid candidates bypassed validation via existing slots");
      check string "invalid candidates change no stored bytes" before (bytes ~base_dir))
      [ [ binding; wrong_owner ]; [ binding; other_binding; tool ]; [ tool ] ])
;;

let () =
  run "keeper_loop_tool_projection"
    [ ( "continuation turn"
      , [ test_case "common tools land once under the actual turn" `Quick test_continuation_rows_land_once
        ; test_case "a rejected mapping drops the projection" `Quick test_rejected_mapping_drops_the_projection
        ; test_case "an unprepared turn without tools projects nothing" `Quick test_no_tool_calls_projects_nothing
        ; test_case "a failed turn keeps only sealed evidence" `Quick test_failed_turn_keeps_only_sealed_evidence
        ; test_case "missing or changed preparation survives attempt boundaries" `Quick
            test_missing_or_changed_preparation_drops_only_projection
        ; test_case "a new attempt clears its predecessor's mapping rejection" `Quick
            test_a_new_attempt_clears_the_previous_rejection
        ; test_case "a quarantined row is reported" `Quick test_a_quarantined_row_is_reported
        ; test_case "successive turns retain separate common tool ownership" `Quick
            test_turns_share_inputs_without_sharing_tool_ownership
        ; test_case "conflicting input order or result writes nothing" `Quick
            test_input_conflicts_leave_the_transcript_unchanged
        ; test_case "binding-only turns are durable internal rows" `Quick
            test_binding_only_turn_is_stored_and_hidden_from_presentation
        ; test_case "missing or duplicate existing bindings are not repaired" `Quick
            test_malformed_existing_association_is_not_repaired
        ; test_case "other public writers cannot poison the turn owner" `Quick
            test_unrelated_writers_cannot_poison_an_autonomous_owner
        ; test_case "execution ownership is announced under the actual turn once" `Quick
            test_owned_rows_report_the_actual_turn_once
        ; test_case "partial projection announces only new execution slots" `Quick
            test_partial_projection_announces_only_added_execution_slots
        ; test_case "a hidden binding page preserves its physical cursor" `Quick
            test_binding_only_page_preserves_its_physical_cursor
        ; test_case "candidate identity is checked before existing slot shortcuts" `Quick
            test_candidate_validation_precedes_existing_slot_shortcuts
        ] ) ]
;;
