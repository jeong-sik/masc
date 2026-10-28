open Result.Syntax

let route_can_consume (meta : Keeper_meta_contract.keeper_meta) =
  let route = Keeper_meta_contract.runtime_id_of_meta meta in
  let candidate_can_consume id =
    match Runtime.get_runtime_by_id id with
    | None -> false
    | Some runtime ->
      match runtime.Runtime_instance.execution with
      | Runtime_execution.Codex_app_server _ | Runtime_execution.Claude_code _
      | Runtime_execution.Antigravity_cli _ | Runtime_execution.Muse_serve _ -> true
      | Runtime_execution.Agent_core _ -> true
  in
  match Runtime.resolve_assignment route with
  | `Missing | `Unavailable _ -> false
  | `Lane lane ->
    (* Dispatch may reorder candidates after quota/auth failure. Every reachable
       owner must consume the receipt, rather than just the declared entry. *)
    match Runtime_lane.ordered_candidates lane with
    | [] -> false
    | _ :: _ as candidates -> List.for_all candidate_can_consume candidates

let wake_hint ~base_path ~keeper_name =
  try
    match Keeper_registry.wakeup_running ~intent:Keeper_registry.Reactive_signal
        ~base_path keeper_name with
    | Keeper_registry.Signaled -> ()
    | Deferred_unregistered | Deferred_not_running _ | Deferred_lifecycle _ -> ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Keeper.warn ~keeper_name "tool result wake hint failed: %s"
      (Printexc.to_string exn)

let notify ~base_path ~keeper_name =
  let config = Workspace.default_config base_path in
  let* meta = Keeper_meta_store.read_effective_meta config keeper_name in
  match meta with
  | None -> Ok ()
  | Some meta when not (route_can_consume meta) -> Ok ()
  | Some meta ->
    let keeper_name = meta.Keeper_meta_contract.name in
    let* snapshot = Keeper_client_tool_outbox.load ~base_path ~keeper_name in
    let receipt_ids = Keeper_client_tool_outbox.receipt_ids snapshot in
    let* () = List.fold_left (fun acc receipt_id ->
      let* () = acc in
      let stimulus : Keeper_event_queue.stimulus =
        {post_id="keeper-tool-result:" ^ receipt_id;
         urgency=Immediate;arrived_at=Time_compat.now ();
         payload=Tool_result_ready receipt_id} in
      (* A queue turn-start is not receipt delivery. Unlike once-delivery,
         pending/outbox dedup permits notification again after a refused or
         failed model turn, until that client ACKs its actual snapshot. *)
      match Keeper_registry_event_queue.enqueue_stimulus_durable_result
          ~base_path keeper_name stimulus with
      | Keeper_registry_event_queue.Stimulus_enqueued | Stimulus_already_present -> Ok ()
      | Stimulus_storage_error detail -> Error detail)
        (Ok ()) receipt_ids in
    (* Retry a lost hint for the same still-pending queue row. Receipt ACK is
       the stopping condition, not a count of hints or model turn starts. *)
    (match receipt_ids with [] -> () | _ :: _ -> wake_hint ~base_path ~keeper_name);
    Ok ()

type t = {config : Workspace.config; mutable discovering : bool}
let create ~config = {config;discovering=false}

let reconcile supervisor =
  let* names = Keeper_meta_store.retained_keeper_names_read_only_result supervisor.config in
  List.iter (fun keeper_name ->
    match notify ~base_path:supervisor.config.base_path ~keeper_name with
    | Ok () -> ()
    | Error detail -> Log.Keeper.warn ~keeper_name "unread tool result retained: %s" detail
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Log.Keeper.warn ~keeper_name "unread tool result recovery raised: %s"
        (Printexc.to_string exn)) names;
  Ok ()

let pulse ~sw supervisor =
  Eio.Switch.check sw;
  if not supervisor.discovering then (
    supervisor.discovering <- true;
    let release () = supervisor.discovering <- false in
    try
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:release (fun () ->
          Eio.Fiber.yield ();
          match reconcile supervisor with
          | Ok () -> ()
          | Error detail -> Log.Server.warn "unread tool result discovery failed: %s" detail
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception exn -> Log.Server.warn "unread tool result discovery raised: %s"
              (Printexc.to_string exn)))
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      release ();
      Printexc.raise_with_backtrace exn bt)
