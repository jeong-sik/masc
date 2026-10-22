open Alcotest
open Masc
module Response = Keeper_input_wait_response
module Store = Keeper_checkpoint_store
module Core = Agent_core

let pending ~run_id ~request_id =
  Core.Agent_input_request.
    { run_id; request =
        { request_id; participant_name = Some "operator"; question = "Original question?"
        ; schema = None; timeout_s = Some 1.0; created_at = 1.0 } }

let source_checkpoint pending =
  let tool = Core.Types.tool_schema_of_params
      ~name:"retained-tool" ~description:"Retained schema" ~parameters:[] () in
  let context = Core.Context.create_sync () in
  Core.Context.set context "retained-entry" (`Assoc ["nested", `String "original"]);
  Core.Checkpoint.
    { version = checkpoint_version; session_id = "trace-input-response"
    ; agent_name = "input-response"; model = "opaque-runtime"
    ; system_prompt = Some "Retained system"
    ; messages = [Core.Types.
        {role=User; content=[Text "Retained history"]; name=None; tool_call_id=None
        ;metadata=["origin", `String "original"]}]
    ; usage = Core.Types.empty_usage; turn_count = 4; created_at = 10.0
    ; tools = [tool]; tool_choice = Some Core.Types.Auto
    ; disable_parallel_tool_use = true; temperature = Some 0.5
    ; top_p = Some 0.8; top_k = Some 20; min_p = Some 0.1
    ; enable_thinking = Some true; preserve_thinking = Some true
    ; response_format = Core.Types.Off; reasoning_effort = None
    ; cache_system_prompt = true; context
    ; mcp_sessions =
        [ Core.Mcp_session.
            { server_name="retained-server"; command="retained-command"
            ; args=["retained-argument"]; env=[]; http_base_url=None
            ; http_headers=[]; tool_schemas=[tool]; transport_kind=Stdio } ]
    ; working_context = Some (`Assoc ["retained", `Bool true])
    ; pending_input = Some pending }

let exact (checkpoint : Core.Checkpoint.t) =
  let trace = match Keeper_id.Trace_id.of_string checkpoint.Core.Checkpoint.session_id with
    | Ok trace -> trace | Error detail -> fail detail in
  match Store.exact_snapshot_of_value ~expected_session_id:trace checkpoint with
  | Ok snapshot -> snapshot
  | Error error -> fail (Store.checkpoint_ref_load_error_to_string error)

let prepare env source supplied response =
  Response.prepare ~net:env#net ~source
    ~expected_source_ref:(Store.exact_snapshot_reference source)
    ~pending:supplied ~response

let prepared = function Ok value -> value | Error _ -> fail "response candidate refused"

let test_canonical_response_preserves_complete_checkpoint () =
  Eio_main.run @@ fun env ->
  let owned = pending ~run_id:"run-a" ~request_id:"request-a" in
  let source = exact (source_checkpoint owned) in
  let original = Store.exact_snapshot_checkpoint source in
  let before = Core.Checkpoint.to_string original in
  let forged = {owned with request={owned.request with question="Forged question"}} in
  List.iter (fun response ->
    let candidate = prepare env source forged response |> prepared in
    let after = Response.checkpoint candidate in
    check bool "candidate consumes only its original wait" true (after.pending_input=None);
    let restored = {after with messages=original.messages; pending_input=original.pending_input} in
    check string "all other checkpoint fields are preserved" before
      (Core.Checkpoint.to_string restored);
    check string "original snapshot was not changed" before (Core.Checkpoint.to_string original);
    check bool "candidate retains the exact source witness" true
      (Keeper_checkpoint_ref.equal (Response.source_ref candidate)
         (Store.exact_snapshot_reference source));
    (match response with
     | Core.Hooks.Answer _ ->
       check bool "answer uses the canonical question" true
         (after.messages = original.messages @ [Core.Types.
           {role=User; content=[Text "[User input] Original question?: \"yes\""]
           ;name=None;tool_call_id=None;metadata=[]}])
     | Core.Hooks.Declined ->
       check bool "explicit decline preserves history and reports canonical question" true
         (after.messages = original.messages @ [Core.Types.user_msg "[Input declined] Original question?"])
     | Core.Hooks.Timeout ->
       check bool "explicit timeout is distinct and preserves original history" true
         (after.messages = original.messages @ [Core.Types.user_msg "[Input timed out] Original question?"]));
    match prepare env (exact after) owned response with
    | Error (Response.Input_not_current Core.Agent_input_request.No_pending_request) -> ()
    | Error (Source_changed _ | Input_checkpoint_failed _ | Input_not_current Request_not_current)
    | Ok _ -> fail "duplicate response was accepted")
    [Core.Hooks.Answer (`String "yes"); Core.Hooks.Declined; Core.Hooks.Timeout]

let test_stale_run_request_and_source_are_refused () =
  Eio_main.run @@ fun env ->
  let owned = pending ~run_id:"run-a" ~request_id:"request-a" in
  let source = exact (source_checkpoint owned) in
  List.iter (fun supplied ->
    match prepare env source supplied Core.Hooks.Declined with
    | Error (Response.Input_not_current Core.Agent_input_request.Request_not_current) -> ()
    | Error (Source_changed _ | Input_checkpoint_failed _ | Input_not_current No_pending_request)
    | Ok _ -> fail "a different run or request was accepted")
    [ {owned with run_id="run-b"}
    ; {owned with request={owned.request with request_id="request-b"}} ];
  let changed = exact {(Store.exact_snapshot_checkpoint source) with
    pending_input=Some (pending ~run_id:"run-b" ~request_id:"request-b")} in
  match Response.prepare ~net:env#net ~source:changed
      ~expected_source_ref:(Store.exact_snapshot_reference source)
      ~pending:owned ~response:Core.Hooks.Declined with
  | Error (Response.Source_changed actual) ->
    check bool "same-turn replacement returns the actual exact source" true
      (Keeper_checkpoint_ref.equal actual (Store.exact_snapshot_reference changed))
  | Error (Input_not_current _ | Input_checkpoint_failed _) | Ok _ ->
    fail "same-turn source replacement was not refused"

let test_autonomous_input_owner_rejects_lost_response_lineage () =
  let root = Filename.temp_dir "autonomous-input-owner-" "" in
  Fun.protect ~finally:(fun () -> Eio_main.run (fun env ->
    Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root))) @@ fun () ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "autonomous-input-test"));
  let original = source_checkpoint (pending ~run_id:"run-a" ~request_id:"request-a") in
  let keeper_name = original.agent_name in
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name",`String keeper_name;"trace_id",`String original.session_id;
    "activation_mode",`String "manual"]) |> prepared in
  Keeper_meta_store.replace_snapshot workspace meta |> prepared;
  Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
    ~on_turn_slot_released:None workspace |> prepared |> ignore;
  let owner = Keeper_owner_registry.get ~base_path:root ~keeper_name |> prepared in
  let session_dir = Filename.concat root original.session_id in
  Unix.mkdir session_dir 0o700;
  let accepted = ref None in
  let prepare source = Keeper_input_checkpoint_producer.prepare ~base_path:root ~keeper_name
      ~session_dir ~trace_id:meta.runtime.trace_id ~source in
  let refused_source label source = match prepare source with
    | Error (Keeper_input_checkpoint_producer.Source_changed | Source_missing) -> ()
    | Error _ | Ok _ -> fail label in
  (match Keeper_owner.run_autonomous_if_idle owner (fun () ->
     let producer = prepare None |> prepared in
     let producer = Keeper_input_checkpoint_producer.publish_autonomous producer original |> prepared in
     let candidate = Response.prepare ~net:env#net ~source:(exact original)
         ~expected_source_ref:(Store.exact_snapshot_reference (exact original))
         ~pending:(Option.get original.pending_input) ~response:(Core.Hooks.Answer (`String "production")) |> prepared in
     let consumed = Response.checkpoint candidate in
     ignore (Keeper_input_checkpoint_producer.publish_autonomous producer consumed |> prepared);
     accepted := Some consumed;
     refused_source "old wait was resurrected" (Some original);
     refused_source "missing source borrowed consumed evidence" None;
     refused_source "pending=None hid the missing accepted answer"
       (Some {original with pending_input=None});
     let progressed = {consumed with messages=consumed.messages @ [Core.Types.
       {role=Assistant;content=[Text "answer retained"];name=None;tool_call_id=None;metadata=[]}]} in
     ignore (prepare (Some progressed) |> prepared)) with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _ | `Interrupted) | Error _ -> fail "autonomous publication did not run");
  let reference = Keeper_owner.input_checkpoint owner ~trace_id:meta.runtime.trace_id |> prepared
    |> (function Keeper_chat_operation_store.Input_observed reference -> reference
      | Input_unobserved | Prior_input_unavailable -> fail "input owner was not observed") in
  let observed = Store.load_retained_exact_snapshot ~session_dir ~reference |> prepared
    |> Store.exact_snapshot_checkpoint in
  check bool "consumed payload remains authoritative after child settlement" true
    (observed.pending_input=None && observed.messages=(Option.get !accepted).messages);
  ignore (Keeper_owner.begin_stopping owner |> prepared)

let test_install_refuses_stale_nonhistory () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs env#fs;
  let root=Filename.temp_dir "input-response-stale-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  let owned=pending ~run_id:"original-run" ~request_id:"original-request" in
  let checkpoint=source_checkpoint owned in
  let operation_id=Keeper_chat_operation.Operation_id.of_string "original-response-operation" |> Result.get_ok in
  let scope=Keeper_execution_scope_id.direct_operation operation_id in
  let frame=Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
      (Keeper_repetition_snapshot.Fresh scope) |> Result.get_ok in
  Keeper_repetition_context.save checkpoint.context frame;
  let retained=exact checkpoint in
  let reference=Store.exact_snapshot_reference retained in
  let waiting=Keeper_semantic_execution.input_wait ~checkpoint:reference ~pending:owned |> Result.get_ok in
  let authority=Response.authorize ~session_root:root ~operation_id ~waiting ~destination:Keeper_semantic_execution.Canonical_input ~recorded:None in
  let session_dir=Filename.concat root checkpoint.session_id in
  Fs_compat.mkdir_p session_dir;
  ignore (Store.retain_exact_snapshot ~session_dir retained |> Store.require_confirmed_installation |> Result.get_ok);
  let candidates =
    [ (let context=Core.Context.copy checkpoint.context in
       Core.Context.delete context "retained-entry"; {checkpoint with context})
    ; {checkpoint with working_context=None}
    ; {checkpoint with tools=[]}
    ; {checkpoint with mcp_sessions=[]}
    ; {checkpoint with turn_count=checkpoint.turn_count+1} ] in
  List.iter (fun stale ->
    let canonical=Store.agent_core_checkpoint_path ~session_dir ~session_id:checkpoint.session_id in
    (match Fs_compat.save_file_atomic canonical (Core.Checkpoint.to_string stale) with
     | Ok () -> () | Error detail -> fail detail);
    let before=Fs_compat.load_file canonical in
    (match Response.prepare_installation ~net:env#net ~authority ~response:Core.Hooks.Declined with
     | Error (Response.Invalid_response _) -> ()
     | Error _ | Ok _ -> fail "stale nonhistory was accepted or misclassified");
    check string "refused response does not overwrite canonical evidence" before (Fs_compat.load_file canonical);
    let after=Store.load_retained_exact_snapshot ~session_dir ~reference |> Result.get_ok in
    check string "refused response preserves exact original retained bytes"
      (Store.exact_snapshot_canonical_bytes retained) (Store.exact_snapshot_canonical_bytes after)) candidates;
  let context=Core.Context.copy checkpoint.context in
  Core.Context.set_scoped context Session "message_count" (`Int (List.length checkpoint.messages));
  let canonical={checkpoint with Core.Checkpoint.context} in
  let path=Store.agent_core_checkpoint_path ~session_dir ~session_id:checkpoint.session_id in
  (match Fs_compat.save_file_atomic path (Core.Checkpoint.to_string canonical) with
   | Ok () -> () | Error detail -> fail detail);
  (* Unsorted nested objects must derive the same exact C after the response
     intent is supplied to fresh authority with a different answer key order. *)
  let answer=Core.Hooks.Answer (`Assoc ["z",`Int 2;"a",`Assoc ["n",`Int 1;"b",`String "yes"]]) in
  let replay_answer=Core.Hooks.Answer (`Assoc ["a",`Assoc ["b",`String "yes";"n",`Int 1];"z",`Int 2]) in
  let plan=match Response.prepare_installation ~net:env#net ~authority ~response:answer with
    | Ok plan -> plan | Error error -> fail (Response.installation_error_to_string error) in
  let intent=Response.planned_intent plan in
  check bool "preparation leaves canonical source unchanged" true
    (Keeper_checkpoint_ref.equal intent.source
      (Store.exact_snapshot_reference (Store.load_agent_core_exact_snapshot ~session_dir ~session_id:checkpoint.session_id |> Result.get_ok)));
  check bool "canonical source may differ from original W" false (Keeper_checkpoint_ref.equal intent.source waiting.checkpoint);
  List.iter (fun reference -> ignore (Store.load_retained_exact_snapshot ~session_dir ~reference |> Result.get_ok))
    [intent.source;intent.candidate];
  (* This physical-only fixture exercises the primitive. Actual intent journaling
     and fresh Owner recovery are exercised through HTTP/SQLite below. *)
  let receipt=match Response.install plan with
    | Ok receipt -> receipt | Error error -> fail (Response.installation_error_to_string error) in
  check bool "physical receipt stays bound to original authority" true (Response.belongs_to receipt authority);
  let consumed=Store.load_retained_exact_snapshot ~session_dir ~reference:(Response.installed_checkpoint receipt)
    |> Result.get_ok |> Store.exact_snapshot_checkpoint in
  check bool "physical Answer consumes original pending" true (consumed.pending_input=None);
  check int "physical Answer adds only canonical response" 2 (List.length consumed.messages);
  check bool "consumed derived count agrees with new history" true
    (Core.Context.get_scoped consumed.context Session "message_count"=Some (`Int 2));
  check bool "physical Answer keeps original working context tools and MCP" true
    (consumed.working_context=checkpoint.working_context && consumed.tools=checkpoint.tools
      && consumed.mcp_sessions=checkpoint.mcp_sessions);
  let fresh=Response.authorize ~session_root:root ~operation_id ~waiting ~destination:Keeper_semantic_execution.Canonical_input ~recorded:(Some intent) in
  check bool "old receipt cannot become fresh authority" false (Response.belongs_to receipt fresh);
  (match Response.prepare_installation ~net:env#net ~authority:fresh ~response:Core.Hooks.Timeout with
   | Error (Response.Invalid_response _) -> () | Error _ | Ok _ -> fail "recovery changed recorded response");
  let candidate_path=Filename.concat (Filename.concat session_dir Store.retained_dirname) (intent.candidate.sha256 ^ ".json") in
  let candidate_bytes=Fs_compat.load_file candidate_path in
  Fs_compat.save_file candidate_path "corrupt retained candidate";
  Fun.protect ~finally:(fun () -> Fs_compat.save_file candidate_path candidate_bytes) (fun () ->
    match Response.prepare_installation ~net:env#net ~authority:fresh ~response:replay_answer with
    | Error (Response.Retained_unavailable _) -> () | Error _ | Ok _ -> fail "corrupt recorded C was replaced from source");
  let recovered=Response.prepare_installation ~net:env#net ~authority:fresh ~response:replay_answer
    |> function Ok plan -> plan | Error error -> fail (Response.installation_error_to_string error) in
  let canonical_before=Store.load_agent_core_exact_snapshot ~session_dir ~session_id:checkpoint.session_id |> Result.get_ok in
  let changed={consumed with working_context=Some (`Assoc ["other",`Bool true])} in
  Fs_compat.save_file path (Core.Checkpoint.to_string changed);
  (match Response.install recovered with
   | Error (Response.Installation_unconfirmed _) -> () | Error _ | Ok _ -> fail "captured C CAS overwrote foreign canonical");
  Fs_compat.save_file path (Store.exact_snapshot_canonical_bytes canonical_before);
  let recovered=Response.prepare_installation ~net:env#net ~authority:fresh ~response:replay_answer
    |> function Ok plan -> plan | Error error -> fail (Response.installation_error_to_string error) in
  let receipt=Response.install recovered |> function Ok receipt -> receipt | Error error -> fail (Response.installation_error_to_string error) in
  check bool "fresh confirmed rewrite belongs only to fresh authority" true (Response.belongs_to receipt fresh);
  check bool "recovery installs the exact recorded candidate" true (Keeper_checkpoint_ref.equal intent.candidate (Response.installed_checkpoint receipt))

type branch_gate_case =
  | Retained_gate_source_missing
  | Gate_host_destination_unconfirmed
  | Gate_approved_replay
  | Gate_denied_resume

(* Actual physical files, SQLite and an independently executing Owner child
   publishing G through the real Producer. The fresh branch case also invokes
   the native adapter; the public response remains guarded while the complete
   recovery/finalization path is being connected. *)
let test_operation_response_preserves_producer_g ?(gate_case=None) ~canonical_intent ~fault () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  let root=Filename.temp_dir "branch-response-producer-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  let module Journal=Keeper_chat_operation_store in
  let module Semantic=Keeper_semantic_execution in
  let module Native=Keeper_native_call in
  let value=function Ok value -> value | Error detail -> fail detail in
  let journal_ok result=Result.map_error Journal.error_to_string result |> value in
  let physical result=Result.map_error Response.installation_error_to_string result |> value in
  let workspace=Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "branch-response-test"));
  let owned=pending ~run_id:"original-branch-run" ~request_id:"original-branch-question" in
  let original=source_checkpoint owned in
  let keeper_name=original.agent_name in
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_name;
    "trace_id",`String original.session_id;"activation_mode",`String "manual"]) |> value in
  Keeper_meta_store.replace_snapshot workspace meta |> value;
  let operation_id=Keeper_chat_operation.Operation_id.of_string "original-branch-response" |> value in
  let frame=Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
    (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation operation_id)) |> Result.get_ok in
  Keeper_repetition_context.save original.context frame;
  let session_dir=Keeper_types_support.keeper_session_dir workspace original.session_id in
  Fs_compat.mkdir_p session_dir;
  let canonical=Store.agent_core_checkpoint_path ~session_dir ~session_id:original.session_id in
  let save checkpoint = match Store.save_agent_core_classified ~session_dir ~history_retained:0 checkpoint with
    | Ok (Store.Saved _) -> () | Ok (Stale_noop _) | Error _ -> fail "physical canonical fixture was not installed" in
  let reference=Store.retain_exact_snapshot ~session_dir (exact original)
    |> Store.require_confirmed_installation |> Result.get_ok in
  save original;
  let waiting=Semantic.input_wait ~checkpoint:reference ~pending:owned |> value in
  let path=Journal.path_for_keeper ~keepers_runtime_dir:(Workspace.keepers_runtime_dir workspace) ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  let with_journal f =
    let journal=Journal.open_or_create ~path |> journal_ok in
    Fun.protect ~finally:(fun () -> Journal.For_testing.clear_commit_fault ();Journal.close journal |> journal_ok)
      (fun () -> f journal) in
  let operation,recorded,old_receipt=with_journal (fun journal ->
    Journal.submit journal ~now:1. ~operation_id ~source:(`Assoc []) ~input:(`String "original invocation") |> journal_ok |> ignore;
    let operation=Journal.claim_next journal ~now:2. |> journal_ok |> Option.get in
    let call_id="019a0010-1000-7000-8000-000000000051" in
    let locator=Core.Agent.execution_locator_of_yojson (`Assoc ["version",`Int 1;"run_id",`String "execution-run-original-branch-response"]) |> value in
    let call=Native.create ~call_id ~runtime_id:"native.primary" ~operation_digest:operation.execution_digest
      ~api:Native.Continue_from_checkpoint ~seed_checkpoint:reference ~locator |> value in
    Journal.update_direct_native_call journal ~now:3. ~operation_id ~execution_digest:operation.execution_digest
      (Native.Bind {observed=Native.No_native_call;call}) |> journal_ok;
    Journal.update_direct_input_checkpoint journal ~now:4. ~operation_id ~execution_digest:operation.execution_digest
      ~call_id ~observed:reference ~observed_input:None ~checkpoint:reference |> journal_ok |> ignore;
    Journal.update_direct_native_call journal ~now:5. ~operation_id ~execution_digest:operation.execution_digest
      (Native.Terminal {call_id;disposition={Core.Agent.outcome=Core.Agent.Terminal_succeeded;recovery=Core.Agent.Retire}}) |> journal_ok;
    Journal.defer_direct_input_wait journal ~now:6. ~operation_id ~execution_digest:operation.execution_digest ~waiting |> journal_ok |> ignore;
    if not canonical_intent then operation,None,None else
    let source={original with Core.Checkpoint.messages=original.messages @ [Core.Types.assistant_msg "original operation later source"]} in
    save source;
    let authority=Response.authorize ~session_root:(Filename.dirname session_dir) ~operation_id ~waiting
      ~destination:Semantic.Canonical_input ~recorded:None in
    let plan=Response.prepare_installation ~net:env#net ~authority ~response:Core.Hooks.Declined |> physical in
    let intent=Response.planned_intent plan in
    Journal.prepare_direct_input_response journal ~now:7. ~operation_id ~execution_digest:operation.execution_digest ~intent |> journal_ok;
    let receipt=Response.install plan |> physical in
    operation,Some intent,Some receipt) in
  let newer_pending=pending ~run_id:"independent-global-run" ~request_id:"independent-global-question" in
  let newer_pending={newer_pending with request={newer_pending.request with question="Independent global question?"}} in
  let context=Core.Context.copy original.context in
  Core.Context.set context "independent-global-context" (`String "preserve this context");
  let independent=Keeper_execution_scope_id.autonomous_admission
    (Uuidm.of_string "00000000-0000-4000-8000-000000000009" |> Option.get) in
  let frame=Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
    (Keeper_repetition_snapshot.Fresh independent) |> Result.get_ok in
  Keeper_repetition_context.save context frame;
  let newer={original with Core.Checkpoint.context;turn_count=original.turn_count+1;
    messages=original.messages @ [Core.Types.assistant_msg "independent later history"];
    pending_input=Some newer_pending;working_context=Some (`Assoc ["independent",`Bool true])} in
  let newer_snapshot=exact newer in
  let g=Store.exact_snapshot_reference newer_snapshot in
  let g_payload_bytes=Store.exact_snapshot_canonical_bytes newer_snapshot in
  Eio.Switch.run (fun owner_sw ->
    Keeper_owner_registry.install_from_store ~sw:owner_sw ~operation_runner:None ~on_turn_slot_released:None workspace |> prepared |> ignore;
    let owner=Keeper_owner_registry.get ~base_path:root ~keeper_name |> prepared in
    (match Keeper_owner.run_autonomous_if_idle owner (fun () ->
       let producer=Keeper_input_checkpoint_producer.prepare ~base_path:root ~keeper_name ~session_dir
         ~trace_id:meta.runtime.trace_id ~source:(Some original) |> prepared in
       ignore (Keeper_input_checkpoint_producer.publish_autonomous producer newer |> prepared);
       save newer) with
     | Ok (`Ran ()) -> () | Ok (`Busy _ | `Interrupted) | Error _ -> fail "independent Producer did not publish G");
    (* The primitive fault scenarios below install their own sealed response.
       Public response and its actual continuation run in the shared native and
       admitted-Keeper fixtures, without this deliberate private setup. *)
    check bool "independent Producer preserves the original exact waiting operation" true
      (Option.equal Semantic.equal_input_wait (Some waiting) (Keeper_owner.direct_input_wait owner ~operation_id |> prepared));
    ignore (Keeper_owner.begin_stopping owner |> prepared));
  let g_bytes=Fs_compat.load_file canonical in
  let authority=Response.authorize ~session_root:(Filename.dirname session_dir) ~operation_id ~waiting
    ~destination:Semantic.Operation_input ~recorded in
  let plan=Response.prepare_installation ~net:env#net ~authority ~response:Core.Hooks.Declined |> physical in
  let branched=Response.planned_intent plan in
  (match recorded with
   | None -> check bool "fresh branch derives from exact retained W" true (Keeper_checkpoint_ref.equal reference branched.source)
   | Some prior ->
     check bool "promotion preserves original source and consumed candidate" true
       (Semantic.continues_input_response_intent ~previous:prior ~next:branched
         && Keeper_checkpoint_ref.equal prior.candidate branched.candidate));
  let check_g journal =
    check string "operation branch never rewrites canonical G" g_bytes (Fs_compat.load_file canonical);
    check bool "operation branch never replaces global input G" true
      (Journal.input_checkpoint journal ~trace_id:meta.runtime.trace_id |> journal_ok=Journal.Input_observed g);
    let retained=Store.load_retained_exact_snapshot ~session_dir ~reference:g |> Result.get_ok in
    check bool "G keeps other pending context and complete bytes" true
      (Store.exact_snapshot_canonical_bytes retained=g_payload_bytes) in
  with_journal (fun journal ->
    Journal.prepare_direct_input_response journal ~now:8. ~operation_id ~execution_digest:operation.execution_digest ~intent:branched |> journal_ok;
    let actual=Journal.direct_input_response_intent journal ~operation_id |> journal_ok |> Option.get in
    Option.iter (fun receipt -> check bool "old canonical receipt cannot match promoted destination" false
      (Semantic.equal_input_response_intent actual (Response.installed_intent receipt))) old_receipt;
    let receipt=Response.install plan |> physical in
    check bool "fresh branch receipt stays bound to its captured authority" true (Response.belongs_to receipt authority);
    (match fault with None -> () | Some fault -> Journal.For_testing.fail_next_commit fault);
    let result=Journal.resolve_direct_input_wait journal ~now:9. ~operation_id ~execution_digest:operation.execution_digest
      ~observed:waiting ~checkpoint:(Response.installed_checkpoint receipt) in
    (match fault,result with
     | None,Ok () -> () | Some _,Error (Journal.Store_unavailable _) -> ()
     | (Some _ | None),(Ok () | Error _) -> fail "branch resolution did not preserve actual commit uncertainty");
    Journal.For_testing.clear_commit_fault ();check_g journal);
  with_journal (fun journal ->
    check_g journal;
    let remaining=Journal.direct_input_wait journal ~operation_id |> journal_ok in
    (match remaining with
     | None -> ()
     | Some waiting ->
       let recorded=Journal.direct_input_response_intent journal ~operation_id |> journal_ok in
       let fresh=Response.authorize ~session_root:(Filename.dirname session_dir) ~operation_id ~waiting
         ~destination:Semantic.Operation_input ~recorded in
       let plan=Response.prepare_installation ~net:env#net ~authority:fresh ~response:Core.Hooks.Declined |> physical in
       let receipt=Response.install plan |> physical in
       Journal.resolve_direct_input_wait journal ~now:10. ~operation_id ~execution_digest:operation.execution_digest
         ~observed:waiting ~checkpoint:(Response.installed_checkpoint receipt) |> journal_ok);
    let branch=Journal.direct_input_branch journal ~operation_id |> journal_ok |> Option.get in
    check bool "reopened branch preserves exact original wait and consumed C" true
      (Semantic.equal_input_wait branch.origin waiting && Keeper_checkpoint_ref.equal branch.checkpoint branched.candidate);
    (match Journal.resolve_direct_input_wait journal ~now:11. ~operation_id ~execution_digest:operation.execution_digest
        ~observed:waiting ~checkpoint:branched.candidate with
     | Error _ -> () | Ok () -> fail "duplicate branch response was accepted");
    check_g journal);
  (* Exercise actual Owner child authority and the selected continuation. *)
  match canonical_intent,fault with
  | true,(Some _ | None) | false,Some _ -> ()
  | false,None ->
    match gate_case with
    | Some gate_case ->
      let module Gate=Keeper_direct_gate_continuation in
      ignore (Keeper_approval_queue.install_persistence ~base_path:root |> prepared);
      let gate_input=`Assoc ["capability",`String "web_search";
        "input",`Assoc ["query",`String "Original branch Gate evidence";"limit",`Int 1]] in
      let decision=match gate_case with
        | Gate_denied_resume -> Keeper_approval_queue_rules_types.Decision.Reject "Keep this original effect declined"
        | Retained_gate_source_missing | Gate_host_destination_unconfirmed | Gate_approved_replay ->
          Keeper_approval_queue_rules_types.Decision.Approve in
      let submission=Keeper_approval_queue.submit_pending ~base_path:root ~keeper_name
        ~tool_name:Keeper_gate.network_read_gate_operation ~input:gate_input
        ~call_summary:None ~origin:Keeper_approval_origin.unavailable () |> prepared in
      let observed=Keeper_approval_queue.observe_waiting_request ~base_path:root ~id:submission.approval_id
        |> prepared |> Option.get in
      let obligation=Semantic.gate_obligation ~approval_id:submission.approval_id
        ~tool_name:observed.waiting_request.tool_name ~input_hash:observed.waiting_request.input_hash |> value in
      let gate_wait=Semantic.gate_wait ~checkpoint:branched.candidate ~obligations:[obligation] |> value in
      with_journal (fun journal ->
        ignore (Journal.claim_next journal ~now:11. |> journal_ok |> Option.get);
        Journal.resume_direct_checkpoint journal ~now:12. ~operation_id
          ~observed:(Semantic.Agent_core branched.candidate) |> journal_ok;
        ignore (Journal.defer_direct_gate journal ~now:13. ~operation_id
          ~execution_digest:operation.execution_digest ~waiting:gate_wait |> journal_ok));
      let ready=ref false in
      let owner_cell=ref None in
      let result_cell=ref None in
      let settled,resolve_settled=Eio.Promise.create () in
      let owner_ok result=Result.map_error Keeper_owner.error_to_string result |> value in
      let execute ~sw:turn_sw ~keeper_name:_ ~claim =
        ready:=false;
        let result=try
          let (claimed:Keeper_chat_operation.t)=claim () |> owner_ok |> Option.get in
          check bool "Gate continuation belongs to the original branch child" true
            (Keeper_chat_operation.Operation_id.equal claimed.operation_id operation_id);
          let destination=Keeper_checkpoint_destination.capture_direct ~base_path:root ~keeper_name
            ~session_dir ~trace_id:meta.runtime.trace_id ~operation_id |> value in
          let checkpoint=Keeper_checkpoint_destination.current_checkpoint destination |> value |> Option.get in
          let retained_path=Store.retained_checkpoint_path ~session_dir branched.candidate in
          (match gate_case with
           | Retained_gate_source_missing -> Unix.rename retained_path (retained_path ^ ".held")
           | Gate_host_destination_unconfirmed ->
             (match Eio.Cancel.sub (fun cancellation ->
                Eio.Cancel.cancel cancellation (Failure "cancel Gate host destination");
                Keeper_checkpoint_destination.save destination checkpoint) with
              | exception Eio.Cancel.Cancelled _ -> ()
              | Ok _ | Error _ -> fail "cancelled Gate host save returned without cancellation")
           | Gate_approved_replay | Gate_denied_resume -> ());
          let loaded=Fun.protect ~finally:(fun () -> match gate_case with
            | Retained_gate_source_missing -> Unix.rename (retained_path ^ ".held") retained_path
            | Gate_host_destination_unconfirmed | Gate_approved_replay | Gate_denied_resume -> ())
            (fun () -> Gate.load ~config:workspace ~meta ~operation_id ~session_dir ~destination) in
          let owner=Option.get !owner_cell in
          (match gate_case with
          | Retained_gate_source_missing | Gate_host_destination_unconfirmed ->
          (match loaded with Error _ -> () | Ok _ -> fail "failed Gate admission authorized continuation");
          let state=Keeper_owner.direct_gate_state owner ~operation_id |> owner_ok |> Option.get in
          check bool "post-resume failure restores the exact original wait" true
            (Semantic.equal_gate_wait state.waiting gate_wait && state.resolution=None);
          check bool "Gate obligation survives post-resume failure" true
            (Keeper_owner.direct_gate_obligations owner ~operation_id |> owner_ok=[obligation]);
          check bool "failed Gate is pending rather than dispatchable" true
            (Gate.pending ~base_path:root ~keeper_name ~operation_id |> value
              =Some (Gate.Bound_checkpoint branched.candidate))
          | Gate_approved_replay | Gate_denied_resume ->
            let admission=loaded |> value |> Option.get in
            let checkpoint=Gate.checkpoint admission |> Option.get in
            let checkpoint=match gate_case with
              | Gate_denied_resume -> checkpoint
              | Gate_approved_replay ->
                let resolution=Gate.resolution admission in
                let grant=Keeper_gate.cycle_grant_of_resolution resolution |> Option.get in
                let publication_recovery={Keeper_publication_recovery_availability.keeper_name;
                  provider=Keeper_publication_recovery_availability.non_runtime_provider} in
                let replay ()=Keeper_gate_replay.replay_approved_effect ~config:workspace ~meta
                  ~publication_recovery ~turn_sandbox_factory:None ~grant ~approval_id:submission.approval_id () in
                let applied=Tool_misc.with_web_search_simulation_for_test
                  ~outcomes:["searxng",`Hits ["Original evidence","https://example.com/original-gate","Original branch replay evidence"]]
                  replay in
                let output_reference=function
                  | Keeper_gate_replay.Applied {output_ref;_} -> output_ref
                  | (Not_applicable | Applied_with_warning _ | Failed _ | Indeterminate _
                      | Repair_required _ | Resolution_absent _) as outcome -> fail (Keeper_gate_replay.outcome_to_string outcome) in
                let first=output_reference applied in
                let recovered=Tool_misc.with_web_search_simulation_for_test ~outcomes:[] replay |> output_reference in
                check bool "repeated Gate replay reads the same durable result without another network effect" true (first=recovered);
                check bool "original Gate grant is durably consumed" true
                  (Keeper_approval_queue.approved_resolution_state ~base_path:root ~id:submission.approval_id |> prepared
                    =Keeper_approval_queue_result.Resolution_consumed);
                let model=Keeper_gate_replay.user_message_with_hitl_resolution ~base_path:root
                  ~user_message:"Continue the original branch" (Some resolution) in
                let identity,message=Keeper_gate_replay.approval_input (Option.get model.replay_evidence)
                  |> Result.map_error Keeper_approval_input_admission.error_to_string |> value in
                Keeper_approval_input_checkpoint.admit_to_destination ~destination ~session_dir
                  ~identity ~message checkpoint |> value
              | Retained_gate_source_missing | Gate_host_destination_unconfirmed -> fail "Gate case changed during admission" in
            Gate.discharge ~config:workspace ~keeper_name ~operation_id
              ~user_message:"Continue the original branch" ~checkpoint admission |> value;
            check bool "only admitted original Gate evidence discharges its obligation" true
              (Keeper_owner.direct_gate_obligations owner ~operation_id |> owner_ok=[]);
            Runtime_agent_execution_runtime.initialize ~sw:turn_sw ~domain_mgr:env#domain_mgr ~domain_count:1
              |> Result.map_error Runtime_agent_execution_runtime.initialization_error_to_string |> value;
            let previous_catalog=Llm_provider.Model_catalog.global () in
            Eio.Switch.on_release turn_sw (fun () -> match previous_catalog with
              | None -> Llm_provider.Model_catalog.clear_global ()
              | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
            let catalog=Printf.sprintf
              "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" checkpoint.model in
            Llm_provider.Model_catalog.of_toml_string ~source:"original-branch-Gate-test" catalog |> value
              |> Llm_provider.Model_catalog.set_global;
            let reply=Yojson.Safe.to_string (`Assoc ["id",`String "original-Gate-native";"model",`String checkpoint.model;
              "choices",`List [`Assoc ["index",`Int 0;"message",`Assoc ["role",`String "assistant";
                "content",`String "original Gate continued"];"finish_reason",`String "stop"]];
              "usage",`Assoc ["prompt_tokens",`Int 1;"completion_tokens",`Int 1;"total_tokens",`Int 2]]) in
            let server=Exact_output_fixture.start_server ~sw:turn_sw ~net:env#net ~clock:env#clock
              (Exact_output_fixture.Reply reply) in
            let provider_cfg=Llm_provider.Provider_config.make ~kind:Llm_provider.Provider_config.OpenAI_compat
              ~provider_id:"fixture" ~model_id:checkpoint.model ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
            let native_config=Runtime_agent.default_config ~name:keeper_name ~provider_cfg
              ~system_prompt:"Continue the original Gate evidence." ~tools:[] in
            let native_config={native_config with context=Some checkpoint.context;session_id=Some original.session_id;
              checkpoint_sidecar=checkpoint.working_context;
              checkpoint_sink=Some (fun snapshot -> Keeper_checkpoint_destination.save destination snapshot.Core.Agent.checkpoint
                |> Result.map (fun _ -> ()))} in
            let binding:Keeper_direct_native_continuation.binding={base_path=root;keeper_name;operation_id;
              execution_digest=operation.execution_digest;session_dir;session_id=original.session_id;checkpoint_destination=destination} in
            let agent_ref=ref None in
            let prepared_native=Keeper_direct_native_continuation.prepare ~binding ~runtime_id:"native.primary"
              ~config:native_config ~agent_core_checkpoint:(Some checkpoint)
              ~input:Keeper_direct_native_continuation.Continue_from_checkpoint ~agent_ref () |> value in
            let continued=Keeper_direct_native_continuation.reconcile_after_dispatch binding (fun () ->
              Runtime_agent.continue_from_checkpoint ~sw:turn_sw ~net:env#net
                ~config:(Keeper_direct_native_continuation.config prepared_native) ~agent_ref
                ~checkpoint:(Keeper_direct_native_continuation.prepared_checkpoint prepared_native |> Option.get) ())
              |> Result.map_error Core.Error.to_string |> value in
            check string "actual native Gate continuation completes" "original Gate continued"
              (Core.Types.text_of_content continued.response.content);
            check int "Gate continuation dispatches once" 1 (Exact_output_fixture.post_count server);
            let expected_inputs=List.filter_map (fun (message:Core.Types.message) -> match message.role with
              | Core.Types.User -> Some (Core.Types.text_of_content message.content)
              | Assistant | System | Tool -> None) checkpoint.messages in
            List.iter (fun body ->
              let messages=Yojson.Safe.from_string body |> Yojson.Safe.Util.member "messages" |> Yojson.Safe.Util.to_list in
              List.iter (fun expected ->
                check bool "actual provider input preserves each original User and admitted Gate message" true
                  (List.exists (fun row -> Yojson.Safe.Util.member "role" row=`String "user"
                    && Yojson.Safe.Util.member "content" row=`String expected) messages)) expected_inputs)
              (Exact_output_fixture.request_bodies server);
            let final=Keeper_checkpoint_destination.current_checkpoint destination |> value |> Option.get in
            let final_ref=Store.exact_snapshot_reference (exact final) in
            ignore (Keeper_owner.defer_direct_checkpoint owner ~operation_id ~execution_digest:operation.execution_digest
              ~checkpoint:(Semantic.Agent_core final_ref) |> owner_ok));
          check string "Gate admission and native continuation preserve independent canonical G" g_bytes (Fs_compat.load_file canonical);
          Ok ()
        with exn -> Error exn in
        result_cell:=Some result;Keeper_owner.Operation_deferred in
      Eio.Switch.run (fun owner_sw ->
        let runner={Keeper_owner.ready=(fun ~keeper_name:_ -> !ready);execute;
          on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ -> Eio.Promise.resolve resolve_settled ())} in
        Keeper_owner_registry.install_from_store ~sw:owner_sw ~operation_runner:(Some runner)
          ~on_turn_slot_released:None workspace |> prepared |> ignore;
        let owner=Keeper_owner_registry.get ~base_path:root ~keeper_name |> prepared in
        owner_cell:=Some owner;
        Keeper_approval_queue.resolve_with_policy ~base_path:root ~id:submission.approval_id
          ~decision
          ~source:Keeper_approval_queue_rules_types.Auto_judge () |> prepared |> ignore;
        Gate.reconcile ~config:workspace ~meta |> value;
        ready:=true;Keeper_owner.wake_operation_drain owner |> owner_ok;
        Eio.Promise.await settled;
        (match !result_cell with Some (Ok ()) -> () | Some (Error exn) -> raise exn
          | None -> fail "original Gate child did not run");
        let operation=Keeper_owner.exact_operation owner operation_id |> owner_ok |> Option.get in
        check bool "Gate boundary retains the original operation" true (operation.state=Keeper_chat_operation.Queued);
        (match gate_case with
        | Retained_gate_source_missing | Gate_host_destination_unconfirmed ->
        Gate.reconcile ~config:workspace ~meta |> value;
        let state=Keeper_owner.direct_gate_state owner ~operation_id |> owner_ok |> Option.get in
        check bool "durable resolution can wake the same restored Gate" true
          (state.resolution=Some {Semantic.obligation;decision=Semantic.Gate_approved})
        | Gate_approved_replay | Gate_denied_resume ->
          check bool "admitted Gate continuation preserves no stale Gate wait" true
            (Keeper_owner.direct_gate_state owner ~operation_id |> owner_ok=None);
          check bool "actual Gate native result is a durable original continuation" true
            (Option.is_some (Keeper_owner.direct_checkpoint owner ~operation_id |> owner_ok)));
        ignore (Keeper_owner.begin_stopping owner |> owner_ok));
      with_journal (fun journal ->
        check_g journal;
        match gate_case with
        | Retained_gate_source_missing | Gate_host_destination_unconfirmed ->
        let state=Journal.direct_gate_state journal ~operation_id |> journal_ok |> Option.get in
        check bool "reopen retains the original Gate wait and obligation" true
          (Semantic.equal_gate_wait state.waiting gate_wait
            && state.resolution=Some {Semantic.obligation;decision=Semantic.Gate_approved})
        | Gate_approved_replay | Gate_denied_resume ->
          check bool "reopen retains original continuation and discharged Gate" true
            (Option.is_some (Journal.direct_checkpoint journal ~operation_id |> journal_ok)
              && (Journal.direct_gate_obligations journal ~operation_id |> journal_ok)=[]))
    | None ->
    let ready=ref false in
    let owner_cell=ref None in
    let writer_cell=ref None in
    let execution_result=ref None in
    let settled,resolve_settled=Eio.Promise.create () in
    let owner_ok result=Result.map_error Keeper_owner.error_to_string result |> value in
    let execute ~sw:turn_sw ~keeper_name:_ ~claim =
      ready:=false;
      let result = try
        let (claimed:Keeper_chat_operation.t)=claim () |> owner_ok |> Option.get in
        check bool "same original operation claims its branch" true
          (Keeper_chat_operation.Operation_id.equal claimed.operation_id operation_id);
        let owner=Option.get !owner_cell in
        let admission=Keeper_direct_checkpoint_continuation.load ~base_path:root ~keeper_name ~operation_id
            ~session_dir ~session_id:original.session_id |> value |> Option.get in
        let consumed=Keeper_direct_checkpoint_continuation.checkpoint admission |> Option.get in
        check bool "cooperative admission uses retained C, not independent G" true
          (Keeper_checkpoint_ref.equal (Store.exact_snapshot_reference (exact consumed)) branched.candidate);
        check string "branch loading preserves global canonical bytes" g_bytes (Fs_compat.load_file canonical);
        Keeper_direct_checkpoint_continuation.consume ~base_path:root ~keeper_name ~operation_id admission |> value;
        let capture_destination ()=Keeper_checkpoint_destination.capture_direct ~base_path:root ~keeper_name
          ~session_dir ~trace_id:meta.runtime.trace_id ~operation_id |> value in
        let cancelled_destination=capture_destination () in
        (match Eio.Cancel.sub (fun cancellation ->
           Eio.Cancel.cancel cancellation (Failure "cancel original branch host publication");
           Keeper_checkpoint_destination.save cancelled_destination consumed) with
         | exception Eio.Cancel.Cancelled _ -> ()
         | Ok _ | Error _ -> fail "cancelled host publication returned without cancellation");
        (match Keeper_checkpoint_destination.current_checkpoint cancelled_destination with
         | Error _ -> () | Ok _ -> fail "cancelled publication exposed its old payload as confirmed latest");
        (match Keeper_checkpoint_destination.save cancelled_destination consumed with
         | Error _ -> () | Ok _ -> fail "cancelled dispatch retried its uncertain branch write");
        let destination=capture_destination () in
        let refused=Keeper_checkpoint_host_transform.preserve ~source:(exact consumed)
          ~candidate:{consumed with messages=[]} in
        (match refused with Error _ -> () | Ok _ -> fail "host proof discarded the accepted original response");
        let producer=Keeper_input_checkpoint_producer.prepare ~base_path:root ~keeper_name ~session_dir
            ~trace_id:meta.runtime.trace_id ~source:(Some consumed) |> prepared in
        (match Keeper_input_checkpoint_producer.destination producer with
         | Keeper_owner.Operation_input actual when Keeper_chat_operation.Operation_id.equal actual operation_id -> ()
         | Operation_input _ | Global_input -> fail "branch child borrowed global input destination");
        let writer=Keeper_owner.begin_input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_ok in
        writer_cell:=Some writer;
        let context=Core.Context.copy consumed.context ~eio:true in
        Core.Context.set context "original-native-setup" (`Bool true);
        let seed={consumed with Core.Checkpoint.context} in
        (match Keeper_checkpoint_destination.save destination seed |> value with
         | Store.Saved _ -> () | Stale_noop _ -> fail "host preparation was not confirmed");
        let saved=Keeper_checkpoint_destination.current_checkpoint destination |> value |> Option.get in
        let saved_bytes=Store.exact_snapshot_canonical_bytes (exact saved) in
        Core.Context.set seed.context "later-native-context-mutation" (`Bool true);
        let still_saved=Keeper_checkpoint_destination.current_checkpoint destination |> value |> Option.get in
        check string "native mutable context does not rewrite a private confirmed host source"
          saved_bytes (Store.exact_snapshot_canonical_bytes (exact still_saved));
        let seed_ref=Store.retain_exact_snapshot ~session_dir (exact seed)
            |> Store.require_confirmed_installation |> Result.get_ok in
        let identity_proof=Keeper_checkpoint_host_transform.preserve ~source:(exact saved) ~candidate:saved |> value in
        (match Keeper_owner.checkpoint_operation_input_branch owner ~writer
            ~observed:(Store.exact_snapshot_reference (exact saved)) ~checkpoint:seed_ref
            ~transformation:identity_proof with
         | Error (Keeper_owner.Operation_rejected (Journal.Invalid_input _)) -> ()
         | Error _ | Ok () -> fail "Owner reused a host proof for an edited retained candidate");
        (* Run the real native adapter and Core journal against loopback HTTP,
           using the consumed original C while the independent global G stays
           installed. Later synthetic receipts below cover another pending
           boundary; they are not evidence of another Core invocation. *)
        Runtime_agent_execution_runtime.initialize ~sw:turn_sw ~domain_mgr:env#domain_mgr ~domain_count:1
          |> Result.map_error Runtime_agent_execution_runtime.initialization_error_to_string |> value;
        let previous_catalog=Llm_provider.Model_catalog.global () in
        Eio.Switch.on_release turn_sw (fun () -> match previous_catalog with
          | None -> Llm_provider.Model_catalog.clear_global ()
          | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
        let catalog=Printf.sprintf
          "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" seed.model in
        Llm_provider.Model_catalog.of_toml_string ~source:"original-branch-native-test" catalog |> value
          |> Llm_provider.Model_catalog.set_global;
        let tool_calls=ref 0 in
        let response index=Yojson.Safe.to_string (`Assoc ["id",`String "original-branch-native";
          "model",`String seed.model;"choices",`List [`Assoc ["index",`Int 0;
            "message",(if index=0 then `Assoc ["role",`String "assistant";"content",`Null;
              "tool_calls",`List [`Assoc ["id",`String "original-branch-effect-call";"type",`String "function";
                "function",`Assoc ["name",`String "branch_effect";"arguments",`String "{}"]]]]
              else `Assoc ["role",`String "assistant";"content",`String "original branch native completed"]);
            "finish_reason",`String (if index=0 then "tool_calls" else "stop")]];
          "usage",`Assoc ["prompt_tokens",`Int 1;"completion_tokens",`Int 1;"total_tokens",`Int 2]]) in
        let server=Exact_output_fixture.start_server ~sw:turn_sw ~net:env#net ~clock:env#clock
          (Exact_output_fixture.Reply_with (fun index _ ->
            check string "actual native provider dispatch preserves G bytes" g_bytes (Fs_compat.load_file canonical);
            `OK,response index)) in
        let provider_cfg=Llm_provider.Provider_config.make ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~provider_id:"fixture" ~model_id:seed.model ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
        let tool=Core.Tool.create ~name:"branch_effect" ~description:"Record the original operation's effect" ~parameters:[]
          (fun _ -> incr tool_calls;
            Core.Context.set seed.context "original-native-tool-receipt" (`Bool true);
            Ok {Core.Types.content="original branch effect recorded";content_blocks=None;_meta=None}) in
        let binding:Keeper_direct_native_continuation.binding={base_path=root;keeper_name;operation_id;
          execution_digest=operation.execution_digest;session_dir;session_id=original.session_id;
          checkpoint_destination=destination} in
        let native_config=Runtime_agent.default_config ~name:keeper_name ~provider_cfg
          ~system_prompt:"Continue the original operation from its accepted response." ~tools:[tool] in
        let native_config={native_config with context=Some seed.context;session_id=Some original.session_id;
          checkpoint_sidecar=seed.working_context;
          checkpoint_sink=Some (fun snapshot ->
            let result=Keeper_checkpoint_destination.save destination snapshot.Core.Agent.checkpoint in
            check string "actual native host sink preserves G bytes" g_bytes (Fs_compat.load_file canonical);
            Result.map (fun _ -> ()) result)} in
        let agent_ref=ref None in
        let prepared_native=Keeper_direct_native_continuation.prepare ~binding ~runtime_id:"native.primary"
          ~config:native_config ~agent_core_checkpoint:(Some seed)
          ~input:Keeper_direct_native_continuation.Continue_from_checkpoint ~agent_ref () |> value in
        let result=Keeper_direct_native_continuation.reconcile_after_dispatch binding (fun () ->
          Runtime_agent.continue_from_checkpoint ~sw:turn_sw ~net:env#net
            ~config:(Keeper_direct_native_continuation.config prepared_native) ~agent_ref
            ~checkpoint:(Keeper_direct_native_continuation.prepared_checkpoint prepared_native |> Option.get) ())
          |> Result.map_error Core.Error.to_string |> value in
        check string "actual native continuation completes" "original branch native completed"
          (Core.Types.text_of_content result.response.content);
        check int "original native tool executes once" 1 !tool_calls;
        check int "native provider sees only its tool and final rounds" 2 (Exact_output_fixture.post_count server);
        List.iter (fun body ->
          let fields=Yojson.Safe.from_string body |> Yojson.Safe.Util.member "messages" |> Yojson.Safe.Util.to_list in
          check bool "actual model input retains its original explicit declined response" true
            (List.exists (fun row -> Yojson.Safe.Util.member "role" row=`String "user"
              && Yojson.Safe.Util.member "content" row=`String "[Input declined] Original question?") fields))
          (Exact_output_fixture.request_bodies server);
        let observed_native=Keeper_owner.direct_native_call owner ~operation_id |> owner_ok in
        let actual_native=match observed_native with
          | Native.Terminal_unacknowledged (call,{Core.Agent.recovery=Retire;_}) -> call
          | No_native_call | Active _
          | Terminal_unacknowledged (_, {Core.Agent.recovery=Operator_repair_required Effect_outcome_unknown;_}) ->
            fail "actual Core continuation did not retire its original native receipt" in
        let seed=Keeper_checkpoint_destination.current_checkpoint destination |> value |> Option.get in
        let seed_ref=Store.exact_snapshot_reference (exact seed) in
        check bool "actual native terminal Context and branch reference are confirmed together" true
          (Keeper_checkpoint_ref.equal seed_ref actual_native.checkpoint
            && Core.Context.get seed.context "original-native-tool-receipt"=Some (`Bool true));
        check bool "real native completion preserves global input G" true
          (Keeper_owner.input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_ok=Journal.Input_observed g);
        (* Exercise the typed retired cut with distinct actual native N and
           confirmed host H. The earlier settled tool result must survive the
           second real invocation; no provider truncation decision is simulated. *)
        let context=Core.Context.copy seed.context ~eio:true in
        Core.Context.set context "host-before-response-cut" (`String "retained host metadata");
        let host={seed with Core.Checkpoint.context} in
        (match Keeper_checkpoint_destination.save destination host |> value with
         | Store.Saved _ -> () | Stale_noop _ -> fail "host cut source was not confirmed");
        let host=Keeper_checkpoint_destination.current_checkpoint destination |> value |> Option.get in
        let host_ref=Store.exact_snapshot_reference (exact host) in
        check bool "actual retired N and host H are distinct" false
          (Keeper_checkpoint_ref.equal actual_native.checkpoint host_ref);
        let cut={host with Core.Checkpoint.messages=List.take (List.length host.messages-1) host.messages} in
        let cut_config={native_config with context=Some cut.context;checkpoint_sidecar=cut.working_context} in
        let prepare_cut ?retired_history_cut checkpoint agent_ref=
          Keeper_direct_native_continuation.prepare ~binding ~runtime_id:"native.primary" ~config:cut_config
            ~agent_core_checkpoint:(Some checkpoint) ~input:Keeper_direct_native_continuation.Continue_from_checkpoint
            ~agent_ref ?retired_history_cut () in
        (match prepare_cut cut (ref None) with Error _ -> () | Ok _ -> fail "ordinary branch continuation accepted an unproved history cut");
        let proof=Keeper_direct_native_continuation.authorize_incomplete_response_cut ~binding ~checkpoint:cut () |> value in
        (match prepare_cut ~retired_history_cut:proof {cut with working_context=None} (ref None) with
         | Error _ -> () | Ok _ -> fail "branch cut proof accepted an edited next source");
        let agent_ref=ref None in
        let prepared_cut=prepare_cut ~retired_history_cut:proof cut agent_ref |> value in
        let retried=Keeper_direct_native_continuation.reconcile_after_dispatch binding (fun () ->
          Runtime_agent.continue_from_checkpoint ~sw:turn_sw ~net:env#net
            ~config:(Keeper_direct_native_continuation.config prepared_cut) ~agent_ref
            ~checkpoint:(Keeper_direct_native_continuation.prepared_checkpoint prepared_cut |> Option.get) ())
          |> Result.map_error Core.Error.to_string |> value in
        check string "actual branch continuation after typed cut completes" "original branch native completed"
          (Core.Types.text_of_content retried.response.content);
        check int "typed history cut never repeats the original tool effect" 1 !tool_calls;
        check int "only the extra native final round dispatches after cut" 3 (Exact_output_fixture.post_count server);
        let observed_native=Keeper_owner.direct_native_call owner ~operation_id |> owner_ok in
        let after_cut=match observed_native with
          | Native.Terminal_unacknowledged (call,{Core.Agent.recovery=Retire;_}) -> call
          | No_native_call | Active _
          | Terminal_unacknowledged (_, {Core.Agent.recovery=Operator_repair_required Effect_outcome_unknown;_}) ->
            fail "typed cut continuation did not retire its actual journal" in
        let seed=Keeper_checkpoint_destination.current_checkpoint destination |> value |> Option.get in
        let seed_ref=Store.exact_snapshot_reference (exact seed) in
        check bool "typed cut publishes next native and branch together with host metadata" true
          (Keeper_checkpoint_ref.equal after_cut.checkpoint seed_ref
            && Core.Context.get seed.context "host-before-response-cut"=Some (`String "retained host metadata")
            && List.for_all (fun message -> List.mem message seed.messages) cut.messages);
        check string "actual branch cut leaves all independent G bytes unchanged" g_bytes (Fs_compat.load_file canonical);
        check bool "actual branch cut leaves global input G unchanged" true
          (Keeper_owner.input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_ok=Journal.Input_observed g);
        let call_id="019a0010-1000-7000-8000-000000000053" in
        let locator=Core.Agent.execution_locator_of_yojson
            (`Assoc ["version",`Int 1;"run_id",`String "execution-run-owner-branch-continuation"]) |> value in
        let call=Native.create ~call_id ~runtime_id:"native.primary" ~operation_digest:operation.execution_digest
            ~api:Native.Continue_from_checkpoint ~seed_checkpoint:seed_ref ~locator |> value in
        Keeper_checkpoint_destination.publish_native destination ~checkpoint:seed (fun () ->
          Keeper_owner.bind_direct_native_call owner ~operation_id ~execution_digest:operation.execution_digest
            ~observed:observed_native ~call
          |> Result.map_error Keeper_owner.error_to_string |> Result.map (fun () -> seed_ref,())) |> value;
        let context=Core.Context.copy seed.context in
        let observation=Keeper_repetition_snapshot.observation ~tool_name:"original-native-tool"
          ~input_fingerprint:None ~output_fingerprint:None |> Result.get_ok in
        let frame=Keeper_repetition_context.load context |> Result.get_ok in
        let frame=Keeper_repetition_snapshot.record frame
          ~scope:(Keeper_execution_scope_id.direct_operation operation_id) observation |> Result.get_ok in
        Keeper_repetition_context.save context frame;
        let ordinary={seed with Core.Checkpoint.context;turn_count=seed.turn_count+1;
          messages=seed.messages @ [Core.Types.assistant_msg "original branch continued"]} in
        let ordinary_ref=Store.retain_exact_snapshot ~session_dir (exact ordinary)
            |> Store.require_confirmed_installation |> Result.get_ok in
        Keeper_checkpoint_destination.publish_native destination ~checkpoint:ordinary (fun () ->
          Keeper_owner.checkpoint_direct_native_call owner ~operation_id ~execution_digest:operation.execution_digest
            ~call_id ~observed:seed_ref ~checkpoint:ordinary_ref
          |> Result.map_error Keeper_owner.error_to_string |> Result.map (fun () -> ordinary_ref,())) |> value;
        let rollback={ordinary with Core.Checkpoint.context=Core.Context.copy seed.context} in
        (match Keeper_checkpoint_host_transform.preserve ~source:(exact ordinary) ~candidate:rollback with
         | Error _ -> () | Ok _ -> fail "host proof rolled back repetition observations");
        let replay_source={ordinary with messages=ordinary.messages @ [Core.Types.assistant_msg ""]} in
        let proof,projected,_=Keeper_checkpoint_host_transform.replay ~source:(exact replay_source)
          ~history_messages:consumed.messages ~response_text:"" ~suppress_visible_response:false
          ~stop_reason:Runtime_agent.Completed |> value in
        check bool "typed direct replay can remove only the inert final Assistant" true
          (projected.messages=ordinary.messages);
        Keeper_checkpoint_host_transform.validate proof ~source:(exact replay_source) ~candidate:(exact projected) |> value;
        let tool_use=Core.Types.make_message ~role:Core.Types.Assistant
          [Core.Types.ToolUse {id="original-result";name="retained-projection-tool";input=`Assoc []}] in
        let tool_bearing=Core.Types.make_message ~role:Core.Types.Tool
          [Core.Types.ToolResult {tool_use_id="original-result";content="settled result";
            outcome=Core.Types.Tool_succeeded;json=None;content_blocks=None}] in
        let effect_messages=ordinary.messages @ [tool_use;tool_bearing] in
        let effect_source={ordinary with messages=effect_messages @ [Core.Types.assistant_msg "suppressed final"]} in
        let _,effect_projection,_=Keeper_checkpoint_host_transform.replay ~source:(exact effect_source)
          ~history_messages:consumed.messages ~response_text:"" ~suppress_visible_response:true
          ~stop_reason:Runtime_agent.Completed |> value in
        check bool "host replay preserves valid ToolUse and ToolResult while suppressing final text" true
          (effect_projection.messages=effect_messages);
        let open_effect_source={ordinary with messages=ordinary.messages @ [tool_use]} in
        (match Keeper_checkpoint_host_transform.replay ~source:(exact open_effect_source)
            ~history_messages:consumed.messages ~response_text:"" ~suppress_visible_response:true
            ~stop_reason:Runtime_agent.Completed with
         | Error _ -> () | Ok _ -> fail "host replay projection erased a retained ToolUse");
        let next_pending=pending ~run_id:"original-owner-second-run" ~request_id:"original-owner-second-request" in
        let next={ordinary with Core.Checkpoint.pending_input=Some next_pending} in
        let next_ref=Keeper_checkpoint_destination.publish_native destination ~checkpoint:next (fun () ->
          Keeper_input_checkpoint_producer.publish_direct producer ~operation_id
            ~execution_digest:operation.execution_digest ~call_id ~observed:ordinary_ref next
          |> Result.map_error Keeper_input_checkpoint_producer.error_to_string
          |> Result.map (fun (_producer,reference) -> reference,reference)) |> value in
        (* The producer was captured at C. Ordinary native advancement to seed
           and then ordinary_ref must not make it overwrite or borrow G. *)
        let branch=Keeper_owner.direct_input_branch owner ~operation_id |> owner_ok |> Option.get in
        check bool "Owner input and native advance to the same exact branch head" true
          (Keeper_checkpoint_ref.equal branch.checkpoint next_ref);
        (match Keeper_owner.direct_native_call owner ~operation_id |> owner_ok with
         | Native.Active actual -> check bool "actual native receipt matches second input" true
             (Keeper_checkpoint_ref.equal actual.checkpoint next_ref)
         | No_native_call | Terminal_unacknowledged _ -> fail "native receipt disappeared");
        Keeper_owner.terminal_direct_native_call owner ~operation_id ~execution_digest:operation.execution_digest
            ~call_id ~disposition:{Core.Agent.outcome=Core.Agent.Terminal_succeeded;recovery=Core.Agent.Retire} |> owner_ok;
        let context=Core.Context.copy next.context in
        Core.Context.set context "original-host-finalization" (`Bool true);
        let finalized={next with Core.Checkpoint.context} in
        (match Keeper_checkpoint_destination.save destination finalized |> value with
         | Store.Saved _ -> () | Stale_noop _ -> fail "retired host finalization was not confirmed");
        let host_ref=Store.exact_snapshot_reference (exact finalized) in
        check bool "host finalization keeps the actual native Retire receipt separate" true
          (match Keeper_owner.direct_native_call owner ~operation_id |> owner_ok with
           | Native.Terminal_unacknowledged (actual,{Core.Agent.recovery=Retire;_}) ->
             Keeper_checkpoint_ref.equal actual.checkpoint next_ref
             && not (Keeper_checkpoint_ref.equal actual.checkpoint host_ref)
           | No_native_call | Active _
           | Terminal_unacknowledged (_, {Core.Agent.recovery=Operator_repair_required Effect_outcome_unknown;_}) -> false);
        ignore (Keeper_owner.defer_direct_input_wait owner ~operation_id ~request:next_pending.request |> owner_ok);
        Ok host_ref
      with exn -> Error exn in
      execution_result:=Some result;
      Keeper_owner.Operation_deferred in
    Eio.Switch.run (fun owner_sw ->
      let runner={Keeper_owner.ready=(fun ~keeper_name:_ -> !ready);execute;
        on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ -> Eio.Promise.resolve resolve_settled ())} in
      Keeper_owner_registry.install_from_store ~sw:owner_sw ~operation_runner:(Some runner)
        ~on_turn_slot_released:None workspace |> prepared |> ignore;
      let owner=Keeper_owner_registry.get ~base_path:root ~keeper_name |> prepared in
      owner_cell:=Some owner;ready:=true;
      Keeper_owner.wake_operation_drain owner |> owner_ok;
      Eio.Promise.await settled;
      let next_ref=match !execution_result with Some (Ok reference) -> reference
        | Some (Error exn) -> raise exn | None -> fail "original child did not execute" in
      let writer=Option.get !writer_cell in
      (match Keeper_owner.advance_direct_input_checkpoint owner ~writer ~operation_id
          ~execution_digest:operation.execution_digest ~call_id:"019a0010-1000-7000-8000-000000000053"
          ~observed:next_ref ~checkpoint:next_ref with
       | Error (Keeper_owner.Operation_rejected (Journal.Invalid_input _)) -> ()
       | Error _ | Ok _ -> fail "non-child caller reused the captured branch writer");
      (match Keeper_owner.checkpoint_direct_native_call owner ~operation_id
          ~execution_digest:operation.execution_digest ~call_id:"019a0010-1000-7000-8000-000000000053"
          ~observed:next_ref ~checkpoint:next_ref with
       | Error (Keeper_owner.Operation_rejected (Journal.Invalid_input _)) -> ()
       | Error _ | Ok _ -> fail "non-child caller published a native branch receipt");
      let next_wait=Keeper_owner.direct_input_wait owner ~operation_id |> owner_ok |> Option.get in
      check bool "repeated wait owns the branch, not independent global B" true
        (Keeper_checkpoint_ref.equal next_wait.checkpoint next_ref);
      check bool "Owner child preserves global input G" true
        (Keeper_owner.input_checkpoint owner ~trace_id:meta.runtime.trace_id |> owner_ok=Journal.Input_observed g);
      check string "Owner child preserves all canonical G bytes" g_bytes (Fs_compat.load_file canonical);
      ignore (Keeper_owner.begin_stopping owner |> owner_ok));
    with_journal (fun journal -> check_g journal;
      check bool "reopen preserves original branch's second pending wait" true
        (Option.is_some (Journal.direct_input_wait journal ~operation_id |> journal_ok)))

let () =
  run "Keeper stored input response"
    [ "independent branch response primitives",
      [test_case "fresh response preserves actual Producer G and other pending" `Quick
         (test_operation_response_preserves_producer_g ~canonical_intent:false ~fault:None);
       test_case "branch Gate retained-read failure restores its original wait" `Quick
         (test_operation_response_preserves_producer_g ~gate_case:(Some Retained_gate_source_missing)
            ~canonical_intent:false ~fault:None);
       test_case "branch Gate host-save refusal restores its original wait" `Quick
         (test_operation_response_preserves_producer_g ~gate_case:(Some Gate_host_destination_unconfirmed)
            ~canonical_intent:false ~fault:None);
       test_case "approved branch Gate replays exact durable evidence and continues natively" `Quick
         (test_operation_response_preserves_producer_g ~gate_case:(Some Gate_approved_replay)
            ~canonical_intent:false ~fault:None);
       test_case "denied branch Gate admits rejection and continues natively" `Quick
         (test_operation_response_preserves_producer_g ~gate_case:(Some Gate_denied_resume)
            ~canonical_intent:false ~fault:None);
       test_case "canonical intent promotes with same consumed C after actual Producer G" `Quick
         (test_operation_response_preserves_producer_g ~canonical_intent:true ~fault:None);
       test_case "branch precommit failure reopens exact physical intent" `Quick
         (test_operation_response_preserves_producer_g ~canonical_intent:true ~fault:(Some Keeper_chat_operation_store.For_testing.Fail_before_commit));
       test_case "uncertain committed branch response preserves actual G after reopen" `Quick
         (test_operation_response_preserves_producer_g ~canonical_intent:true ~fault:(Some Keeper_chat_operation_store.For_testing.Fail_after_commit))];
      "physical response ownership",
      [test_case "same pending cannot discard retained context working-context tools MCP or turn" `Quick test_install_refuses_stale_nonhistory];
      "autonomous input ownership",
      [test_case "consumed answer lineage survives settlement and rejects stale sources" `Quick
         test_autonomous_input_owner_rejects_lost_response_lineage];
      "candidate preparation",
      [ test_case "canonical responses preserve full source metadata" `Quick
          test_canonical_response_preserves_complete_checkpoint
      ; test_case "stale run, request and exact source are refused" `Quick
          test_stale_run_request_and_source_are_refused ] ]
