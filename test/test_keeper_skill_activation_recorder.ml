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

let invocation tool_use_id =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id
    ~turn:0
    ~schedule:
      { planned_index = 0
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_core.Tool_contract.Serial
      }
    ~completion:Agent_core.Tool_contract.Continue_after_success
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

let make_context ~trace_id ~task_scope =
  match
    Recorder.make
      ~trace_id
      ~runtime_id:(fun () -> Some "test.runtime")
      ~turn_ref:
        (Ids.Turn_ref.make
           ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
           ~absolute_turn:3)
      ~snapshot_revision
      ~task_scope
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
      ~task_scope:
        (Keeper_task_skill_turn.Task
           { task_id = "task-007"; references = [ task_reference ] })
  in
  (match
     Recorder.record_instruction
       ~config
       context
       ~invocation:(invocation "call-task")
       ~content:(Recorder.Body "task body")
       task_reference
   with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  (match
     Recorder.record_composition
       ~config
       context
       ~invocation:(invocation "call-composition")
       ~tool_name:"keeper_compose_global"
       session_reference
   with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    (match
       List.map (fun (activation : Ledger.activation) -> activation.invocation)
         (Ledger.activations ledger)
     with
     | [ Ledger.Instruction_invocation
           { origin = Ledger.Task_instruction { task_id = observed }; _ }
       ; Ledger.Composition_invocation
           { origin = Ledger.Session_composition; tool_name }
       ] ->
       check string "Task origin" "task-007" (Keeper_id.Task_id.to_string observed);
       check string "composition origin" "keeper_compose_global" tool_name;
       let summary = Ledger.summarize ledger in
       check int "one instruction body" 1 summary.skill_bodies_served;
       check int "composition is not a body" 1 summary.composition_invocations;
       let composition_json =
         match Ledger.to_yojson ledger with
         | `Assoc ledger_fields ->
           (match List.assoc_opt "activations" ledger_fields with
            | Some (`List [ _; `Assoc activation_fields ]) ->
              Option.value
                ~default:`Null
                (List.assoc_opt "invocation" activation_fields)
            | _ -> `Null)
         | _ -> `Null
       in
       (match composition_json with
        | `Assoc fields ->
          check (option string) "typed composition JSON" (Some "composition")
            (match List.assoc_opt "kind" fields with
             | Some (`String kind) -> Some kind
             | Some _ | None -> None);
          check bool "composition JSON has no served content" false
            (List.mem_assoc "served_content" fields)
        | _ -> fail "composition invocation JSON missing")
     | _ -> fail "exact references did not derive the expected origins")
;;

let test_invalid_task_scope_fails_closed () =
  let trace_id = trace_id "trace-recorder" in
  let task_reference = reference 'a' in
  match
    Recorder.make
      ~trace_id
      ~runtime_id:(fun () -> Some "test.runtime")
      ~turn_ref:
        (Ids.Turn_ref.make ~trace_id:"trace-recorder" ~absolute_turn:1)
      ~snapshot_revision
      ~task_scope:
        (Keeper_task_skill_turn.Task
           { task_id = ""; references = [ task_reference ] })
  with
  | Error (Recorder.Invalid_task_id task_id) ->
    check string "rejected exact id" "" task_id
  | Error error -> fail (Recorder.error_to_string error)
  | Ok _ -> fail "invalid Task scope was accepted"
;;

let test_resource_receipt_keeps_path_size_and_digest () =
  with_session @@ fun config trace_id ->
  let reference = reference 'a' in
  let context =
    make_context ~trace_id ~task_scope:Keeper_task_skill_turn.No_task
  in
  let relative_path =
    match Skill_resource_path.of_string "references/PROOF.md" with
    | Ok path -> path
    | Error error -> fail (Skill_resource_path.error_to_string error)
  in
  (match
     Recorder.record_instruction
       ~config
       context
       ~invocation:(invocation "call-resource")
       ~content:(Recorder.Resource { relative_path; contents = "RESOURCE_BYTES" })
       reference
   with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    (match Ledger.activations ledger with
     | [ { invocation =
             Ledger.Instruction_invocation
               { served_content = Ledger.Skill_resource observed; _ }
         ; _
         } ] ->
       check string "relative path" "references/PROOF.md" observed.relative_path;
       check int "exact bytes" 14 observed.bytes;
       check
         string
         "exact digest"
         "4891552b0a1e3de55b9f5cfdf1f06508210fcbcdae3e5133a40a82aba9920b8b"
         observed.sha256
     | _ -> fail "resource invocation was not recorded as a resource")
;;

let test_turn_scope_mismatch_is_rejected_before_recording () =
  let trace = trace_id "trace-recorder" in
  match
    Recorder.make
      ~trace_id:trace
      ~runtime_id:(fun () -> Some "test.runtime")
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:"another-trace" ~absolute_turn:1)
      ~snapshot_revision
      ~task_scope:Keeper_task_skill_turn.No_task
  with
  | Error Recorder.Turn_scope_mismatch -> ()
  | Error error -> fail (Recorder.error_to_string error)
  | Ok _ -> fail "cross-trace activation context was accepted"
;;

let test_runtime_attempt_is_required_before_recording () =
  with_session @@ fun config trace_id ->
  let context =
    match
      Recorder.make
        ~trace_id
        ~runtime_id:(fun () -> None)
        ~turn_ref:
          (Ids.Turn_ref.make
             ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
             ~absolute_turn:1)
        ~snapshot_revision
        ~task_scope:Keeper_task_skill_turn.No_task
    with
    | Ok context -> context
    | Error error -> fail (Recorder.error_to_string error)
  in
  match
    Recorder.record_instruction
      ~config
      context
      ~invocation:(invocation "call-before-runtime")
      ~content:(Recorder.Body "BODY")
      (reference 'a')
  with
  | Error Recorder.Runtime_attempt_missing -> ()
  | Error error -> fail (Recorder.error_to_string error)
  | Ok _ -> fail "activation was recorded before runtime selection"
;;

let test_runtime_provider_tracks_candidate_failover () =
  with_session @@ fun config trace_id ->
  let selected_runtime = Atomic.make (Some "runtime-a") in
  let context =
    match
      Recorder.make
        ~trace_id
        ~runtime_id:(fun () -> Atomic.get selected_runtime)
        ~turn_ref:
          (Ids.Turn_ref.make
             ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
             ~absolute_turn:1)
        ~snapshot_revision
        ~task_scope:Keeper_task_skill_turn.No_task
    with
    | Ok context -> context
    | Error error -> fail (Recorder.error_to_string error)
  in
  let record tool_use_id =
    match
      Recorder.record_instruction
        ~config
        context
        ~invocation:(invocation tool_use_id)
        ~content:(Recorder.Body "BODY")
        (reference 'a')
    with
    | Ok _ -> ()
    | Error error -> fail (Recorder.error_to_string error)
  in
  record "call-runtime-a";
  Atomic.set selected_runtime (Some "runtime-b");
  record "call-runtime-b";
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    check
      (list string)
      "each activation keeps its concrete candidate"
      [ "runtime-a"; "runtime-b" ]
      (List.map
         (fun (activation : Ledger.activation) -> activation.runtime_id)
         (Ledger.activations ledger))
;;

let () =
  run
    "keeper Skill activation recorder"
    [ ( "recording"
      , [ test_case "exact refs derive Task and session origins" `Quick
            test_task_and_session_origins_are_derived_from_exact_refs
        ; test_case "invalid Task scope fails closed" `Quick
            test_invalid_task_scope_fails_closed
        ; test_case "resource receipt is exact" `Quick
            test_resource_receipt_keeps_path_size_and_digest
        ; test_case "turn scope mismatch is rejected" `Quick
            test_turn_scope_mismatch_is_rejected_before_recording
        ; test_case "runtime attempt is required" `Quick
            test_runtime_attempt_is_required_before_recording
        ; test_case "runtime provider follows failover" `Quick
            test_runtime_provider_tracks_candidate_failover
        ] )
    ]
;;
