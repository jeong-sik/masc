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
    ~terminal_error ~pre_tool_rejects:(ref []) ~on_tool_boundary:(fun ~tool_name:_ -> Ok stop)
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
  content_blocks=Some [Llm_provider.Types.Text "original-block-bytes"];_meta=None}

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

(* The Read of a file whose line was cut inside a Korean syllable: the tool's
   bytes are not UTF-8, the receipt is JSON, and [load] repairs on read. *)
let test_cut_multibyte_result_is_retained_and_sendable () = with_workspace (fun base_path ->
  let cut = "\xEB\xA1\x9C\xEC\x9D" in
  let terminal_error = ref None in
  Eio.Switch.run (fun result_scope ->
    let tool, _ = project_with_producer ~result_scope:(Some result_scope)
      ~base_path ~stop:None ~terminal_error (fun _ ->
        Ok {Agent_core.Types.content=marker ^ cut;
            content_blocks=Some [Llm_provider.Types.Text cut];_meta=None}) in
    let sent = tool.call ~call_id:"cut-read" (`Assoc []) in
    check bool "the string sent to the client is valid UTF-8" true
      (String.is_valid_utf_8 sent.content);
    check bool "the sent original keeps its physical-write token" true
      (Option.is_some sent.on_response_sent));
  check (option string) "retention reports no failure" None !terminal_error;
  check int "the original is retained and the outbox still loads" 1
    (List.length (Outbox.receipt_ids (load base_path))))

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

let test_shared_context_preserves_each_retained_result () = with_workspace (fun base_path ->
  let first = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"client-a" ~turn_count:1)
  and second = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"client-b" ~turn_count:1) in
  let arguments = `Assoc ["page",`String (String.make 4096 'a'); "offset",`Int 0] in
  let response = `Assoc ["ok",`Bool true; "content",`String "retained \"original\" 한글"] in
  for index = 0 to 19 do
    get (Outbox.retain_host_result first ~invocation_index:index ~call_id:"reused-id"
      ~tool_name:"Read" ~arguments ~response)
  done;
  get (Outbox.retain_host_result second ~invocation_index:0 ~call_id:"reused-id"
    ~tool_name:"Read" ~arguments ~response:(`Assoc ["ok",`Bool false; "error",`String "not executed"]));
  get (Outbox.retain ~base_path ~keeper_name
    {thread_id="vendor-thread";turn_id="vendor-turn";call_id="vendor-call";
     tool_name="Read";arguments;response});
  let snapshot = load base_path in
  let ids = Outbox.receipt_ids snapshot in
  check int "physical calls and both producer kinds remain distinct" 22 (List.length ids);
  List.iter (fun id ->
    check bool "each retained result is found by its exact identity" true
      (Outbox.contains_receipt snapshot ~receipt_id:id)) ids;
  check bool "a different identity is not present" false
    (Outbox.contains_receipt snapshot ~receipt_id:"not-a-receipt");
  let session = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
  let directory = Filename.concat (Filename.dirname session) "undelivered-tools" in
  let originals = List.map (fun id -> Yojson.Safe.from_file (Filename.concat directory (id ^ ".json"))) ids in
  let context = match Outbox.developer_context snapshot with
    | [context] -> context | _ -> fail "one retained-results context expected" in
  let json_start = String.rindex context '\n' + 1 in
  let json = String.sub context json_start (String.length context - json_start) in
  let payload = Yojson.Safe.from_string json in
  let shared, references = match payload with
    | `Assoc fields ->
      (match List.assoc_opt "shared" fields, List.assoc_opt "receipts" fields with
       | Some (`List shared), Some (`List references) -> Array.of_list shared, references
       | _ -> fail "missing shared receipt data")
    | _ -> fail "repeated large receipts should use shared data" in
  let unpack reference =
    let index, fields = match reference with
      | `List [`Int index; `String call_id] -> index, ["call_id", `String call_id]
      | `List [`Int index; `String call_id; `Int physical_index] ->
        index, ["call_id", `String call_id; "host_invocation_index", `Int physical_index]
      | _ -> fail "invalid receipt reference" in
    if index < 0 || index >= Array.length shared then fail "invalid shared index";
    match shared.(index) with
    | `Assoc common -> `Assoc (fields @ common)
    | _ -> fail "shared result must be an object" in
  let reconstructed = List.map unpack references in
  check bool "every original survives in snapshot order, including failures and identity" true
    (Yojson.Safe.equal (Yojson.Safe.sort (`List originals)) (Yojson.Safe.sort (`List reconstructed)));
  check bool "shared context including its explanation is smaller" true
    (String.length Keeper_client_tool_outbox_encoding.shared_description + String.length json
     < String.length (Yojson.Safe.to_string (`List originals)));
  check (list string) "producing context changes no durable acknowledgements" ids
    (Outbox.receipt_ids (load base_path)))

let test_ambiguous_receipt_shape_is_not_shared () =
  let payload = `String (String.make 4096 'x') in
  let rows = List.init 4 (fun index ->
    `Assoc ["call_id",`String "first"; "call_id",`String (string_of_int index); "response",payload]) in
  match Keeper_client_tool_outbox_encoding.encode rows with
  | Individual json ->
    check bool "fallback preserves ambiguous fields" true
      (Yojson.Safe.equal (`List rows) (Yojson.Safe.from_string json))
  | Shared _ -> fail "ambiguous identities must not use shared encoding"

let test_small_shared_json_does_not_expand_context () =
  let response = `String (String.make 50 'x') in
  let rows = List.map (fun call_id ->
    `Assoc ["thread_id",`String "t"; "turn_id",`String "u"; "tool_name",`String "Read";
      "call_id",`String call_id; "arguments",`Assoc []; "response",response]) ["a";"b"] in
  match Keeper_client_tool_outbox_encoding.encode rows with
  | Individual json ->
    check bool "individual retains the complete inputs" true
      (Yojson.Safe.equal (`List rows) (Yojson.Safe.from_string json))
  | Shared _ -> fail "shared explanation would make this input larger"

let test_unique_results_remain_individual () =
  let payload = `String (String.make 4096 'x') in
  let rows = List.init 8 (fun index ->
    `Assoc ["call_id",`String (string_of_int index);
      "response",`Assoc ["sequence",`Int index; "payload",payload]]) in
  match Keeper_client_tool_outbox_encoding.encode rows with
  | Individual json ->
    check bool "unique results remain complete" true
      (Yojson.Safe.equal (`List rows) (Yojson.Safe.from_string json))
  | Shared _ -> fail "unrepeated results should remain individual"

let test_sparse_repetition_falls_back_without_losing_unique_result () =
  let row call_id response = `Assoc ["call_id", `String call_id; "response", `String response] in
  let rows = [row "first" "x"; row "second" "x"; row "third" (String.make 100_000 'y')] in
  match Keeper_client_tool_outbox_encoding.encode rows with
  | Individual json ->
    check string "large unique data survives when sharing is not worthwhile"
      (Yojson.Safe.to_string (`List rows)) json
  | Shared _ -> fail "small repeated group does not offset the shared description"

let test_shared_nested_signed_zero () =
  let payload = `String (String.make 4096 'x') in
  let rows = List.init 4 (fun index ->
    let number = if index mod 2 = 0 then 0.0 else -0.0 in
    `Assoc ["call_id",`String (string_of_int index);
      "response",`Assoc ["nested",`List [`Float number]; "payload",payload]]) in
  let json = match Keeper_client_tool_outbox_encoding.encode rows with
    | Shared json -> Yojson.Safe.from_string json
    | Individual _ -> fail "the repeated large results should be shared" in
  let open Yojson.Safe.Util in
  let shared = json |> member "shared" |> to_list |> Array.of_list in
  let refs = json |> member "receipts" |> to_list in
  check int "each input has one shared reference" 4 (List.length refs);
  List.iteri (fun index row ->
    let shared_index = match row with
      | `List [`Int shared_index; `String _] -> shared_index
      | _ -> fail "invalid shared reference" in
    let value = shared.(shared_index) |> member "response" |> member "nested" |> to_list in
    let actual = match value with [`Float number] -> Int64.bits_of_float number
      | _ -> fail "missing nested number" in
    let expected = Int64.bits_of_float (if index mod 2 = 0 then 0.0 else -0.0) in
    check bool "each receipt retains the bit pattern of its nested zero" true (expected = actual)) refs

let test_representation_choice_uses_exact_serialized_size () =
  List.iter (fun count -> List.iter (fun payload_length -> List.iter (fun host ->
    let common = if payload_length = 0 then [] else
      ["payload", `String (String.make payload_length 'x');
       "nested", `Assoc ["same", `Int 1; "same", `String "\"한글\n"]] in
    let call_id index = Printf.sprintf "call-\"한글\n-%d" index in
    let identity index = ["call_id", `String (call_id index)] @
      if host then ["host_invocation_index", `Int index] else [] in
    let rows = List.init count (fun index ->
      let fields = if index mod 2 = 0 then identity index @ common else common @ identity index in
      `Assoc fields) in
    let references = List.init count (fun index ->
      `List ([`Int 0; `String (call_id index)] @ if host then [`Int index] else [])) in
    let individual = Yojson.Safe.to_string (`List rows) in
    let shared = Yojson.Safe.to_string (`Assoc ["shared", `List [`Assoc common];
      "receipts", `List references]) in
    let sharing_is_smaller = String.length Keeper_client_tool_outbox_encoding.shared_description
      + String.length shared < String.length individual in
    (match Keeper_client_tool_outbox_encoding.encode rows with
     | Shared actual ->
       check bool "shared representation is selected only when smaller" true sharing_is_smaller;
       check string "shared representation contains every reference" shared actual
     | Individual actual ->
       check bool "individual is selected when sharing is not smaller" false sharing_is_smaller;
       check string "individual representation retains original field order" individual actual))
    [false;true]) [0;40;200;2048]) [2;5;24;72]

let test_mixed_groups_use_exact_serialized_size () =
  List.iter (fun payload_length ->
    let groups = [| []; ["response", `String (String.make payload_length 'x')];
      ["response", `String (String.make 10_000 'y')] |] in
    let specs = [0, "a\"", None; 1, "b", Some 0; 0, "c\n", Some 1;
      2, "unique", None; 1, "한글", None] in
    let rows = List.map (fun (group, call_id, physical) ->
      let identity = ["call_id", `String call_id] @
        Option.to_list (Option.map (fun index -> "host_invocation_index", `Int index) physical) in
      `Assoc (identity @ groups.(group))) specs in
    let references = List.map (fun (group, call_id, physical) ->
      `List ([`Int group; `String call_id] @ Option.to_list (Option.map (fun index -> `Int index) physical))) specs in
    let individual = Yojson.Safe.to_string (`List rows) in
    let shared = Yojson.Safe.to_string (`Assoc
      ["shared", `List (Array.to_list (Array.map (fun fields -> `Assoc fields) groups));
       "receipts", `List references]) in
    let sharing_is_smaller = String.length Keeper_client_tool_outbox_encoding.shared_description
      + String.length shared < String.length individual in
    match Keeper_client_tool_outbox_encoding.encode rows with
    | Shared actual ->
      check bool "mixed groups select shared only when smaller" true sharing_is_smaller;
      check string "mixed groups retain each reference" shared actual
    | Individual actual ->
      check bool "mixed groups fall back only when sharing is not smaller" false sharing_is_smaller;
      check string "mixed groups retain original fields" individual actual) [1; 202; 203; 204; 6000]

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

(* A Read of a file whose line was cut inside a Korean syllable returns bytes
   that [Safe_ops.parse_json_safe] repairs to U+FFFD on every later read. *)
let test_original_that_reads_back_different_creates_no_receipt () = with_workspace (fun base_path ->
  let producer = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"invalid-utf8" ~turn_count:0) in
  let retain invocation_index response = Outbox.retain_host_result producer ~invocation_index
    ~call_id:"call" ~tool_name:"Read" ~arguments:(`Assoc []) ~response in
  let cut_mid_syllable = "\xEB\xA1\x9C\xEA\xB7\xB8\xEC\x9D" in
  (match retain 0 (`String cut_mid_syllable) with
   | Error _ -> ()
   | Ok () -> fail "a response that changes when read back was retained");
  check int "the rejected response leaves no receipt and load still succeeds" 0
    (List.length (Outbox.receipt_ids (load base_path)));
  get (retain 1 (`String "\xEB\xA1\x9C\xEA\xB7\xB8\xEC\x9D\xB8"));
  get (retain 2 (`String marker));
  check int "later valid originals, including Korean text, are retained" 2
    (List.length (Outbox.receipt_ids (load base_path))))

let () = run "Original official-client host result retention"
  ["durable host stop",[
    test_case "typed stop retains original before transport continuation" `Quick test_stop_retains_before_transport_return;
    test_case "ordinary completion ACKs only frozen physical writes" `Quick test_ordinary_tool_acknowledges_only_frozen_physical_writes;
    test_case "cut multibyte result is retained and sendable" `Quick test_cut_multibyte_result_is_retained_and_sendable;
    test_case "disconnect before write preserves ordinary original" `Quick test_disconnect_before_write_retains_ordinary_original;
    test_case "original is retained before later post-hook failure" `Quick test_post_hook_failure_preserves_original_before_substitution;
    test_case "retention failure prevents safe consumption claim" `Quick test_retention_failure_cannot_claim_safe_consumption;
    test_case "retention failure keeps the proven committed effect" `Quick test_retention_failure_keeps_proven_effect;
    test_case "retention failure preserves authoritative effect failure" `Quick test_retention_failure_preserves_authoritative_failure;
    test_case "MCP reused string id keeps each physical invocation" `Quick test_mcp_reused_string_id_keeps_physical_invocations;
    test_case "host invocation index schema is strict" `Quick test_host_invocation_index_validation;
    test_case "original that reads back different creates no receipt" `Quick test_original_that_reads_back_different_creates_no_receipt;
    test_case "source identity deduplicates exact originals across mixed producers" `Quick test_producer_identity_and_vendor_coexistence;
    test_case "shared context preserves retained originals in order" `Quick test_shared_context_preserves_each_retained_result;
    test_case "ambiguous receipt shape remains individual" `Quick test_ambiguous_receipt_shape_is_not_shared;
    test_case "small shared JSON does not expand context" `Quick test_small_shared_json_does_not_expand_context;
    test_case "unique results remain individual" `Quick test_unique_results_remain_individual;
    test_case "sparse repetition preserves the large unique result" `Quick test_sparse_repetition_falls_back_without_losing_unique_result;
    test_case "nested signed zero stays distinct" `Quick test_shared_nested_signed_zero;
    test_case "representation choice matches serialized size" `Quick test_representation_choice_uses_exact_serialized_size;
    test_case "mixed groups match serialized size" `Quick test_mixed_groups_use_exact_serialized_size]]
