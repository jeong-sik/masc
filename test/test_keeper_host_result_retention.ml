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

let project ~base_path ~stop ~terminal_error handler =
  let tool = Agent_core.Tool.create ~name:"CompleteEffect" ~description:"Complete an effect once"
      ~parameters:[{Agent_core.Types.name="input";description="original call data";
        param_type=String;required=false}] handler in
  match Host.dynamic_tools ~base_path ~content_transport:Runtime_official_client_tool.Mcp
    ~accepts_image_input:true ~tool_approval:None ~runtime_label:"host-result-fixture"
    ~keeper_name ~turn_count:7 ~tools:[tool] ~loading_plan:Host.All_on_demand
    ~hooks:Agent_core.Hooks.empty ~event_bus:None ~context_injector:None
    ~context:(Some (Agent_core.Context.create_sync ()))
    ~terminal_effect_state:(fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ~terminal_error ~pre_tool_rejects:(ref []) ~on_tool_boundary:(fun () -> Ok stop)
    ~raw_trace_run:None () with
  | Ok [tool] -> tool
  | Ok _ -> fail "one original tool required"
  | Error error -> fail (Agent_core.Error.to_string error)

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
     "host_producer_id";"host_turn_count";"host-result-fixture"];
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

let test_ordinary_tool_does_not_create_a_continuation () = with_workspace (fun base_path ->
  let terminal_error = ref None in
  let tool = project ~base_path ~stop:None ~terminal_error (fun _ -> returned ()) in
  let result = tool.call ~call_id:"ordinary-host-call" (`Assoc []) in
  check bool "ordinary call stays with its original provider" true (Option.is_none result.abort_turn);
  check int "ordinary result creates no completion wake" 0
    (List.length (Outbox.receipt_ids (load base_path))))

let test_retention_failure_cannot_claim_safe_consumption () = with_workspace (fun base_path ->
  let session_path = get (Keeper_official_client_session_store.path ~base_path ~keeper_name) in
  Fs_compat.mkdir_p (Filename.dirname session_path);
  Fs_compat.save_file (Filename.concat (Filename.dirname session_path) "undelivered-tools") "blocked original store";
  let terminal_error = ref None and effects = ref 0 in
  let tool = project ~base_path ~stop:(Some stop) ~terminal_error
      (fun _ -> incr effects; returned ()) in
  let result = tool.call ~call_id:"failed-retention-call" (`Assoc []) in
  check bool "the transport is still stopped" true (result.abort_turn=Some stop);
  check bool "runtime receives authoritative retention failure" true (Option.is_some !terminal_error);
  check string "actual returned content is not invented or discarded" marker result.content;
  check int "storage refusal does not replay completed effect" 1 !effects;
  match Outbox.load ~base_path ~keeper_name with
  | Error _ -> () | Ok _ -> fail "unavailable original store became empty success")

let test_producer_identity_and_vendor_coexistence () = with_workspace (fun base_path ->
  let first = get (Outbox.host_producer ~runtime_label:"Claude" ~turn_count:1)
  and replacement = get (Outbox.host_producer ~runtime_label:"Muse" ~turn_count:1) in
  let retain producer = get (Outbox.retain_host_result producer ~base_path ~keeper_name
    ~call_id:"same-client-local-call-id" ~tool_name:"Execute" ~arguments:(`Assoc []) ~response:(`String marker)) in
  retain first; retain first;
  check int "the same original source/result is idempotent" 1
    (List.length (Outbox.receipt_ids (load base_path)));
  retain replacement;
  get (Outbox.retain ~base_path ~keeper_name
    {thread_id="actual-vendor-thread";turn_id="actual-vendor-turn";call_id="actual-vendor-call";
     tool_name="Execute";arguments=`Assoc [];response=`String "original vendor result"});
  check int "replacement host and vendor sources retain their own identities" 3
    (List.length (Outbox.receipt_ids (load base_path))))

let () = run "Original official-client host result retention"
  ["durable host stop",[
    test_case "typed stop retains original before transport continuation" `Quick test_stop_retains_before_transport_return;
    test_case "ordinary call stays in the current provider turn" `Quick test_ordinary_tool_does_not_create_a_continuation;
    test_case "retention failure prevents safe consumption claim" `Quick test_retention_failure_cannot_claim_safe_consumption;
    test_case "source identity deduplicates exact originals across mixed producers" `Quick test_producer_identity_and_vendor_coexistence]]
