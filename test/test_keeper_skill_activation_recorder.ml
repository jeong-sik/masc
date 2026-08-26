open Alcotest
open Masc

module Ledger = Keeper_skill_activation_ledger
module Recorder = Keeper_skill_activation_recorder

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let trace_id value =
  match Keeper_id.Trace_id.of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let task_id value =
  match Keeper_id.Task_id.of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let source_id value =
  match Skill_source_config.source_id_of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let package_id value =
  match Skill_reference.package_id_of_directory value with
  | Ok value -> value
  | Error _ -> fail "invalid package fixture"
;;

let content_revision character =
  match Skill_reference.content_revision_of_string (String.make 64 character) with
  | Ok value -> value
  | Error _ -> fail "invalid content revision fixture"
;;

let snapshot_revision =
  match Skill_catalog_snapshot.snapshot_revision_of_string (String.make 64 'f') with
  | Ok value -> value
  | Error _ -> fail "invalid snapshot revision fixture"
;;

let reference ?(package = "review") ?(name = "review") revision =
  Skill_reference.make
    ~identity:
      (Skill_reference.make_identity
         ~source_id:(source_id "workspace")
         ~package_id:(package_id package)
         ~name)
    ~content_revision:(content_revision revision)
;;

let with_session operation =
  let root = Filename.temp_dir "skill-activation-recorder-" "" in
  let config = Workspace.default_config root in
  let trace_id = trace_id "trace-recorder" in
  let session_dir = Keeper_fs.keeper_session_dir config "trace-recorder" in
  Unix.mkdir session_dir 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> operation config trace_id)
;;

let make_context ~trace_id ~task_id ~task_references =
  match
    Recorder.make
      ~trace_id
      ~turn_ref:
        (Ids.Turn_ref.make
           ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
           ~absolute_turn:3)
      ~snapshot_revision
      ~task_id
      ~task_references
  with
  | Ok context -> context
  | Error error -> fail (Recorder.error_to_string error)
;;

let test_task_and_session_origins_are_derived_from_exact_refs () =
  with_session @@ fun config trace_id ->
  let task_reference = reference 'a' in
  let session_reference = reference ~package:"global" ~name:"global" 'b' in
  let context =
    make_context
      ~trace_id
      ~task_id:(Some (task_id "task-007"))
      ~task_references:[ task_reference ]
  in
  (match Recorder.record_instruction ~config context task_reference with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  (match
     Recorder.record_composition
       ~config
       context
       ~tool_name:"keeper_compose_global"
       session_reference
   with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    (match
       List.map (fun (activation : Ledger.activation) -> activation.origin)
         (Ledger.activations ledger)
     with
     | [ Ledger.Task_instruction { task_id = observed }
       ; Ledger.Session_composition { tool_name }
       ] ->
       check string "Task origin" "task-007" (Keeper_id.Task_id.to_string observed);
       check string "composition origin" "keeper_compose_global" tool_name
     | _ -> fail "exact references did not derive the expected origins")
;;

let test_task_reference_without_task_scope_fails_closed () =
  with_session @@ fun config trace_id ->
  let task_reference = reference 'a' in
  let context =
    make_context ~trace_id ~task_id:None ~task_references:[ task_reference ]
  in
  match Recorder.record_instruction ~config context task_reference with
  | Error (Recorder.Task_scope_missing observed) ->
    check bool "same exact reference" true
      (Skill_reference.equal task_reference observed)
  | Error error -> fail (Recorder.error_to_string error)
  | Ok _ -> fail "Task-declared activation invented a session origin"
;;

let test_turn_scope_mismatch_is_rejected_before_recording () =
  let trace = trace_id "trace-recorder" in
  match
    Recorder.make
      ~trace_id:trace
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:"another-trace" ~absolute_turn:1)
      ~snapshot_revision
      ~task_id:None
      ~task_references:[]
  with
  | Error Recorder.Turn_scope_mismatch -> ()
  | Error error -> fail (Recorder.error_to_string error)
  | Ok _ -> fail "cross-trace activation context was accepted"
;;

let () =
  run
    "keeper Skill activation recorder"
    [ ( "recording"
      , [ test_case "exact refs derive Task and session origins" `Quick
            test_task_and_session_origins_are_derived_from_exact_refs
        ; test_case "missing Task scope fails closed" `Quick
            test_task_reference_without_task_scope_fails_closed
        ; test_case "turn scope mismatch is rejected" `Quick
            test_turn_scope_mismatch_is_rejected_before_recording
        ] )
    ]
;;
