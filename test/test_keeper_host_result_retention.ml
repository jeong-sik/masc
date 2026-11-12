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
    ?(loading_plan = Host.All_on_demand) ?read_arrived ?(raw_trace_run = None)
    ~base_path ~stop ~terminal_error handler =
  let tool = Agent_core.Tool.create ~name:"CompleteEffect" ~description:"Complete an effect once"
      ~parameters:[{Agent_core.Types.name="input";description="original call data";
        param_type=String;required=false}] handler in
  match Host.dynamic_tools ~result_scope ~base_path ?read_arrived
    ~content_transport:Runtime_official_client_tool.Mcp
    ~accepts_image_input:true ~tool_approval:None ~runtime_label:"host-result-fixture"
    ~keeper_name ~turn_count:7 ~tools:[tool] ~loading_plan
    ~hooks ~event_bus:None ~context_injector:None
    ~context:(Some (Agent_core.Context.create_sync ()))
    ~terminal_effect_state:(fun () -> effect_state)
    ~terminal_error ~pre_tool_rejects:(ref []) ~on_tool_boundary:(fun ~tool_name:_ -> Ok stop)
    ~on_result_handoff ~raw_trace_run () with
  | Ok ([tool], producer) -> tool, producer
  | Ok _ -> fail "one original tool required"
  | Error error -> fail (Agent_core.Error.to_string error)

let project ?result_scope ?hooks ?effect_state ?on_result_handoff ?loading_plan ?read_arrived
    ?raw_trace_run ~base_path ~stop ~terminal_error handler =
  fst (project_with_producer ?result_scope ?hooks ?effect_state ?on_result_handoff
    ?loading_plan ?read_arrived ?raw_trace_run ~base_path ~stop ~terminal_error handler)

let stop = Host.Terminal_tool_boundary {tool_name="CompleteEffect";outcome=Durable_stimulus_deferred}
let load base_path = get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt)
let returned () = Ok {Agent_core.Types.content=marker;
  content_blocks=Some [Llm_provider.Types.Text "original-block-bytes"];_meta=None}

let blob_store base_path = Tool_blob_store.create ~base_path

let held store sha256 = match Tool_blob_store.fetch store ~sha256 with
  | Ok held -> held
  | Error error -> fail (Tool_blob_store.fetch_error_to_string error)

(* The masc_dos_screen result of #49634: a few KB of text and a PNG. Every
   later request re-reads a retained receipt, so it names the bytes by blob
   address and the store holds them. *)
let test_screenshot_receipt_names_bytes_by_address () = with_workspace (fun base_path ->
  let screen = String.concat " " (List.init 512 (Printf.sprintf "cell-%03d")) in
  let png = "\x89PNG\r\n\x1a\n" ^ String.make 4096 '\x07' in
  let payload = Base64.encode_string png in
  let tool = Agent_core.Tool.create ~name:"Screenshot" ~description:"Return the screen"
      ~parameters:[] (fun _ -> Ok {Agent_core.Types.content=screen;
        content_blocks=Some [Llm_provider.Types.Text screen;
          Llm_provider.Types.Image {media_type="image/png";
            source=Llm_provider.Types.Base64 payload}];_meta=None}) in
  let terminal_error = ref None in
  let screenshot = match Host.dynamic_tools ~result_scope:None ~base_path
      ~content_transport:Runtime_official_client_tool.Mcp ~accepts_image_input:true
      ~tool_approval:None ~runtime_label:"host-result-fixture" ~keeper_name ~turn_count:7
      ~tools:[tool] ~loading_plan:Host.All_on_demand ~hooks:Agent_core.Hooks.empty
      ~event_bus:None ~context_injector:None ~context:(Some (Agent_core.Context.create_sync ()))
      ~terminal_effect_state:(fun () -> Keeper_tools_agent_core.Terminal_effect_open)
      ~terminal_error ~pre_tool_rejects:(ref []) ~on_tool_boundary:(fun ~tool_name:_ -> Ok None)
      ~raw_trace_run:None () with
    | Ok ([screenshot], _) -> screenshot
    | Ok _ -> fail "one screenshot tool is projected"
    | Error error -> fail (Agent_core.Error.to_string error) in
  ignore (screenshot.call ~call_id:"screen-call" (`Assoc []));
  check (option string) "retention reports no failure" None !terminal_error;
  let pending = load base_path in
  check int "the result is retained" 1 (List.length (Outbox.receipt_ids pending));
  let context = String.concat "\n" (Outbox.developer_context pending) in
  let contains = String_util.contains_substring context in
  let address bytes = Agent_core_sha256.(digest_string bytes |> to_hex) in
  let store = blob_store base_path in
  check bool "no base64 payload rides in the receipt" false (contains payload);
  check bool "no text body rides in the receipt" false (contains screen);
  check bool "the receipt names the image by its address" true (contains (address png));
  check (option string) "the store holds the image bytes" (Some png) (held store (address png));
  check (option string) "the store holds the text bytes" (Some screen) (held store (address screen)))

(* What [Outbox.host_response] writes for each payload. An undecodable payload
   is still what the tool returned, so it is kept by address instead of
   failing the retention. Media is labelled octet-stream whatever type the
   tool names, so blob maintenance never expands it as an artifact manifest. *)
let test_host_response_names_each_payload () = with_workspace (fun base_path ->
  let open Yojson.Safe.Util in
  let producer = get (Outbox.host_producer ~base_path ~keeper_name
      ~runtime_label:"host-result-fixture" ~turn_count:7) in
  let respond ~min_result_bytes content content_blocks =
    get (Outbox.host_response producer ~min_result_bytes ~success:true ~content ~content_blocks) in
  let store = blob_store base_path in
  let blob json = match Tool_output.normalized_artifact_ref_of_json json with
    | Tool_output.Decoded_normalized_artifact_ref reference -> reference
    | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ ->
      fail "a blob address is expected" in
  let marker text = match Tool_output.decode_from_agent_core text with
    | Tool_output.Decoded reference -> reference
    | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> fail "a blob marker is expected" in
  let wrapped = "aGVs\nbG8=" and document = "bytes that are not a manifest" in
  let media = respond ~min_result_bytes:0 "small" (Some [
      Llm_provider.Types.Image {media_type="image/png"; source=Llm_provider.Types.Base64 wrapped};
      Llm_provider.Types.Document {media_type=Tool_output.artifact_manifest_mime;
        source=Llm_provider.Types.Base64 (Base64.encode_string document)}]) in
  (match media |> member "content_blocks" |> to_list with
   | [undecodable; named] ->
     check bool "an undecodable payload names no media" true (member "artifact" undecodable = `Null);
     check (option string) "its exact string is held" (Some wrapped)
       (held store (blob (member "undecodable_base64" undecodable)).Tool_output.sha256);
     check bool "the decoder's reason is kept" true (member "detail" undecodable <> `Null);
     let reference = blob (member "artifact" named) in
     check string "media blobs never carry the tool's type" "application/octet-stream"
       reference.Tool_output.mime;
     check string "the block keeps the tool's type" Tool_output.artifact_manifest_mime
       (member "media_type" named |> to_string);
     check (option string) "the decoded bytes are held" (Some document)
       (held store reference.Tool_output.sha256)
   | _ -> fail "two media blocks are expected");
  check string "a body shorter than its marker stays inline" "small"
    (member "content" media |> to_string);
  let long = String.make 3000 'x' in
  check string "a result under the floor stays inline" long
    (respond ~min_result_bytes:4096 long None |> member "content" |> to_string);
  let shared = respond ~min_result_bytes:0 long (Some [Llm_provider.Types.Text long]) in
  let content = member "content" shared |> to_string in
  check (option string) "the marker names the exact body" (Some long)
    (held store (marker content).Tool_output.sha256);
  (match member "content_blocks" shared |> to_list with
   | [block] -> check string "a body content and a block share is one marker" content
       (member "text" block |> to_string)
   | _ -> fail "one text block is expected");
  check string "a marker already in the result stays as it is" content
    (respond ~min_result_bytes:0 content None |> member "content" |> to_string))

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
  match Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt with
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

(* Host receipts written before #49680 hold an image as a base64 wire block in
   [content_blocks]; today's host receipts name it by blob address instead
   (test_screenshot_receipt_names_bytes_by_address). Receipts of the old shape
   stay on disk until a completed turn acknowledges them. *)
let retain_old_host_image_receipt base_path ~call_id image =
  let block = match Agent_core.Checkpoint.wire_content_block_to_json_result
      ~scope:"official_client_original_tool_result" image with
    | Ok block -> block
    | Error error -> fail (Agent_core.Error.to_string error) in
  let producer = get (Outbox.host_producer ~base_path ~keeper_name
      ~runtime_label:"old-host-fixture" ~turn_count:1) in
  get (Outbox.retain_host_result producer ~invocation_index:0 ~call_id
         ~tool_name:"Screenshot" ~arguments:(`Assoc [])
         ~response:(`Assoc ["success", `Bool true; "content", `String "screenshot taken";
                            "content_blocks", `List [block]]))

let test_carrier_names_media_by_identity () = with_workspace (fun base_path ->
  let raw = String.init 3000 (fun index -> Char.chr (index mod 256)) in
  let encoded = Base64.encode_string raw in
  let stored = Agent_core.History.stored_of_raw raw in
  let image = Llm_provider.Types.Image {media_type="image/png";source=Llm_provider.Types.Base64 encoded} in
  retain_old_host_image_receipt base_path ~call_id:"host-image-call" image;
  let items = match Runtime_official_client_tool.project_content Codex
      ~content:"screenshot taken" ~content_blocks:(Some [image]) with
    | Ok items -> items | Error detail -> fail detail in
  get (Outbox.retain ~base_path ~keeper_name
    {thread_id="vendor-thread";turn_id="vendor-turn";call_id="codex-image-call";
     tool_name="Screenshot";arguments=`Assoc [];
     response=`Assoc ["id",`Int 9; "result",`Assoc ["success",`Bool true; "contentItems",`List items]]});
  let snapshot = load base_path in
  let session = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
  let directory = Filename.concat (Filename.dirname session) "undelivered-tools" in
  let read_receipts () = List.map (fun id ->
    Yojson.Safe.to_string (Yojson.Safe.from_file (Filename.concat directory (id ^ ".json"))))
    (Outbox.receipt_ids snapshot) in
  let before = read_receipts () in
  check int "host and Codex receipts are both retained" 2 (List.length before);
  List.iter (fun receipt -> check bool "each retained receipt keeps the base64 payload" true
    (String_util.contains_substring receipt encoded)) before;
  let context = String.concat "\n" (Outbox.developer_context snapshot) in
  check bool "the carrier holds no base64 payload" false
    (String_util.contains_substring context encoded);
  let identity = Printf.sprintf {|"media_type":"image/png","bytes":%d,"content_sha256":"%s"|}
      stored.bytes stored.sha256 in
  let rec count from found = match String_util.find_substring ~pos:from context identity with
    | Some index -> count (index + String.length identity) (found + 1)
    | None -> found in
  check int "both receipts name the image by its decoded length and digest" 2 (count 0 0);
  check (list string) "projecting the carrier leaves the receipt files unchanged" before
    (read_receipts ()))

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
    match Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt with
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

(* The carrier forms of RFC retained-results-carrier-shrinks-to-an-address.
   #49634: 248 retained receipts made one carrier larger than the window, and
   every request of the Keeper was refused until an operator moved them. *)

module Reprojection = Keeper_memory_delivery_reprojection

let refusal = Agent_core.Error.Internal "the provider refused the request size"

let reduction = testable (fun formatter reduction ->
    Format.pp_print_string formatter (match reduction with
      | Reprojection.Unchanged -> "Unchanged"
      | Reprojection.Reprojected -> "Reprojected")) ( = )

let form = testable (fun formatter form ->
    Format.pp_print_string formatter (match form with
      | Outbox.Inline -> "Inline"
      | Outbox.By_address -> "By_address")) ( = )

let check_reduction message expected actual =
  check (result reduction string) message (Ok expected) actual

let unreached ~refusal:_ = fail "the memory hook runs only when the carrier step is unchanged"

let sha256_hex text = Agent_core_sha256.(digest_string text |> to_hex)

let outbox_directory ~keeper_name base_path =
  let session = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
  Filename.concat (Filename.dirname session) "undelivered-tools"

let receipt_files base_path =
  let directory = outbox_directory ~keeper_name base_path in
  Sys.readdir directory |> Array.to_list |> List.sort String.compare
  |> List.map (fun name ->
    name, In_channel.with_open_bin (Filename.concat directory name) In_channel.input_all)

let vendor_receipt ~call_id ~tool_name response =
  {Outbox.thread_id="carrier-thread"; turn_id="carrier-turn"; call_id; tool_name;
   arguments=`Assoc ["call", `String call_id]; response}

(* Written as [Outbox.retain] writes them, without one durable write per file,
   so a test can hold thousands. The first goes through [Outbox.retain], which
   makes the owned outbox directory. *)
let retain_vendor_receipts ?(keeper_name = keeper_name) base_path = function
  | [] -> ()
  | first :: rest ->
    get (Outbox.retain ~base_path ~keeper_name first);
    let directory = outbox_directory ~keeper_name base_path in
    List.iter (fun (receipt : Outbox.receipt) ->
      let body = Yojson.Safe.to_string (`Assoc [
          "thread_id", `String receipt.Outbox.thread_id;
          "turn_id", `String receipt.Outbox.turn_id;
          "call_id", `String receipt.Outbox.call_id;
          "tool_name", `String receipt.Outbox.tool_name;
          "arguments", receipt.Outbox.arguments;
          "response", receipt.Outbox.response]) in
      Out_channel.with_open_gen [Open_wronly; Open_creat; Open_excl; Open_binary] 0o600
        (Filename.concat directory (sha256_hex body ^ ".json"))
        (fun channel -> Out_channel.output_string channel body)) rest

let switch carrier =
  match Outbox.carrier_reprojection carrier ~then_:unreached ~refusal with
  | Ok Reprojection.Reprojected -> ()
  | Ok Reprojection.Unchanged -> fail "the carrier switches to its address form"
  | Error detail -> fail detail

let carried_text carrier =
  match Outbox.carrier_context carrier with
  | [text] -> text
  | _ -> fail "the carrier is one text"

let carried_reference text =
  let marker_start = match String_util.find_substring text "[masc:blob " with
    | Some index -> index
    | None -> fail "the carrier names a blob" in
  let marker_end = match String.index_from_opt text marker_start ']' with
    | Some index -> index
    | None -> fail "the blob marker ends" in
  match Tool_output.decode_from_agent_core
          (String.sub text marker_start (marker_end - marker_start + 1)) with
  | Tool_output.Decoded reference -> reference
  | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> fail "the blob marker decodes"

let hiding sha256 text =
  match String_util.find_substring text sha256 with
  | Some index ->
    let after = index + String.length sha256 in
    String.concat "" [String.sub text 0 index; "<sha256>";
      String.sub text after (String.length text - after)]
  | None -> fail "the carrier names its blob by sha256"

let is_digit character = character >= '0' && character <= '9'

(* Every run of digits becomes one '#'. *)
let without_numbers text =
  let buffer = Buffer.create (String.length text) in
  String.iteri (fun index character ->
    if not (is_digit character) then Buffer.add_char buffer character
    else if index = 0 || not (is_digit text.[index - 1]) then Buffer.add_char buffer '#')
    text;
  Buffer.contents buffer

let message_text (message : Agent_core.Types.message) =
  match message.Llm_provider.Types.content with
  | [Llm_provider.Types.Text text] -> text
  | _ -> fail "the carrier message is one text block"

(* However many receipts a run holds, the address text changes only in its
   numbers: the receipt count, the count per tool and the blob's byte count. *)
let test_address_text_differs_only_in_numbers () = with_workspace (fun base_path ->
  let response = `String (String.make 2048 'r') in
  let shape count =
    let keeper_name = Printf.sprintf "carrier-shape-%d" count in
    retain_vendor_receipts ~keeper_name base_path (List.init count (fun index ->
      vendor_receipt ~call_id:(Printf.sprintf "shape-%05d" index) ~tool_name:"Screen" response));
    let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true
        (get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt)) in
    switch carrier;
    let text = carried_text carrier in
    without_numbers (hiding (carried_reference text).Tool_output.sha256 text) in
  let one = shape 1 in
  check string "248 receipts change only the numbers" one (shape 248);
  check string "5,000 receipts change only the numbers" one (shape 5000))

let test_address_form_carries_the_inline_text_by_one_blob () = with_workspace (fun base_path ->
  retain_vendor_receipts base_path (List.init 3 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "inline-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'i'))));
  let snapshot = load base_path in
  let inline = Outbox.developer_context snapshot in
  let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true snapshot in
  check form "a run starts inline" Outbox.Inline (Outbox.carrier_form carrier);
  check (list string) "the inline form is the developer context" inline
    (Outbox.carrier_context carrier);
  check bool "the inline message is the snapshot's context message" true
    (Outbox.carrier_message carrier = Outbox.context_message snapshot);
  let before = receipt_files base_path in
  switch carrier;
  check form "the switched run carries the address form" Outbox.By_address
    (Outbox.carrier_form carrier);
  let text = carried_text carrier in
  let reference = carried_reference text in
  check string "the blob is labelled plain text, never an artifact manifest" "text/plain"
    reference.Tool_output.mime;
  check (option string) "the blob holds the inline text byte for byte"
    (Some (String.concat "\n\n" inline)) (held (blob_store base_path) reference.Tool_output.sha256);
  (match Outbox.carrier_message carrier with
   | Some message ->
     check bool "the address message is the retained-results carrier" true
       (Outbox.is_context_message message);
     check string "the message carries the address text" text (message_text message)
   | None -> fail "a carrier with receipts has a message");
  check (list (pair string string)) "switching leaves the receipt files unchanged" before
    (receipt_files base_path))

let test_counts_follow_first_appearance () = with_workspace (fun base_path ->
  let tools = ["Screen"; "Key"; "Screen"; "Read"; "Key"; "Screen"] in
  retain_vendor_receipts base_path (List.mapi (fun index tool_name ->
    vendor_receipt ~call_id:(Printf.sprintf "count-%d" index) ~tool_name
      (`String (String.make 2048 'c'))) tools);
  let snapshot = load base_path in
  let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true snapshot in
  switch carrier;
  (* Snapshot order is the order of the receipt files, so the expected order is
     read back from them. *)
  let directory = outbox_directory ~keeper_name base_path in
  let names = List.map (fun id ->
    match Yojson.Safe.from_file (Filename.concat directory (id ^ ".json")) with
    | `Assoc fields ->
      (match List.assoc_opt "tool_name" fields with
       | Some (`String name) -> name
       | _ -> fail "a receipt names its tool")
    | _ -> fail "a receipt is an object") (Outbox.receipt_ids snapshot) in
  let counts = List.fold_left (fun counts name ->
    if List.mem_assoc name counts
    then List.map (fun (seen, count) ->
        if String.equal seen name then seen, count + 1 else seen, count) counts
    else counts @ [name, 1]) [] names in
  check int "three tools in six receipts" 3 (List.length counts);
  check bool "the counts are a JSON object in order of first appearance" true
    (String_util.contains_substring (carried_text carrier)
       (Yojson.Safe.to_string (`Assoc (List.map (fun (name, count) -> name, `Int count) counts)))))

let test_carrier_step_switches_once_and_only_when_shorter () = with_workspace (fun base_path ->
  let memory_calls = ref 0 in
  let memory ~refusal:_ = incr memory_calls; Ok Reprojection.Unchanged in
  let empty = Outbox.carrier ~base_path ~artifact_reader_available:true (load base_path) in
  check (list string) "no receipts carry nothing" [] (Outbox.carrier_context empty);
  check_reduction "no receipts leave the refusal to the memory hook" Reprojection.Unchanged
    (Outbox.carrier_reprojection empty ~then_:memory ~refusal);
  check int "the memory hook is asked" 1 !memory_calls;
  get (Outbox.retain ~base_path ~keeper_name
    (vendor_receipt ~call_id:"tiny" ~tool_name:"Ping" (`String "ok")));
  let tiny_snapshot = load base_path in
  let tiny = Outbox.carrier ~base_path ~artifact_reader_available:true tiny_snapshot in
  check_reduction "an address form that is not shorter is not taken" Reprojection.Unchanged
    (Outbox.carrier_reprojection tiny ~then_:memory ~refusal);
  check int "the memory hook is asked again" 2 !memory_calls;
  check form "the run stays inline" Outbox.Inline (Outbox.carrier_form tiny);
  check (option string) "no blob is written for a form that is not taken" None
    (held (blob_store base_path)
       (sha256_hex (String.concat "\n\n" (Outbox.developer_context tiny_snapshot))));
  retain_vendor_receipts base_path (List.init 4 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "large-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'l'))));
  let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true (load base_path) in
  check_reduction "a shorter address form is taken before the memory hook"
    Reprojection.Reprojected (Outbox.carrier_reprojection carrier ~then_:unreached ~refusal);
  let switched = Outbox.carrier_context carrier in
  let memory_reprojects ~refusal:_ = incr memory_calls; Ok Reprojection.Reprojected in
  check_reduction "after the switch the memory hook decides" Reprojection.Reprojected
    (Outbox.carrier_reprojection carrier ~then_:memory_reprojects ~refusal);
  check int "the memory hook is asked once the carrier is switched" 3 !memory_calls;
  check form "the form never switches back" Outbox.By_address (Outbox.carrier_form carrier);
  check (list string) "the address text stays as it was" switched (Outbox.carrier_context carrier))

let test_blob_write_failure_keeps_the_run_inline () = with_workspace (fun base_path ->
  retain_vendor_receipts base_path (List.init 4 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "blocked-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'b'))));
  let snapshot = load base_path in
  (* A regular file where the blob directory belongs makes the durable write
     fail structurally, even when the test runs as root. *)
  Out_channel.with_open_bin (Tool_blob_store.root_dir (blob_store base_path))
    (fun channel -> Out_channel.output_string channel "not a directory");
  let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true snapshot in
  (match Outbox.carrier_reprojection carrier ~then_:unreached ~refusal with
   | Error _ -> ()
   | Ok _ -> fail "a blob that cannot be written cannot switch the form");
  check form "the run stays inline" Outbox.Inline (Outbox.carrier_form carrier);
  check (list string) "the carrier keeps the inline text" (Outbox.developer_context snapshot)
    (Outbox.carrier_context carrier))

let test_address_text_names_the_reader_only_when_offered () = with_workspace (fun base_path ->
  retain_vendor_receipts base_path (List.init 3 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "reader-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'a'))));
  let snapshot = load base_path in
  let switched_text artifact_reader_available =
    let carrier = Outbox.carrier ~base_path ~artifact_reader_available snapshot in
    switch carrier;
    carried_text carrier in
  let with_reader = switched_text true in
  let without_reader = switched_text false in
  let contains text part = String_util.contains_substring text part in
  check bool "an offered reader is named" true (contains with_reader "keeper_artifact_read");
  check bool "an offered reader is not told it cannot read" false
    (contains with_reader "cannot read");
  check bool "no reader is named when none is offered" false
    (contains without_reader "keeper_artifact_read");
  check bool "a request without a reader is told it cannot read the receipts" true
    (contains without_reader "cannot read");
  check string "both texts name the same blob" (carried_reference with_reader).Tool_output.sha256
    (carried_reference without_reader).Tool_output.sha256)

(* A Codex receipt holds its image as a base64 data URL in the file (#49697).
   #49665 keeps it out of the inline text, and the address form carries that
   same text. The host receipt here is written by today's code, which names
   its image by blob address. *)
let test_address_form_keeps_base64_out () = with_workspace (fun base_path ->
  let raw = String.init 3000 (fun index -> Char.chr (index mod 256)) in
  let encoded = Base64.encode_string raw in
  let image = Llm_provider.Types.Image {media_type="image/png";source=Llm_provider.Types.Base64 encoded} in
  let terminal_error = ref None in
  let tool = project ~base_path ~stop:(Some stop) ~terminal_error (fun _ ->
    Ok {Agent_core.Types.content="screenshot taken";content_blocks=Some [image];_meta=None}) in
  ignore (tool.call ~call_id:"host-image-call" (`Assoc []));
  let items = match Runtime_official_client_tool.project_content Codex
      ~content:"screenshot taken" ~content_blocks:(Some [image]) with
    | Ok items -> items | Error detail -> fail detail in
  get (Outbox.retain ~base_path ~keeper_name
    {thread_id="vendor-thread";turn_id="vendor-turn";call_id="codex-image-call";
     tool_name="Screenshot";arguments=`Assoc [];
     response=`Assoc ["id",`Int 9; "result",`Assoc ["success",`Bool true; "contentItems",`List items]]});
  retain_vendor_receipts base_path (List.init 4 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "text-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 't'))));
  let files = receipt_files base_path in
  check bool "the receipt files keep the base64 payload" true
    (List.exists (fun (_, body) -> String_util.contains_substring body encoded) files);
  let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true (load base_path) in
  switch carrier;
  let text = carried_text carrier in
  check bool "the address text holds no base64 payload" false
    (String_util.contains_substring text encoded);
  (match held (blob_store base_path) (carried_reference text).Tool_output.sha256 with
   | Some carried ->
     check bool "the carried blob holds no base64 payload" false
       (String_util.contains_substring carried encoded)
   | None -> fail "the carried blob is held");
  check (list (pair string string)) "switching leaves the receipt files unchanged" files
    (receipt_files base_path))

(* A host receipt written before #49680 holds its image as a base64 wire block
   in [content_blocks]. #49665 names it by bytes and sha256 in the inline text,
   so neither the address text nor its blob carries the payload. *)
let test_address_form_keeps_old_host_base64_out () = with_workspace (fun base_path ->
  let raw = String.init 3000 (fun index -> Char.chr (index mod 256)) in
  let encoded = Base64.encode_string raw in
  let image = Llm_provider.Types.Image {media_type="image/png";source=Llm_provider.Types.Base64 encoded} in
  retain_old_host_image_receipt base_path ~call_id:"old-host-image" image;
  retain_vendor_receipts base_path (List.init 4 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "old-host-text-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'o'))));
  let files = receipt_files base_path in
  check int "only the old host receipt file holds the base64 payload" 1
    (List.length (List.filter (fun (_, body) -> String_util.contains_substring body encoded) files));
  let snapshot = load base_path in
  check bool "the inline text names the image instead of carrying it" false
    (String_util.contains_substring (String.concat "\n\n" (Outbox.developer_context snapshot)) encoded);
  let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true snapshot in
  switch carrier;
  let text = carried_text carrier in
  check bool "the address text holds no base64 payload" false
    (String_util.contains_substring text encoded);
  (match held (blob_store base_path) (carried_reference text).Tool_output.sha256 with
   | Some carried ->
     check bool "the carried blob holds no base64 payload" false
       (String_util.contains_substring carried encoded)
   | None -> fail "the carried blob is held");
  check (list (pair string string)) "switching leaves the receipt files unchanged" files
    (receipt_files base_path))

(* The switch is decided on a planned marker. If the stored marker came out
   longer, a carrier near the threshold would switch to a text that is not
   shorter, and every fixture far from the threshold would still pass. *)
let test_planned_marker_is_as_long_as_the_stored_one () = with_workspace (fun base_path ->
  retain_vendor_receipts base_path (List.init 4 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "planned-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'p'))));
  let snapshot = load base_path in
  let inline = String.concat "\n\n" (Outbox.developer_context snapshot) in
  let carrier = Outbox.carrier ~base_path ~artifact_reader_available:true snapshot in
  switch carrier;
  let text = carried_text carrier in
  let stored = carried_reference text in
  let planned =
    match Tool_output.make_artifact_ref
            ~sha256:(String.make (String.length stored.Tool_output.sha256) '0')
            ~bytes:(String.length inline) ~preview:stored.Tool_output.preview
            ~mime:stored.Tool_output.mime with
    | Ok planned -> planned
    | Error error -> fail (Tool_output.make_error_to_string error) in
  let marker reference = Tool_output.encode_for_agent_core (Tool_output.Stored reference) in
  check int "the planned marker is as long as the stored one"
    (String.length (marker stored)) (String.length (marker planned));
  check bool "the switched text is strictly shorter than the inline text" true
    (String.length text < String.length inline))

(* Nothing durable names the carrier blob, so a deploy sweep may delete it
   while the receipts it carried stay. The next run writes it again. *)
let test_maintenance_keeps_receipt_blobs_and_the_next_run_rewrites () =
  with_workspace (fun base_path ->
  let producer = get (Outbox.host_producer ~base_path ~keeper_name
      ~runtime_label:"carrier-fixture" ~turn_count:1) in
  let body = String.make 8192 'm' in
  let response = get (Outbox.host_response producer ~min_result_bytes:0 ~success:true
      ~content:body ~content_blocks:None) in
  get (Outbox.retain_host_result producer ~invocation_index:0 ~call_id:"host-call"
      ~tool_name:"Read" ~arguments:(`Assoc []) ~response);
  retain_vendor_receipts base_path (List.init 3 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "swept-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 's'))));
  let snapshot = load base_path in
  let store = blob_store base_path in
  check (option string) "the host receipt names its body by a held blob" (Some body)
    (held store (sha256_hex body));
  let first = Outbox.carrier ~base_path ~artifact_reader_available:true snapshot in
  switch first;
  let carried = carried_reference (carried_text first) in
  for _pass = 1 to 2 do
    match Tool_blob_maintenance.run ~base_path ~scope:Server_tool_blob_scope.scope
            ~mode:Tool_blob_maintenance.Delete_previous_candidates with
    | Ok _ -> ()
    | Error error -> fail (Tool_blob_maintenance.error_to_string error)
  done;
  check (option string) "maintenance keeps the blob a retained receipt names" (Some body)
    (held store (sha256_hex body));
  let path = Filename.concat
      (Filename.concat (Tool_blob_store.root_dir store)
         (String.sub carried.Tool_output.sha256 0 2))
      carried.Tool_output.sha256 in
  if Sys.file_exists path then Sys.remove path;
  check (option string) "the carrier blob is gone" None (held store carried.Tool_output.sha256);
  let next = Outbox.carrier ~base_path ~artifact_reader_available:true snapshot in
  switch next;
  check string "the next run names the same address" carried.Tool_output.sha256
    (carried_reference (carried_text next)).Tool_output.sha256;
  check (option string) "and writes its bytes again"
    (Some (String.concat "\n\n" (Outbox.developer_context snapshot)))
    (held store carried.Tool_output.sha256))

(* A runtime makes one run_carrier per run. Its first attempt loads the outbox;
   every later attempt gets the same snapshot and carrier, so a switched form
   stays switched and the run acknowledges exactly what it loaded. *)
let test_run_carrier_loads_once () = with_workspace (fun base_path ->
  retain_vendor_receipts base_path (List.init 2 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "run-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'u'))));
  let retained = Outbox.run_carrier ~base_path ~keeper_name ~artifact_reader_available:true ~viewer:Outbox.Unowned_only in
  let snapshot, carrier = get (Outbox.run_carrier_load retained) in
  get (Outbox.retain ~base_path ~keeper_name
    (vendor_receipt ~call_id:"run-late" ~tool_name:"Read" (`String "written after the load")));
  let later_snapshot, later_carrier = get (Outbox.run_carrier_load retained) in
  check int "the run holds the two receipts written before its first load" 2
    (List.length (Outbox.receipt_ids later_snapshot));
  check (list string) "a later attempt gets the snapshot the run loaded"
    (Outbox.receipt_ids snapshot) (Outbox.receipt_ids later_snapshot);
  check bool "a later attempt renders the same carrier" true (carrier == later_carrier))

let test_run_carrier_reprojection_waits_for_the_load () = with_workspace (fun base_path ->
  retain_vendor_receipts base_path (List.init 4 (fun index ->
    vendor_receipt ~call_id:(Printf.sprintf "wait-%d" index) ~tool_name:"Read"
      (`String (String.make 2048 'w'))));
  let retained = Outbox.run_carrier ~base_path ~keeper_name ~artifact_reader_available:true ~viewer:Outbox.Unowned_only in
  let calls = ref 0 in
  let memory ~refusal:_ = incr calls; Ok Reprojection.Unchanged in
  check_reduction "before the run loads, the memory hook alone answers" Reprojection.Unchanged
    (Outbox.run_carrier_reprojection retained ~then_:memory ~refusal);
  check int "the memory hook ran once" 1 !calls;
  let _, carrier = get (Outbox.run_carrier_load retained) in
  check_reduction "after the load, the carrier step comes first" Reprojection.Reprojected
    (Outbox.run_carrier_reprojection retained ~then_:unreached ~refusal);
  check form "the loaded carrier switched" Outbox.By_address (Outbox.carrier_form carrier);
  let _, again = get (Outbox.run_carrier_load retained) in
  check form "a later attempt renders the switched form" Outbox.By_address
    (Outbox.carrier_form again);
  check_reduction "a switched run leaves the next refusal to the memory hook" Reprojection.Unchanged
    (Outbox.run_carrier_reprojection retained ~then_:memory ~refusal);
  check int "the memory hook ran again" 2 !calls)

(* Rows that reached the Keeper's queue while the client ran the turn go out
   after the tool's own text, once each, and the original result keeps its
   retention marker. *)
let arrived_row ~arrival ~arrived_at receipt : Keeper_event_queue_state.pending_selection =
  { Keeper_event_queue_state.source =
      { Keeper_event_queue.post_id = Printf.sprintf "post-%Ld" arrival
      ; urgency = Keeper_event_queue.Normal
      ; arrived_at
      ; payload = Keeper_event_queue.Tool_result_ready receipt
      }
  ; admitted_revision = 1L
  ; arrival
  ; checkpoint_retentions = 0
  ; first_admitted_at = None
  }

let after_projection () = Time_compat.now () +. 60.
let arrival_banner = "--- Arrived While This Turn Ran ---"
let has text needle = String_util.contains_substring text needle

let notify (result : Host.dynamic_tool_result) =
  match result.on_response_sent with
  | Some notify -> notify ()
  | None -> fail "the result has no physical-write token"

let test_arrived_rows_follow_the_tool_text_and_the_original_stays_marked () = with_workspace (fun base_path ->
  Eio.Switch.run (fun result_scope ->
    let rows = [arrived_row ~arrival:1L ~arrived_at:(after_projection ()) "background-run"] in
    let tool, producer = project_with_producer ~result_scope:(Some result_scope)
      ~read_arrived:(fun () -> Ok rows)
      ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
    let producer = match producer with Some producer -> producer | None -> fail "missing actual producer" in
    let first = tool.call ~call_id:"first-with-arrival" (`Assoc []) in
    check bool "the tool's own text comes first" true (String.starts_with ~prefix:marker first.content);
    check bool "the block follows it" true (has first.content arrival_banner);
    check bool "the block names the row" true
      (has first.content "tool_result_ready receipt_id=background-run");
    (match first.content_blocks with
     | Some [Llm_provider.Types.Text original; Llm_provider.Types.Text block] ->
       check string "the original block is untouched" "original-block-bytes" original;
       check bool "the client reads the block as its own item" true (has block arrival_banner)
     | Some _ | None -> fail "the original block and one block of arrived rows");
    check bool "the response can be observed as projected" true
      (Option.is_some (Runtime_official_client_tool.response_observer Mcp first));
    notify first;
    let second = tool.call ~call_id:"second-after-the-write" (`Assoc []) in
    check string "a row the client already received is not listed again" marker second.content;
    notify second;
    check int "the marker of each original ran at its write, block or not" 2
      (List.length (Outbox.receipt_ids (Outbox.close_delivery_frontier producer)))))

let test_a_text_only_result_carries_the_block_in_its_content () = with_workspace (fun base_path ->
  let rows = [arrived_row ~arrival:1L ~arrived_at:(after_projection ()) "background-run"] in
  let tool = project ~read_arrived:(fun () -> Ok rows)
    ~base_path ~stop:None ~terminal_error:(ref None)
    (fun _ -> Ok {Agent_core.Types.content=marker;content_blocks=None;_meta=None}) in
  let result = tool.call ~call_id:"text-only" (`Assoc []) in
  check bool "the block follows the text" true
    (String.starts_with ~prefix:marker result.content && has result.content arrival_banner);
  check bool "no blocks are invented for a text-only result" true
    (Option.is_none result.content_blocks))

let test_results_asked_before_a_write_both_list_the_row () = with_workspace (fun base_path ->
  let rows = [arrived_row ~arrival:1L ~arrived_at:(after_projection ()) "background-run"] in
  let tool = project ~read_arrived:(fun () -> Ok rows)
    ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
  let first = tool.call ~call_id:"side-by-side-one" (`Assoc []) in
  let second = tool.call ~call_id:"side-by-side-two" (`Assoc []) in
  check bool "the first lists the row" true (has first.content arrival_banner);
  check bool "the second lists it too: nothing was written yet" true (has second.content arrival_banner);
  notify first;
  let third = tool.call ~call_id:"side-by-side-three" (`Assoc []) in
  check string "the first write counted the row" marker third.content)

let test_a_result_the_block_would_push_past_its_bound_goes_out_as_it_was () = with_workspace (fun base_path ->
  let rows = [arrived_row ~arrival:1L ~arrived_at:(after_projection ()) "background-run"] in
  let loading_plan = Host.Declared
    {on_demand=[]; result_bounds=["CompleteEffect", String.length marker + 5]} in
  let tool = project ~loading_plan ~read_arrived:(fun () -> Ok rows)
    ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
  let result = tool.call ~call_id:"bounded" (`Assoc []) in
  check string "the bounded result is unchanged" marker result.content;
  check bool "its own marker is still there" true (Option.is_some result.on_response_sent))

let test_a_result_that_ends_the_turn_carries_no_block () = with_workspace (fun base_path ->
  let rows = [arrived_row ~arrival:1L ~arrived_at:(after_projection ()) "background-run"] in
  let tool = project ~read_arrived:(fun () -> Ok rows)
    ~base_path ~stop:(Some stop) ~terminal_error:(ref None) (fun _ -> returned ()) in
  let result = tool.call ~call_id:"terminal" (`Assoc []) in
  check bool "the result stops the turn" true (Option.is_some result.abort_turn);
  check string "so nothing follows it" marker result.content)

let test_an_unreadable_queue_costs_the_result_nothing () = with_workspace (fun base_path ->
  let tool = project ~read_arrived:(fun () -> Error "queue file locked")
    ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
  let result = tool.call ~call_id:"unreadable" (`Assoc []) in
  check string "the result goes out as it was" marker result.content;
  check bool "its own marker is still there" true (Option.is_some result.on_response_sent))

let test_a_row_name_cut_inside_a_character_keeps_the_marker_bound () = with_workspace (fun base_path ->
  let cut = "\xEB\xA1\x9C\xEC\x9D" in
  let rows = [arrived_row ~arrival:1L ~arrived_at:(after_projection ()) cut] in
  let tool = project ~read_arrived:(fun () -> Ok rows)
    ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
  let result = tool.call ~call_id:"cut-row-name" (`Assoc []) in
  check bool "the block was appended" true (has result.content arrival_banner);
  check bool "the string sent to the client is valid UTF-8" true (String.is_valid_utf_8 result.content);
  check bool "so the observer is still bound" true
    (Option.is_some (Runtime_official_client_tool.response_observer Mcp result)))

(* A row name cut inside a character is repaired to a longer text, so a bound
   that is judged before the repair lets the result pass it by a few bytes. *)
let test_the_bound_is_judged_on_the_text_the_client_receives () = with_workspace (fun base_path ->
  let cut = "\xEB\xA1\x9C\xEC\x9D" in
  let rows = [arrived_row ~arrival:1L ~arrived_at:(after_projection ()) cut] in
  let call loading_plan call_id =
    let tool = project ~loading_plan ~read_arrived:(fun () -> Ok rows)
      ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
    tool.call ~call_id (`Assoc []) in
  let bounded limit = Host.Declared {on_demand=[]; result_bounds=["CompleteEffect", limit]} in
  let full = String.length (call Host.All_on_demand "unbounded").content in
  check string "one byte under the repaired length: left alone" marker
    (call (bounded (full - 1)) "one-under").content;
  check bool "at the repaired length: appended" true
    (has (call (bounded full) "exact").content arrival_banner))

let test_a_row_older_than_the_projection_is_not_listed () = with_workspace (fun base_path ->
  let rows = [arrived_row ~arrival:1L ~arrived_at:(Time_compat.now () -. 60.) "background-run"] in
  let tool = project ~read_arrived:(fun () -> Ok rows)
    ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
  let result = tool.call ~call_id:"older-row" (`Assoc []) in
  check string "the turn's first request already carried it" marker result.content)

(* The measurement reads this record: each listed row by queue entry number and
   arrival time, and the tool whose result carried the block. *)
let test_an_appended_block_is_recorded_in_the_raw_trace () = with_workspace (fun base_path ->
  let path = Filename.concat base_path "raw-trace.jsonl" in
  let traced = function Ok value -> value | Error error -> fail (Agent_core.Error.to_string error) in
  let trace = traced (Agent_core.Raw_trace.create ~path ()) in
  let active = traced (Agent_core.Raw_trace.start_run trace ~agent_name:keeper_name ~prompt:"fixture" ()) in
  let arrived_at = after_projection () in
  let rows = [arrived_row ~arrival:7L ~arrived_at "background-run"] in
  let tool = project ~raw_trace_run:(Some active) ~read_arrived:(fun () -> Ok rows)
    ~base_path ~stop:None ~terminal_error:(ref None) (fun _ -> returned ()) in
  ignore (tool.call ~call_id:"traced" (`Assoc []));
  let projections = traced (Agent_core.Raw_trace.read_all ~path ())
    |> List.filter (fun (record : Agent_core.Raw_trace.record) ->
         record.hook_name = Some "arrived_stimuli_projection") in
  match projections with
  | [record] ->
    check (option string) "the record says the block was appended" (Some "appended") record.hook_decision;
    let detail = match record.hook_detail with
      | Some text -> Yojson.Safe.from_string text
      | None -> fail "the record has no detail" in
    let open Yojson.Safe.Util in
    check string "the tool whose result carried it" "CompleteEffect" (detail |> member "tool" |> to_string);
    check int "no row waits for a later result" 0 (detail |> member "later" |> to_int);
    (match detail |> member "rows" |> to_list with
     | [row] ->
       check int "the row's queue entry number" 7 (row |> member "arrival" |> to_int);
       check (float 0.001) "the row's arrival time" arrived_at (row |> member "arrived_at" |> to_float)
     | rows -> failf "one listed row is expected, got %d" (List.length rows))
  | records -> failf "one projection record is expected, got %d" (List.length records))

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
    test_case "screenshot receipt names its bytes by blob address" `Quick test_screenshot_receipt_names_bytes_by_address;
    test_case "host response names each payload by address" `Quick test_host_response_names_each_payload;
    test_case "source identity deduplicates exact originals across mixed producers" `Quick test_producer_identity_and_vendor_coexistence;
    test_case "shared context preserves retained originals in order" `Quick test_shared_context_preserves_each_retained_result;
    test_case "carrier names retained media by identity" `Quick test_carrier_names_media_by_identity;
    test_case "ambiguous receipt shape remains individual" `Quick test_ambiguous_receipt_shape_is_not_shared;
    test_case "small shared JSON does not expand context" `Quick test_small_shared_json_does_not_expand_context;
    test_case "unique results remain individual" `Quick test_unique_results_remain_individual;
    test_case "sparse repetition preserves the large unique result" `Quick test_sparse_repetition_falls_back_without_losing_unique_result;
    test_case "nested signed zero stays distinct" `Quick test_shared_nested_signed_zero;
    test_case "representation choice matches serialized size" `Quick test_representation_choice_uses_exact_serialized_size;
    test_case "mixed groups match serialized size" `Quick test_mixed_groups_use_exact_serialized_size];
   "arrived rows after a tool result",[
    test_case "rows follow the tool text and the original stays marked" `Quick
      test_arrived_rows_follow_the_tool_text_and_the_original_stays_marked;
    test_case "a text-only result carries the block in its content" `Quick
      test_a_text_only_result_carries_the_block_in_its_content;
    test_case "results asked before a write both list the row" `Quick
      test_results_asked_before_a_write_both_list_the_row;
    test_case "a result past its bound goes out as it was" `Quick
      test_a_result_the_block_would_push_past_its_bound_goes_out_as_it_was;
    test_case "a result that ends the turn carries no block" `Quick
      test_a_result_that_ends_the_turn_carries_no_block;
    test_case "an unreadable queue costs the result nothing" `Quick
      test_an_unreadable_queue_costs_the_result_nothing;
    test_case "a row name cut inside a character keeps the marker bound" `Quick
      test_a_row_name_cut_inside_a_character_keeps_the_marker_bound;
    test_case "the bound is judged on the text the client receives" `Quick
      test_the_bound_is_judged_on_the_text_the_client_receives;
    test_case "a row older than the projection is not listed" `Quick
      test_a_row_older_than_the_projection_is_not_listed;
    test_case "an appended block is recorded in the raw trace" `Quick
      test_an_appended_block_is_recorded_in_the_raw_trace];
   "retained-results carrier form",[
    test_case "address text differs only in numbers" `Quick test_address_text_differs_only_in_numbers;
    test_case "address form carries the inline text by one blob" `Quick
      test_address_form_carries_the_inline_text_by_one_blob;
    test_case "counts follow first appearance" `Quick test_counts_follow_first_appearance;
    test_case "carrier step switches once and only when shorter" `Quick
      test_carrier_step_switches_once_and_only_when_shorter;
    test_case "blob write failure keeps the run inline" `Quick
      test_blob_write_failure_keeps_the_run_inline;
    test_case "address text names the reader only when offered" `Quick
      test_address_text_names_the_reader_only_when_offered;
    test_case "address form keeps base64 out" `Quick test_address_form_keeps_base64_out;
    test_case "address form keeps old host base64 out" `Quick
      test_address_form_keeps_old_host_base64_out;
    test_case "planned marker is as long as the stored one" `Quick
      test_planned_marker_is_as_long_as_the_stored_one;
    test_case "maintenance keeps receipt blobs and the next run rewrites" `Quick
      test_maintenance_keeps_receipt_blobs_and_the_next_run_rewrites];
   "retained-results carrier run",[
    test_case "run carrier loads once" `Quick test_run_carrier_loads_once;
    test_case "run carrier reprojection waits for the load" `Quick
      test_run_carrier_reprojection_waits_for_the_load]]
