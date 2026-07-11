(** Global Eio context for shared network/clock access.
    Set during server startup (main_eio.ml). *)

type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

val set_net :
  [> `Network | `Platform of [> `Generic | `Unix ]] Eio.Resource.t -> unit
(** Set the global Eio network handle. *)

val set_clock : float Eio.Time.clock_ty Eio.Resource.t -> unit
(** Set the global Eio clock. *)

val set_mono_clock : Eio.Time.Mono.ty Eio.Resource.t -> unit
(** Set the global Eio monotonic clock. *)

val get_mono_clock : unit -> (Eio.Time.Mono.ty Eio.Resource.t, string) result
(** Get the global Eio monotonic clock.
    Returns Error if not initialized. *)

val get_mono_clock_opt : unit -> Eio.Time.Mono.ty Eio.Resource.t option
(** Get the global Eio monotonic clock if available. *)

val set_switch : Eio.Switch.t -> unit
(** Set the global Eio switch (server root_sw). Written once at server
    bootstrap; survives until process exit. *)

val get_root_switch_opt : unit -> Eio.Switch.t option
(** Get the server root switch without consulting the fiber-local
    turn-scoped binding. Use only for work that must survive a single
    keeper turn, such as queued background voice playback. *)

val set_env : Eio_unix.Stdenv.base -> unit
(** Set the global Eio standard environment.  Required by long-lived
    consumers that need more than [net]/[clock] (e.g. piaf
    [Client.create] in [Masc_http_client.Pool]).  Written once at
    server bootstrap. *)

val get_env_opt : unit -> Eio_unix.Stdenv.base option
(** Get the Eio standard environment if available.  Returns [None]
    before [set_env] is called (test setup before [Eio_main.run] or
    pre-bootstrap helper code).  Callers that need [env] must handle
    this gracefully — see [Masc_http_client] for the lazy-init
    pattern. *)

val with_turn_switch : Eio.Switch.t -> (unit -> 'a) -> 'a
(** [with_turn_switch sw f] binds [sw] as the turn-scoped switch on the
    *current fiber* and any fibers forked from inside [f]. Reads of
    [get_switch_opt] / [get_switch] from within that scope return [sw];
    reads from outside the binding (server, dashboard, bootstrap fibers)
    fall through to the global atomic set by [set_switch] (= server
    root_sw).

    Used by [keeper_agent_run.run_turn] to constrain resources opened
    during a single turn to that turn's lifetime: when the outer
    [Eio.Switch.run] closes, those resources are released, preventing
    the FD accumulation observed in the 2026-05-16 ENFILE storm.

    Reference: RFC-0107 §3.3, audit §10.5. *)

val with_test_env :
  net:[> `Network | `Platform of [> `Generic | `Unix ]] Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  sw:Eio.Switch.t ->
  (unit -> 'a) -> 'a
(** Temporarily override the global Eio context for a test scope and restore the
    previous values afterwards.
    Callers should keep all spawned work inside the provided structured Eio switch
    so the override does not outlive the test scope. *)

val get_net_opt : unit -> eio_net option
(** Get the Eio network handle if available. *)

val get_clock_opt : unit -> float Eio.Time.clock_ty Eio.Resource.t option
(** Get the Eio clock if available. *)

val get_switch_opt : unit -> Eio.Switch.t option
(** Get the Eio switch if available. *)

val get_bound_turn_switch_opt : unit -> Eio.Switch.t option
(** Return only the turn-scoped fiber binding, without falling back to the
    server root switch.  This is an exact boundary check for operations that
    must reject self-cancellation of their owning turn. *)

val get_net : unit -> (eio_net, string) result
(** Get the Eio network handle.
    Returns Error if not initialized. *)

val get_clock : unit -> (float Eio.Time.clock_ty Eio.Resource.t, string) result
(** Get the Eio clock.
    Returns Error if not initialized. *)

val get_switch : unit -> (Eio.Switch.t, string) result
(** Get the Eio switch.
    Returns Error if not initialized. *)

(** [get_https_connector] removed — use [get_https_connector_result] instead. *)

val get_https_connector_result :
  unit ->
  ((Uri.t ->
    [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
    [ `Close | `Flow | `R | `Shutdown | `Tls | `W ] Eio.Resource.t),
   string)
  result
(** Non-raising HTTPS connector lookup. *)
