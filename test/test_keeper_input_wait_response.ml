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
     | Core.Hooks.Declined | Core.Hooks.Timeout ->
       check bool "explicit settlement preserves the original messages" true
         (after.messages = original.messages));
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
  let authority=Response.authorize ~session_root:root ~operation_id ~waiting ~recorded:None in
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
  let fresh=Response.authorize ~session_root:root ~operation_id ~waiting ~recorded:(Some intent) in
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

let () =
  run "Keeper stored input response"
    [ "physical response ownership",
      [test_case "same pending cannot discard retained context working-context tools MCP or turn" `Quick test_install_refuses_stale_nonhistory];
      "autonomous input ownership",
      [test_case "consumed answer lineage survives settlement and rejects stale sources" `Quick
         test_autonomous_input_owner_rejects_lost_response_lineage];
      "candidate preparation",
      [ test_case "canonical responses preserve full source metadata" `Quick
          test_canonical_response_preserves_complete_checkpoint
      ; test_case "stale run, request and exact source are refused" `Quick
          test_stale_run_request_and_source_are_refused ] ]
