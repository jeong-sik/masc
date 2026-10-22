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

(* Actual physical files, SQLite and an independently executing Owner child
   publishing G through the real Producer. This does not dispatch the original
   native continuation; the public Owner response remains guarded until that
   whole branch path is connected. *)
let test_operation_response_preserves_producer_g ~canonical_intent ~fault () =
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
    (* Do not expose a successful response before the native branch path exists. *)
    (match Keeper_owner.respond_direct_input_wait owner ~net:env#net ~operation_id ~observed:waiting ~response:Core.Hooks.Declined with
     | Error (Keeper_owner.Response_owner_error (Keeper_owner.Operation_rejected (Journal.Invalid_input _))) -> ()
     | Error _ | Ok _ -> fail "public Owner accepted an unsupported branch continuation");
    check bool "guard preserves the original exact waiting operation" true
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
  (* Exercise actual Owner child authority and both direct loader/publication
     adapters once. Native records here are real Owner/SQLite receipts, but no
     Core native invocation is dispatched by this fixture. *)
  match canonical_intent,fault with
  | true,(Some _ | None) | false,Some _ -> ()
  | false,None ->
    let ready=ref false in
    let owner_cell=ref None in
    let writer_cell=ref None in
    let execution_result=ref None in
    let settled,resolve_settled=Eio.Promise.create () in
    let owner_ok result=Result.map_error Keeper_owner.error_to_string result |> value in
    let execute ~sw:_ ~keeper_name:_ ~claim =
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
        let context=Core.Context.copy consumed.context in
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
        let call_id="019a0010-1000-7000-8000-000000000053" in
        let locator=Core.Agent.execution_locator_of_yojson
            (`Assoc ["version",`Int 1;"run_id",`String "execution-run-owner-branch-continuation"]) |> value in
        let call=Native.create ~call_id ~runtime_id:"native.primary" ~operation_digest:operation.execution_digest
            ~api:Native.Continue_from_checkpoint ~seed_checkpoint:seed_ref ~locator |> value in
        Keeper_checkpoint_destination.publish_native destination ~checkpoint:seed (fun () ->
          Keeper_owner.bind_direct_native_call owner ~operation_id ~execution_digest:operation.execution_digest
            ~observed:Native.No_native_call ~call
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
        let tool_bearing=Core.Types.make_message ~role:Core.Types.Assistant
          [Core.Types.ToolResult {tool_use_id="original-result";content="settled result";
            outcome=Core.Types.Tool_succeeded;json=None;content_blocks=None}] in
        let effect_source={ordinary with messages=ordinary.messages @ [tool_bearing]} in
        (match Keeper_checkpoint_host_transform.replay ~source:(exact effect_source)
            ~history_messages:consumed.messages ~response_text:"" ~suppress_visible_response:true
            ~stop_reason:Runtime_agent.Completed with
         | Error _ -> () | Ok _ -> fail "host replay projection erased a retained ToolResult");
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
           | Terminal_unacknowledged (_, {Core.Agent.recovery=(Retire | Operator_repair_required Effect_outcome_unknown);_}) -> false);
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
