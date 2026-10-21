(* A child can end while its operation's native call is still Active, because
   the cancelled call never reported a terminal disposition. These tests drive
   the Owner with an executor that leaves exactly that state behind and check
   what the Owner settles, what it keeps available, and what it leaves for the
   next process. An operator interrupt, a raised exception and a reported
   success close the call as an unknown effect. A stopping Owner and a failure
   the runner reports on its own leave it for the next process to resume.
   Assertions are on typed states, never on message text. *)
open Alcotest
open Masc

module Owner = Keeper_owner
module Chat_operation = Owner.Chat_operation
module Store = Keeper_chat_operation_store
module Native = Keeper_native_call
module Agent = Agent_core.Agent

let operation_id value =
  match Chat_operation.Operation_id.of_string value with
  | Ok id -> id
  | Error detail -> fail detail
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ; "activation_mode", `String "manual"
        ])
  with
  | Ok meta -> meta
  | Error detail -> fail ("meta fixture failed: " ^ detail)
;;

let owner_ok = function
  | Ok value -> value
  | Error error -> fail (Owner.error_to_string error)
;;

let operation_source = `Assoc [ "kind", `String "dashboard" ]
let operation_input text = `Assoc [ "message", `String text ]
let settle_deadline_s = 5.0
let poll_s = 0.01
let call_id = "019a0010-1000-7000-8000-0000000000a1"
let cancelled_message = "operator interrupted the turn"

let unknown_effect_disposition =
  { Agent.outcome = Agent.Terminal_cancelled
  ; recovery = Agent.Operator_repair_required Agent.Effect_outcome_unknown
  }
;;

let retired_disposition =
  { Agent.outcome = Agent.Terminal_cancelled; recovery = Agent.Retire }
;;

let checkpoint =
  match
    Keeper_checkpoint_ref.create
      ~trace_id:(Keeper_id.Trace_id.of_string "open-native-trace" |> Result.get_ok)
      ~turn_count:1
      ~canonical_checkpoint_bytes:"open native call seed"
  with
  | Ok reference -> reference
  | Error _ -> fail "checkpoint fixture"
;;

let locator =
  match
    Agent.execution_locator_of_yojson
      (`Assoc [ "version", `Int 1; "run_id", `String "execution-run-open-native-call" ])
  with
  | Ok locator -> locator
  | Error detail -> fail detail
;;

let make_call (operation : Chat_operation.t) =
  match
    Native.create
      ~call_id
      ~runtime_id:"native.primary"
      ~operation_digest:operation.execution_digest
      ~api:(Native.New_input { seed_message_count = 0 })
      ~seed_checkpoint:checkpoint
      ~locator
  with
  | Ok call -> call
  | Error detail -> fail detail
;;

(* Bind a native call to the claimed operation the way the native dispatch
   does, leaving it Active. *)
let bind_active_call owner (operation : Chat_operation.t) =
  owner_ok
    (Owner.bind_direct_native_call
       owner
       ~operation_id:operation.operation_id
       ~execution_digest:operation.execution_digest
       ~observed:Native.No_native_call
       ~call:(make_call operation))
;;

let wait_until ~clock ~what condition =
  let rec loop () =
    if condition ()
    then ()
    else (
      Eio.Time.sleep clock poll_s;
      loop ())
  in
  try Eio.Time.with_timeout_exn clock settle_deadline_s loop with
  | Eio.Time.Timeout -> fail ("timed out waiting for " ^ what)
;;

let operation_of owner id =
  match owner_ok (Owner.exact_operation owner id) with
  | Some operation -> operation
  | None -> fail "operation is missing"
;;

let await_terminal ~clock owner id =
  wait_until ~clock ~what:"a terminal operation" (fun () ->
    Chat_operation.is_terminal (operation_of owner id).state);
  operation_of owner id
;;

let native_state owner id = owner_ok (Owner.direct_native_call owner ~operation_id:id)

let failed_kind (operation : Chat_operation.t) =
  match operation.state with
  | Chat_operation.Failed { failure; _ } -> failure.kind
  | Chat_operation.Queued | Chat_operation.Running _ | Chat_operation.Succeeded _
  | Chat_operation.Cancelled _ ->
    fail ("operation did not fail: " ^ Chat_operation.state_to_string operation.state)
;;

let cancelled_by_turn =
  Owner.Operation_failed
    { kind = Chat_operation.Turn_cancelled; detail = cancelled_message; outcome_ref = None }
;;

let interrupt_running owner id =
  match owner_ok (Owner.interrupt_running_operation owner id) with
  | Owner.Operation_interrupt_signalled -> ()
  | Owner.Operation_not_current _ | Owner.Operation_settling
  | Owner.Operation_maintenance_running | Owner.Operation_slot_held_by_autonomous_turn
  | Owner.Operation_interrupt_failed _ ->
    fail "the interrupt did not reach the running child"
;;

let is_unknown_effect = function
  | Native.Terminal_unacknowledged (_, disposition) -> disposition = unknown_effect_disposition
  | Native.No_native_call | Native.Active _ -> false
;;

let is_active = function
  | Native.Active _ -> true
  | Native.No_native_call | Native.Terminal_unacknowledged _ -> false
;;

let is_running (operation : Chat_operation.t) =
  match operation.state with
  | Chat_operation.Running _ -> true
  | Chat_operation.Queued | Chat_operation.Succeeded _ | Chat_operation.Failed _
  | Chat_operation.Cancelled _ -> false
;;

let fresh_store_path ~sw =
  let path = Filename.temp_file "keeper-owner-open-native-" ".sqlite3" in
  Unix.unlink path;
  Eio.Switch.on_release sw (fun () -> if Sys.file_exists path then Unix.unlink path);
  path
;;

let start_owner ~sw ~path ~name ~runner =
  owner_ok
    (Owner.start
       ~sw
       ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
       ~operation_store_path:path ~session_root:(Filename.concat (Filename.dirname path) "traces")
       ~now:(fun () -> 42.0)
       ~operation_runner:(Some runner)
       ~on_turn_slot_released:None
       ~keeper_name:name
       ~initial_meta:(Some (make_meta name)))
;;

let runner ~ready execute =
  Owner.
    { ready = (fun ~keeper_name:_ -> !ready)
    ; execute
    ; on_execution_settled = (fun ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ -> ())
    }
;;

let submit owner id text =
  ignore
    (owner_ok
       (Owner.submit_operation
          owner
          ~operation_id:id
          ~source:operation_source
          ~input:(operation_input text)))
;;

(* The reported failure: an operator interrupt leaves an Active native call
   with no terminal disposition. Settling that operation used to be refused as
   store corruption, which fenced the whole Owner: a queued operation could not
   be cancelled and nothing behind the stuck one could start. *)
let test_interrupted_active_call_settles_and_keeps_the_owner_available () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun sw ->
  let owner_cell = ref None in
  let ready = ref true in
  let first = ref true in
  let bound = ref false in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation = match owner_ok (claim ()) with
      | Some operation -> operation
      | None -> fail "the executor claimed nothing" in
    if !first
    then (
      first := false;
      (* Hold the later operations queued until the test releases them. *)
      ready := false;
      bind_active_call (Option.get !owner_cell) operation;
      bound := true;
      (* The interrupt fails this child's switch. *)
      Eio.Fiber.await_cancel ())
    else Owner.Operation_succeeded { outcome_ref = "later" }
  in
  let owner =
    start_owner ~sw ~path:(fresh_store_path ~sw) ~name:"open-native-interrupt"
      ~runner:(runner ~ready execute)
  in
  owner_cell := Some owner;
  let stuck = operation_id "open-native-stuck" in
  let cancelled = operation_id "open-native-cancelled" in
  let next = operation_id "open-native-next" in
  submit owner stuck "first";
  wait_until ~clock ~what:"the native call to bind" (fun () -> !bound);
  submit owner cancelled "to cancel";
  submit owner next "runs after";
  interrupt_running owner stuck;
  let settled = await_terminal ~clock owner stuck in
  check bool "the interrupted operation fails as cancelled" true
    (failed_kind settled = Chat_operation.Turn_cancelled);
  check bool "the Owner is not fenced" false (Owner.operation_projection owner).store_unavailable;
  check bool "the unknown effect stays on record for an operator" true
    (is_unknown_effect (native_state owner stuck));
  (match owner_ok (Owner.cancel_queued_operation owner cancelled) with
   | { Chat_operation.state = Chat_operation.Cancelled _; _ } -> ()
   | operation -> fail ("queued cancel left " ^ Chat_operation.state_to_string operation.state));
  ready := true;
  submit owner (operation_id "open-native-wake") "wakes the drain";
  let ran = await_terminal ~clock owner next in
  check bool "the next queued operation became claimable and completed" true
    (match ran.state with
     | Chat_operation.Succeeded _ -> true
     | Chat_operation.Queued | Chat_operation.Running _ | Chat_operation.Failed _
     | Chat_operation.Cancelled _ -> false)
;;

(* A runner that reports its own cancellation, without the Owner having
   signalled it, also ends the operation: a cancelled call is not resumed. *)
let test_runner_reported_cancellation_closes_the_call () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun sw ->
  let owner_cell = ref None in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation = match owner_ok (claim ()) with
      | Some operation -> operation
      | None -> fail "the executor claimed nothing" in
    bind_active_call (Option.get !owner_cell) operation;
    cancelled_by_turn
  in
  let owner =
    start_owner ~sw ~path:(fresh_store_path ~sw) ~name:"open-native-reported"
      ~runner:(runner ~ready:(ref true) execute)
  in
  owner_cell := Some owner;
  let id = operation_id "open-native-reported" in
  submit owner id "cancelled by the runner";
  let settled = await_terminal ~clock owner id in
  check bool "fails as cancelled" true (failed_kind settled = Chat_operation.Turn_cancelled);
  check bool "the unknown effect stays on record" true (is_unknown_effect (native_state owner id))
;;

(* An exception out of the runner may have left a tool attempt unsettled, so the
   call closes as an unknown effect. *)
let test_raised_exception_closes_the_call () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun sw ->
  let owner_cell = ref None in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation = match owner_ok (claim ()) with
      | Some operation -> operation
      | None -> fail "the executor claimed nothing" in
    bind_active_call (Option.get !owner_cell) operation;
    failwith "runner raised after dispatch"
  in
  let owner =
    start_owner ~sw ~path:(fresh_store_path ~sw) ~name:"open-native-raised"
      ~runner:(runner ~ready:(ref true) execute)
  in
  owner_cell := Some owner;
  let id = operation_id "open-native-raised" in
  submit owner id "runner raises";
  let settled = await_terminal ~clock owner id in
  check bool "fails as an exception" true (failed_kind settled = Chat_operation.Turn_exception);
  check bool "the unknown effect stays on record" true (is_unknown_effect (native_state owner id))
;;

(* A resumed call that fails before anything is dispatched, such as a
   checkpoint that cannot be loaded, is the runner's own failure. The call is
   untouched by this process, so it stays Active and resumable. Closing it as an
   unknown effect would lose an operation no new attempt ran. *)
let test_failure_before_dispatch_leaves_the_call_resumable () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun sw ->
  let owner_cell = ref None in
  let ready = ref true in
  let bound = ref false in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation = match owner_ok (claim ()) with
      | Some operation -> operation
      | None -> fail "the executor claimed nothing" in
    ready := false;
    bind_active_call (Option.get !owner_cell) operation;
    bound := true;
    Owner.Operation_failed
      { kind = Chat_operation.Turn_exception
      ; detail = "continuation could not be loaded"
      ; outcome_ref = None
      }
  in
  let owner =
    start_owner ~sw ~path:(fresh_store_path ~sw) ~name:"open-native-predispatch"
      ~runner:(runner ~ready execute)
  in
  owner_cell := Some owner;
  let id = operation_id "open-native-predispatch" in
  let queued = operation_id "open-native-predispatch-queued" in
  submit owner id "resumed call fails to load";
  wait_until ~clock ~what:"the failure to be reported" (fun () ->
    !bound && Option.is_none (Owner.turn_in_flight owner));
  submit owner queued "waits behind";
  check bool "the operation is not settled" true (is_running (operation_of owner id));
  check bool "the call stays active for the next process" true (is_active (native_state owner id));
  check bool "the Owner is not fenced" false (Owner.operation_projection owner).store_unavailable;
  (match owner_ok (Owner.cancel_queued_operation owner queued) with
   | { Chat_operation.state = Chat_operation.Cancelled _; _ } -> ()
   | operation -> fail ("queued cancel left " ^ Chat_operation.state_to_string operation.state))
;;

(* The terminal disposition is already on record: settlement is unchanged and
   the retired call is acknowledged, not rewritten as an unknown effect. *)
let test_recorded_disposition_settles_as_before () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun sw ->
  let owner_cell = ref None in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation = match owner_ok (claim ()) with
      | Some operation -> operation
      | None -> fail "the executor claimed nothing" in
    let owner = Option.get !owner_cell in
    bind_active_call owner operation;
    owner_ok
      (Owner.terminal_direct_native_call
         owner
         ~operation_id:operation.operation_id
         ~execution_digest:operation.execution_digest
         ~call_id
         ~disposition:retired_disposition);
    cancelled_by_turn
  in
  let owner =
    start_owner ~sw ~path:(fresh_store_path ~sw) ~name:"open-native-recorded"
      ~runner:(runner ~ready:(ref true) execute)
  in
  owner_cell := Some owner;
  let id = operation_id "open-native-recorded" in
  submit owner id "recorded";
  let settled = await_terminal ~clock owner id in
  check bool "fails as cancelled" true (failed_kind settled = Chat_operation.Turn_cancelled);
  check bool "the retired call is acknowledged" true
    (Native.equal_state Native.No_native_call (native_state owner id))
;;

(* A turn that reports success while its native call is still Active has no
   proof the effects finished. The claimed success is not recorded. *)
let test_success_without_a_disposition_is_not_recorded () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun sw ->
  let owner_cell = ref None in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation = match owner_ok (claim ()) with
      | Some operation -> operation
      | None -> fail "the executor claimed nothing" in
    bind_active_call (Option.get !owner_cell) operation;
    Owner.Operation_succeeded { outcome_ref = "claimed" }
  in
  let owner =
    start_owner ~sw ~path:(fresh_store_path ~sw) ~name:"open-native-success"
      ~runner:(runner ~ready:(ref true) execute)
  in
  owner_cell := Some owner;
  let id = operation_id "open-native-success" in
  submit owner id "claims success";
  let settled = await_terminal ~clock owner id in
  check bool "recorded as an invariant failure, not a success" true
    (failed_kind settled = Chat_operation.Turn_invariant);
  check bool "the Owner is not fenced" false (Owner.operation_projection owner).store_unavailable;
  check bool "the unknown effect stays on record" true (is_unknown_effect (native_state owner id))
;;

(* The call already holds an unknown-effect receipt when the turn reports
   success. The receipt cannot complete, so the success is not recorded, and
   refusing it is a precondition, not store corruption that fences the Owner. *)
let test_success_over_an_unknown_effect_receipt_is_not_recorded () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun sw ->
  let owner_cell = ref None in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation = match owner_ok (claim ()) with
      | Some operation -> operation
      | None -> fail "the executor claimed nothing" in
    let owner = Option.get !owner_cell in
    bind_active_call owner operation;
    owner_ok
      (Owner.terminal_direct_native_call
         owner
         ~operation_id:operation.operation_id
         ~execution_digest:operation.execution_digest
         ~call_id
         ~disposition:unknown_effect_disposition);
    Owner.Operation_succeeded { outcome_ref = "claimed" }
  in
  let owner =
    start_owner ~sw ~path:(fresh_store_path ~sw) ~name:"open-native-unknown-success"
      ~runner:(runner ~ready:(ref true) execute)
  in
  owner_cell := Some owner;
  let id = operation_id "open-native-unknown-success" in
  submit owner id "claims success";
  let settled = await_terminal ~clock owner id in
  check bool "recorded as an invariant failure, not a success" true
    (failed_kind settled = Chat_operation.Turn_invariant);
  check bool "the Owner is not fenced" false (Owner.operation_projection owner).store_unavailable;
  check bool "the unknown effect stays on record" true (is_unknown_effect (native_state owner id))
;;

(* An Owner that is stopping leaves the Active call alone. The next process
   requeues the operation and resumes the same call from its checkpoint, so
   closing the call here would destroy work the restart is built to recover. *)
let test_stopping_owner_leaves_the_active_call_for_restart_recovery () =
  Eio_main.run @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run @@ fun file_sw ->
  let path = fresh_store_path ~sw:file_sw in
  let id = operation_id "open-native-stopping" in
  (Eio.Switch.run @@ fun sw ->
   let owner_cell = ref None in
   let bound = ref false in
   let execute ~sw:_ ~keeper_name:_ ~claim =
     let operation = match owner_ok (claim ()) with
       | Some operation -> operation
       | None -> fail "the executor claimed nothing" in
     bind_active_call (Option.get !owner_cell) operation;
     bound := true;
     (* The stop fails this child's switch. *)
     Eio.Fiber.await_cancel ()
   in
   let owner =
     start_owner ~sw ~path ~name:"open-native-stopping"
       ~runner:(runner ~ready:(ref true) execute)
   in
   owner_cell := Some owner;
   submit owner id "stopped mid call";
   wait_until ~clock ~what:"the native call to bind" (fun () -> !bound);
   ignore (owner_ok (Owner.begin_stopping owner));
   wait_until ~clock ~what:"the slot to release" (fun () ->
     Option.is_none (Owner.turn_in_flight owner)));
  let store = match Store.open_existing ~path with
    | Ok store -> store
    | Error error -> fail (Store.error_to_string error) in
  Fun.protect
    ~finally:(fun () -> ignore (Store.close store : (unit, Store.error) result))
    (fun () ->
       check bool "the operation stays running" true
         (match Store.get store id with
          | Ok (Some { Chat_operation.state = Chat_operation.Running _; _ }) -> true
          | Ok _ | Error _ -> false);
       check bool "the native call stays active" true
         (match Store.direct_native_call store ~operation_id:id with
          | Ok (Native.Active _) -> true
          | Ok (Native.No_native_call | Native.Terminal_unacknowledged _) | Error _ -> false))
;;

(* These cases exercise the actual child mailbox, retained filesystem and
   SQLite input/native journal. They do not fake a provider run or prove the
   complete direct-turn/HTTP/UI path. Lifecycle and native run IDs deliberately
   differ: they are bound by the exact published checkpoint, not string equality. *)
type input_wait_fixture = Owned_wait | Consumed_input | Missing_retained | Corrupt_retained | Changed_retained | Foreign_scope

let test_owned_input_wait fixture () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_dir "owner-input-wait-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  let path = Filename.concat root Store.database_file in
  let name = "owned-input-wait" in
  let meta = make_meta name in
  let session_root = Filename.concat root "traces" in
  let session_dir = Filename.concat session_root (Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
  Fs_compat.mkdir_p session_dir;
  let id = operation_id "owned-input-wait-original" in
  let later = operation_id "owned-input-wait-independent" in
  let pending : Agent_core.Agent_input_request.pending =
    {run_id="lifecycle-original-input";request={request_id="question-original";
      participant_name=Some "operator";question="Which original choice?";
      schema=Some (`Assoc ["type",`String "string"]);timeout_s=Some 0.1;created_at=1.}} in
  let owned = ref None in
  Eio.Switch.run (fun sw ->
    let owner_cell = ref None and first = ref true and ready = ref true in
    let finished,notify_finished = Eio.Promise.create () in
    let hold,release = Eio.Promise.create () in
    let execute ~sw:_ ~keeper_name:_ ~claim =
      let operation : Chat_operation.t = match owner_ok (claim ()) with Some operation -> operation | None -> fail "no claimed original" in
      let owner = Option.get !owner_cell in
      if not !first then Owner.Operation_succeeded {outcome_ref="independent actual result"}
      else begin
        first := false;
        let initial = Keeper_context_core.create ~eio:true ~system_prompt:"original input fixture"
          |> Keeper_context_core.checkpoint_of_context in
        let frame_scope = match fixture with Foreign_scope -> later
          | Owned_wait | Consumed_input | Missing_retained | Corrupt_retained | Changed_retained -> id in
        let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
            (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation frame_scope))
          |> Result.map_error Keeper_repetition_snapshot.error_to_string |> Result.get_ok in
        Keeper_repetition_context.save initial.context frame;
        let seed = {initial with Agent_core.Checkpoint.session_id=Keeper_id.Trace_id.to_string meta.runtime.trace_id;
          turn_count=1;messages=[Agent_core.Types.user_msg "original admitted input"]} in
        let retain checkpoint =
          let snapshot = Keeper_checkpoint_store.exact_snapshot_of_value ~expected_session_id:meta.runtime.trace_id checkpoint
            |> Result.map_error Keeper_checkpoint_store.checkpoint_ref_load_error_to_string |> Result.get_ok in
          Keeper_checkpoint_store.retain_exact_snapshot ~session_dir snapshot
            |> Keeper_checkpoint_store.require_confirmed_installation
            |> function Ok reference -> reference | Error _ -> fail "actual retention was not confirmed" in
        let seed_reference = retain seed in
        let call = Native.create ~call_id ~runtime_id:"native.primary" ~operation_digest:operation.execution_digest
            ~api:(Native.New_input {seed_message_count=1}) ~seed_checkpoint:seed_reference ~locator
          |> Result.get_ok in
        owner_ok (Owner.bind_direct_native_call owner ~operation_id:id
          ~execution_digest:operation.execution_digest ~observed:Native.No_native_call ~call);
        let writer = owner_ok (Owner.begin_input_checkpoint owner ~trace_id:meta.runtime.trace_id) in
        let checkpoint = {seed with Agent_core.Checkpoint.pending_input=(match fixture with
          | Consumed_input -> None
          | Owned_wait | Missing_retained | Corrupt_retained | Changed_retained | Foreign_scope -> Some pending)} in
        let reference = retain checkpoint in
        owned := Some reference;
        ignore (owner_ok (Owner.advance_direct_input_checkpoint owner ~writer ~operation_id:id
          ~execution_digest:operation.execution_digest ~call_id ~observed:seed_reference ~checkpoint:reference));
        owner_ok (Owner.terminal_direct_native_call owner ~operation_id:id ~execution_digest:operation.execution_digest
          ~call_id ~disposition:{Agent.outcome=Agent.Terminal_succeeded;recovery=Agent.Retire});
        (* A readable old pending canonical cannot substitute for retained evidence. *)
        let canonical = {checkpoint with pending_input=Some pending} in
        (match Keeper_checkpoint_store.save_agent_core_classified ~session_dir ~history_retained:0 canonical with
         | Ok (Keeper_checkpoint_store.Saved _) -> ()
         | Ok (Stale_noop _) -> fail "fixture canonical did not install"
         | Error detail -> fail detail);
        let readable = Keeper_checkpoint_store.load_agent_core_exact_snapshot ~session_dir
            ~session_id:canonical.session_id
          |> Result.map_error Keeper_checkpoint_store.checkpoint_ref_load_error_to_string |> Result.get_ok in
        check bool "canonical fallback is readable before retained fault" true
          ((Keeper_checkpoint_store.exact_snapshot_checkpoint readable).pending_input=Some pending);
        let retained = Filename.concat (Filename.concat session_dir Keeper_checkpoint_store.retained_dirname)
            (reference.sha256 ^ ".json") in
        (match fixture with
         | Owned_wait -> Fs_compat.save_file
             (Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:canonical.session_id) "corrupt canonical"
         | Missing_retained -> Unix.unlink retained
         | Corrupt_retained -> Fs_compat.save_file retained "corrupt retained"
         | Changed_retained -> Fs_compat.save_file retained ("\n" ^ Fs_compat.load_file retained)
         | Consumed_input | Foreign_scope -> ());
        let result = Owner.defer_direct_input_wait owner ~operation_id:id in
        Eio.Promise.resolve notify_finished result;
        match fixture with
        | Owned_wait -> ignore (owner_ok result); Owner.Operation_deferred
        | Consumed_input | Missing_retained | Corrupt_retained | Changed_retained | Foreign_scope ->
          ready := false;
          ignore (Eio.Promise.await hold);
          Owner.Operation_failed {kind=Chat_operation.Turn_invariant;detail="fixture rejection observed";outcome_ref=None}
      end in
    let owner = start_owner ~sw ~path ~name ~runner:(runner ~ready execute) in
    owner_cell := Some owner;
    submit owner id "original admitted input";
    let result = Eio.Promise.await finished in
    (match fixture,result with
     | Owned_wait,Ok _ ->
       let waiting = owner_ok (Owner.direct_input_wait owner ~operation_id:id) |> Option.get in
       check bool "question comes from exact owned bytes" true
         (Yojson.Safe.equal (Agent_core.Agent_input_request.pending_to_json pending)
            (Agent_core.Agent_input_request.pending_to_json waiting.pending));
       check bool "same original checkpoint" true (Keeper_checkpoint_ref.equal (Option.get !owned) waiting.checkpoint);
       check bool "retirement acknowledged with wait" true (native_state owner id=Native.No_native_call);
       (match Owner.defer_direct_input_wait owner ~operation_id:id with
        | Error (Owner.Operation_rejected (Store.Invalid_input _)) -> ()
        | Error error -> fail (Owner.error_to_string error) | Ok _ -> fail "outside fiber acquired child authority");
       submit owner later "independent input";
       ignore (await_terminal ~clock:env#clock owner later);
       check bool "original remains queued after child settlement" true
         ((operation_of owner id).state=Chat_operation.Queued);
       check bool "unresolved wait does not become claimable" false
         (Owner.operation_projection owner).has_claimable_queued
     | (Consumed_input | Missing_retained | Corrupt_retained | Changed_retained | Foreign_scope),
         Error (Owner.Operation_rejected (Store.Invalid_input _)) ->
       check bool "refusal leaves original running" true (is_running (operation_of owner id));
       check bool "refusal mints no wait" true (owner_ok (Owner.direct_input_wait owner ~operation_id:id)=None);
       check bool "refusal preserves native receipt" true (match native_state owner id with
         | Native.Terminal_unacknowledged _ -> true | No_native_call | Active _ -> false);
       check bool "refusal preserves exact input owner" true
         ((owner_ok (Owner.current_input_checkpoint owner)).observation=Store.Input_observed (Option.get !owned));
       Eio.Promise.resolve release ()
     | (Owned_wait | Consumed_input | Missing_retained | Corrupt_retained | Changed_retained | Foreign_scope),Error error ->
       fail (Owner.error_to_string error)
     | (Consumed_input | Missing_retained | Corrupt_retained | Changed_retained | Foreign_scope),Ok _ ->
       fail "unavailable or foreign input was accepted"));
  (match fixture with
   | Owned_wait ->
     Eio.Switch.run (fun sw ->
       let ready = ref false in
       let owner = start_owner ~sw ~path ~name ~runner:(runner ~ready (fun ~sw:_ ~keeper_name:_ ~claim:_ ->
         fail "unresolved input was redispatched after restart")) in
       check bool "original wait survives actual Owner reopen" true
         (Option.is_some (owner_ok (Owner.direct_input_wait owner ~operation_id:id)));
       check bool "restarted wait remains blocked" false (Owner.operation_projection owner).has_claimable_queued;
       ignore (owner_ok (Owner.cancel_queued_operation owner id));
       check bool "cancellation settles original wait" true
         (owner_ok (Owner.direct_input_wait owner ~operation_id:id)=None);
       check bool "cancellation preserves global input fact" true
         ((owner_ok (Owner.current_input_checkpoint owner)).observation=Store.Input_observed (Option.get !owned)))
   | Consumed_input | Missing_retained | Corrupt_retained | Changed_retained | Foreign_scope -> ())
;;

let () =
  run
    "keeper-owner-open-native-call"
    [ ( "child ends with an open native call"
      , [ test_case "interrupted turn settles and keeps the Owner available" `Quick
            test_interrupted_active_call_settles_and_keeps_the_owner_available
        ; test_case "runner-reported cancellation closes the call" `Quick
            test_runner_reported_cancellation_closes_the_call
        ; test_case "raised exception closes the call" `Quick
            test_raised_exception_closes_the_call
        ; test_case "failure before dispatch leaves the call resumable" `Quick
            test_failure_before_dispatch_leaves_the_call_resumable
        ; test_case "success over an unknown-effect receipt is not recorded" `Quick
            test_success_over_an_unknown_effect_receipt_is_not_recorded
        ; test_case "recorded disposition settles as before" `Quick
            test_recorded_disposition_settles_as_before
        ; test_case "success without a disposition is not recorded" `Quick
            test_success_without_a_disposition_is_not_recorded
        ; test_case "owned input wait blocks original while independent work and restart survive" `Quick (test_owned_input_wait Owned_wait)
        ; test_case "consumed input cannot be deferred as waiting" `Quick (test_owned_input_wait Consumed_input)
        ; test_case "missing retained input refuses despite readable canonical" `Quick (test_owned_input_wait Missing_retained)
        ; test_case "corrupt retained input refuses despite readable canonical" `Quick (test_owned_input_wait Corrupt_retained)
        ; test_case "changed retained bytes refuse despite readable canonical" `Quick (test_owned_input_wait Changed_retained)
        ; test_case "foreign original operation scope refuses input wait" `Quick (test_owned_input_wait Foreign_scope)
        ; test_case "stopping Owner leaves the call for restart recovery" `Quick
            test_stopping_owner_leaves_the_active_call_for_restart_recovery
        ] )
    ]
;;
