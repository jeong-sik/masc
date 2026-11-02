(* Pending confirmations change when their own deadline passes, even when no
   writer runs. This worker waits for that deadline, a store publication, or
   workspace retirement; it never scans on an interval. *)
module Expiry_key = struct
  type t = string * string
  let compare = compare
end

module Expiry_set = Set.Make (Expiry_key)

type expiry_plan = {
  expired : Expiry_set.t;
  next : float option;
}

let expiry_plan ~now entries =
  List.fold_left (fun plan (entry : Operator_pending_confirm.pending_confirm) ->
    match entry.expires_at with
    | None -> plan
    | Some text ->
      (match Masc_domain.parse_iso8601_opt text with
       | None -> plan (* The store decoder already rejects this value. *)
       | Some at when Float.compare at now <= 0 ->
           { plan with expired = Expiry_set.add (entry.confirm_token, text) plan.expired }
       | Some at ->
           let next = match plan.next with
             | Some previous -> Some (Float.min previous at)
             | None -> Some at in
           { plan with next }))
    { expired = Expiry_set.empty; next = None } entries
;;

let start_with ~sw ~clock ~(state : Mcp_server.server_state) ~read ~invalidate =
  let wake = Eio.Stream.create 1 in
  let wake_mu = Stdlib.Mutex.create () in
  let signal () =
    Stdlib.Mutex.protect wake_mu (fun () ->
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ()) in
  let observer ~base_path =
    let current = Mcp_server.workspace_scope state in
    let may_match =
      match Config_dir_resolver.canonical_base_path base_path,
            Config_dir_resolver.canonical_base_path current.config.base_path with
      | Ok source, Ok target -> String.equal source target
      | Error _, _ | _, Error _ -> true in
    if may_match then signal ();
    invalidate ~base_path in
  Operator_pending_confirm.install_change_observer observer;
  Eio.Switch.on_release sw (fun () ->
    ignore (Operator_pending_confirm.replace_change_observer_if_current
      ~current:observer ~replacement:invalidate));
  let is_current scope =
    Mcp_server.Workspace_scope_epoch.equal scope.Mcp_server.epoch
      (Mcp_server.workspace_scope state).epoch in
  let await_next scope next =
    Eio.Fiber.first
      (fun () -> Eio.Promise.await (Mcp_server.workspace_scope_replaced scope); `Replaced)
      (fun () ->
        match next with
        | None -> Eio.Stream.take wake; `Changed
        | Some at ->
            Eio.Fiber.first
              (fun () -> Eio.Time.sleep_until clock at; `Deadline)
              (fun () -> Eio.Stream.take wake; `Changed)) in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec scan scope notified source_failed =
      let result = Eio.Fiber.first
        (fun () -> `Read (read scope.Mcp_server.config))
        (fun () ->
          Eio.Promise.await (Mcp_server.workspace_scope_replaced scope);
          `Replaced) in
      match result with
      | `Replaced -> follow_current ()
      | `Read _ when not (is_current scope) -> follow_current ()
      | `Read reading ->
        let notified, next, source_failed = match reading with
          | Error _ ->
              (* Store decoder errors may contain confirmation tokens. *)
              Log.Server.warn "pending-confirm deadline observation failed";
              if not source_failed then invalidate ~base_path:scope.config.base_path;
              notified, None, true
          | Ok entries ->
              let plan = expiry_plan ~now:(Eio.Time.now clock) entries in
              let newly_expired =
                not (Expiry_set.is_empty (Expiry_set.diff plan.expired notified)) in
              (* A confirmation past its deadline leaves the store unwritten:
                 readers stop listing it at read time. A deadline that passed
                 while the store could not be read may since have been removed
                 by a reader's cleanup, so a read that recovers is announced
                 too. *)
              if source_failed || newly_expired then begin
                invalidate ~base_path:scope.config.base_path;
                Operator_pending_confirm_broadcast.changed ~base_path:scope.config.base_path
              end;
              plan.expired, plan.next, false in
        match await_next scope next with
        | `Replaced -> follow_current ()
        | `Changed | `Deadline -> scan scope notified source_failed
    and follow_current () =
      scan (Mcp_server.workspace_scope state) Expiry_set.empty false in
    follow_current ())
;;

let read_storage config =
  try
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Ok (Operator_pending_confirm.raw_pending_confirms config))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Operator_pending_confirm.Store_error detail -> Error detail
  | exn -> Error (Printexc.to_string exn)
;;

let start ~sw ~clock ~state =
  start_with ~sw ~clock ~state ~read:read_storage
    ~invalidate:Server_routes_http_runtime.invalidate_full_health_snapshot_for_workspace
;;

module For_testing = struct
  let start = start_with
end
