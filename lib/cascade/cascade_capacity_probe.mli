(** Provider-agnostic capacity probe adapter.

    See {!Cascade_capacity_probe} for documentation. *)

(** {1 Module type} *)

module type Probe = sig
  val can_probe : url:string -> bool
  val probe :
    sw:Eio.Switch.t ->
    net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
    url:string ->
    ?timeout_s:float ->
    unit ->
    Cascade_throttle.capacity_info option
  val cached : url:string -> ?now:float -> unit -> Cascade_throttle.capacity_info option
  val refresh_many :
    sw:Eio.Switch.t ->
    net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
    urls:string list ->
    ?timeout_s:float ->
    unit ->
    unit
end

(** {1 First-class module type} *)

type t = (module Probe)
(** Packaged probe for registration. *)

(** {1 Registry} *)

val register : t -> unit
(** [register probe] appends [probe] to the probe list.  Probes are
    consulted in registration order. *)

(** {1 Query (provider-agnostic)} *)

val can_probe : url:string -> bool
(** [can_probe ~url] is [true] when at least one registered probe
    recognises [url]. *)

val cached : url:string -> ?now:float -> unit -> Cascade_throttle.capacity_info option
(** [cached ~url ?now ()] reads the first registered probe's cache that
    recognises [url].  Pure: no IO. *)

val capacity : string -> Cascade_throttle.capacity_info option
(** [capacity url] is the 3-tier resolution chain:
    [Cascade_throttle] → registered probes' cache →
    [Cascade_client_capacity].  Identical semantics to the previous
    per-caller hardcoded chain. *)

val probe :
  sw:Eio.Switch.t ->
  net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
  url:string ->
  ?timeout_s:float ->
  unit ->
  Cascade_throttle.capacity_info option
(** [probe ~sw ~net ~url ?timeout_s ()] performs a live probe via the
    first registered probe that recognises [url]. *)

val refresh_many :
  sw:Eio.Switch.t ->
  net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
  urls:string list ->
  ?timeout_s:float ->
  unit ->
  unit
(** [refresh_many ~sw ~net ~urls ?timeout_s ()] delegates to every
    registered probe's [refresh_many].  Each probe internally filters
    URLs it cannot handle. *)
