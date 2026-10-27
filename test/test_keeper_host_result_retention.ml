open Alcotest
open Masc
module Host = Keeper_official_client_host
module Outbox = Keeper_client_tool_outbox
let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "original-host-result-owner"
let marker = "original-host-result-after-completed-effect"

let with_workspace f =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "keeper-host-result-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  f base_path

let project_with_producer ?(result_scope=None) ?(hooks=Agent_core.Hooks.empty)
    ?(effect_state = Keeper_tools_agent_core.Terminal_effect_open)
    ?(on_result_handoff = fun ~invocation:_ ~content:_ -> ())
    ~base_path ~stop ~terminal_error handler =
  let tool = Agent_core.Tool.create ~name:"CompleteEffect" ~description:"Complete an effect once"
      ~parameters:[{Agent_core.Types.name="input";description="original call data";
        param_type=String;required=false}] handler in
  match Host.dynamic_tools ~result_scope ~base_path ~content_transport:Runtime_official_client_tool.Mcp
    ~accepts_image_input:true ~tool_approval:None ~runtime_label:"host-result-fixture"
    ~keeper_name ~turn_count:7 ~tools:[tool] ~loading_plan:Host.All_on_demand
    ~hooks ~event_bus:None ~context_injector:None
    ~context:(Some (Agent_core.Context.create_sync ()))
    ~terminal_effect_state:(fun () -> effect_state)
    ~terminal_error ~pre_tool_rejects:(ref []) ~on_tool_boundary:(fun () -> Ok stop)
    ~on_result_handoff ~raw_trace_run:None () with
  | Ok ([tool], producer) -> tool, producer
  | Ok _ -> fail "one original tool required"
  | Error error -> fail (Agent_core.Error.to_string error)

let project ?result_scope ?hooks ?effect_state ?on_result_handoff
    ~base_path ~stop ~terminal_error handler =
  fst (project_with_producer ?result_scope ?hooks ?effect_state ?on_result_handoff
    ~base_path ~stop ~terminal_error handler)

let stop = Host.Terminal_tool_boundary {tool_name="CompleteEffect";outcome=Durable_stimulus_deferred}
let load base_path = get (Outbox.load ~base_path ~keeper_name)
let returned () = Ok {Agent_core.Types.content=marker;
  content_blocks=Some [Agent_core.Types.Text "original-block-bytes"];_meta=None}

let test_stop_retains_before_transport_return () = with_workspace (fun base_path ->
  let terminal_error = ref None and effects = ref 0 in
  let before = load base_path in
  let tool = project ~base_path ~stop:(Some stop) ~terminal_error
      (fun _ -> incr effects; returned ()) in
  let result = tool.call ~call_id:"actual-host-call-id" (`Assoc ["input",`String "original-arguments"]) in
  check bool "host returns its typed scheduling stop" true (result.abort_turn=Some stop);
  check (option string) "durable retention has no terminal error" None !terminal_error;
  let original = load base_path in
  check int "original is durable before the transport receives its stop" 1
    (List.length (Outbox.receipt_ids original));
  let context = String.concat "\n" (Outbox.developer_context original) in
  List.iter (fun bytes -> check bool "retained data includes original source and complete result" true
    (String_util.contains_substring context bytes))
    [marker;"original-block-bytes";"original-arguments";"actual-host-call-id";
     "host_producer_id";"host_turn_count";"host_invocation_index";"host-result-fixture"];
  check bool "host source does not impersonate vendor coordinates" false
    (String_util.contains_substring context "thread_id");
  get (Outbox.settle_after_turn before ~stop_reason:(Completed {provider_turn_ordinal=0}));
  check int "the earlier consumer snapshot cannot ACK a newly produced result" 1
    (List.length (Outbox.receipt_ids (load base_path)));
  get (Outbox.settle_after_turn original
    ~stop_reason:(Yielded_to_durable_stimulus {turns_used=1;provider_turn_ordinal=0}));
  check int "handoff does not consume the returned original" 1
    (List.length (Outbox.receipt_ids (load base_path)));
  get (Outbox.settle_after_turn original ~stop_reason:(Completed {provider_turn_ordinal=1}));
  check int "the later completed consumer ACKs the exact original" 0
    (List.length (Outbox.receipt_ids (load base_path)));
  check int "receipt consumption executes no effect again" 1 !effects)

let test_ordinary_tool_acknowledges_only_frozen_physical_writes () = with_workspace (fun base_path ->
  Eio.Switch.run (fun result_scope ->
    let tool, producer = project_with_producer ~result_scope:(Some result_scope)
      ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
    let producer = match producer with Some producer -> producer | None -> fail "missing actual producer" in
    let call () = tool.call ~call_id:"reused-ordinary-client-id" (`Assoc []) in
    let sent = call () in
    let unsent = call () in
    check bool "ordinary result stays with its original provider" true (Option.is_none sent.abort_turn);
    check int "active ordinary results cannot wake a concurrent consumer" 0
      (List.length (Outbox.receipt_ids (load base_path)));
    let notify (result : Host.dynamic_tool_result) = match result.on_response_sent with
      | Some notify -> notify () | None -> fail "unchanged original has no physical-write token" in
    notify sent; notify sent;
    let delivered = Outbox.close_delivery_frontier producer in
    check int "repeated notification marks exactly one physical response" 1
      (List.length (Outbox.receipt_ids delivered));
    notify unsent;
    let late = call () in
    notify late;
    check (list string) "terminal frontier excludes late marks and later completed tools"
      (Outbox.receipt_ids delivered) (Outbox.receipt_ids (Outbox.close_delivery_frontier producer));
    get (Outbox.settle_after_turn delivered
      ~stop_reason:(Yielded_to_durable_stimulus {turns_used=1;provider_turn_ordinal=0}));
    get (Outbox.settle_after_turn delivered ~stop_reason:(Completed {provider_turn_ordinal=1})));
  let pending = load base_path in
  check int "normal completion ACKs only the sent original before its terminal" 2
    (List.length (Outbox.receipt_ids pending));
  check bool "late originals retain complete returned bytes" true
    (String_util.contains_substring (String.concat "" (Outbox.developer_context pending)) marker))

let test_disconnect_before_write_retains_ordinary_original () = with_workspace (fun base_path ->
  Eio.Switch.run (fun result_scope ->
    let tool, producer = project_with_producer ~result_scope:(Some result_scope)
      ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
    ignore (tool.call ~call_id:"disconnected-response" (`Assoc []));
    let producer = match producer with Some producer -> producer | None -> fail "missing actual producer" in
    let delivered = Outbox.close_delivery_frontier producer in
    check (list string) "no complete transport write was observed" [] (Outbox.receipt_ids delivered);
    get (Outbox.settle_after_turn delivered ~stop_reason:(Completed {provider_turn_ordinal=1})));
  check int "transport loss leaves the original for a later consumer" 1
    (List.length (Outbox.receipt_ids (load base_path))))

let test_post_hook_failure_preserves_original_before_substitution () = with_workspace (fun base_path ->
  let effects = ref 0 and terminal_error = ref None in
  let hooks = {Agent_core.Hooks.empty with post_tool_use=Some (fun _ ->
    let original = load base_path in
    check int "the original is durable before the user's post hook runs" 1
      (List.length (Outbox.receipt_ids original));
    check bool "the hook sees exact original bytes already saved" true
      (String_util.contains_substring (String.concat "" (Outbox.developer_context original)) marker);
    Agent_core.Hooks.HookFailed {stage=Post_tool_use;detail="post-effect observer failed"})} in
  let tool = project ~hooks ~base_path ~stop:None ~terminal_error
    (fun _ -> incr effects; returned ()) in
  let result = tool.call ~call_id:"post-hook-original" (`Assoc []) in
  check bool "the host recorded its later hook failure" true (Option.is_some !terminal_error);
  check bool "substituted hook guidance cannot claim original delivery" true
    (Option.is_none result.on_response_sent);
  check int "post-hook failure executes the effect only once" 1 !effects;
  check int "the original survives a later observer failure" 1
    (List.length (Outbox.receipt_ids (load base_path))))

let test_retention_failure_cannot_claim_safe_consumption () = with_workspace (fun base_path ->
  let session_path = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
  Fs_compat.mkdir_p (Filename.dirname session_path);
  Fs_compat.save_file (Filename.concat (Filename.dirname session_path) "undelivered-tools") "blocked original store";
  let terminal_error = ref None and effects = ref 0 in
  let tool = project ~base_path ~stop:(Some stop) ~terminal_error
      (fun _ -> incr effects; returned ()) in
  let result = tool.call ~call_id:"failed-retention-call" (`Assoc []) in
  let stop = match result.abort_turn with
    | Some (Host.Terminal_tool_boundary
        {outcome=Terminal_failed {failure_class=Tool_result.Runtime_failure;
          effect_disposition=Tool_result.Effect_outcome_unknown;
          detail=Keeper_terminal_effect_detail.Tool_result_retention_failed {model_tool_name;message}};_} as stop) ->
      check string "failed original belongs to the executed tool" "CompleteEffect" model_tool_name;
      check bool "storage diagnosis is preserved" true (message <> "");
      stop
    | Some _ | None -> fail "retention refusal must replace a safe scheduling stop with typed failure" in
  (match Host.host_stop_result ~runtime_id:"fixture" ~model:"fixture" ~session_id:"session"
      ~turn_id:"turn" ~provider_turn_ordinal:0 ~turns_used:1 ~latency_ms:None ~request_context:None stop with
   | Error error ->
     (match Keeper_internal_error.classify_masc_internal_error error with
      | Some (Keeper_internal_error.Terminal_effect_failed
          {detail=Keeper_terminal_effect_detail.Tool_result_retention_failed _;_}) -> ()
      | Some _ | None -> fail "host lost its typed retention failure")
   | Ok _ -> fail "host settlement cannot yield or complete after original retention failed");
  check bool "runtime receives additional diagnostic" true (Option.is_some !terminal_error);
  check string "actual returned content is not invented or discarded" marker result.content;
  check int "storage refusal does not replay completed effect" 1 !effects;
  match Outbox.load ~base_path ~keeper_name with
  | Error _ -> () | Ok _ -> fail "unavailable original store became empty success")

let test_retention_failure_keeps_proven_effect () = with_workspace (fun base_path ->
  let session_path = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
  Fs_compat.mkdir_p (Filename.dirname session_path);
  Fs_compat.save_file (Filename.concat (Filename.dirname session_path) "undelivered-tools") "blocked";
  let effect_state = Keeper_tools_agent_core.Terminal_effect_completed
      (Keeper_tool_execution.Surface_post_completed
        (Keeper_surface_post.To_discord {channel_id="fixture-destination"})) in
  let tool = project ~effect_state ~base_path ~stop:(Some stop) ~terminal_error:(ref None)
      (fun _ -> returned ()) in
  match (tool.call ~call_id:"proven-effect-retention-failure" (`Assoc [])).abort_turn with
  | Some (Host.Terminal_tool_boundary {outcome=Terminal_failed
      {effect_disposition=Tool_result.Proven_post_effect;
       detail=Keeper_terminal_effect_detail.Tool_result_retention_failed _;_};_}) -> ()
  | Some _ | None -> fail "retention refusal lost the producer's committed-effect proof")

let test_retention_failure_preserves_authoritative_failure () = with_workspace (fun base_path ->
  let session_path = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
  Fs_compat.mkdir_p (Filename.dirname session_path);
  Fs_compat.save_file (Filename.concat (Filename.dirname session_path) "undelivered-tools") "blocked";
  let terminal_error = ref None in
  let failure : Keeper_tools_agent_core.terminal_effect_failure =
    {failure_class=Tool_result.Workflow_rejection;effect_disposition=Tool_result.Proven_post_effect;
     detail=Keeper_terminal_effect_detail.Tool_failed {internal_tool_name="effect";message="original failure"}} in
  let tool = project ~effect_state:(Keeper_tools_agent_core.Terminal_effect_failed failure)
      ~base_path ~stop:(Some stop) ~terminal_error (fun _ -> returned ()) in
  let result = tool.call ~call_id:"failed-effect-and-retention" (`Assoc []) in
  (match result.abort_turn with
   | Some (Host.Terminal_tool_boundary {outcome=Terminal_failed original;_}) ->
     check bool "producer failure remains authoritative" true
       (original.failure_class=failure.failure_class && original.effect_disposition=failure.effect_disposition
        && original.detail=failure.detail)
   | Some _ | None -> fail "authoritative effect failure disappeared");
  check bool "secondary original-result retention failure is recorded" true
    (match !terminal_error with
     | Some message -> String_util.contains_substring message "original result was not retained"
     | None -> false))

let test_producer_identity_and_vendor_coexistence () = with_workspace (fun base_path ->
  let first = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"Claude" ~turn_count:1)
  and replacement = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"Muse" ~turn_count:1) in
  let retain ?(invocation_index=0) producer = get (Outbox.retain_host_result producer ~invocation_index
    ~call_id:"same-client-local-call-id" ~tool_name:"Execute" ~arguments:(`Assoc []) ~response:(`String marker)) in
  retain first; retain first;
  check int "the same original source/result is idempotent" 1
    (List.length (Outbox.receipt_ids (load base_path)));
  retain ~invocation_index:1 first;
  check int "distinct physical invocation survives identical client id and returned bytes" 2
    (List.length (Outbox.receipt_ids (load base_path)));
  retain replacement;
  get (Outbox.retain ~base_path ~keeper_name
    {thread_id="actual-vendor-thread";turn_id="actual-vendor-turn";call_id="actual-vendor-call";
     tool_name="Execute";arguments=`Assoc [];response=`String "original vendor result"});
  check int "replacement host and vendor sources retain their own identities" 4
    (List.length (Outbox.receipt_ids (load base_path))))

let test_mcp_reused_string_id_keeps_physical_invocations () = with_workspace (fun base_path ->
  let module Mcp = Runtime_official_client_mcp in
  let effects = ref 0 and invocations = ref [] and pending_stops = ref [] in
  let stop_latch = ref None in
  let tool = project ~base_path ~stop:(Some stop) ~terminal_error:(ref None)
      ~on_result_handoff:(fun ~invocation ~content:_ ->
        invocations := !invocations @
          [Agent_core.Tool_contract.Invocation.tool_use_id invocation,
           Agent_core.Tool_contract.Invocation.planned_index invocation])
      (fun _ -> incr effects; returned ()) in
  let session = Mcp.create_session () in
  let dispatch message =
    match Mcp.handle_message ~session ~server_name:"fixture" ~tool_call_policy:Mcp.Allow_tool_calls
        ~tool_specs:(fun () -> [])
        ~call_tool:(fun ~name ~call_id ~arguments ->
          if name <> tool.name then None else
          let result = tool.call ~call_id arguments in
          Option.iter (fun stop -> pending_stops := !pending_stops @ [stop]) result.abort_turn;
          Some {Mcp.success=result.success;content=result.content;content_blocks=result.content_blocks}) message with
    | Ok result -> result
    | Error {detail;_} -> fail detail in
  ignore (dispatch (`Assoc ["jsonrpc",`String "2.0";"id",`Int 1;"method",`String "initialize";
    "params",`Assoc ["protocolVersion",`String "2025-11-25";"capabilities",`Assoc [];
      "clientInfo",`Assoc ["name",`String "fixture";"version",`String "1"]]]));
  ignore (dispatch (`Assoc ["jsonrpc",`String "2.0";"method",`String "notifications/initialized"]));
  let request = `Assoc ["jsonrpc",`String "2.0";"id",`String "reused-client-id";
    "method",`String "tools/call";"params",`Assoc ["name",`String "CompleteEffect";
      "arguments",`Assoc ["input",`String "same-arguments"]]] in
  (* Core dispatch precedes the transport's response-sent stop notification.
     Both physical calls can therefore enter this same Host projection before
     that notification latches the stop. No synthetic call IDs are supplied. *)
  let first = dispatch request in
  let second = dispatch request in
  List.iter (fun (result : Mcp.dispatch) ->
    check bool "actual MCP dispatcher ran the physical tool" true result.tool_called;
    match result.response with
    | Some (`Assoc fields) ->
      check bool "MCP string request id stays unchanged" true
        (List.assoc_opt "id" fields=Some (`String "reused-client-id"))
    | Some _ | None -> fail "MCP dispatch lost its response") [first;second];
  check (option string) "transport stop callback has not latched yet" None
    (Option.map (fun _ -> "latched") !stop_latch);
  check (list (pair string int)) "Host assigns distinct physical indices to reused MCP id"
    ["reused-client-id",0;"reused-client-id",1] !invocations;
  check int "both effects actually execute" 2 !effects;
  check int "both stop notifications await transport response handling" 2 (List.length !pending_stops);
  check int "both originals survive identical producer, MCP id, arguments and result" 2
    (List.length (Outbox.receipt_ids (load base_path)));
  List.iter (fun stop -> if Option.is_none !stop_latch then stop_latch := Some stop) !pending_stops;
  check bool "transport can subsequently latch the original stop" true (!stop_latch=Some stop))

let test_host_invocation_index_validation () =
  List.iter (fun index_fields -> with_workspace (fun base_path ->
    let producer = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"index-validation" ~turn_count:0) in
    get (Outbox.retain_host_result producer ~invocation_index:0
      ~call_id:"call" ~tool_name:"Execute" ~arguments:(`Assoc []) ~response:(`String marker));
    let session_path = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
    let directory = Filename.concat (Filename.dirname session_path) "undelivered-tools" in
    let id = match Outbox.receipt_ids (load base_path) with
      | [id] -> id | _ -> fail "one validation seed required" in
    let original = In_channel.with_open_bin (Filename.concat directory (id ^ ".json"))
      In_channel.input_all |> Yojson.Safe.from_string in
    let fields = match original with `Assoc fields -> List.remove_assoc "host_invocation_index" fields
      | _ -> fail "persisted original must be an object" in
    let invalid = `Assoc (index_fields @ fields) in
    (* Recompute the real digest so schema validation, not a filename mismatch,
       refuses this committed receipt. Keep the valid seed beside it. *)
    let name = Agent_core_sha256.(digest_string (Yojson.Safe.to_string invalid) |> to_hex) ^ ".json" in
    Fs_compat.save_file (Filename.concat directory name) (Yojson.Safe.to_string invalid);
    match Outbox.load ~base_path ~keeper_name with
    | Error _ -> () | Ok _ -> fail "malformed physical invocation index was accepted"))
    [ []; ["host_invocation_index",`Int (-1)]; ["host_invocation_index",`String "0"];
      ["host_invocation_index",`Int 0;"host_invocation_index",`Int 1] ];
  with_workspace (fun base_path ->
    let producer = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"negative-index" ~turn_count:0) in
    match Outbox.retain_host_result producer ~invocation_index:(-1)
      ~call_id:"call" ~tool_name:"Execute" ~arguments:(`Assoc []) ~response:(`String marker) with
    | Error _ -> check int "invalid producer index creates no receipt" 0
        (List.length (Outbox.receipt_ids (load base_path)))
    | Ok () -> fail "negative producer invocation index was retained")

let () = run "Original official-client host result retention"
  ["durable host stop",[
    test_case "typed stop retains original before transport continuation" `Quick test_stop_retains_before_transport_return;
    test_case "ordinary completion ACKs only frozen physical writes" `Quick test_ordinary_tool_acknowledges_only_frozen_physical_writes;
    test_case "disconnect before write preserves ordinary original" `Quick test_disconnect_before_write_retains_ordinary_original;
    test_case "original is retained before later post-hook failure" `Quick test_post_hook_failure_preserves_original_before_substitution;
    test_case "retention failure prevents safe consumption claim" `Quick test_retention_failure_cannot_claim_safe_consumption;
    test_case "retention failure keeps the proven committed effect" `Quick test_retention_failure_keeps_proven_effect;
    test_case "retention failure preserves authoritative effect failure" `Quick test_retention_failure_preserves_authoritative_failure;
    test_case "MCP reused string id keeps each physical invocation" `Quick test_mcp_reused_string_id_keeps_physical_invocations;
    test_case "host invocation index schema is strict" `Quick test_host_invocation_index_validation;
    test_case "source identity deduplicates exact originals across mixed producers" `Quick test_producer_identity_and_vendor_coexistence]]
