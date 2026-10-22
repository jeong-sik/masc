(* Actual Owner admission, retained checkpoint bytes and SQLite restart.
   Checkpoints below are full fixtures, not provider/Core execution evidence.
   Independent work explicitly prepares a fresh Context; this does not exercise
   AgentRun's production canonical-checkpoint fallback. *)
open Alcotest
open Masc
module Owner = Keeper_owner
module Journal = Keeper_chat_operation_store
module Semantic = Keeper_semantic_execution
module Runtime_scope = Keeper_repetition_scope.Execution
module Frame = Keeper_repetition_snapshot
module Scope = Keeper_execution_scope_id
module Core = Agent_core
module Physical = Keeper_checkpoint_store
let value = function Ok value -> value | Error detail -> fail detail
let owner_value result = result |> Result.map_error Owner.error_to_string |> value
let journal_value result = result |> Result.map_error Journal.error_to_string |> value
let semantic_value result = result |> Result.map_error Journal.semantic_error_to_string |> value
let frame_value result = result |> Result.map_error Frame.error_to_string |> value
let hash text = Digestif.SHA256.(digest_string text |> to_hex)
let source text = Semantic.source_member ~post_id:text ~admitted_revision:1L
    ~checkpoint_retentions:0 ~source_sha256:(hash text) |> value
let ran = function
  | Ok (`Ran value) -> value
  | Ok (`Busy _ | `Interrupted) -> fail "original Owner child did not run"
  | Error error -> fail (Owner.error_to_string error)
let refused label = function
  | Error (Owner.Operation_rejected (Journal.Invalid_input _)) -> ()
  | Ok _ | Error _ -> fail label
let with_root f =
  let root=Filename.temp_dir "autonomous-owner-journal-" "" in
  Fun.protect ~finally:(fun () ->
    Journal.For_testing.clear_commit_fault ();
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () -> f root)
let meta () = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name",`String "autonomous-owner";"trace_id",`String "autonomous-owner-trace";
    "activation_mode",`String "manual"]) |> value
let path root = Filename.concat root Journal.database_file
let with_owner root f =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let meta=meta () in
  let owner=Owner.start ~sw ~store:{replace=(fun _ -> Ok ());remove=(fun _ -> Ok ())}
      ~operation_store_path:(path root) ~session_root:root ~now:(fun () -> 50.)
      ~operation_runner:None ~on_turn_slot_released:None
      ~keeper_name:meta.name ~initial_meta:(Some meta) |> owner_value in
  f owner meta sw
let read root f =
  let journal=Journal.open_or_create ~path:(path root) |> journal_value in
  Fun.protect ~finally:(fun () -> Journal.close journal |> journal_value)
    (fun () -> f journal)
let get root scope = read root (fun journal ->
  Journal.semantic_get journal scope |> semantic_value |> Option.get)
let checkpoint context : Core.Checkpoint.t =
  {version=Core.Checkpoint.checkpoint_version;session_id="autonomous-owner-trace";
   agent_name="autonomous-owner";model="owner-fixture";system_prompt=Some "original system";
   messages=[Core.Types.user_msg "original source"];usage=Core.Types.empty_usage;
   turn_count=2;created_at=10.;tools=[];tool_choice=Some Core.Types.Auto;
   disable_parallel_tool_use=true;temperature=None;top_p=None;top_k=None;min_p=None;
   enable_thinking=None;preserve_thinking=None;response_format=Core.Types.Off;
   reasoning_effort=None;cache_system_prompt=true;context;mcp_sessions=[];
   working_context=Some (`Assoc ["original",`Bool true]);
   pending_input=Some {run_id="original-run";request={request_id="original-request";
     participant_name=Some "operator";question="Original question?";
     schema=Some (`Assoc ["type",`String "string"]);timeout_s=None;created_at=10.}}}
let prepare execution =
  let context=Core.Context.create_sync () in
  let unrelated=Scope.autonomous_admission
      (Uuidm.of_string "00000000-0000-4000-8000-000000000091" |> Option.get) in
  let frame=Frame.admit Frame.empty (Frame.Fresh unrelated) |> frame_value in
  Keeper_repetition_scope.save context frame;
  let calls=Runtime_scope.prepare execution ~source:(Core.Context.create_sync ()) ~target:context |> frame_value in
  check int "fresh execution does not inherit other scopes' calls" 0 (List.length calls);
  Runtime_scope.observe execution ~target:context
    {Keeper_tool_call_detail.tool_name="observe-original";provider="fixture";
     execution_outcome=Tool_result.Ok;typed_outcome=None;latency_ms=0.;
     task_id=None;route_evidence=None;input_fingerprint=None;output_fingerprint=None};
  context
let retain root (checkpoint:Core.Checkpoint.t) =
  let trace_id=Keeper_id.Trace_id.of_string checkpoint.Core.Checkpoint.session_id |> value in
  let session_dir=Filename.concat root checkpoint.session_id in
  if not (Sys.file_exists session_dir) then Unix.mkdir session_dir 0o700;
  let snapshot=Physical.exact_snapshot_of_value ~expected_session_id:trace_id checkpoint
    |> Result.map_error Physical.checkpoint_ref_load_error_to_string |> value in
  Physical.retain_exact_snapshot ~session_dir snapshot |> Physical.require_confirmed_installation
  |> function Ok reference -> reference | Error _ -> fail "full checkpoint retention was unconfirmed"
let created = function
  | Journal.Semantic_created execution -> execution
  | Semantic_existing _ -> fail "existing admission is observation, not fresh dispatch"
let waiting execution = match execution.Semantic.phase with
  | Semantic.Recovering {origin=Semantic.Input_wait waiting;_} -> Some waiting
  | _ -> None
let start owner execution text =
  Owner.start_autonomous_execution owner ~execution ~input:(`String text)
    ~sources:[source text] |> owner_value |> created

let test_wait_restart_and_independent_work () = with_root @@ fun root ->
  let scope,bytes,reference,old_execution,old_writer=with_owner root (fun owner meta _sw ->
    Owner.run_autonomous_if_idle owner (fun execution ->
      let context=prepare execution in
      let writer=Owner.begin_input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_value in
      let uuid=Scope.to_json (Runtime_scope.scope execution)
        |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string
        |> Uuidm.of_string |> Option.get in
      let forged=Runtime_scope.autonomous_admission uuid in
      refused "equal scope value forged the Owner-issued execution object"
        (Owner.start_autonomous_execution owner ~execution:forged ~input:(`String "original-A")
          ~sources:[source "original-A"]);
      let admitted=start owner execution "original-A" in
      refused "writer captured before admission bypassed the journal"
        (Owner.advance_autonomous_input_checkpoint owner ~writer
          ~checkpoint:(retain root (checkpoint context)));
      let payload=checkpoint context in
      let foreign=retain root {payload with context=Core.Context.create_sync ()} in
      refused "retained bytes without the original active scope became a wait"
        (Owner.park_autonomous_input_wait owner ~execution ~writer ~checkpoint:foreign);
      let reference=retain root payload in
      let writer=Owner.park_autonomous_input_wait owner ~execution ~writer ~checkpoint:reference |> owner_value in
      refused "duplicate wait became a new acceptance"
        (Owner.park_autonomous_input_wait owner ~execution ~writer ~checkpoint:reference);
      refused "completion consumed parked pending input"
        (Owner.finish_autonomous_execution owner ~execution ~ending:Journal.Autonomous_completed);
      let parked=get root admitted.id in
      check int "journal stores only original scope" 1 (List.length (Frame.scope_ids parked.frame));
      check int "journal stores original observation" 1
        (Frame.observations parked.frame ~scope:admitted.id |> frame_value |> List.length);
      check bool "frame and input wait codec remain coherent" true
        (Result.is_ok (Semantic.of_json (Semantic.to_json parked)));
      admitted.id,Core.Checkpoint.to_string payload,reference,execution,writer) |> ran) in
  let parked=get root scope in
  check bool "normal child exit preserves pending input" true (Option.is_some (waiting parked));
  with_owner root (fun owner meta _sw ->
    refused "outside caller borrowed original execution"
      (Owner.start_autonomous_execution owner ~execution:old_execution ~input:(`String "original-A")
         ~sources:[source "original-A"]);
    refused "outside caller reused old writer"
      (Owner.park_autonomous_input_wait owner ~execution:old_execution ~writer:old_writer ~checkpoint:reference);
    check bool "Owner restart preserves complete wait" true
      (Yojson.Safe.equal (Semantic.to_json parked) (Semantic.to_json (get root scope)));
    let canonical=Core.Checkpoint.of_string bytes |> Result.map_error Core.Error.to_string |> value in
    let canonical={canonical with pending_input=None;turn_count=9;
      messages=[Core.Types.user_msg "unrelated canonical history"]} in
    Physical.save_agent_core_classified ~session_dir:(Filename.concat root canonical.session_id)
      ~history_retained:0 canonical |> value |> ignore;
    let b,seed=Owner.run_autonomous_if_idle owner (fun execution ->
      ignore (prepare execution);
      refused "fresh child borrowed old execution object"
        (Owner.start_autonomous_execution owner ~execution:old_execution ~input:(`String "original-A")
          ~sources:[source "original-A"]);
      refused "fresh execution stole original A source"
        (Owner.start_autonomous_execution owner ~execution ~input:(`String "original-B")
          ~sources:[source "original-A"]);
      let admitted=start owner execution "original-B" in
      let seed=Owner.capture_autonomous_input_seed owner ~execution |> owner_value in
      refused "same child recaptured seed after admission"
        (Owner.capture_autonomous_input_seed owner ~execution);
      let selected=match Owner.autonomous_input_seed_history seed with
        | Physical.Saved_history checkpoint -> checkpoint
        | No_saved_history | Saved_history_superseded _ -> fail "original retained history was not selected" in
      let original=Core.Checkpoint.of_string bytes |> Result.map_error Core.Error.to_string |> value in
      check string "B seed preserves all original fields except pending; canonical is not a fallback"
        (Core.Checkpoint.to_string {original with pending_input=None}) (Core.Checkpoint.to_string selected);
      Core.Context.set selected.context "seed-caller-mutation" (`Bool true);
      let untouched=match Owner.autonomous_input_seed_history seed with
        | Physical.Saved_history checkpoint -> Core.Context.get checkpoint.context "seed-caller-mutation"
        | No_saved_history | Saved_history_superseded _ -> fail "seed changed history kind" in
      check bool "seed getter owns a separate mutable context" true (untouched=None);
      let bound=Owner.bind_autonomous_input_seed owner ~seed |> owner_value in
      check bool "B writer retains original W predecessor" true
        (Option.equal Keeper_checkpoint_ref.equal (Some reference) (Owner.input_checkpoint_reference bound));
      refused "seed writer bypassed the original typed publication guard"
        (Owner.advance_autonomous_input_checkpoint owner ~writer:bound ~checkpoint:reference);
      Owner.finish_autonomous_execution owner ~execution ~ending:Journal.Autonomous_completed |> owner_value |> ignore;
      admitted.id,seed) |> ran in
    refused "escaped seed was rebound outside its inherited child"
      (Owner.bind_autonomous_input_seed owner ~seed);
    check bool "B has its own original identity" false (Scope.equal scope b);
    Owner.run_autonomous_if_idle owner (fun execution ->
      ignore (prepare execution);
      ignore (start owner execution "original-B");
      Owner.finish_autonomous_execution owner ~execution ~ending:Journal.Autonomous_completed |> owner_value |> ignore)
    |> ran;
    check bool "completed B frees only B sources" true
      (Yojson.Safe.equal (Semantic.to_json parked) (Semantic.to_json (get root scope)));
    check bool "B does not replace global A wait" true
      (Owner.input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_value=Journal.Input_observed reference);
    let session_dir=Filename.concat root (Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
    let retained=Physical.load_retained_exact_snapshot ~session_dir ~reference
      |> function Ok snapshot -> snapshot | Error _ -> fail "original wait bytes lost" in
    check string "full original wait bytes remain pinned" bytes
      (Physical.exact_snapshot_checkpoint retained |> Core.Checkpoint.to_string))

let test_unsettled_exit () = with_root @@ fun root ->
  let id=with_owner root (fun owner _ _sw ->
    Owner.run_autonomous_if_idle owner (fun execution ->
      ignore (prepare execution);
      (start owner execution "unfinished").id) |> ran) in
  let observed=get root id in
  check bool "physical callback return is not semantic completion" true
    (match observed.phase with Semantic.Recovering {origin=Semantic.Interrupted_execution;_} -> true | _ -> false);
  with_owner root (fun owner _ _sw ->
    Owner.run_autonomous_if_idle owner (fun execution ->
      ignore (prepare execution);
      ignore (start owner execution "independent");
      Owner.finish_autonomous_execution owner ~execution ~ending:Journal.Autonomous_completed |> owner_value |> ignore)
    |> ran)

let test_wait_commit_uncertainty after_commit () = with_root @@ fun root ->
  let id,reference=with_owner root (fun owner meta _sw ->
    Owner.run_autonomous_if_idle owner (fun execution ->
      let context=prepare execution in
      let writer=Owner.begin_input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_value in
      let admitted=start owner execution "uncertain-A" in
      let reference=retain root (checkpoint context) in
      Journal.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
      (match Owner.park_autonomous_input_wait owner ~execution ~writer ~checkpoint:reference with
       | Error _ -> () | Ok _ -> fail "uncertain commit returned acceptance");
      admitted.id,reference) |> ran) in
  with_owner root (fun owner meta _sw ->
    check bool "restart observes actual wait commit" after_commit (Option.is_some (waiting (get root id)));
    check bool "global input and semantic wait agree after uncertainty" true
      (Owner.input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_value=
        if after_commit then Journal.Input_observed reference else Journal.Input_unobserved))

let test_checkpoint_and_exception_boundaries () = with_root @@ fun root ->
  let suspended,reference=with_owner root (fun owner _ _sw ->
    Owner.run_autonomous_if_idle owner (fun execution ->
      let context=prepare execution in
      let admitted=start owner execution "checkpointed" in
      let full=checkpoint context in
      let pending=retain root full in
      refused "typed checkpoint outcome hid a pending request"
        (Owner.finish_autonomous_execution owner ~execution ~ending:(Journal.Autonomous_checkpointed pending));
      let reference=retain root {full with pending_input=None} in
      Owner.finish_autonomous_execution owner ~execution ~ending:(Journal.Autonomous_checkpointed reference)
      |> owner_value |> ignore;
      admitted.id,reference) |> ran) in
  check bool "physical exit preserves explicit retained checkpoint" true
    ((get root suspended).phase=Semantic.Suspended reference);
  let original=ref None in
  (try with_owner root (fun owner meta _sw ->
     Owner.run_autonomous_if_idle owner (fun execution ->
       let context=prepare execution in
       let writer=Owner.begin_input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_value in
       let admitted=start owner execution "exception-wait" in
       let reference=retain root (checkpoint context) in
       Owner.park_autonomous_input_wait owner ~execution ~writer ~checkpoint:reference |> owner_value |> ignore;
       original:=Some admitted.id;
       raise Exit) |> ran)
   with Exit -> ());
  check bool "child exception after wait publication cannot erase the wait" true
    (Option.is_some (waiting (get root (Option.get !original))))

let test_interrupt_survives_settlement_failure () = with_root @@ fun root ->
  with_owner root (fun owner _ sw ->
    let started,resolve_started=Eio.Promise.create () in
    let finished,finish=Eio.Promise.create () in
    let never,_=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let result=Owner.run_autonomous_if_idle owner (fun execution ->
        ignore (prepare execution);
        ignore (start owner execution "interrupt");
        Eio.Promise.resolve resolve_started ();
        Fun.protect ~finally:(fun () ->
          Journal.For_testing.fail_next_commit Fail_before_commit)
          (fun () -> Eio.Promise.await never)) in
      Eio.Promise.resolve finish result);
    Eio.Promise.await started;
    let flight=Owner.turn_in_flight owner |> Option.get in
    ignore (Owner.pause_and_interrupt owner (Owner.Observed_turn
      {interrupt_token=flight.interrupt_token}) |> owner_value);
    check bool "original operator interruption remains distinct from store failure" true
      (match Eio.Promise.await finished with Ok `Interrupted -> true | _ -> false);
    check bool "separate settlement failure remains observable" true
      (Owner.operation_projection owner).store_unavailable)

let test_registry_producer_wait () = with_root @@ fun root ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  let workspace=Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "owner-journal-test"));
  let meta=meta () in
  Keeper_meta_store.replace_snapshot workspace meta |> value;
  ignore (Keeper_registry.For_testing.register ~base_path:root meta.name meta);
  Eio.Switch.on_release sw (fun () -> Keeper_registry.For_testing.clear ());
  Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
    ~on_turn_slot_released:None workspace
  |> Result.map_error Keeper_owner_registry.install_error_to_string |> value |> ignore;
  let registry_value result=result |> Result.map_error Keeper_owner_registry.command_error_to_string |> value in
  let owner=Keeper_owner_registry.get ~base_path:root ~keeper_name:meta.name
    |> Result.map_error Keeper_owner_registry.lookup_error_to_string |> value in
  let session_dir=Filename.concat (Keeper_fs.session_store_path workspace)
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 Eio.Path.(env#fs / session_dir);
  let ctx : _ Keeper_types_profile.context =
    {config=workspace;agent_name="original-source-intake";sw;clock=env#clock;
     proc_mgr=None;net=None;publication_recovery_provider=
       Masc_test_deps.non_runtime_publication_recovery_provider} in
  let intake owned_sources = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~owned_sources ~meta_after_triage:meta ~pending_board_events:[] in
  let idle=intake (Error "ownership store unavailable") in
  check bool "empty queue does not gate unrelated cadence on ownership read" true
    (idle.event_queue_intake_error=None && Keeper_heartbeat_source_batch.count idle.source_batch=0);
  let stimulus post_id arrived_at : Keeper_event_queue.stimulus =
    {post_id;arrived_at;urgency=Keeper_event_queue.Normal;payload=Keeper_event_queue.Bootstrap} in
  List.iter (fun source -> Keeper_registry_event_queue.enqueue_durable_result
    ~base_path:root meta.name source |> value) [stimulus "original-source-A" 1.;stimulus "independent-source-B" 2.];
  let selections () = Keeper_registry_event_queue.pending_selections_result ~base_path:root meta.name |> value in
  let original=List.find (fun (selection:Keeper_event_queue_state.pending_selection) ->
    selection.source.post_id="original-source-A") (selections ()) in
  let original_sources=Keeper_heartbeat_source_batch.semantic_members
      (Keeper_heartbeat_source_batch.of_selections [original]) |> value in
  (Keeper_owner_registry.run_autonomous_if_idle ~base_path:root ~keeper_name:meta.name (fun execution ->
    let context=prepare execution in
    let producer=Keeper_input_checkpoint_producer.prepare ~base_path:root ~keeper_name:meta.name
        ~session_dir ~trace_id:meta.runtime.trace_id ~source:None
      |> Result.map_error Keeper_input_checkpoint_producer.error_to_string |> value in
    Keeper_owner_registry.start_autonomous_execution ~base_path:root ~keeper_name:meta.name
      ~execution ~input:(`String "producer-original") ~sources:original_sources
    |> registry_value |> created |> ignore;
    let payload=checkpoint context in
    (match Keeper_input_checkpoint_producer.publish_autonomous producer payload with
     | Error (Keeper_input_checkpoint_producer.Owner_failed _) -> ()
     | Error _ | Ok _ -> fail "ordinary Producer publication bypassed its journal admission");
    Keeper_input_checkpoint_producer.publish_autonomous_wait ~execution producer payload
    |> Result.map_error Keeper_input_checkpoint_producer.error_to_string |> value |> ignore;
    let reference=match Owner.input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_value with
      | Journal.Input_observed reference -> reference
      | Input_unobserved | Prior_input_unavailable -> fail "Producer wait has no committed input owner" in
    let retained=Physical.load_retained_exact_snapshot ~session_dir ~reference
      |> function Ok snapshot -> snapshot | Error _ -> fail "Producer retained bytes unavailable" in
    check string "Registry/Producer publishes exact full pending bytes"
      (Core.Checkpoint.to_string payload)
      (Physical.exact_snapshot_checkpoint retained |> Core.Checkpoint.to_string))
  |> registry_value |> function
  | `Ran () -> ()
  | `Busy _ | `Interrupted -> fail "Registry did not run original Producer child");
  let owned () = Keeper_owner_registry.reserved_sources ~base_path:root ~keeper_name:meta.name
      |> Result.map_error Keeper_owner_registry.command_error_to_string in
  let selected_ids observed = Keeper_heartbeat_source_batch.selections observed.Keeper_heartbeat_stimulus_intake.source_batch
      |> List.map (fun (selection:Keeper_event_queue_state.pending_selection) -> selection.source.post_id) in
  check (list string) "actual intake excludes A's wait and admits independent B"
    ["independent-source-B"] (selected_ids (intake (owned ())));
  ignore (Keeper_registry_event_queue.note_checkpoint_retention_result ~base_path:root meta.name
    ~selection:original () |> value);
  check (list string) "retention bookkeeping cannot re-admit original A"
    ["independent-source-B"] (selected_ids (intake (owned ())));
  let held=owned () |> value in
  let changed_revision={original with admitted_revision=Int64.succ original.admitted_revision} in
  let changed_snapshot={original with source={original.source with arrived_at=3.}} in
  List.iter (fun selection ->
    let batch=Keeper_heartbeat_source_batch.of_selections [selection] in
    let available=Keeper_heartbeat_source_batch.exclude_owned ~owned:held batch |> value in
    check int "different source incarnation or full snapshot remains eligible" 1
      (Keeper_heartbeat_source_batch.count available)) [changed_revision;changed_snapshot];
  let before=selections () in
  let unavailable=intake (Error "ownership primary unreadable") in
  check bool "unavailable ownership is an explicit failed intake" true
    (Option.is_some unavailable.event_queue_intake_error);
  check int "unavailable ownership admits no queue sources" 0
    (Keeper_heartbeat_source_batch.count unavailable.source_batch);
  check bool "intake never ACKs or mutates the parked original queue source" true
    (before=selections ());
  let b=List.find (fun (selection:Keeper_event_queue_state.pending_selection) ->
    selection.source.post_id="independent-source-B") (selections ()) in
  Keeper_owner_registry.run_autonomous_if_idle ~base_path:root ~keeper_name:meta.name (fun execution ->
    ignore (prepare execution);
    let sources=Keeper_heartbeat_source_batch.semantic_members
        (Keeper_heartbeat_source_batch.of_selections [b]) |> value in
    Keeper_owner_registry.start_autonomous_execution ~base_path:root ~keeper_name:meta.name
      ~execution ~input:(`String "registry-independent-B") ~sources |> registry_value |> created |> ignore;
    let seed=Keeper_owner_registry.capture_autonomous_input_seed ~base_path:root ~keeper_name:meta.name
        ~execution |> registry_value in
    (match Owner.autonomous_input_seed_history seed with
     | Physical.Saved_history checkpoint -> check bool "Registry seed is independent of A pending" true (checkpoint.pending_input=None)
     | No_saved_history | Saved_history_superseded _ -> fail "Registry lost retained A history");
    let bound=Keeper_owner_registry.bind_autonomous_input_seed ~base_path:root ~keeper_name:meta.name
        ~seed |> registry_value in
    check bool "Registry binding captures an existing retained global predecessor" true
      (Option.is_some (Owner.input_checkpoint_reference bound));
    Keeper_owner_registry.finish_autonomous_execution ~base_path:root ~keeper_name:meta.name
      ~execution ~ending:Journal.Autonomous_completed |> registry_value |> ignore)
  |> registry_value |> function
  | `Ran () -> ()
  | `Busy _ | `Interrupted -> fail "Registry did not run independent seed child"

let test_canonical_seed_observation () = with_root @@ fun root ->
  with_owner root (fun owner meta _sw ->
    let session_dir=Filename.concat root (Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
    Unix.mkdir session_dir 0o700;
    Owner.run_autonomous_if_idle owner (fun execution ->
      let context=prepare execution in
      ignore (start owner execution "fresh-independent");
      let seed=Owner.capture_autonomous_input_seed owner ~execution |> owner_value in
      (match Owner.autonomous_input_seed_history seed with
       | Physical.No_saved_history -> ()
       | Saved_history _ | Saved_history_superseded _ -> fail "absent canonical became saved history");
      let candidate={(checkpoint context) with pending_input=None} in
      Physical.save_agent_core_classified ~session_dir ~history_retained:0 candidate |> value |> ignore;
      refused "canonical appearing after capture borrowed newer history"
        (Owner.bind_autonomous_input_seed owner ~seed);
      refused "changed canonical permitted replacement seed in the same child"
        (Owner.capture_autonomous_input_seed owner ~execution);
      Owner.finish_autonomous_execution owner ~execution ~ending:Journal.Autonomous_completed |> owner_value |> ignore)
    |> ran;
    Owner.run_autonomous_if_idle owner (fun execution ->
      ignore (prepare execution);ignore (start owner execution "canonical-independent");
      let seed=Owner.capture_autonomous_input_seed owner ~execution |> owner_value in
      (match Owner.autonomous_input_seed_history seed with
       | Physical.Saved_history checkpoint -> check bool "canonical source has no pending input" true (checkpoint.pending_input=None)
       | No_saved_history | Saved_history_superseded _ -> fail "actual canonical history was not loaded");
      ignore (Owner.bind_autonomous_input_seed owner ~seed |> owner_value);
      let canonical_path=Physical.agent_core_checkpoint_path ~session_dir
          ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
      Fs_compat.save_file canonical_path "{";
      check bool "corrupt canonical remains a seed binding failure" true
        (Result.is_error (Owner.bind_autonomous_input_seed owner ~seed));
      Owner.finish_autonomous_execution owner ~execution ~ending:Journal.Autonomous_completed |> owner_value |> ignore)
    |> ran;
    Fs_compat.save_file (Physical.agent_core_checkpoint_path ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id))
      (Core.Checkpoint.to_string (checkpoint (Core.Context.create_sync ())));
    Owner.run_autonomous_if_idle owner (fun execution ->
      ignore (prepare execution);ignore (start owner execution "unowned-pending");
      refused "unowned canonical pending input was stripped for another invocation"
        (Owner.capture_autonomous_input_seed owner ~execution);
      Owner.finish_autonomous_execution owner ~execution ~ending:Journal.Autonomous_completed |> owner_value |> ignore)
    |> ran)

let () = run "autonomous Owner journal"
  ["original ownership",[
    test_case "full wait survives Owner restart and independent admitted work" `Quick test_wait_restart_and_independent_work;
    test_case "unsettled physical return reconciles rather than completing" `Quick test_unsettled_exit;
    test_case "retained checkpoint and later child exception preserve original authority" `Quick test_checkpoint_and_exception_boundaries;
    test_case "actual operator interruption survives journal settlement failure" `Quick test_interrupt_survives_settlement_failure;
    test_case "Registry and Producer publish the retained original wait" `Quick test_registry_producer_wait;
    test_case "canonical seed observations stay bound to the original physical child" `Quick test_canonical_seed_observation];
   "commit uncertainty",[
    test_case "precommit failure preserves both original relations" `Quick (test_wait_commit_uncertainty false);
    test_case "lost acknowledgement preserves actual wait and input" `Quick (test_wait_commit_uncertainty true)]]
