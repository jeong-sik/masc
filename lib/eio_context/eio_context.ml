
(** Global Eio context for shared network/clock access.
    Set once during server startup (main_eio.ml), read from any context.

    Uses Atomic.t (lock-free WORM pattern): each field is written once at
    init and read many times from Eio fibers, CI tests, and OAS callbacks.
    No mutex needed — Atomic.get/set are single-instruction operations. *)

type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

type state_snapshot = {
  net : eio_net option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t option;
  sw : Eio.Switch.t option;
  net_initialized : bool;
}

let current_net : eio_net option Atomic.t = Atomic.make None
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option Atomic.t = Atomic.make None
let current_mono_clock : Eio.Time.Mono.ty Eio.Resource.t option Atomic.t = Atomic.make None
let current_sw : Eio.Switch.t option Atomic.t = Atomic.make None
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

let snapshot_state () =
  {
    net = Atomic.get current_net;
    clock = Atomic.get current_clock;
    mono_clock = Atomic.get current_mono_clock;
    sw = Atomic.get current_sw;
    net_initialized = Atomic.get net_initialized;
  }

let restore_state snapshot =
  Atomic.set current_net snapshot.net;
  Atomic.set current_clock snapshot.clock;
  Atomic.set current_mono_clock snapshot.mono_clock;
  Atomic.set current_sw snapshot.sw;
  Atomic.set net_initialized snapshot.net_initialized

let set_net net =
  Atomic.set current_net (Some (net :> eio_net));
  Atomic.set net_initialized true

let set_clock clock =
  Atomic.set current_clock (Some clock)

let set_mono_clock mc =
  Atomic.set current_mono_clock (Some mc)

let get_mono_clock () : (Eio.Time.Mono.ty Eio.Resource.t, string) result =
  match Atomic.get current_mono_clock with
  | Some mc -> Ok mc
  | None -> Error "Eio mono_clock not initialized"

let get_mono_clock_opt () =
  Atomic.get current_mono_clock

let set_switch sw =
  Atomic.set current_sw (Some sw)

let get_root_switch_opt () =
  Atomic.get current_sw

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

let get_bound_turn_switch_opt () =
  try Eio.Fiber.get sw_key with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Stdlib.Effect.Unhandled _ -> None
;;

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
  let from_fiber = get_bound_turn_switch_opt () in
  match from_fiber with
  | Some _ as some_sw -> some_sw
  | None -> Atomic.get current_sw

let get_net () : (eio_net, string) result =
  match Atomic.get current_net with
  | Some net -> Ok net
  | None ->
      if Atomic.get net_initialized then
        Error "Eio net was set but is now None (unexpected state)"
      else
        Error "Eio net not initialized - ensure set_net is called during server startup"

let get_clock () : (float Eio.Time.clock_ty Eio.Resource.t, string) result =
  match Atomic.get current_clock with
  | Some clock -> Ok clock
  | None ->
      Error "Eio clock not initialized - ensure set_clock is called during server startup"

let get_switch () : (Eio.Switch.t, string) result =
  match get_switch_opt () with
  | Some sw -> Ok sw
  | None ->
      Error "Eio switch not initialized - ensure set_switch is called during server startup"

(** TLS connector for Cohttp_eio HTTPS support.

    Stored as an [Atomic.t] cell so concurrent reads from multiple OCaml 5
    domains are safe.  Initialization uses [Atomic.compare_and_set] for a
    lock-free once pattern: the first domain that observes [None] builds the
    connector and publishes it; any racing builder discards its own result and
    returns the published one. *)
let _https_connector_cache :
  ((Uri.t ->
     [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
     [> Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t),
   string)
  result
  option
  Atomic.t =
  Atomic.make None

let https_error message = Error message

let build_https_connector_result () =
  try
    match Ca_certs.authenticator () with
    | Error (`Msg msg) -> https_error ("CA certs unavailable: " ^ msg)
    | Error _ -> https_error "CA certs unavailable: unknown error"
    | Ok authenticator -> (
        match Tls.Config.client ~authenticator () with
        | Error (`Msg msg) -> https_error ("TLS config error: " ^ msg)
        | Ok tls_config ->
            Ok
              (fun uri
                    (raw : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t)
                  ->
                let flow =
                  (raw :>
                    [> Eio.Flow.two_way_ty | Eio.Resource.close_ty ]
                    Eio.Resource.t)
                in
                let host =
                  match Uri.host uri with
                  | None -> None
                  | Some h -> (
                      match Domain_name.of_string h with
                      | Ok d -> Some (Domain_name.host_exn d)
                      | Error _ -> None)
                in
                match host with
                | None -> raise (Invalid_argument "TLS host missing/invalid")
                | Some host -> Tls_eio.client_of_flow tls_config ~host flow))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> https_error ("HTTPS connector build failed: " ^ Printexc.to_string exn)

let get_https_connector_result () =
  match Atomic.get _https_connector_cache with
  | Some result -> result
  | None -> (
      let result = build_https_connector_result () in
      match Atomic.compare_and_set _https_connector_cache None (Some result) with
      | true -> result
      | false -> (
          (* Another domain published while we were building; return the
             winner to keep the process-global connector deterministic. *)
          match Atomic.get _https_connector_cache with
          | Some other -> other
          | None -> result))

(* get_https_connector (crash variant) removed — all callers use
   get_https_connector_result which returns (connector, string) result. *)
