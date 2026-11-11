(* Core commits the terminal disposition to its journal before it tells the
   host. When the host's receipt write fails, the journal holds the terminal
   while the Owner call stays Active. [reconcile_after_dispatch] copies the
   journal terminal into the Owner receipt when the dispatch ends, whether it
   returns or raises. These tests run a real Core execution whose host sink
   fails, then end the dispatch both ways. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Registry = Keeper_owner_registry
module Agent = Agent_core.Agent

let keeper_name = "native-reconcile-proof"
let session_id = "native-reconcile-session"
let model_id = "native-reconcile-model"
let runtime_id = "native-reconcile.runtime"
let goal = "Answer once."
let call_id = "019a0010-1000-7000-8000-0000000000b1"
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-reconcile-operation"
  |> require "operation ID"

let final_reply =
  {|{"id":"reconcile-final","model":"native-reconcile-model","choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

exception Dispatch_aborted

type dispatch_end =
  | Returns
  | Raises

(* What the Owner call held when the dispatch ended. *)
type observation =
  { call_before : Keeper_native_call.state
  ; call_after : Keeper_native_call.state
  ; raised_dispatch_aborted : bool
  }

let succeeded_retired =
  { Agent.outcome = Agent.Terminal_succeeded; recovery = Agent.Retire }

let is_active = function
  | Keeper_native_call.Active _ -> true
  | Keeper_native_call.No_native_call | Keeper_native_call.Terminal_unacknowledged _ -> false

let run_case ~how root =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "native execution runtime";
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Eio.Switch.on_release sw (fun () -> Llm_provider.Catalog_snapshot.publish previous_catalog);
  let catalog = Printf.sprintf
      "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-reconcile-test" catalog
    |> require "model catalog" |> (fun models -> Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:(None)));
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ -> `OK, final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let workspace = Workspace.default_config root in
  let session_dir = Filename.concat root session_id in
  ignore (Workspace.init workspace ~agent_name:(Some "native-reconcile-test"));
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name", `String keeper_name; "trace_id", `String session_id;
    "activation_mode", `String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
  Unix.mkdir session_dir 0o700;
  let observed, resolve_observed = Eio.Promise.create () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim operation" |> Option.get in
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    (* A real Core execution. Its host sink fails after the journal commits the
       terminal, which is the state left when the Owner receipt write fails. *)
    let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
    let dir = Eio.Path.(env#fs / session_dir / "native-executions" / call_id) in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let locator = ref None in
    let execution_store = Agent.execution_store ~runtime ~dir
        ~on_scope_ready:(fun published -> locator := Some published; Ok ())
        ~on_terminal_disposition:(fun _ -> Error "host receipt sink unavailable") () in
    let config = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:keeper_name ~provider_cfg
        ~system_prompt:"Answer once." ~tools:[] in
    let config = {config with execution_store=Some execution_store} in
    (match Runtime_agent.run ~sw:turn_sw ~net:env#net ~config goal with
     | Error _ -> ()
     | Ok _ -> fail "the failing host sink did not fail the Core call");
    let checkpoint = Keeper_checkpoint_ref.of_persisted
        ~trace_id:(Keeper_id.Trace_id.of_string session_id |> require "trace id")
        ~turn_count:1 ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes "reconcile seed")
      |> require "checkpoint" in
    let call = Keeper_native_call.create ~call_id ~runtime_id
        ~operation_digest:operation.execution_digest
        ~api:(Keeper_native_call.New_input {seed_message_count=0})
        ~seed_checkpoint:checkpoint ~locator:(Option.get !locator)
      |> require "native call" in
    Registry.bind_direct_native_call ~base_path:root ~keeper_name ~operation_id
      ~execution_digest:operation.execution_digest
      ~observed:Keeper_native_call.No_native_call ~call |> require "bind native call";
    let read () = Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
      |> require "read native call" in
    let call_before = read () in
    let raised_dispatch_aborted =
      match how with
      | Returns ->
        Native.reconcile_after_dispatch binding (fun () -> ()); false
      | Raises ->
        (match Native.reconcile_after_dispatch binding (fun () -> raise Dispatch_aborted) with
         | () -> false
         | exception Dispatch_aborted -> true) in
    Eio.Promise.resolve resolve_observed
      {call_before; call_after=read (); raised_dispatch_aborted};
    Keeper_owner.Operation_failed
      {kind=Keeper_chat_operation.Turn_cancelled; detail="fixture finished"; outcome_ref=None}
  in
  let runner : Keeper_owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution:_ -> ())} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  Keeper_direct_native_continuation.complete_restart_settlements
    ~runtime:(Runtime_agent_execution_runtime.get () |> Option.get) ~base_path:root
    |> require "complete startup native journal settlement" |> ignore;
  let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "canonical input" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source:(`Assoc ["kind", `String "fixture"]) ~input |> require "submit operation" |> ignore;
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
    (fun () -> Eio.Promise.await observed)

let with_root f =
  let root = Filename.temp_dir "keeper-native-reconcile-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () -> f root)

let check_reconciled observation =
  check bool "the Owner call was Active before reconciliation" true
    (is_active observation.call_before);
  check bool "the journal terminal reached the Owner receipt" true
    (match observation.call_after with
     | Keeper_native_call.Terminal_unacknowledged (_, disposition) ->
       disposition = succeeded_retired
     | Keeper_native_call.No_native_call | Keeper_native_call.Active _ -> false)

let test_returned_dispatch () =
  with_root (fun root ->
    let observation = run_case ~how:Returns root in
    check_reconciled observation;
    check bool "a normal return raises nothing" false observation.raised_dispatch_aborted)

let test_raising_dispatch () =
  with_root (fun root ->
    let observation = run_case ~how:Raises root in
    check_reconciled observation;
    check bool "the original exception continues" true observation.raised_dispatch_aborted)

module Store = Keeper_chat_operation_store
module Operation = Keeper_chat_operation
module Identity = Keeper_chat_delivery_identity
module Journal = Keeper_chat_event_log

let boot_peer_id = Operation.Operation_id.of_string "native-reconcile-boot-peer" |> require "peer ID"
let boot_input text =
  Keeper_chat_operation_payload.input_to_json ~message:text ~user_blocks:[]
    ~turn_instructions:None ~surface_context:None ~attachments:[]
  |> Operation.canonical_json |> require "boot input"

let boot_source ?(keeper_name=keeper_name) () =
  let thread_id = "keeper:" ^ keeper_name in
  let continuation_channel = Keeper_continuation_channel.dashboard ~thread_id |> require "reply channel" in
  Keeper_chat_operation_payload.source_to_json ~submitted_by:"operator" ~thread_id ~continuation_channel
    ~surface:(Surface_ref.Dashboard {session_id=None}) ~channel:"" ~channel_user_id:""
    ~channel_user_name:"" ~channel_workspace_id:"" ~conversation_id:None ~external_message_id:None
    ~workspace_id:None ~extra_mentions:[] ~sender_keeper:None ~user_row_origin:Keeper_chat_store.Needs_append
  |> require "boot source"

(* The first application switch writes a real Core journal, then disappears.
   Its next application has no runtime while installing the persisted Owner.
   No extra codec/runtime is introduced into either application's boot. *)
let prepare_boot_journal ?(keeper_name=keeper_name) ?(session_id=session_id)
    env ~root ~workspace ~unknown_receipt =
  Eio.Switch.run @@ fun sw ->
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "previous application runtime";
  let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Eio.Switch.on_release sw (fun () -> Llm_provider.Catalog_snapshot.publish previous_catalog);
  let catalog = Printf.sprintf
      "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-boot-settlement-test" catalog
    |> require "boot catalog"
    |> (fun models -> Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:None));
  let provider_calls = Atomic.make 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ -> ignore (Atomic.fetch_and_add provider_calls 1); `OK, final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~provider_id:"fixture" ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let path = Store.path_for_keeper ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path:root) ~keeper_name in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 Eio.Path.(env#fs / Filename.dirname path);
  let store = Store.open_or_create ~path |> require "boot Store" in
  Fun.protect ~finally:(fun () -> Store.close store |> require "close previous Store") @@ fun () ->
  List.iter (fun (id, text) ->
    Store.submit store ~now:1. ~operation_id:id ~source:(boot_source ~keeper_name ()) ~input:(boot_input text)
    |> require "submit original batch member" |> ignore)
    [operation_id, goal; boot_peer_id, "Keep the second original request."];
  let operation = Store.claim_next ~batch:Keeper_chat_operation_batch.select store ~now:2.
    |> require "claim original batch" |> Option.get in
  let members = Store.batch_operations store ~operation_id |> require "original member inputs" in
  check int "the production selector froze both original requests" 2 (List.length members);
  let session_dir = Filename.concat (Keeper_fs.session_store_path workspace) session_id in
  let dir = Eio.Path.(env#fs / session_dir / "native-executions" / call_id) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  let agent_ref = ref None in
  let retain () =
    let checkpoint = Agent.checkpoint ~session_id (Option.get !agent_ref) in
    let snapshot = Keeper_checkpoint_store.exact_snapshot_of_value
        ~expected_session_id:(Keeper_id.Trace_id.of_string session_id |> require "boot trace") checkpoint
      |> require "capture exact native checkpoint" in
    let reference = Keeper_checkpoint_store.retain_exact_snapshot ~session_dir snapshot
      |> Keeper_checkpoint_store.require_confirmed_installation |> require "retain native checkpoint" in
    checkpoint, reference in
  let execution_store = Agent.execution_store ~runtime ~dir
      ~on_scope_ready:(fun locator ->
        let checkpoint, seed_checkpoint = retain () in
        let call = Keeper_native_call.create ~call_id ~runtime_id ~operation_digest:operation.execution_digest
            ~api:(Keeper_native_call.New_input {seed_message_count=List.length checkpoint.messages})
            ~seed_checkpoint ~locator |> require "published native identity" in
        Store.update_direct_native_call store ~now:3. ~operation_id ~execution_digest:operation.execution_digest
          (Keeper_native_call.Bind {observed=Keeper_native_call.No_native_call; call})
        |> Result.map_error Store.error_to_string)
      ~on_terminal_disposition:(fun _ -> Error "fixture lost the Owner terminal receipt") () in
  let config = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ())
      ~name:keeper_name ~provider_cfg ~system_prompt:"Answer once." ~tools:[] in
  let message = operation.input |> Option.get |> Keeper_chat_operation_payload.input_of_json
    |> require "aggregate input" |> fun input -> input.message in
  (match Runtime_agent.run ~sw ~net:env#net ~config:{config with execution_store=Some execution_store}
      ~agent_ref message with
   | Error _ -> ()
   | Ok _ -> fail "the deliberately failed terminal sink unexpectedly succeeded");
  let checkpoint, latest = retain () in
  check bool "the retained checkpoint contains the exact original input" true
    (List.exists (fun (entry : Agent_core.Types.message) ->
      entry.role = Agent_core.Types.User && entry.content = [Agent_core.Types.Text message]) checkpoint.messages);
  let initial = match Store.direct_native_call store ~operation_id |> require "published Active call" with
    | Keeper_native_call.Active call -> call
    | No_native_call | Terminal_unacknowledged _ -> fail "previous application did not retain Active" in
  Store.update_direct_native_call store ~now:4. ~operation_id ~execution_digest:operation.execution_digest
    (Keeper_native_call.Checkpoint {call_id; observed=initial.checkpoint; checkpoint=latest})
    |> require "retain final input without acknowledging terminal";
  let original_call = Keeper_native_call.advance initial ~observed:initial.checkpoint ~checkpoint:latest
    |> require "exact advanced call" in
  let projection = Agent.open_execution_projection ~runtime ~dir original_call.locator
    |> require "read actual canonical terminal" in
  let terminal = Agent.read_execution_terminal projection |> require "canonical terminal" |> Option.get in
  check bool "Core committed the successful retirable terminal" true (terminal.disposition = succeeded_retired);
  if unknown_receipt then
    Store.update_direct_native_call store ~now:5. ~operation_id ~execution_digest:operation.execution_digest
      (Keeper_native_call.Terminal {call_id; disposition=Keeper_native_call.unknown_effect_disposition})
    |> require "retain pre-existing unknown-effect receipt";
  operation, members, original_call, session_dir, provider_calls

let check_boot_projection ?(keeper_name=keeper_name) ~root (operation : Operation.t) =
  let id = Operation.Operation_id.to_string operation.operation_id in
  let request_id = Identity.Request_id.of_string id |> require "original delivery ID" in
  let rows = Keeper_chat_store.load_result ~base_dir:root ~keeper_name |> require "failure transcript" in
  let matching = List.filter (fun (row : Keeper_chat_store.chat_message) ->
    match row.delivery_provenance with
    | Some provenance -> Identity.delivery_key_equal provenance.delivery_key (Identity.Operation request_id)
        && Identity.transcript_slot_equal provenance.transcript_slot Identity.Settled_failure
    | None -> false) rows in
  check int "each original request has one failure transcript" 1 (List.length matching);
  let completed_at = match operation.state with
    | Operation.Failed {completed_at; failure={kind=Operation.Interrupted_by_restart; _}} -> completed_at
    | Queued | Running _ | Succeeded _ | Cancelled _ | Failed _ -> fail "original request did not settle as restart interruption" in
  let journal = Journal.open_journal ~base_dir:root ~keeper_name ~operation_id:id () in
  let settlement : Journal.operation_settlement = {operation_id=operation.operation_id; completed_at} in
  check bool "journal terminal names this exact committed operation settlement" true
    (Option.is_some (Journal.find_operation_terminal journal ~settlement |> require "original terminal identity"));
  check int "journal has one terminal occurrence" 1 (List.length (Journal.read_journal journal |> require "terminal journal"))

let test_boot_terminal_settlement ~with_runner ~unknown_receipt ~failed_commit () =
  with_root @@ fun root ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  check bool "no runtime before either application" true (Option.is_none (Runtime_agent_execution_runtime.get ()));
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "boot-settlement-test"));
  List.iter (fun (name, trace_id) ->
    Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String name; "trace_id",`String trace_id;
      "activation_mode",`String "manual"]) |> require "boot meta"
    |> Keeper_meta_store.replace_snapshot workspace |> require "persist boot meta")
    [keeper_name, session_id; "healthy-boot-sibling", "healthy-boot-session"];
  let original, members, original_call, session_dir, provider_calls =
    prepare_boot_journal env ~root ~workspace ~unknown_receipt in
  (* Startup may settle an existing receipt and release its live checkpoint
     ownership. Read the original bytes before either settlement boundary. *)
  let snapshot = Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir ~reference:original_call.checkpoint
    |> require "retained original input before Owner installation" in
  check bool "retained checkpoint has the exact original reference" true
    (Keeper_checkpoint_ref.equal (Keeper_checkpoint_store.exact_snapshot_reference snapshot) original_call.checkpoint);
  let original_message = original.input |> Option.get |> Keeper_chat_operation_payload.input_of_json
    |> require "original aggregate input" |> fun input -> input.message in
  check bool "retained bytes contain the original aggregate input" true
    (List.exists (fun (entry : Agent_core.Types.message) ->
       entry.role = Agent_core.Types.User && entry.content = [Agent_core.Types.Text original_message])
       (Keeper_checkpoint_store.exact_snapshot_messages snapshot));
  check bool "the next application installs Owner before its runtime" true
    (Option.is_none (Runtime_agent_execution_runtime.get ()));
  let dispatched = ref 0 in
  let runner : Keeper_owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true);
     execute=(fun ~sw:_ ~keeper_name:_ ~claim:_ -> incr dispatched;
       Keeper_owner.Operation_failed {kind=Operation.Turn_invariant;detail="unexpected boot dispatch";outcome_ref=None});
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution:_ -> ())} in
  Registry.install_from_store ~sw ~operation_runner:(if with_runner then Some runner else None)
    ~on_turn_slot_released:None workspace |> require "install before runtime" |> ignore;
  let owner = Registry.get ~base_path:root ~keeper_name |> require "installed original Owner" in
  let initial_rows = Registry.batch_operations ~base_path:root ~keeper_name operation_id
    |> require "pre-runtime batch inputs" in
  if not unknown_receipt then (
    check bool "both original inputs remain before runtime" true
      (List.map (fun (row : Operation.t) -> row.input) initial_rows
       = List.map (fun (row : Operation.t) -> row.input) members);
    check int "deferred Active row is not in failed_at_start" 0
      (List.length (Keeper_owner.failed_operations_at_start owner));
    check bool "even direct claims cannot run the deferred call" true
      (Option.is_none (Keeper_owner.claim_next_operation owner |> require "pre-runtime claim")));
  check int "ready=true cannot dispatch before journal completion" 0 !dispatched;
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "next application runtime";
  let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
  if failed_commit then Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
  Fun.protect ~finally:Store.For_testing.clear_commit_fault @@ fun () ->
  let completed = Native.complete_restart_settlements ~runtime ~base_path:root |> require "production startup completion" in
  check int "a late failure excludes only its exact Owner" (if failed_commit then 1 else 2) completed;
  if failed_commit then (
    (match Registry.get ~base_path:root ~keeper_name with
     | Error (Registry.Owner_unavailable _) -> ()
     | Error _ | Ok _ -> fail "late SQL failure did not fence this Keeper");
    (match Keeper_owner.exact_operation owner operation_id with
     | Error Keeper_owner.Owner_closed -> ()
     | Error _ | Ok _ -> fail "failed startup actor still owns a live Store");
    Registry.get ~base_path:root ~keeper_name:"healthy-boot-sibling" |> require "healthy sibling remains available" |> ignore;
    let path = Store.path_for_keeper ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path:root) ~keeper_name in
    let stored = Store.open_existing ~path |> require "inspect refused settlement" in
    Fun.protect ~finally:(fun () -> Store.close stored |> require "close inspection") @@ fun () ->
    check bool "failed commit preserves the original Running input" true
      ((Store.get stored operation_id |> require "retained operation") = Some original);
    check bool "failed commit preserves exact native identity" true
      (Keeper_native_call.equal_state (Keeper_native_call.Active original_call)
        (Store.direct_native_call stored ~operation_id |> require "retained call")))
  else (
    let expected = if unknown_receipt then Keeper_native_call.unknown_effect_disposition else succeeded_retired in
    let current_call = Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id |> require "settled receipt" in
    check bool "the exact original call and receipt disposition survive" true
      (Keeper_native_call.equal_state (Keeper_native_call.Terminal_unacknowledged (original_call, expected)) current_call);
    let settled = Registry.batch_operations ~base_path:root ~keeper_name operation_id |> require "committed failed batch" in
    List.iter2 (fun (before : Operation.t) (after : Operation.t) ->
      check bool "operation ID and original admission/source survive" true
        (before.operation_id = after.operation_id && before.admission_digest = after.admission_digest
         && before.execution_digest = after.execution_digest && before.source = after.source);
      check_boot_projection ~root after) members settled;
    Native.complete_restart_settlements ~runtime ~base_path:root |> require "idempotent startup completion" |> ignore;
    List.iter (check_boot_projection ~root) settled);
  check int "restart never calls a Keeper runner" 0 !dispatched;
  check int "restart never resends the provider request" 1 (Atomic.get provider_calls)

let test_late_boot_terminal_settlement ~before_ready ~unknown_receipt ~failed_commit () =
  with_root @@ fun root ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "late-boot-settlement-test"));
  let original, members, original_call, _, provider_calls =
    prepare_boot_journal env ~root ~workspace ~unknown_receipt in
  let dispatched = ref 0 in
  let runner : Keeper_owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true);
     execute=(fun ~sw:_ ~keeper_name:_ ~claim:_ -> incr dispatched;
       Keeper_owner.Operation_failed {kind=Operation.Turn_invariant;detail="unexpected late boot dispatch";outcome_ref=None});
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution:_ -> ())} in
  check int "the first inventory has no metadata Owners" 0
    (Registry.install_from_store ~sw ~operation_runner:(if before_ready then Some runner else None)
       ~on_turn_slot_released:None workspace |> require "empty inventory before runtime");
  let create name trace_id =
    let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String name;
      "trace_id",`String trace_id; "activation_mode",`String "manual"]) |> require "materialized meta" in
    Registry.create_meta ~base_path:root meta in
  if before_ready then (
    create keeper_name "new-materialized-trace" |> require "create before runtime ready" |> ignore;
    check bool "creation before readiness leaves the original Running input intact" true
      ((Registry.exact_operation ~base_path:root ~keeper_name operation_id |> require "deferred late original") = Some original);
    check bool "creation before readiness leaves the exact old call Active" true
      (Keeper_native_call.equal_state (Keeper_native_call.Active original_call)
        (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id |> require "deferred late native call")));
  check bool "late creation did not initialize a replacement runtime" true
    (Option.is_none (Runtime_agent_execution_runtime.get ()));
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "late application runtime";
  let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
  Fun.protect ~finally:Store.For_testing.clear_commit_fault @@ fun () ->
  let completed =
    if failed_commit then
      Registry.complete_restart_settlements ~base_path:root
        ~journal_terminal:(fun ~keeper_name:observed_name ~session_root observed ->
          let result = Native.journal_terminal ~runtime ~base_path:root
              ~keeper_name:observed_name ~session_root observed in
          (* Target the late completion transaction, after Owner.start's SQL. *)
          Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
          result)
    else Native.complete_restart_settlements ~runtime ~base_path:root in
  check int "readiness snapshots only the Owners already registered" (if before_ready then 1 else 0)
    (completed |> require "initial runtime completion");
  create "healthy-late-sibling" "healthy-late-trace" |> require "create healthy late sibling" |> ignore;
  let created = if before_ready then Ok None else create keeper_name "new-materialized-trace" in
  if failed_commit then (
    (match created with
     | Error (Registry.Command_lookup_failed (Registry.Owner_unavailable name)) ->
       check string "late failure identifies its exact Owner" keeper_name name
     | Error _ | Ok _ -> fail "failed late settlement was reported as creation success");
    check bool "failed late settlement did not publish new metadata" true
      ((Keeper_meta_store.read_meta workspace keeper_name |> require "failed creation meta") = None);
    let path = Store.path_for_keeper ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path:root) ~keeper_name in
    let store = Store.open_existing ~path |> require "failed late Store" in
    Fun.protect ~finally:(fun () -> Store.close store |> require "close failed late Store") @@ fun () ->
    check bool "late SQL failure preserves the original Running input and source" true
      ((Store.get store operation_id |> require "late original operation") = Some original);
    check bool "late SQL failure preserves the original native call" true
      (Keeper_native_call.equal_state (Keeper_native_call.Active original_call)
        (Store.direct_native_call store ~operation_id |> require "late original call")))
  else (
    created |> require "late metadata creation" |> ignore;
    let expected = if unknown_receipt then Keeper_native_call.unknown_effect_disposition else succeeded_retired in
    check bool "late creation preserves the old call/trace/checkpoint and receipt" true
      (Keeper_native_call.equal_state (Keeper_native_call.Terminal_unacknowledged (original_call, expected))
        (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id |> require "late settled receipt"));
    let projection = Registry.operation_projection ~base_path:root ~keeper_name |> require "late operation projection" in
    check bool "the old Running row no longer blocks claims" true (Option.is_none projection.running_operation_id);
    let settled = Registry.batch_operations ~base_path:root ~keeper_name operation_id |> require "late settled batch" in
    List.iter2 (fun (before : Operation.t) (after : Operation.t) ->
      check bool "late settlement keeps original admission, execution and source" true
        (before.operation_id = after.operation_id && before.admission_digest = after.admission_digest
         && before.execution_digest = after.execution_digest && before.source = after.source);
      check_boot_projection ~root after) members settled;
    Native.complete_restart_settlements ~runtime ~base_path:root |> require "late settlement is idempotent" |> ignore;
    List.iter (check_boot_projection ~root) settled);
  Registry.get ~base_path:root ~keeper_name:"healthy-late-sibling" |> require "late sibling stays available" |> ignore;
  check int "late startup never dispatches a Keeper runner" 0 !dispatched;
  check int "late startup never replays the provider" 1 (Atomic.get provider_calls)

let test_creation_during_restart_snapshot () =
  with_root @@ fun root ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "racing-boot-settlement-test"));
  let _, _, first_call, _, first_provider_calls =
    prepare_boot_journal env ~root ~workspace ~unknown_receipt:false in
  let late_name = "created-during-restart-snapshot" in
  let _, late_members, late_call, _, late_provider_calls =
    prepare_boot_journal ~keeper_name:late_name ~session_id:"late-snapshot-session"
      env ~root ~workspace ~unknown_receipt:false in
  let meta name trace_id = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String name;
    "trace_id",`String trace_id; "activation_mode",`String "manual"]) |> require "snapshot meta" in
  Keeper_meta_store.replace_snapshot workspace (meta keeper_name session_id) |> require "first Owner snapshot";
  Registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None workspace
    |> require "install first snapshot Owner" |> ignore;
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "racing application runtime";
  let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
  let entered, signal_entered = Eio.Promise.create () in
  let resume, signal_resume = Eio.Promise.create () in
  let completed, signal_completed = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Fiber.yield ();
    let result = Registry.complete_restart_settlements ~base_path:root
        ~journal_terminal:(fun ~keeper_name:observed_name ~session_root observed ->
          if String.equal observed_name keeper_name then (
            Eio.Promise.resolve signal_entered ();
            Eio.Promise.await resume);
          Native.journal_terminal ~runtime ~base_path:root ~keeper_name:observed_name ~session_root observed) in
    Eio.Promise.resolve signal_completed result);
  Eio.Promise.await entered;
  Registry.create_meta ~base_path:root (meta late_name "different-new-trace")
    |> require "create while first Owner completion is awaiting" |> ignore;
  check bool "late Owner settles before the original snapshot resumes" true
    (Keeper_native_call.equal_state (Keeper_native_call.Terminal_unacknowledged (late_call, succeeded_retired))
      (Registry.direct_native_call ~base_path:root ~keeper_name:late_name ~operation_id |> require "concurrent late receipt"));
  Eio.Promise.resolve signal_resume ();
  check int "the first completion only counts its captured snapshot" 1
    (Eio.Promise.await completed |> require "concurrent first completion");
  check bool "the first snapshot Owner retains its exact receipt" true
    (Keeper_native_call.equal_state (Keeper_native_call.Terminal_unacknowledged (first_call, succeeded_retired))
      (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id |> require "concurrent first receipt"));
  let settled = Registry.batch_operations ~base_path:root ~keeper_name:late_name operation_id |> require "concurrent batch" in
  List.iter2 (fun (before : Operation.t) (after : Operation.t) ->
    check bool "concurrent creation preserves the original input authority" true
      (before.operation_id = after.operation_id && before.admission_digest = after.admission_digest
       && before.execution_digest = after.execution_digest && before.source = after.source);
    check_boot_projection ~keeper_name:late_name ~root after) late_members settled;
  Native.complete_restart_settlements ~runtime ~base_path:root |> require "both completions are idempotent" |> ignore;
  List.iter (check_boot_projection ~keeper_name:late_name ~root) settled;
  check int "first Owner provider was not replayed" 1 (Atomic.get first_provider_calls);
  check int "late Owner provider was not replayed" 1 (Atomic.get late_provider_calls)

let () =
  run "native reconcile after dispatch"
    ["journal terminal", [
       test_case "boot defers a real terminal before runtime with a ready runner" `Quick
         (test_boot_terminal_settlement ~with_runner:true ~unknown_receipt:false ~failed_commit:false);
       test_case "boot projects the terminal without a live runner" `Quick
         (test_boot_terminal_settlement ~with_runner:false ~unknown_receipt:false ~failed_commit:false);
       test_case "boot preserves an existing unknown-effect receipt" `Quick
         (test_boot_terminal_settlement ~with_runner:false ~unknown_receipt:true ~failed_commit:false);
       test_case "late boot SQL failure isolates its Owner and preserves input" `Quick
         (test_boot_terminal_settlement ~with_runner:false ~unknown_receipt:false ~failed_commit:true);
       test_case "empty inventory creates an Active Owner before runtime readiness" `Quick
         (test_late_boot_terminal_settlement ~before_ready:true ~unknown_receipt:false ~failed_commit:false);
       test_case "empty inventory creates an Active Owner after runtime readiness" `Quick
         (test_late_boot_terminal_settlement ~before_ready:false ~unknown_receipt:false ~failed_commit:false);
       test_case "late materialization preserves an unknown receipt" `Quick
         (test_late_boot_terminal_settlement ~before_ready:false ~unknown_receipt:true ~failed_commit:false);
       test_case "late materialization SQL failure leaves metadata absent and sibling available" `Quick
         (test_late_boot_terminal_settlement ~before_ready:false ~unknown_receipt:false ~failed_commit:true);
       test_case "Owner creation during a paused first completion misses no retained call" `Quick
         test_creation_during_restart_snapshot;
       test_case "returned dispatch copies the terminal" `Quick test_returned_dispatch;
       test_case "raising dispatch copies the terminal and re-raises" `Quick test_raising_dispatch]]
