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

let () =
  run "Keeper stored input response"
    [ "autonomous input ownership",
      [test_case "consumed answer lineage survives settlement and rejects stale sources" `Quick
         test_autonomous_input_owner_rejects_lost_response_lineage];
      "candidate preparation",
      [ test_case "canonical responses preserve full source metadata" `Quick
          test_canonical_response_preserves_complete_checkpoint
      ; test_case "stale run, request and exact source are refused" `Quick
          test_stale_run_request_and_source_are_refused ] ]
