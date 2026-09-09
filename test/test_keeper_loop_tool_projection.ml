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

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
;;

let with_base_dir prefix f =
  let base_dir = temp_base_path prefix in
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
         { Agent_core.Hooks.planned_index; source_tool_use_ordinal })
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

let approval_key id =
  match Keeper_chat_delivery_identity.Request_id.of_string id with
  | Ok request_id -> Keeper_chat_delivery_identity.Approval_lifecycle request_id
  | Error detail -> fail detail
;;

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-fixture" ~absolute_turn:7

let persist ?(turn_failed = false) t ~base_dir ~approval_id =
  (P.persist_continuation t ~base_dir ~keeper_name ~approval_id ~turn_ref ~turn_failed)
    .P.outcome
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
    let t = P.create () in
    feed_one_sealed_call t;
    let key = approval_key "approval-1" in
    let persisted =
      P.persist_continuation t ~base_dir ~keeper_name ~approval_id:"approval-1" ~turn_ref
        ~turn_failed:false
    in
    check int "a clean stream quarantines nothing" 0 (List.length persisted.P.quarantined);
    (match persisted.P.outcome with
     | P.Projected (K.Appended _) -> ()
     | P.Projected (K.Already_present _) -> fail "first append reported as already present"
     | P.Nothing_to_project -> fail "a sealed call projected nothing"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    (match K.load ~base_dir ~keeper_name with
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
          check bool "delivered under the approval's identity" true
            (Keeper_chat_delivery_identity.delivery_key_equal key delivery_key);
          check bool "slot is the store-owned delivery ordinal" true
            (Keeper_chat_delivery_identity.transcript_slot_equal
               (Keeper_chat_delivery_identity.Tool_delivery { ordinal = 0 })
               transcript_slot)
        | None -> fail "row carries no delivery provenance")
     | rows -> fail (Printf.sprintf "expected one tool row, got %d" (List.length rows)));
    (match persist t ~base_dir ~approval_id:"approval-1" with
     | P.Projected (K.Already_present _) -> ()
     | P.Projected (K.Appended _) -> fail "a second persist appended the rows again"
     | P.Nothing_to_project -> fail "second persist saw no rows"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    check int "still one row" 1 (List.length (K.load ~base_dir ~keeper_name)))
;;

let test_rejected_mapping_drops_the_projection () =
  with_base_dir "keeper-loop-projection-rejected" (fun base_dir ->
    let t = P.create () in
    (* An open block is not execution authority: sealing over it is rejected. *)
    P.on_event t (start ~index:0 ~tool_id:"open-call" ~tool_name:"Read");
    P.on_event t (json_snapshot ~index:0 {|{"path":"partial.ml"}|});
    P.on_tool_stream_observation t (turn_collected [ 0 ]);
    (match persist t ~base_dir ~approval_id:"approval-2" with
     | P.Projection_dropped (P.Mapping_rejected _) -> ()
     | P.Projection_dropped (P.Invalid_approval_id _ | P.Append_failed _) ->
       fail "rejected mapping reported under another reason"
     | P.Projected _ -> fail "rejected mapping still projected rows"
     | P.Nothing_to_project -> fail "rejected mapping reported as nothing to project");
    check int "no row" 0 (List.length (K.load ~base_dir ~keeper_name)))
;;

let test_no_tool_calls_projects_nothing () =
  with_base_dir "keeper-loop-projection-empty" (fun base_dir ->
    let t = P.create () in
    P.on_tool_stream_observation t (turn_collected []);
    (match persist t ~base_dir ~approval_id:"approval-3" with
     | P.Nothing_to_project -> ()
     | P.Projected _ -> fail "a turn without tool calls projected rows"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    check int "no row" 0 (List.length (K.load ~base_dir ~keeper_name)))
;;

let test_failed_turn_keeps_only_sealed_evidence () =
  with_base_dir "keeper-loop-projection-failed" (fun base_dir ->
    let t = P.create () in
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:0);
    feed_one_sealed_call t;
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:1);
    P.on_event t (start ~index:0 ~tool_id:"failed-call" ~tool_name:"Write");
    P.on_event t (json_snapshot ~index:0 {|{"path":"failed.ml"}|});
    P.on_event t (stop ~index:0);
    (match persist ~turn_failed:true t ~base_dir ~approval_id:"approval-4" with
     | P.Projected (K.Appended _) -> ()
     | P.Projected (K.Already_present _) -> fail "first append reported as already present"
     | P.Nothing_to_project -> fail "sealed evidence projected nothing"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    (match K.load ~base_dir ~keeper_name with
     | [ row ] -> check (option string) "only the sealed call" (Some "Edit") row.tool_call_name
     | rows -> fail (Printf.sprintf "expected the sealed row only, got %d" (List.length rows))))
;;

let test_invalid_approval_id_drops_the_projection () =
  with_base_dir "keeper-loop-projection-bad-id" (fun base_dir ->
    let t = P.create () in
    feed_one_sealed_call t;
    (match persist t ~base_dir ~approval_id:"" with
     | P.Projection_dropped (P.Invalid_approval_id _) -> ()
     | P.Projection_dropped (P.Mapping_rejected _ | P.Append_failed _) ->
       fail "an unusable approval id was reported under another reason"
     | P.Projected _ -> fail "rows were appended under an unusable approval id"
     | P.Nothing_to_project -> fail "a sealed call reported as nothing to project");
    check int "no row" 0 (List.length (K.load ~base_dir ~keeper_name)))
;;

(* A rejection belongs to the attempt that produced it. The next attempt
   boundary quarantines that attempt's rows, so a clean second attempt is
   projected on its own. *)
let test_a_new_attempt_clears_the_previous_rejection () =
  with_base_dir "keeper-loop-projection-attempt-reset" (fun base_dir ->
    let t = P.create () in
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:0);
    P.on_event t (start ~index:0 ~tool_id:"open-call" ~tool_name:"Read");
    P.on_event t (json_snapshot ~index:0 {|{"path":"partial.ml"}|});
    P.on_tool_stream_observation t (turn_collected [ 0 ]);
    P.on_tool_stream_observation t (attempt_started ~lane_attempt_index:1);
    feed_one_sealed_call t;
    (match persist t ~base_dir ~approval_id:"approval-5" with
     | P.Projected (K.Appended _) -> ()
     | P.Projected (K.Already_present _) -> fail "first append reported as already present"
     | P.Nothing_to_project -> fail "the clean attempt projected nothing"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    (match K.load ~base_dir ~keeper_name with
     | [ row ] -> check (option string) "only the clean attempt's call" (Some "Edit") row.tool_call_name
     | rows -> fail (Printf.sprintf "expected the clean attempt's row only, got %d" (List.length rows))))
;;

(* A delta that arrives after its block stopped is quarantined by the
   collector. The chat lane's live bridge reports those as they happen; the
   loop lane has no bridge, so the projection hands them back with the
   outcome instead of leaving the turn short with nothing saying so. *)
let test_a_quarantined_row_is_reported () =
  with_base_dir "keeper-loop-projection-quarantine" (fun base_dir ->
    let t = P.create () in
    P.on_event t (start ~index:0 ~tool_id:"call-1" ~tool_name:"Edit");
    P.on_event t (json_snapshot ~index:0 {|{"path":"lib/a.ml"}|});
    P.on_event t (stop ~index:0);
    P.on_event t (json_snapshot ~index:0 {|{"path":"late.ml"}|});
    P.on_tool_stream_observation t (turn_collected [ 0 ]);
    let persisted =
      P.persist_continuation t ~base_dir ~keeper_name ~approval_id:"approval-6" ~turn_ref
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

(* The store merges once-appends per slot ordinal. A second turn continuing
   the same approval would read its first rows as present and append only
   its surplus, interleaving two turns under one identity; the key is looked
   up first and the later turn is reported as already present, rows intact. *)
let test_a_second_turn_under_the_same_approval_is_not_interleaved () =
  with_base_dir "keeper-loop-projection-second-turn" (fun base_dir ->
    let first = P.create () in
    feed_one_sealed_call first;
    (match persist first ~base_dir ~approval_id:"approval-7" with
     | P.Projected (K.Appended _) -> ()
     | P.Projected (K.Already_present _) -> fail "first append reported as already present"
     | P.Nothing_to_project -> fail "the first turn projected nothing"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    let second = P.create () in
    P.on_event second (start ~index:0 ~tool_id:"call-2" ~tool_name:"Read");
    P.on_event second (json_snapshot ~index:0 {|{"path":"lib/b.ml"}|});
    P.on_event second (stop ~index:0);
    P.on_event second (start ~index:1 ~tool_id:"call-3" ~tool_name:"Write");
    P.on_event second (json_snapshot ~index:1 {|{"path":"lib/c.ml"}|});
    P.on_event second (stop ~index:1);
    P.on_tool_stream_observation second (turn_collected [ 0; 1 ]);
    let later_turn_ref = Ids.Turn_ref.make ~trace_id:"trace-fixture" ~absolute_turn:8 in
    let persisted =
      P.persist_continuation second ~base_dir ~keeper_name ~approval_id:"approval-7"
        ~turn_ref:later_turn_ref ~turn_failed:false
    in
    check int "no quarantined row" 0 (List.length persisted.P.quarantined);
    (match persisted.P.outcome with
     | P.Projected (K.Already_present _) -> ()
     | P.Projected (K.Appended _) ->
       fail "a second turn appended rows under the first turn's identity"
     | P.Nothing_to_project -> fail "the second turn reported no rows"
     | P.Projection_dropped reason -> fail (P.drop_reason_to_string reason));
    (match K.load ~base_dir ~keeper_name with
     | [ row ] ->
       check (option string) "only the first turn's call" (Some "Edit") row.tool_call_name;
       check bool "and the first turn's ref" true
         (Option.equal Ids.Turn_ref.equal (Some turn_ref) row.turn_ref)
     | rows ->
       fail (Printf.sprintf "expected the first turn's row only, got %d" (List.length rows))))
;;

let () =
  run
    "keeper_loop_tool_projection"
    [ ( "continuation turn"
      , [ test_case "tool rows land once under the approval key" `Quick
            test_continuation_rows_land_once
        ; test_case "a rejected mapping drops the projection and says why" `Quick
            test_rejected_mapping_drops_the_projection
        ; test_case "a turn without tool calls projects nothing" `Quick
            test_no_tool_calls_projects_nothing
        ; test_case "a failed turn keeps only sealed evidence" `Quick
            test_failed_turn_keeps_only_sealed_evidence
        ; test_case "an unusable approval id drops the projection" `Quick
            test_invalid_approval_id_drops_the_projection
        ; test_case "a new attempt clears the previous rejection" `Quick
            test_a_new_attempt_clears_the_previous_rejection
        ; test_case "a quarantined row is reported with the outcome" `Quick
            test_a_quarantined_row_is_reported
        ; test_case "a second turn under the same approval is not interleaved" `Quick
            test_a_second_turn_under_the_same_approval_is_not_interleaved
        ] )
    ]
;;
