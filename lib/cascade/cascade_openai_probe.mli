(** OpenAI-compatible endpoint capacity probe.

    Probes OpenAI-compatible endpoints (RunPod, vLLM, etc.) via
    [/v1/models] for basic health/capacity discovery.  Registered in
    [Cascade_capacity_probe] after the ollama-specific probe; ollama
    URLs take precedence via first-match semantics.

    @since 0.10.0 *)

(* ── Explicit URL registry ──────────────────────────────────── *)

val register_url : url:string -> unit
val is_registered : url:string -> bool
val registered_count : unit -> int

(* ── Cache ──────────────────────────────────────────────────── *)

val cached_capacity : ?now:float -> string -> Cascade_throttle.capacity_info option
val cache_size : unit -> int

(* ── Probe adapter ───────────────────────────────────────────── *)

(** First-class probe wrapper for registration with
    {!Cascade_capacity_probe.register}.  Structurally satisfies
    {!Cascade_capacity_probe.Probe} without an explicit annotation,
    avoiding a circular dependency between the two compilation units. *)
module Openai_probe : sig
  val can_probe : url:string -> bool

  val probe
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> url:string
    -> ?timeout_s:float
    -> unit
    -> Cascade_throttle.capacity_info option

  val cached : url:string -> ?now:float -> unit -> Cascade_throttle.capacity_info option

  val refresh_many
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> urls:string list
    -> ?timeout_s:float
    -> unit
    -> unit
end
