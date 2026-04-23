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
(** Set the global Eio switch. *)

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
