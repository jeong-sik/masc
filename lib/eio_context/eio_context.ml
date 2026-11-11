
(** Global Eio context for shared network/clock access.
    Set once during server startup (main_eio.ml), read from any context.

    Uses Atomic.t (lock-free WORM pattern): each field is written once at
    init and read many times from Eio fibers, CI tests, and AGENT_CORE callbacks.
    No mutex needed — Atomic.get/set are single-instruction operations. *)

type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

type root_switch_binding =
  { switch : Eio.Switch.t
  ; owner_domain : Domain.id
  ; dispatch_stream : (unit -> unit) Eio.Stream.t
  }

type state_snapshot = {
  net : eio_net option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t option;
  root_switch : root_switch_binding option;
  net_initialized : bool;
  (* The environment is restored with the rest. A fixture that binds it inside
     [with_test_env] used to leave it behind, so once that fixture's
     [Eio_main.run] returned, later tests in the same executable read a closed
     environment back out of [get_env_opt]. *)
  env : Eio_unix.Stdenv.base option;
}

let current_net : eio_net option Atomic.t = Atomic.make None
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option Atomic.t = Atomic.make None
let current_mono_clock : Eio.Time.Mono.ty Eio.Resource.t option Atomic.t = Atomic.make None
(* The root switch and its owning domain form one immutable atomic value. This
   prevents the switch and owner identity from drifting across concurrent reads
   or temporary test snapshots. *)
let current_sw : root_switch_binding option Atomic.t = Atomic.make None
(* RFC-0107 Phase D.2c — full Eio standard environment, required by
   piaf [Client.create] (and any other API needing more than just
   [net]/[clock]).  Set once at server bootstrap; read by long-lived
   consumers like [Masc_http_client] that initialize their per-process
   [Pool.t] lazily.  Same WORM atomic pattern as the other fields. *)
let current_env : Eio_unix.Stdenv.base option Atomic.t = Atomic.make None
let net_initialized : bool Atomic.t = Atomic.make false
let with_test_env_lock = Eio.Mutex.create ()

(* RFC-0107 §3.3 / audit §10.5 — fiber-local turn switch.
   Phase C.1 wiring: [keeper_agent_run.run_turn] wraps its body with
   [with_turn_switch turn_sw]; reads of [get_switch_opt] from within
   that scope (and forked children) return turn_sw, while reads from
   outside (server/dashboard fibers — see audit §2.1, §10.2) fall
   through to the global atomic [current_sw] = server root_sw.

   Created once at module init via [Eio.Fiber.create_key]; the key
   identity is what [with_binding] / [get] use to look up the value. *)
let sw_key : Eio.Switch.t Eio.Fiber.key = Eio.Fiber.create_key ()

(* [snapshot] is the opaque .mli face of [state_snapshot]: the fields are
   written by [snapshot_state] and read by [restore_state] only. *)
type snapshot = state_snapshot

let snapshot_state () =
  {
    net = Atomic.get current_net;
    clock = Atomic.get current_clock;
    mono_clock = Atomic.get current_mono_clock;
    root_switch = Atomic.get current_sw;
    net_initialized = Atomic.get net_initialized;
    env = Atomic.get current_env;
  }

let restore_state snapshot =
  Atomic.set current_net snapshot.net;
  Atomic.set current_clock snapshot.clock;
  Atomic.set current_mono_clock snapshot.mono_clock;
  Atomic.set current_sw snapshot.root_switch;
  Atomic.set net_initialized snapshot.net_initialized;
  Atomic.set current_env snapshot.env

let set_net net =
  Atomic.set current_net (Some (net :> eio_net));
  Atomic.set net_initialized true

let set_clock clock =
  Atomic.set current_clock (Some clock)

let set_mono_clock mc =
  Atomic.set current_mono_clock (Some mc)

let get_mono_clock_opt () =
  Atomic.get current_mono_clock

let set_switch sw =
  let owner_domain = Domain.self () in
  (* No bound: a post never waits. A request's connection posts from inside
     its cleanup, shielded from cancellation, and a wait there would hold the
     serving domain open once this domain no longer takes tasks. *)
  let dispatch_stream = Eio.Stream.create max_int in
  let binding = { switch = sw; owner_domain; dispatch_stream } in
  let some_binding = Some binding in
  Atomic.set current_sw some_binding;
  Eio.Switch.on_release sw (fun () ->
    let _ = Atomic.compare_and_set current_sw some_binding None in
    let rec drain () =
      match Eio.Stream.take_nonblocking dispatch_stream with
      | Some task ->
        (try task () with _ -> ());  (* cancel-guard-ok: release-time drain; Cancelled is the expected teardown signal here and must not abort the drain. @observe-allowed: the switch is already releasing, so no caller is left to hand a task's failure to *)
        drain ()
      | None -> ()
    in
    drain ());
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      let task = Eio.Stream.take dispatch_stream in
      Eio.Fiber.fork ~sw (fun () ->
        try task () with _ -> ());  (* cancel-guard-ok: daemon safety net; a task's own catch resolves its promise first, so this arm only sees fork-teardown noise the daemon must survive. @observe-allowed: same reason -- what reaches here was already reported by the task, or is teardown *)
      (* One task starts per pass of this domain's run queue. Without the
         yield every queued task starts in this one run, and with the HTTP
         serving domain on that is every request in flight: 32 keep-alive
         connections held this domain's timers back 86 ms at the median
         against 7 ms with the connections on this domain (2026-11-10, GET
         /health, 15,000 requests). A queue that is otherwise empty passes
         at once, so nothing waits while this domain is idle. *)
      Eio.Fiber.yield ()
    done;
    `Stop_daemon)

module For_testing = struct
  let clear_root_switch () =
    Atomic.set current_sw None
end

(* A finished switch is not a root switch.

   Nothing clears this slot when its switch finishes except the switch's own
   release hook, and a scope that installs a switch can end before a reader
   asks. A finished switch left in the slot cannot be forked into: the caller
   would learn about it at [Fiber.fork], as [Invalid_argument "Switch
   finished!"], far from the write that left it. Measured 2026-09-06 in
   test_heartbeat_integration, where six cases failed this way (#33200).
   Answering [None] instead lets [Keeper_lane.fork_server_owned] refuse the
   lane as having no owner.

   Asking the switch is the only way to know: a finished switch is not a
   failed one, so [get_error] answers [None] for it. *)
let get_root_switch_opt () =
  match Atomic.get current_sw with
  | None -> None
  | Some binding ->
    (match Eio.Switch.check binding.switch with
     | () -> Some binding.switch
     | exception _ -> None)  (* cancel-guard-ok: reports on another switch, not on the caller's fiber; every reason check raises means the same thing to someone asking for a switch to fork into *)

let root_switch_on_current_domain () =
  match Atomic.get current_sw with
  | Some binding -> binding.owner_domain = Domain.self ()
  | None -> false

let owner_post () =
  match Atomic.get current_sw with
  | None -> None
  | Some binding when binding.owner_domain = Domain.self () -> None
  | Some binding -> Some (fun task -> Eio.Stream.add binding.dispatch_stream task)

let run_on_owner_domain (type a) (f : unit -> a) : a =
  match Atomic.get current_sw with
  | None -> f ()
  | Some binding when binding.owner_domain = Domain.self () -> f ()
  | Some binding ->
    let p, r = Eio.Promise.create () in
    let task () =
      try
        let res = f () in
        Eio.Promise.resolve_ok r res
      with exn ->  (* not a swallow: the exception, Cancelled included, is re-delivered to the awaiting domain via the promise below *)
        let bt = Printexc.get_raw_backtrace () in
        Eio.Promise.resolve_error r (exn, bt)
    in
    Eio.Stream.add binding.dispatch_stream task;
    match Eio.Promise.await p with
    | Ok res -> res
    | Error (exn, bt) -> Printexc.raise_with_backtrace exn bt

let set_env env =
  Atomic.set current_env (Some env)

let get_env_opt () : Eio_unix.Stdenv.base option =
  Atomic.get current_env

(* RFC-0107 §3.3 wiring — bind a turn-scoped switch on the *current fiber*
   (and all children forked inside [f]). On exit the binding is removed,
   so subsequent fibers in the parent see the previous binding (or [None]).

   Distinct from [set_switch] which writes the global atomic: this one is
   fiber-local and *propagates with fork* (Eio.Fiber.with_binding contract),
   so runtime attempts forked from inside [f] inherit [sw] automatically.

   Caller contract: invoke from *inside* the body of an outer
   [Eio.Switch.run] whose switch is [sw], so resources opened during [f]
   that read [get_switch_opt ()] attach to [sw] and are released when the
   outer switch closes. *)
let with_turn_switch sw f = Eio.Fiber.with_binding sw_key sw f

let with_test_env ~net ~clock ~mono_clock ~sw f =
  (* Test bodies may deliberately raise [Alcotest.Skip] or fail assertions.
     The state is restored in [finally], so use the non-poisoning lock helper:
     one skipped test must not poison later Eio-context tests in the same
     executable. *)
  Eio.Mutex.use_ro with_test_env_lock (fun () ->
    let snapshot = snapshot_state () in
    set_net net;
    set_clock clock;
    set_mono_clock mono_clock;
    set_switch sw;
    Fun.protect
      ~finally:(fun () -> restore_state snapshot)
      f)

let get_net_opt () : eio_net option =
  Atomic.get current_net

let get_clock_opt () =
  Atomic.get current_clock

let get_switch_opt () =
  (* RFC-0107 §3.3 / audit §10.5 — fiber-local first, then atomic fallback.

     - Inside [with_turn_switch] (keeper_agent_run.run_turn body): returns
       the turn_sw → resources opened during the turn attach to turn_sw
       and are released when the turn ends.
     - Outside any binding (server/dashboard fibers, bootstrap path —
       audit §10.2, §10.6): returns the global atomic = server root_sw
       → long-lived resources (gRPC heartbeat, dashboard fibers) survive
       turn boundaries as intended.

     [Eio.Fiber.get] raises if called outside any Eio fiber context
     (e.g. test setup before [Eio_main.run]). In that case there is no
     fiber-local state to consult, so we fall through to the atomic. *)
  let from_fiber =
    try Eio.Fiber.get sw_key
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> None
  in
  match from_fiber with
  | Some _ as some_sw -> some_sw
  | None -> get_root_switch_opt ()

let get_clock () : (float Eio.Time.clock_ty Eio.Resource.t, string) result =
  match Atomic.get current_clock with
  | Some clock -> Ok clock
  | None ->
      Error "Eio clock not initialized - ensure set_clock is called during server startup"
