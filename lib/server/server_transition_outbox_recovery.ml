module Recovery = Masc.Keeper_event_queue_recovery

type source = Startup | Maintenance
let source_label = function Startup -> "startup" | Maintenance -> "maintenance"

let log_page ~source ~base_path:_ (page : Recovery.sweep_page) =
  let report = page.report in
  let source_label = source_label source in
  Option.iter (fun error ->
    Log.Server.error "keeper transition outbox %s discovery retained error=%s"
      source_label (Recovery.discovery_error_to_string error)) report.discovery_error;
  List.iter (fun (failure : Recovery.owner_failure) ->
    Log.Server.error "keeper transition outbox %s retained keeper=%s error=%s"
      source_label failure.keeper_name (Recovery.projection_error_to_string failure.error))
    report.failures;
  let should_log = match source with
    | Startup -> true
    | Maintenance -> report.converged > 0 || report.claim_busy > 0
        || report.shutdown_reserved > 0 || report.failures <> []
        || Option.is_some report.discovery_error in
  if should_log then Log.Server.info
    "keeper transition outbox %s discovered=%d processed=%d deferred=%d converged=%d no_pending=%d claim_busy=%d shutdown_reserved=%d failures=%d"
    source_label report.discovered report.processed report.deferred report.converged
    report.no_pending report.claim_busy report.shutdown_reserved (List.length report.failures)

type t =
  { base_path : string
  ; budget : Recovery.owner_budget
  ; on_page : source:source -> base_path:string -> Recovery.sweep_page -> unit
  ; mutable cursor : Recovery.sweep_cursor
  ; mutable active : bool
  }

let create ~base_path ~budget ?(on_page=log_page) () =
  {base_path;budget;on_page;cursor=Recovery.initial_sweep_cursor;active=false}

type phase = Reserved | Started | Settled | Interrupted | Raised

let observe ~base_path ~source ~reserved_ns phase =
  let emit () =
    try Log.Server.routine_lazy (fun () ->
      let phase, identity = match phase with
        | Reserved -> "reserved", Printf.sprintf " base_path=%S" base_path
        | Started -> "started", "" | Settled -> "settled", ""
        | Interrupted -> "interrupted", "" | Raised -> "raised", "" in
      Printf.sprintf "transition_outbox_recovery source=%s reserved_ns=%Ld phase=%s at_ns=%Ld%s"
        (source_label source) reserved_ns phase (Mtime_clock.elapsed_ns ()) identity)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let pulse ~sw supervisor source =
  Eio.Switch.check sw;
  if not supervisor.active then (
    let cursor = supervisor.cursor in
    let reserved_ns = Mtime_clock.elapsed_ns () in
    let observe = observe ~base_path:supervisor.base_path ~source ~reserved_ns in
    supervisor.active <- true;
    let release () = supervisor.active <- false in
    try
      observe Reserved;
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:release (fun () ->
          try
            Eio.Fiber.yield ();
            observe Started;
            let page = Recovery.project_discovered_bounded
                ~base_path:supervisor.base_path ~budget:supervisor.budget ~cursor in
            (* The actual returned page owns cursor progress. A slow or failed
               observer cannot replace it with the previous page's position. *)
            supervisor.cursor <- page.next_cursor;
            observe Settled;
            (try supervisor.on_page ~source ~base_path:supervisor.base_path page with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Log.Server.warn "transition outbox observer failed source=%s: %s"
                 (source_label source) (Printexc.to_string exn))
          with
          | Eio.Cancel.Cancelled _ as exn -> observe Interrupted; raise exn
          | exn ->
              observe Raised;
              Log.Server.warn "transition outbox recovery retained source=%s: %s"
                (source_label source) (Printexc.to_string exn)))
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      release ();
      Printexc.raise_with_backtrace exn bt)
