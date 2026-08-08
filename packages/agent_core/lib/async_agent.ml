(** Async Agent — Eio fiber-based background agent execution.

    @since 0.55.0 *)

let log = Log.create ~module_name:"async_agent" ()

let internal_agent_exception exn =
  Log.debug
    log
    "agent execution raised"
    [ Log.S ("exception", Stdlib.Printexc.to_string exn) ];
  Error.Internal "agent execution failed"
;;

(* ── Internal cancellation exception ──────────────────────────── *)

exception Cancelled

(* ── Future type ──────────────────────────────────────────────── *)

type 'a future =
  { promise : ('a, Error.sdk_error) Result.t Eio.Promise.t
  ; resolver : ('a, Error.sdk_error) Result.t Eio.Promise.u
  ; cancelled_u : unit Eio.Promise.u
  ; resolved : bool Atomic.t
  ; cancel_sent : bool Atomic.t
  ; cancel_fn : (unit -> unit) option Atomic.t
  ; cancel_mu : Eio.Mutex.t
  }

(** Resolve the future exactly once. Subsequent calls are no-ops. *)
let resolve_once future result =
  if not (Atomic.exchange future.resolved true)
  then Eio.Promise.resolve future.resolver result
;;

let with_cancel_fn_lock future f = Eio.Mutex.use_rw ~protect:true future.cancel_mu f

let clear_cancel_fn future =
  with_cancel_fn_lock future (fun () -> Atomic.set future.cancel_fn None)
;;

let take_cancel_fn future =
  with_cancel_fn_lock future (fun () -> Atomic.exchange future.cancel_fn None)
;;

let invoke_cancel_fn future =
  match take_cancel_fn future with
  | Some f -> f ()
  | None -> ()
;;

(* ── Agent name extraction ────────────────────────────────────── *)

let agent_name agent = (Agent.state agent).config.name

let run_agent_result ~sw ?clock agent prompt =
  try Agent.run ~sw ?clock agent prompt with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Raw_trace.Trace_error e -> Error e
  | Out_of_memory -> raise Out_of_memory
  | Stack_overflow -> raise Stack_overflow
  | Stdlib.Sys.Break -> raise Stdlib.Sys.Break
  | exn -> Error (internal_agent_exception exn)
;;

(* ── Spawning ─────────────────────────────────────────────────── *)

let spawn ~sw ?clock agent prompt =
  let promise, resolver = Eio.Promise.create () in
  let cancelled_p, cancelled_u = Eio.Promise.create () in
  let resolved = Atomic.make false in
  let cancel_sent = Atomic.make false in
  let future =
    { promise
    ; resolver
    ; cancelled_u
    ; resolved
    ; cancel_sent
    ; cancel_fn = Atomic.make None
    ; cancel_mu = Eio.Mutex.create ()
    }
  in
  Eio.Fiber.fork ~sw (fun () ->
    try
      (* Race the agent execution against an explicit cancellation signal.
         If [cancel] is called before Agent.run starts, the cancellation
         branch wins and Agent.run never starts, avoiding orphan fibers.
         If Agent.run is already running, cancel_fn fails the sub-switch
         and the cancellation branch wins once it exits. *)
      let result =
        Eio.Fiber.first
          (fun () ->
             try
               Eio.Switch.run (fun sub_sw ->
                 Atomic.set
                   future.cancel_fn
                   (Some (fun () -> Eio.Switch.fail sub_sw Cancelled));
                 Fun.protect
                   ~finally:(fun () -> clear_cancel_fn future)
                   (fun () -> run_agent_result ~sw:sub_sw ?clock agent prompt))
             with
             | Cancelled -> Error (Error.Internal "cancelled")
             | Eio.Cancel.Cancelled _ -> Error (Error.Internal "cancelled"))
          (fun () ->
             Eio.Promise.await cancelled_p;
             Error (Error.Internal "cancelled"))
      in
      resolve_once future result
    with
    | Eio.Cancel.Cancelled _ as e ->
      let bt = Stdlib.Printexc.get_raw_backtrace () in
      resolve_once future (Error (Error.Internal "cancelled"));
      Stdlib.Printexc.raise_with_backtrace e bt);
  future
;;

(* ── Awaiting ─────────────────────────────────────────────────── *)

let await future = Eio.Promise.await future.promise
let is_ready future = Option.is_some (Eio.Promise.peek future.promise)

(* ── Cancellation ─────────────────────────────────────────────── *)

let cancel future =
  (* Resolve the cancellation promise so the agent fiber exits. If the agent
     fiber has not started Agent.run yet, Eio.Fiber.first will prefer the
     cancellation branch. If it has started, cancel_fn fails the sub-switch.
     We also resolve the future immediately to preserve the established
     contract that [cancel] returns a ready future; resolve_once makes the
     final result idempotent.

     Guard: if the future is already resolved, the agent fiber has finished
     and its sub-switch has been released. Do not invoke a stale cancel_fn
     closure that would fail a dead switch. *)
  if is_ready future
  then ()
  else if Atomic.compare_and_set future.cancel_sent false true
  then (
    Eio.Promise.resolve future.cancelled_u ();
    (* Invoke the sub-switch failure hook before resolving the future, so a
       running agent sees cancellation even though [resolve_once] will make
       the final result idempotent.  [invoke_cancel_fn] shares a lock with the
       agent fiber finalizer: either the hook is invoked while the sub-switch
       is still alive, or the finalizer clears it before release. *)
    (try invoke_cancel_fn future with
     | Eio.Cancel.Cancelled _ -> ()
     | Eio.Io _ | Unix.Unix_error _ | Failure _ | Invalid_argument _ -> ());
    resolve_once future (Error (Error.Internal "cancelled")))
;;

(* ── Combinators ──────────────────────────────────────────────── *)

let race ~sw ?clock agents =
  match agents with
  | [] -> Error (Error.Internal "race: no agents provided")
  | [ (agent, prompt) ] ->
    let name = agent_name agent in
    (match run_agent_result ~sw ?clock agent prompt with
     | Ok resp -> Ok (name, resp)
     | Error e -> Error e)
  | _ ->
    (* Each closure returns (name, result) — both Ok and Error are
       normal completions. Eio.Fiber.first returns the first fiber to
       finish and cancels the rest via structured concurrency. *)
    let fns =
      List.map
        (fun (agent, prompt) ->
           fun () ->
           let name = agent_name agent in
           let result = run_agent_result ~sw ?clock agent prompt in
           name, result)
        agents
    in
    let rec any_of = function
      | [] -> invalid_arg "any_of: empty list"
      | [ f ] -> f ()
      | f :: rest -> Eio.Fiber.first f (fun () -> any_of rest)
    in
    let name, result = any_of fns in
    Result.map (fun resp -> name, resp) result
;;

let all ~sw ?clock ?max_fibers agents =
  let run_one (agent, prompt) =
    let name = agent_name agent in
    let result = run_agent_result ~sw ?clock agent prompt in
    name, result
  in
  match max_fibers with
  | Some n -> Eio.Fiber.List.map ~max_fibers:n run_one agents
  | None -> Eio.Fiber.List.map run_one agents
;;
