open Alcotest
open Masc
module Owner = Keeper_owner
module Registry = Keeper_owner_registry
module Continuation = Keeper_direct_runtime_continuation
module Checkpoint = Keeper_checkpoint_store
module Store = Keeper_chat_operation_store

let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let write path value =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel value)
let rec remove path =
  match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR; _} ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Unix.unlink path

let test_http_effect_checkpoint_owner_restart_alternate ?(interleave = false) ?(lose_retained = false) ?(projection_failure = false) () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_file "direct-runtime-resume-" "" in
  Unix.unlink base_path; Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (match catalog_snapshot with None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    remove base_path);
  let primary_requests = ref 0 and alternate_bodies = ref [] and effects = ref 0 in
  let callback _connection request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    if String.starts_with ~prefix:"/primary" (Cohttp.Request.resource request) then (
      incr primary_requests;
      if !primary_requests = 1 then
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:{|{"id":"tool-once","model":"resume-fixture","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"effect-once","type":"function","function":{"name":"record_effect","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}|} ()
      else Cohttp_eio.Server.respond_string ~status:`Too_many_requests
        (* The 429 carries a Retry-After hint so the deferred retry's
           not_before lands 1s out: phase 2's owner restart re-arms the wake
           and the alternate resumes once the hint elapses — the production
           cooling path, at test speed. *)
        ~headers:(Cohttp.Header.init_with "Retry-After" "1")
        ~body:{|{"error":{"message":"fixture provider rate limited","type":"rate_limit_error"}}|} ())
    else (
      alternate_bodies := body :: !alternate_bodies;
      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:{|{"id":"completed","model":"resume-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"Original task completed from the saved effect."},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}|} ())
  in
  let socket = Eio.Net.listen env#net ~sw ~backlog:8 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | `Unix _ -> fail "expected TCP socket" in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:raise);
  let catalog_path = Filename.concat base_path "models.toml" in
  write catalog_path (String.concat "\n" (List.map (fun provider -> Printf.sprintf
    "[[models]]\nid_prefix = \"resume-fixture\"\nprovider_name = %S\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" provider)
    ["primary"; "removed"; "alternate"]));
  Llm_provider.Model_catalog.load_file catalog_path |> require "catalog" |> Llm_provider.Model_catalog.set_global;
  let runtime_path = Filename.concat base_path "runtime.toml" in
  let runtime_config ~with_removed = Printf.sprintf {|[runtime]
default = "primary.sample"
[runtime.lanes.direct]
candidates = %s
[providers.primary]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/primary"
[providers.alternate]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/alternate"
%s
[models.sample]
api-name = "resume-fixture"
max-context = 8192
tools-support = true
streaming = false
[primary.sample]
is-default = true
[alternate.sample]
%s
|} (if with_removed then "[\"primary.sample\", \"removed.sample\", \"alternate.sample\"]"
    else "[\"primary.sample\", \"alternate.sample\"]") port port
    (if with_removed then "[providers.removed]\nprotocol = \"openai-compatible-http\"\nendpoint = \"http://127.0.0.1:1\"" else "")
    (if with_removed then "[removed.sample]" else "") in
  write runtime_path (runtime_config ~with_removed:true);
  Runtime.init_default ~config_path:runtime_path |> require "runtime";
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some "continuation-test"));
  let keeper_name = "direct-resume-proof" and session_id = "direct-resume-session" in
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name", `String keeper_name; "trace_id", `String session_id;
    "activation_mode", `String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot config meta |> require "persist meta";
  let session_dir = Filename.concat base_path session_id in
  Unix.mkdir session_dir 0o700;
  let operation_id = Keeper_chat_operation.Operation_id.of_string "kmsg-http-resume"
    |> require "operation ID" in
  let source = `Assoc ["kind", `String "keeper"; "asked_by", `String "original-asker"] in
  let input = Keeper_chat_operation_payload.input_to_json ~message:"Finish original task"
    ~user_blocks:[] ~turn_instructions:(Some "Preserve the original task criteria and evidence")
    ~surface_context:(Some (`Assoc ["task_id", `String "original-task"])) ~attachments:[] in
  let input = Keeper_chat_operation.canonical_json input |> require "canonical input" in
  let source = Keeper_chat_operation.canonical_json source |> require "canonical source" in
  let tool = Agent_core.Tool.create ~name:"record_effect" ~description:"Record one effect"
      ~parameters:[] (fun _ -> incr effects; Ok {content="effect receipt: already completed"; content_blocks = None; _meta = None}) in
  let seen_operations = ref [] in
  let peer_id = Keeper_chat_operation.Operation_id.of_string "kmsg-peer-after-retry" |> require "peer ID" in
  let terminal_failure = ref None in
  let run_phase ~resume =
    Eio.Switch.run @@ fun owner_sw ->
    let settled, resolve_settled = Eio.Promise.create () in
    let ready = ref true in
    let execute ~sw:turn_sw ~keeper_name:_ ~claim =
      let operation : Keeper_chat_operation.t = match claim () |> require "claim" with
        | Some operation -> operation | None -> fail "operation lost at restart" in
      seen_operations := operation.operation_id :: !seen_operations;
      if Keeper_chat_operation.Operation_id.equal peer_id operation.operation_id then (
        ready := false;
        Owner.Operation_succeeded {outcome_ref="peer-work-after-terminal-failure"})
      else (
      check bool "same original operation" true
        (Keeper_chat_operation.Operation_id.equal operation_id operation.operation_id);
      check bool "original task/channel/instructions retained" true (operation.input = Some input && operation.source = source);
      let operation_state () = Registry.exact_operation ~base_path ~keeper_name operation_id
        |> Result.map_error Registry.command_error_to_string
        |> fun result -> Result.bind result (function Some operation -> Ok operation.Keeper_chat_operation.state
          | None -> Error "fixture operation disappeared") in
      let admission = Continuation.load ~base_path ~keeper_name ~operation_id ~session_dir ~session_id in
      match admission with
      | Error detail when resume && lose_retained ->
        terminal_failure := Some detail;
        Registry.submit_operation ~base_path ~keeper_name ~operation_id:peer_id ~source ~input
          |> require "peer admission while original is claimed" |> ignore;
        Server_routes_http_keeper_stream.For_testing.operation_execution_of_outcome
          ~operation_state ~pending_continuation:(fun () -> Keeper_direct_gate_continuation.pending
            ~base_path ~keeper_name ~operation_id)
          ~outcome:(Some (Server_routes_http_keeper_stream.Failed {kind=Turn_failed; detail}))
          ~delivery:(Error detail)
      | Error detail -> fail detail
      | Ok admission ->
      check bool "restart restores typed pending continuation" resume (Option.is_some admission);
      if resume && interleave then (
        let again = Continuation.load ~base_path ~keeper_name ~operation_id ~session_dir ~session_id
          |> require "re-read admitted current-history continuation" |> Option.get in
        check bool "reloading before consume does not duplicate continuation input" true
          ((Continuation.checkpoint again).messages =
           (Continuation.checkpoint (Option.get admission)).messages));
      let context = Agent_core.Context.create_sync () in
      let scope = Keeper_execution_scope_id.direct_operation operation_id in
      let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
          (Keeper_repetition_snapshot.Fresh scope) |> require "scope" in
      Keeper_repetition_scope.save context frame;
      let checkpoint_sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
        let checkpoint = {snapshot.checkpoint with session_id} in
        Checkpoint.save_agent_core_classified ~session_dir checkpoint |> Result.map (fun _ -> ()) in
      let deferred = ref None in
      Option.iter (fun admission -> Continuation.consume ~base_path ~keeper_name ~operation_id admission
        |> require "consume same checkpoint") admission;
      let result = Keeper_turn_driver.run_named
        ~runtime_id:(match admission with None -> "direct" | Some value -> (Continuation.lane value).next_runtime_id)
        ~keeper_name ~base_path ~session_id ~goal:"Finish original task"
        ~system_prompt:"Use the effect receipt to finish the original task."
        ~agent_core_tools:[tool] ~context ~checkpoint_sink ~sw:turn_sw ~net:env#net
        ?agent_core_checkpoint:(Option.map Continuation.checkpoint admission)
        ~continue_from_checkpoint:(Option.is_some admission)
        ?deferred_runtime_lane:(Option.map Continuation.lane admission)
        ~on_runtime_retry_deferred:(fun value -> deferred := Some value) () in
      match result, !deferred with
      | Error _, Some lane ->
        check bool "only the original attempt may defer" false resume;
        Continuation.defer ~base_path ~keeper_name ~operation_id ~session_dir ~session_id lane
          |> require "durable direct deferral";
        ready := false;
        Server_routes_http_keeper_stream.For_testing.operation_execution_of_outcome
          ~operation_state ~pending_continuation:(fun () -> Keeper_direct_gate_continuation.pending
            ~base_path ~keeper_name ~operation_id)
          ~outcome:(Some (if projection_failure then
            Server_routes_http_keeper_stream.Failed {kind=Stream_projection_failed; detail="fixture display failure after durable deferral"}
            else Server_routes_http_keeper_stream.Delivered {outcome_ref="checkpointed-retry"}))
          ~delivery:(Ok ())
      | Ok _, None ->
        check bool "alternate resumes after owner restart" true resume;
        Owner.Operation_succeeded {outcome_ref="alternate-http-completion"}
      | Error error, None -> fail (Agent_core.Error.to_string error)
      | Ok _, Some _ -> fail "successful inference unexpectedly retained deferred failure")
    in
    let runner : Owner.operation_runner = {ready=(fun ~keeper_name:_ -> !ready); execute;
      on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id ~execution ->
        (match execution with
         | Owner.Operation_failed {detail; _} when not lose_retained -> fail detail
         | Owner.Operation_failed _ | Owner.Operation_deferred | Owner.Operation_succeeded _ -> ());
        if not (resume && lose_retained) ||
           Option.exists (Keeper_chat_operation.Operation_id.equal peer_id) claimed_operation_id
        then Eio.Promise.resolve resolve_settled ())} in
    Registry.install_from_store ~sw:owner_sw ~operation_runner:(Some runner)
      ~on_turn_slot_released:None config |> require "install owner" |> ignore;
    if not resume then Registry.submit_operation ~base_path ~keeper_name ~operation_id ~source ~input
      |> require "submit original operation" |> ignore;
    Eio.Promise.await settled;
    if resume && lose_retained then (
      let fresh = Keeper_chat_operation.Operation_id.of_string "kmsg-new-admission-after-recovery"
        |> require "new admission ID" in
      Registry.submit_operation ~base_path ~keeper_name ~operation_id:fresh ~source ~input
        |> require "fresh direct admission is not poisoned by deferred-not-queued" |> ignore)
  in
  run_phase ~resume:false;
  check int "completed tool ran before rate limit" 1 !effects;
  check int "alternate not invoked before owner restart" 0 (List.length !alternate_bodies);
  let store_path =
    Store.path_for_keeper
      ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_name
  in
  let store = Store.open_or_create ~path:store_path |> require "open store after defer" in
  let now = Time_compat.now () in
  check bool "cooling retry is not claimable during cooling window" false
    (Store.has_claimable_queued store ~now |> require "has_claimable_queued");
  check bool "claim_next returns None during cooling window" true
    (match Store.claim_next store ~now |> require "claim_next" with
     | None -> true
     | Some _ -> false);
  check bool "cooling retry becomes claimable once not_before passes" true
    (Store.has_claimable_queued store ~now:(now +. 5.0) |> require "has_claimable_queued after cooling");
  Store.close store |> require "close store";
  if interleave then (
    let original = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id |> require "original snapshot" in
    let reference = Checkpoint.exact_snapshot_reference original in
    let retained = Checkpoint.load_retained_exact_snapshot ~session_dir ~reference |> require "exact retained deferral" in
    let checkpoint = Checkpoint.exact_snapshot_checkpoint retained in
    let context = Agent_core.Context.copy checkpoint.context ~eio:true in
    let frame = Keeper_repetition_scope.load context |> require "original frame" in
    let other_scope = Keeper_execution_scope_id.autonomous_admission
      (Uuidm.of_string "00112233-4455-4677-8899-aabbccddeeff" |> Option.get) in
    let frame = Keeper_repetition_snapshot.admit frame (Keeper_repetition_snapshot.Fresh other_scope)
      |> require "interleaved autonomous scope" in
    Keeper_repetition_scope.save context frame;
    let checkpoint = {checkpoint with Agent_core.Checkpoint.context;
      messages=checkpoint.messages @ [Agent_core.Types.user_msg "Autonomous follow-up";
        Agent_core.Types.make_message ~role:Agent_core.Types.Assistant
          [Agent_core.Types.Text "Board receipt: newer shared work already posted once"]];
      turn_count=checkpoint.turn_count + 1} in
    Checkpoint.save_agent_core_classified ~session_dir checkpoint |> require "advance shared canonical history" |> ignore;
    if lose_retained then (
      (* Model the observed pre-fix store: the original reference exists in the
         journal, but no retained bytes authorize a replay after restart. *)
      let path = Filename.concat (Filename.concat session_dir "accepted-checkpoints")
        (reference.Keeper_checkpoint_ref.sha256 ^ ".json") in
      Unix.unlink path));
  if lose_retained then (
    (* Exact persisted shape observed after the rejected continuation: operation
       Running, semantic Recovering(Runtime_retry), original bytes absent.
       Owner startup must reconcile this before executing the resumed claim. *)
    let store = Store.open_or_create ~path:store_path |> require "open persisted failed-claim shape" in
    let claimed = Store.claim_next store ~now:(now +. 5.0) |> require "persist original as running" |> Option.get in
    check bool "same operation holds stale running projection" true
      (Keeper_chat_operation.Operation_id.equal operation_id claimed.operation_id);
    let execution = Store.semantic_get store (Keeper_execution_scope_id.direct_operation operation_id)
      |> require "read recovering semantic authority" |> Option.get in
    check bool "pending semantic authority survives failed claim" true
      (match execution.phase with Keeper_semantic_execution.Recovering {origin=Runtime_retry _; _} -> true | _ -> false);
    Store.close store |> require "close persisted running store");
  write runtime_path (runtime_config ~with_removed:false);
  Runtime.init_default ~config_path:runtime_path |> require "remove frozen first runtime";
  run_phase ~resume:true;
  check int "completed effect not replayed" 1 !effects;
  if lose_retained then (
    check int "original claims and next peer claim" 3 (List.length !seen_operations);
    check int "missing authority never reaches alternate model" 0 (List.length !alternate_bodies);
    check bool "lost authority remains explicit" true (Option.is_some !terminal_failure);
    let store = Store.open_or_create ~path:store_path |> require "read terminal state" in
    let original = Store.get store operation_id |> require "original state" |> Option.get in
    let peer = Store.get store peer_id |> require "peer state" |> Option.get in
    check bool "original terminal failure is durable" true
      (match original.state with Keeper_chat_operation.Failed _ -> true | _ -> false);
    check bool "next queued peer completed" true
      (match peer.state with Keeper_chat_operation.Succeeded _ -> true | _ -> false);
    check bool "new admission remains queued after recovery" true
      (Store.has_claimable_queued store ~now:(Time_compat.now ()) |> require "owner store remains readable");
    Store.close store |> require "close terminal store")
  else (
  check int "same operation claimed twice" 2 (List.length !seen_operations);
  check int "one alternate request" 1 (List.length !alternate_bodies);
  let body = List.hd !alternate_bodies |> Yojson.Safe.from_string in
  let messages = Yojson.Safe.Util.(body |> member "messages" |> to_list) in
  let contents = List.map (Yojson.Safe.Util.member "content") messages in
  check int "original input occurs once in resumed model input" 1
    (List.filter ((=) (`String "Finish original task")) contents |> List.length);
  check bool "completed tool receipt reaches alternate model" true
    (List.mem (`String "effect receipt: already completed") contents);
  if interleave then (
    check bool "newer Board work remains in model history" true
      (List.mem (`String "Board receipt: newer shared work already posted once") contents);
    check int "one explicit original-operation continuation" 1
      (List.filter (function `String text -> String.starts_with ~prefix:"Resume the original direct operation " text
        | _ -> false) contents |> List.length)))

let test_checkpoint_requires_original_active_scope () =
  let id value = Keeper_chat_operation.Operation_id.of_string value |> require "scope operation" in
  let original = id "original-operation" and other = id "other-operation" in
  let context = Agent_core.Context.create_sync () in
  let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
      (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation original))
      |> require "original scope" in
  Keeper_repetition_scope.save context frame;
  let working = Keeper_context_runtime.create ~eio:false ~system_prompt:"original" in
  let checkpoint = Keeper_context_runtime.checkpoint_of_context working in
  let checkpoint = {checkpoint with Agent_core.Checkpoint.context=context} in
  Continuation.For_testing.validate_scope ~operation_id:original checkpoint |> require "original owner";
  let frame = Keeper_repetition_snapshot.admit frame
      (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation other))
      |> require "other scope" in
  Keeper_repetition_scope.save context frame;
  match Continuation.For_testing.validate_scope ~operation_id:original checkpoint with
  | Error _ -> () | Ok () -> fail "historical membership authorized another operation's checkpoint"

let test_server_transcript_deferral_preserves_final_slot ~native () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  let base_dir = Filename.temp_file "direct-continuation-transcript-" "" in
  Unix.unlink base_dir; Unix.mkdir base_dir 0o700;
  Fun.protect ~finally:(fun () -> remove base_dir) (fun () ->
    let keeper_name = "transcript-proof" in
    let operation_id = Keeper_chat_delivery_identity.Request_id.of_string "same-original-operation"
      |> require "delivery ID" in
    let checkpoint = Keeper_checkpoint_ref.create
        ~trace_id:(Keeper_id.Trace_id.of_string "original-session" |> require "trace")
        ~turn_count:2 ~canonical_checkpoint_bytes:"original input and completed first tool"
        |> require "checkpoint reference" in
    let resumed_checkpoint =
      if native then Keeper_semantic_execution.Official_client
        {client_kind=Codex; runtime_id="codex.default"; session_id="provider/session";
         turn_id="native-turn-before-gate"; tool_surface_sha256=String.make 64 'a';
         frame=Keeper_repetition_snapshot.empty}
      else Keeper_semantic_execution.Agent_core checkpoint in
    let tool execution_id : Keeper_chat_store.tool_call =
      {call_id="provider-reused-id"; execution_id=Some (Ids.Execution_id.of_string execution_id);
       call_name="Execute"; args="{}"} in
    let persist resumed_from settlement tool_calls =
      Server_keeper_operation_transcript.persist ~base_dir ~keeper_name ~operation_id
        ~resumed_from ~settlement ~tool_calls () |> require "production transcript persistence" in
    persist None Server_keeper_operation_transcript.Runtime_deferred [tool "exec-before-retry"];
    let pending = Keeper_chat_store.load_all ~base_dir ~keeper_name in
    check bool "runtime checkpoint does not consume terminal assistant slot" false
      (List.exists (fun (row : Keeper_chat_store.chat_message) ->
        Keeper_chat_store.Role.equal row.role Keeper_chat_store.Role.Assistant) pending);
    let terminal = Server_keeper_operation_transcript.Terminal
      {content="Final answer after alternate runtime"; kind=Keeper_chat_store.Row_kind.Utterance} in
    persist (Some resumed_checkpoint) terminal [tool "exec-after-retry"];
    persist (Some resumed_checkpoint) terminal [tool "exec-after-retry"];
    let rows = Keeper_chat_store.load_all ~base_dir ~keeper_name in
    let answers = List.filter (fun (row : Keeper_chat_store.chat_message) ->
        Keeper_chat_store.Role.equal row.role Keeper_chat_store.Role.Assistant) rows in
    check (list string) "reload retains exactly the final answer" ["Final answer after alternate runtime"]
      (List.map (fun (row : Keeper_chat_store.chat_message) -> row.content) answers);
    let executions = List.filter_map (fun (row : Keeper_chat_store.chat_message) ->
      Option.map Ids.Execution_id.to_string row.execution_id) rows in
    check (list string) "pre/post retry tool evidence survives ordinal zero on each attempt"
      ["exec-before-retry"; "exec-after-retry"] executions;
    match Server_keeper_operation_transcript.persist ~base_dir ~keeper_name ~operation_id
      ~resumed_from:(Some resumed_checkpoint) ~settlement:Server_keeper_operation_transcript.Runtime_deferred
      ~tool_calls:[tool "exec-before-retry"] () with
    | Error _ -> () | Ok () -> fail "old effect was allowed under a new attempt provenance")

let () = run "direct runtime continuation" ["http", [test_case
  "rate limit after tool result resumes same operation across owner restart" `Quick
  (test_http_effect_checkpoint_owner_restart_alternate ~interleave:false ~lose_retained:false ~projection_failure:false);
  test_case "autonomous history advances while original exact continuation survives" `Quick
    (test_http_effect_checkpoint_owner_restart_alternate ~interleave:true ~lose_retained:false ~projection_failure:false);
  test_case "display failure after committed deferral keeps original continuation resumable" `Quick
    (test_http_effect_checkpoint_owner_restart_alternate ~interleave:true ~lose_retained:false ~projection_failure:true);
  test_case "missing original checkpoint terminalizes and releases queued peer after restart" `Quick
    (test_http_effect_checkpoint_owner_restart_alternate ~interleave:true ~lose_retained:true ~projection_failure:false)];
  "authority", [test_case "active original operation owns checkpoint" `Quick
    test_checkpoint_requires_original_active_scope;
    test_case "server persistence keeps final answer and both tool attempts" `Quick
    (test_server_transcript_deferral_preserves_final_slot ~native:false);
    test_case "native Gate preserves original and resumed tool ordinals across reload" `Quick
    (test_server_transcript_deferral_preserves_final_slot ~native:true)]]
