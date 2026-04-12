(** Supervisor — One-for-one Eio fiber supervisor

    Manages a set of named child fibers with restart policies.
    When a child crashes, the supervisor decides whether to restart,
    back off and retry, or escalate.

    Erlang/OTP-inspired but adapted to Eio's cooperative model:
    - Children are (unit -> unit) functions, not processes
    - Restart uses Eio.Fiber.fork, not process spawn
    - Backoff uses Eio.Time.sleep, not erlang timers

    @since 2.102.0 *)

(** {1 Types} *)

type restart_strategy =
  | Permanent    (** Always restart on failure *)
  | Temporary    (** Never restart — failure is expected *)
  | Transient    (** Restart only on abnormal exit (exception) *)

type child_spec = {
  name : string;
  start : unit -> unit;
  strategy : restart_strategy;
  max_restarts : int;       (** Max restarts within restart_window *)
  restart_window_s : float; (** Time window for counting restarts *)
}

type child_state = {
  spec : child_spec;
  mutable restart_count : int;
  mutable restart_times : float list;  (** Timestamps of recent restarts *)
  mutable running : bool;
  mutable disabled : bool;
}

type t = {
  children : child_state list;
  mutable started : bool;
}

(** {1 Construction} *)

let child ~name ~start ?(strategy = Permanent) ?(max_restarts = 5)
    ?(restart_window_s = 60.0) () : child_spec =
  { name; start; strategy; max_restarts; restart_window_s }

let create (specs : child_spec list) : t =
  let children = List.map (fun spec ->
    { spec; restart_count = 0; restart_times = []; running = false; disabled = false }
  ) specs in
  { children; started = false }

(** {1 Internal Helpers} *)

(** Prune restart timestamps outside the window. *)
let prune_restarts cs =
  let now = Unix.gettimeofday () in
  let cutoff = now -. cs.spec.restart_window_s in
  cs.restart_times <- List.filter (fun t -> t > cutoff) cs.restart_times

(** Check if child has exceeded restart limit. *)
let restart_limit_exceeded cs =
  prune_restarts cs;
  List.length cs.restart_times >= cs.spec.max_restarts

(** {1 Child Management} *)

(** Start a single child fiber within the given switch.
    On failure, logs and applies restart policy. *)
let rec start_child ~sw ~clock cs =
  if cs.disabled then begin
    Log.Server.info "[Supervisor] skipping disabled child: %s" cs.spec.name
  end else begin
    cs.running <- true;
    Eio.Fiber.fork ~sw (fun () ->
      let name = cs.spec.name in
      try
        cs.spec.start ();
        cs.running <- false;
        Log.Server.info "[Supervisor] child %s exited normally" name
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        cs.running <- false;
        let msg = Printexc.to_string exn in
        Log.Server.warn "[Supervisor] child %s crashed: %s" name msg;

        match cs.spec.strategy with
        | Temporary ->
            Log.Server.info "[Supervisor] child %s is temporary, not restarting" name
        | Transient when exn = Exit ->
            Log.Server.info "[Supervisor] child %s transient normal exit" name
        | Permanent | Transient ->
            if restart_limit_exceeded cs then begin
              cs.disabled <- true;
              Log.Server.error "[Supervisor] child %s DISABLED: %d restarts in %.0fs"
                name cs.spec.max_restarts cs.spec.restart_window_s
            end else begin
              cs.restart_count <- cs.restart_count + 1;
              cs.restart_times <- Unix.gettimeofday () :: cs.restart_times;
              (* Backoff delay based on *recent* restarts within the window
                 (pruned by [restart_limit_exceeded] above), not the
                 lifetime [restart_count]. A child that crashed heavily
                 once and has been stable for a long time deserves a
                 short delay on a new crash — using the lifetime counter
                 would pin it at the 30s cap forever. *)
              let recent = List.length cs.restart_times in
              let delay = Float.min 30.0 (Float.of_int recent) in
              Log.Server.info
                "[Supervisor] restarting %s in %.0fs (recent %d in %.0fs, lifetime %d)"
                name delay recent cs.spec.restart_window_s cs.restart_count;
              Eio.Time.sleep clock delay;
              start_child ~sw ~clock cs
            end)
  end

(** {1 Public API} *)

(** Start all children. Call within an Eio.Switch context. *)
let start ~sw ~clock t =
  if t.started then
    Log.Server.warn "[Supervisor] already started"
  else begin
    t.started <- true;
    Log.Server.info "[Supervisor] starting %d children" (List.length t.children);
    List.iter (fun cs -> start_child ~sw ~clock cs) t.children
  end

(** Get status of all children. *)
type child_status = {
  name : string;
  running : bool;
  disabled : bool;
  restart_count : int;
  strategy : string;
}

let status t : child_status list =
  List.map (fun cs ->
    let strategy_str = match cs.spec.strategy with
      | Permanent -> "permanent"
      | Temporary -> "temporary"
      | Transient -> "transient"
    in
    { name = cs.spec.name;
      running = cs.running;
      disabled = cs.disabled;
      restart_count = cs.restart_count;
      strategy = strategy_str }
  ) t.children

let status_to_json (s : child_status) : Yojson.Safe.t =
  `Assoc [
    ("name", `String s.name);
    ("running", `Bool s.running);
    ("disabled", `Bool s.disabled);
    ("restart_count", `Int s.restart_count);
    ("strategy", `String s.strategy);
  ]

(** Find a child by name. *)
let find_child t name =
  List.find_opt (fun cs -> cs.spec.name = name) t.children

(** Re-enable a disabled child and restart it. *)
let reenable ~sw ~clock t name =
  match find_child t name with
  | Some cs when cs.disabled ->
      cs.disabled <- false;
      cs.restart_count <- 0;
      cs.restart_times <- [];
      Log.Server.info "[Supervisor] re-enabling child %s" name;
      start_child ~sw ~clock cs;
      true
  | _ -> false
