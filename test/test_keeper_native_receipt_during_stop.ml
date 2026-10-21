(* A server stop fences the Owner inventory, then stops each Owner, which
   cancels its running child. Core commits the cancelled native call's terminal
   disposition under cancellation protection and hands it to the sink that
   [Keeper_direct_native_continuation.prepare] built. That sink advances the
   receipt to the call's last checkpoint and then records the terminal, both
   through the inventory, and [reconcile_after_dispatch] reads the receipt back
   the same way. This test runs a real Core execution through [prepare], with a
   provider request that never completes, stops the inventory while that
   request is open, and checks the receipt the cancelled child read back, what
   the stopped Owner settled, which new calls it still refuses, and what the
   next process finds. Assertions are on typed states, never on message
   text. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Registry = Keeper_owner_registry
module Agent = Agent_core.Agent

let keeper_name = "native-stop-receipt"
let session_id = "native-stop-receipt-session"
let model_id = "native-stop-receipt-model"
let runtime_id = "native-stop-receipt.runtime"
let goal = "Answer once."
let late_call_id = "019a0010-1000-7000-8000-0000000000c2"
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-stop-receipt-operation"
  |> require "operation ID"

(* What the stopped Owner held once [begin_stopping_all] returned. *)
type stop_observation =
  { child_receipt : (Keeper_native_call.state, Registry.command_error) result option
      (** Read by the cancelled child through the inventory after its dispatch
          ended, before the Owner settled the operation. *)
  ; operation : Keeper_chat_operation.t
  ; native_call : Keeper_native_call.state
  ; registry_bind : (unit, Registry.command_error) result
  ; owner_bind : (unit, Keeper_owner.error) result
  }

(* The recovery decides the settlement. *)
let recovery_label (disposition : Agent.execution_terminal_disposition) =
  match disposition.recovery with
  | Agent.Retire -> "retire"
  | Agent.Operator_repair_required Agent.Effect_outcome_unknown -> "operator repair"

let outcome_label (disposition : Agent.execution_terminal_disposition) =
  match disposition.outcome with
  | Agent.Terminal_succeeded -> "succeeded"
  | Agent.Terminal_failed -> "failed"
  | Agent.Terminal_cancelled -> "cancelled"

let late_call (operation : Keeper_chat_operation.t) =
  let seed_checkpoint =
    Keeper_checkpoint_ref.create
      ~trace_id:(Keeper_id.Trace_id.of_string session_id |> require "trace id")
      ~turn_count:1 ~canonical_checkpoint_bytes:"late bind seed"
    |> require "late checkpoint" in
  let locator = Agent.execution_locator_of_yojson
      (`Assoc ["version", `Int 1; "run_id", `String "execution-run-late-bind"])
    |> require "late locator" in
  Keeper_native_call.create ~call_id:late_call_id ~runtime_id
    ~operation_digest:operation.execution_digest
    ~api:(Keeper_native_call.New_input {seed_message_count=0})
    ~seed_checkpoint ~locator
  |> require "late call"

let failed_kind (operation : Keeper_chat_operation.t) =
  match operation.state with
  | Keeper_chat_operation.Failed {failure; _} -> Some failure.kind
  | Keeper_chat_operation.Queued | Keeper_chat_operation.Running _
  | Keeper_chat_operation.Succeeded _ | Keeper_chat_operation.Cancelled _ -> None

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let install_fixture_catalog ~sw =
  let previous_catalog = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () -> match previous_catalog with
    | None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let catalog = Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-stop-receipt-test" catalog
    |> require "model catalog" |> Llm_provider.Model_catalog.set_global

(* The repetition frame a direct operation's native checkpoints must carry. *)
let context_for_operation () =
  let context = Agent_core.Context.create () in
  let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
      (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation operation_id))
    |> require "direct scope" in
  Keeper_repetition_scope.save context frame;
  context

(* Runs the operation through [prepare] until its provider request is open,
   then stops the inventory the way the server shutdown hook does. *)
let stop_while_dispatching env ~root ~workspace ~session_dir =
  Eio.Switch.run @@ fun sw ->
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Incomplete_reply "{") in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let child_receipt = ref None in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim operation" |> Option.get in
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    (match Native.load ~binding |> require "load native admission" with
     | Native.No_pending -> ()
     | Native.Resume _ | Native.Terminal_pending _ -> fail "a fresh operation has a native call");
    let config = Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Answer once." ~tools:[] in
    let config = {config with context=Some (context_for_operation ())} in
    let agent_ref = ref None in
    let input = [Agent_core.Types.Text goal] in
    let prepared = Native.prepare ~binding ~runtime_id ~config ~agent_core_checkpoint:None
        ~input:(Native.New_input {blocks=input; metadata=[]}) ~agent_ref ()
      |> require "prepare native call" in
    let config = Native.config prepared in
    (* The child is cancelled here, so the read runs protected, as the one in
       [reconcile_after_dispatch] does. *)
    let read_back () = Eio.Cancel.protect (fun () ->
      child_receipt := Some
          (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id)) in
    match
      Native.reconcile_after_dispatch binding (fun () ->
        Runtime_agent.run_blocks ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ~input_metadata:[] input)
    with
    | Ok _ -> fail "the provider request that never completes answered"
    | Error _ ->
      read_back ();
      Keeper_owner.Operation_failed
        {kind=Keeper_chat_operation.Turn_exception; detail="dispatch failed"; outcome_ref=None}
    | exception exn ->
      read_back ();
      raise exn
  in
  let runner : Keeper_owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ -> ())} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  let owner = Registry.get ~base_path:root ~keeper_name |> require "Owner handle" in
  let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "canonical input" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source:(`Assoc ["kind", `String "fixture"]) ~input |> require "submit operation" |> ignore;
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
    (fun () -> Eio.Promise.await server.first_request_arrived);
  (match
     Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
       (fun () -> Registry.begin_stopping_all ~base_path:root)
   with
   | Ok results -> List.iter (require "Owner stop") results
   | Error _ -> fail "the inventory did not stop");
  let operation = Keeper_owner.exact_operation owner operation_id
    |> require "read stopped operation" |> Option.get in
  let native_call = Keeper_owner.direct_native_call owner ~operation_id
    |> require "read stopped native call" in
  let call = late_call operation in
  let registry_bind = Registry.bind_direct_native_call ~base_path:root ~keeper_name
      ~operation_id ~execution_digest:operation.execution_digest ~observed:native_call ~call in
  let owner_bind = Keeper_owner.bind_direct_native_call owner ~operation_id
      ~execution_digest:operation.execution_digest ~observed:native_call ~call in
  {child_receipt = !child_receipt; operation; native_call; registry_bind; owner_bind}

(* The next process installs the inventory again; its Owner settles whatever
   the stopped one left Running. No runner, so nothing claims a requeued row. *)
let after_restart ~root ~workspace =
  Eio.Switch.run @@ fun sw ->
  Registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None
    workspace |> require "reinstall Owner" |> ignore;
  Registry.exact_operation ~base_path:root ~keeper_name operation_id
  |> require "read restarted operation" |> Option.get

let run_case root =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "native execution runtime";
  install_fixture_catalog ~sw;
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "native-stop-receipt-test"));
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name", `String keeper_name; "trace_id", `String session_id;
    "activation_mode", `String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
  (* The session lives where the Owner and the startup sweep look. *)
  let session_dir = Filename.concat
      (Keeper_fs.session_store_path_for_runtime_root (Workspace.masc_dir workspace))
      session_id in
  mkdir_p session_dir;
  let stopped = stop_while_dispatching env ~root ~workspace ~session_dir in
  let restarted = after_restart ~root ~workspace in
  stopped, restarted

let with_root f =
  let root = Filename.temp_dir "keeper-native-stop-receipt-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () -> f root)

let test_stop_records_the_cancelled_terminal () =
  with_root (fun root ->
    let stopped, restarted = run_case root in
    let receipt = match stopped.child_receipt with
      | Some (Ok (Keeper_native_call.Terminal_unacknowledged (call, disposition))) ->
        Some (call, disposition)
      | Some (Ok (Keeper_native_call.No_native_call | Keeper_native_call.Active _))
      | Some (Error _) | None -> None in
    check bool "the cancelled child read back a terminal receipt during the stop" true
      (Option.is_some receipt);
    check (option string) "the stop ended the provider call as cancelled"
      (Some "cancelled")
      (Option.map (fun (_, disposition) -> outcome_label disposition) receipt);
    check (option string) "the receipt retires the call, which attempted no tool"
      (Some "retire")
      (Option.map (fun (_, disposition) -> recovery_label disposition) receipt);
    check bool "the receipt advanced to the terminal checkpoint past the seed" true
      (match receipt with
       | Some (call, _) ->
         not (Keeper_checkpoint_ref.equal call.Keeper_native_call.checkpoint call.seed_checkpoint)
       | None -> false);
    check bool "the stopped operation failed as cancelled instead of staying Running" true
      (failed_kind stopped.operation = Some Keeper_chat_operation.Turn_cancelled);
    check bool "its settlement acknowledged the retired call" true
      (Keeper_native_call.equal_state Keeper_native_call.No_native_call stopped.native_call);
    check bool "the inventory refuses a new native call behind the stop fence" true
      (match stopped.registry_bind with
       | Error (Registry.Command_lookup_failed Registry.Inventory_stopping) -> true
       | Ok () | Error (Registry.Command_lookup_failed
           ( Registry.Inventory_not_installed _ | Registry.Owner_not_found _
           | Registry.Owner_unavailable _ | Registry.Owner_initialization_failed _ ))
       | Error (Registry.Command_lifecycle_reserved _ | Registry.Command_rejected _) -> false);
    check bool "the stopping Owner itself refuses to bind a native call" true
      (match stopped.owner_bind with
       | Error Keeper_owner.Owner_stopping -> true
       | Ok ()
       | Error (Keeper_owner.Reducer_rejected _ | Keeper_owner.Operation_rejected _
               | Keeper_owner.Store_unavailable _ | Keeper_owner.Owner_closed) -> false);
    check bool "the next process finds it settled, not requeued for a dead journal" true
      (failed_kind restarted = Some Keeper_chat_operation.Turn_cancelled))

let () =
  run "native receipt during stop"
    ["owner stop", [
       test_case "a stop records the cancelled call's terminal" `Quick
         test_stop_records_the_cancelled_terminal]]
