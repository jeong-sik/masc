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

let task_snapshot () =
  let config =
    match
      Skill_source_config.parse_text
        "[skills]\nresource-read-max-bytes = 65536\n[[skills.sources]]\nid = \"workspace\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-write\"\n"
    with
    | Ok config -> config
    | Error _ -> fail "Skill source fixture config rejected"
  in
  let source =
    match config.Skill_source_config.sources with
    | [ source ] -> source
    | _ -> fail "expected one Skill source"
  in
  let resolved = Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source in
  let resolved_path =
    match resolved.resolution with
    | Skill_source_config.Resolved path -> path
    | _ -> fail "Skill source fixture did not resolve"
  in
  let document name =
    Printf.sprintf "---\nname: %s\ndescription: fixture\n---\n%s body" name name
  in
  let scan : Skill_catalog_snapshot.source_scan =
    { source = resolved
    ; observation = Source_ready { resolved_path; candidates = 2 }
    ; candidates =
        [ Candidate_document { directory = "review"; source_text = document "review" }
        ; Candidate_document { directory = "global"; source_text = document "global" }
        ]
    }
  in
  let snapshot =
    match Skill_catalog_snapshot.configured ~config [ scan ] with
    | Ok snapshot -> snapshot
    | Error _ -> fail "Skill snapshot fixture rejected"
  in
  let exact package name =
    let identity =
      Skill_reference.make_identity
        ~source_id:source.id
        ~package_id:(package_id package)
        ~name
    in
    match Skill_catalog_snapshot.find_exact snapshot identity with
    | Some entry -> Skill_catalog_snapshot.entry_reference entry
    | None -> fail "Skill snapshot fixture entry absent"
  in
  snapshot, exact "review" "review", exact "global" "global"
;;

let resolve_for_task snapshot ~task_id references =
  match Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id references with
  | Ok selection -> selection
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
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

let make_context ?(task_selection = Keeper_task_skill_turn.empty) ~trace_id () =
  match
    Recorder.make
      ~trace_id
      ~runtime_id:(fun () -> Some "test.runtime")
      ~turn_ref:
        (Ids.Turn_ref.make
           ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
           ~absolute_turn:3)
      ~snapshot_revision
      ~task_selection
  with
  | Ok context -> context
  | Error error -> fail (Recorder.error_to_string error)
;;

let test_held_only_and_session_origins_are_derived_from_exact_refs () =
  with_session @@ fun config trace_id ->
  let snapshot, task_reference, session_reference = task_snapshot () in
  let task_selection =
    resolve_for_task snapshot ~task_id:"task-held" [ task_reference ]
  in
  let context =
    make_context ~trace_id ~task_selection ()
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
           { origin = Ledger.Task_instruction { task_ids }; _ }
       ; Ledger.Composition_invocation
           { origin = Ledger.Session_composition; tool_name }
       ] ->
       check (list string) "held Task origin" [ "task-held" ]
         (Ledger.task_id_set_to_list task_ids
          |> List.map Keeper_id.Task_id.to_string);
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

let test_shared_reference_keeps_all_task_ids () =
  with_session @@ fun config trace_id ->
  let snapshot, shared_reference, _ = task_snapshot () in
  let task_selection =
    Keeper_task_skill_turn.merge
      [ resolve_for_task snapshot ~task_id:"task-b" [ shared_reference ]
      ; resolve_for_task snapshot ~task_id:"task-a" [ shared_reference ]
      ]
  in
  let context = make_context ~trace_id ~task_selection () in
  (match
     Recorder.record_instruction
       ~config
       context
       ~invocation:(invocation "call-shared-instruction")
       ~content:(Recorder.Body "shared body")
       shared_reference
   with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  (match
     Recorder.record_composition
       ~config
       context
       ~invocation:(invocation "call-shared-composition")
       ~tool_name:"keeper_compose_shared"
       shared_reference
   with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  let expected = [ "task-a"; "task-b" ] in
  let strings task_ids =
    Ledger.task_id_set_to_list task_ids |> List.map Keeper_id.Task_id.to_string
  in
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    (match Ledger.activations ledger with
     | [ { invocation =
             Ledger.Instruction_invocation
               { origin = Ledger.Task_instruction { task_ids }; _ }
         ; _
         }
       ; { invocation =
             Ledger.Composition_invocation
               { origin = Ledger.Task_composition { task_ids = composition_ids }
               ; _
               }
         ; _
         }
       ] ->
       check (list string) "instruction Task set" expected (strings task_ids);
       check (list string) "composition Task set" expected
         (strings composition_ids)
     | _ -> fail "shared exact reference lost merged Task provenance")
;;

let test_invalid_task_scope_fails_closed () =
  let trace_id = trace_id "trace-recorder" in
  let snapshot, task_reference, _ = task_snapshot () in
  let task_selection = resolve_for_task snapshot ~task_id:"" [ task_reference ] in
  match
    Recorder.make
      ~trace_id
      ~runtime_id:(fun () -> Some "test.runtime")
      ~turn_ref:
        (Ids.Turn_ref.make ~trace_id:"trace-recorder" ~absolute_turn:1)
      ~snapshot_revision
      ~task_selection
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
    make_context ~trace_id ()
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
      ~task_selection:Keeper_task_skill_turn.empty
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
        ~task_selection:Keeper_task_skill_turn.empty
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
        ~task_selection:Keeper_task_skill_turn.empty
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

(* #31081 review P1: a long-lived Keeper's delivery sits at a high MASC
   agent-core turn while a fresh official CLI session restarts its own claim
   counter at 1. The ledger compares an action's turn against the delivery's
   agent-core turn, so native actions must carry the delivery boundary's turn —
   never the CLI session counter. The repaired shape records; the pre-repair
   shape (session counter 1 below delivery turn 7) is a typed rejection that
   the ledger persists append-only instead of silently dropping. *)
let test_native_action_uses_the_delivery_turn_axis () =
  with_session @@ fun config trace_id ->
  let snapshot, task_reference, _session_reference = task_snapshot () in
  let task_selection =
    resolve_for_task snapshot ~task_id:"task-held" [ task_reference ]
  in
  let context = make_context ~trace_id ~task_selection () in
  let body = "task body" in
  (match
     Recorder.record_instruction
       ~config
       context
       ~invocation:(invocation "call-native")
       ~content:(Recorder.Body body)
       task_reference
   with
   | Ok _ -> ()
   | Error error -> fail (Recorder.error_to_string error));
  let receipts =
    [ Keeper_skill_activation_ledger.
        { tool_use_id = "call-native"
        ; content_bytes = String.length body
        ; content_sha256 = Digestif.SHA256.(digest_string body |> to_hex)
        }
    ]
  in
  let delivery_turn = 7 in
  let delivered =
    match
      Recorder.observe_delivery
        ~config
        context
        ~tool_results:receipts
        ~boundary:
          (Keeper_skill_activation_ledger.Official_client_result_handoff
             { agent_core_turn = delivery_turn })
        ~runtime_id:"test.runtime"
    with
    | Ok delivered -> delivered
    | Error error -> fail (Recorder.error_to_string error)
  in
  check (list string) "handoff delivers the served id" [ "call-native" ] delivered;
  (match
     Recorder.observe_native_action
       ~config
       context
       ~active_skill_tool_use_ids:delivered
       ~runtime_id:"test.runtime"
       ~agent_core_turn:delivery_turn
       ~identity:(Runtime_native_tools.Call_id "native-call-1")
       ~tool_name:"shell"
   with
   | Ok recorded -> check int "delivery-axis native action records" 1 recorded
   | Error error -> fail (Recorder.error_to_string error));
  (match
     Recorder.observe_native_action
       ~config
       context
       ~active_skill_tool_use_ids:delivered
       ~runtime_id:"test.runtime"
       ~agent_core_turn:1
       ~identity:(Runtime_native_tools.Call_id "native-call-2")
       ~tool_name:"shell"
   with
   | Ok _ -> fail "a CLI session counter below the delivery turn was accepted"
   | Error _ -> ());
  match Ledger.load ~config ~trace_id with
  | Error error -> fail (Ledger.store_error_to_string error)
  | Ok ledger ->
    (match Ledger.activations ledger with
     | [ activation ] ->
       check int "one action attached on the delivery axis" 1
         (List.length activation.actions)
     | _ -> fail "activation cardinality changed");
    let summary = Ledger.summarize ledger in
    check int "the rejected axis mismatch stays append-only" 1
      summary.invalid_transitions
;;

let () =
  run
    "keeper Skill activation recorder"
    [ ( "recording"
      , [ test_case "held-only exact ref keeps Task origin" `Quick
            test_held_only_and_session_origins_are_derived_from_exact_refs
        ; test_case "shared exact ref keeps every Task id" `Quick
            test_shared_reference_keeps_all_task_ids
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
        ; test_case "native action rides the delivery turn axis" `Quick
            test_native_action_uses_the_delivery_turn_axis
        ] )
    ]
;;
