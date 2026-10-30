type purpose = Initial | Workspace_retry
type request = {
  purpose : purpose;
  base_path : string;
  host : string;
  port : int;
  started_ns : int64;
}
type outcome =
  | Observed of Masc_tui_credential.outcome
  | Not_started of string
  | Unobserved of string
type completion = {
  request : request;
  worker_started_ns : int64 option;
  observed_ns : int64;
  outcome : outcome;
}
type status =
  | Not_requested
  | Preparing of request
  | Awaiting_ui of completion
  | Settled
type t = {
  mutable status : status;
  mutable initial_settled : bool;
  initial_observed : unit Eio.Promise.t;
  initial_observe : unit Eio.Promise.u;
  current_observed : unit Eio.Promise.t option Atomic.t;
}

let create () =
  let initial_observed, initial_observe = Eio.Promise.create () in
  { status = Not_requested; initial_settled = false; initial_observed; initial_observe;
    current_observed = Atomic.make None }
let status t = t.status
let initial_settled t = t.initial_settled
let await_initial t = Eio.Promise.await t.initial_observed
let await_current t = Option.iter Eio.Promise.await (Atomic.get t.current_observed)

let emit message =
  let emit () = try Log.Transport.routine_lazy message with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  match Eio_guard.execution_context () with
  | Eio_fiber -> Eio.Cancel.protect emit
  | Non_eio -> emit ()

let start t ~sw ~purpose ~base_path ~host ~port ~install =
  let admitted = match t.status, purpose, t.initial_settled with
    | (Preparing _ | Awaiting_ui _), _, _ -> false
    | (Not_requested | Settled), Initial, false -> true
    | (Not_requested | Settled), Workspace_retry, true -> true
    | (Not_requested | Settled), Initial, true
    | (Not_requested | Settled), Workspace_retry, false -> false in
  if not admitted then None else begin
    let request = { purpose; base_path; host; port; started_ns = Mtime_clock.elapsed_ns () } in
    let current_observed, observe_current = Eio.Promise.create () in
    Atomic.set t.current_observed (Some current_observed);
    let worker_started_ns = ref None in
    let publish outcome =
      let completion = {
        request; worker_started_ns = !worker_started_ns;
        observed_ns = Mtime_clock.elapsed_ns (); outcome } in
      t.status <- Awaiting_ui completion;
      ignore (Eio.Promise.try_resolve observe_current ());
      (match purpose with
       | Initial -> ignore (Eio.Promise.try_resolve t.initial_observe ())
       | Workspace_retry -> ());
      emit (fun () -> Printf.sprintf
        "tui_credential_preparation_observed started_ns=%Ld worker_started_ns=%s observed_ns=%Ld outcome=%s"
        request.started_ns
        (match completion.worker_started_ns with None -> "unavailable" | Some ns -> Int64.to_string ns)
        completion.observed_ns
        (match outcome with Observed _ -> "observed" | Not_started _ -> "not_started" | Unobserved _ -> "unobserved")) in
    t.status <- Preparing request;
    emit (fun () -> Printf.sprintf
      "tui_credential_preparation_requested purpose=%s started_ns=%Ld base_path=%S host=%S port=%d"
      (match purpose with Initial -> "initial" | Workspace_retry -> "workspace_retry")
      request.started_ns request.base_path request.host request.port);
    (match sw with
     | None -> publish (Not_started "Asynchronous workspace access preparation unavailable")
     | Some sw ->
       (try
          Eio.Switch.check sw;
          Eio.Fiber.fork ~sw (fun () ->
            worker_started_ns := Some (Mtime_clock.elapsed_ns ());
            let outcome =
              try Observed (install ()) with
              | Eio.Cancel.Cancelled _ as exn ->
                  let bt = Printexc.get_raw_backtrace () in
                  publish (Unobserved "Workspace access preparation interrupted; credential outcome not observed");
                  Printexc.raise_with_backtrace exn bt
              | exn -> Unobserved (Printexc.to_string exn) in
            publish outcome)
        with
        | Eio.Cancel.Cancelled _ as exn ->
            let bt = Printexc.get_raw_backtrace () in
            if Option.is_none !worker_started_ns then
              publish (Not_started "Workspace access preparation cancelled before launch");
            Printexc.raise_with_backtrace exn bt
        | exn ->
            if Option.is_none !worker_started_ns then
              publish (Not_started (Printexc.to_string exn))));
    Some request
  end

let take_completed t =
  match t.status with
  | Not_requested | Preparing _ | Settled -> None
  | Awaiting_ui completion ->
      (match completion.request.purpose with
       | Initial -> t.initial_settled <- true
       | Workspace_retry -> ());
      t.status <- Settled;
      Some completion
