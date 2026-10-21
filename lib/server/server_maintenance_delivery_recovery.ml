type kind = Goal_effects | Broadcast_mentions

type settlement =
  | Goal_settled of (unit, string) result
  | Broadcast_settled of (Workspace_broadcast.reconciliation_report, string) result

type t =
  { on_settled : base_path:string -> settlement -> unit
  ; mutable goal_active : bool
  ; mutable broadcast_active : bool
  }

let create ?(on_settled=(fun ~base_path:_ _ -> ())) () =
  {on_settled;goal_active=false;broadcast_active=false}

let label = function Goal_effects -> "goal_effects" | Broadcast_mentions -> "broadcast_mentions"
let active supervisor = function
  | Goal_effects -> supervisor.goal_active
  | Broadcast_mentions -> supervisor.broadcast_active
let set_active supervisor kind value = match kind with
  | Goal_effects -> supervisor.goal_active <- value
  | Broadcast_mentions -> supervisor.broadcast_active <- value

type phase = Reserved | Started | Settled | Interrupted | Raised

let observe ~base_path ~kind ~reserved_ns phase =
  let emit () =
    try Log.Server.routine_lazy (fun () ->
      let phase, identity = match phase with
        | Reserved -> "reserved", Printf.sprintf " base_path=%S" base_path
        | Started -> "started", "" | Settled -> "settled", ""
        | Interrupted -> "interrupted", "" | Raised -> "raised", "" in
      Printf.sprintf "maintenance_delivery kind=%s reserved_ns=%Ld phase=%s at_ns=%Ld%s"
        (label kind) reserved_ns phase (Mtime_clock.elapsed_ns ()) identity)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let log_settlement = function
  | Goal_settled (Ok ()) -> ()
  | Goal_settled (Error detail) ->
      Log.Server.warn "goal effect outbox delivery deferred: %s" detail
  | Broadcast_settled (Error detail) ->
      Log.Server.warn "broadcast mention reconciliation unavailable: %s" detail
  | Broadcast_settled (Ok report) ->
      List.iter
        (fun (receipt : Workspace_broadcast.mention_outbox_quarantine_receipt) ->
          Log.Server.error
            "broadcast mention quarantine source=%s quarantine=%s reason=%s sha256=%s detail=%s"
            receipt.source_name receipt.quarantine_name
            (Workspace_broadcast.mention_outbox_quarantine_reason_to_string receipt.reason)
            receipt.raw_sha256 receipt.detail)
        report.quarantine_receipts;
      if report.pending_rows > 0 || report.corrupt_rows > 0 then
        Log.Server.info
          "broadcast mention reconciliation outbox=%d pending=%d accepted=%d already_accepted=%d deferred=%d rejected=%d corrupt=%d"
          report.outbox_rows report.pending_rows report.accepted report.already_accepted
          report.deferred report.rejected report.corrupt_rows

let pulse ~sw ~config supervisor kind =
  Eio.Switch.check sw;
  if not (active supervisor kind) then (
    let reserved_ns = Mtime_clock.elapsed_ns () in
    let observe = observe ~base_path:config.Workspace_utils.base_path ~kind ~reserved_ns in
    set_active supervisor kind true;
    let release () = set_active supervisor kind false in
    try
      observe Reserved;
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:release (fun () ->
          try
            Eio.Fiber.yield ();
            observe Started;
            let settlement = match kind with
              | Goal_effects -> Goal_settled (Goal_delivery.flush config)
              | Broadcast_mentions -> Broadcast_settled (Workspace_broadcast.reconcile_pending_mentions config) in
            observe Settled;
            log_settlement settlement;
            (try supervisor.on_settled ~base_path:config.Workspace_utils.base_path settlement with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Log.Server.warn "maintenance delivery observer failed kind=%s: %s"
                 (label kind) (Printexc.to_string exn))
          with
          | Eio.Cancel.Cancelled _ as exn ->
              observe Interrupted;
              raise exn
          | exn ->
              observe Raised;
              Log.Server.warn "maintenance delivery retained kind=%s: %s"
                (label kind) (Printexc.to_string exn)))
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      release ();
      Printexc.raise_with_backtrace exn bt)
