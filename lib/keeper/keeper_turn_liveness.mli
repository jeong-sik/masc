(* Keeper_turn_liveness — local-only cascade liveness decisions and turn
   livelock configuration.

   Provider-specific probe knowledge lives in
   [Cascade_capacity_probe]; this module routes probeable URLs through
   that registry without naming any single provider.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_types

(** Deterministic decision for the local-only phase fallback boundary. This
    does not probe runtime liveness; it only decides whether the selected
    labels resolve to runtime URLs that [Cascade_capacity_probe.can_probe]
    before preserving [local_only]. The provider/model label resolver stays
    behind [Cascade_runtime_candidate]. *)
type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of
      { effective_cascade : string
      ; fallback_cascade : string
      ; probeable_base_urls : string list
      }

val decide_local_only_liveness
  :  ?resolve_runtime_url:(string -> string option)
  -> base_cascade:string
  -> effective_cascade:string
  -> string list
  -> local_only_liveness_decision

(** When phase routing temporarily forces the phase-buffer route, fail open to the
    keeper's configured base cascade if no registered local-capable probe
    reports the endpoint as serving. Legacy [local_only] aliases
    normalize through [routes.phase_buffer]. *)
val fail_open_local_only_when_unavailable
  :  ?resolve_runtime_url:(string -> string option)
  -> ?probe_base_url:(string -> bool)
  -> base_cascade:string
  -> effective_cascade:string
  -> string list
  -> string

(** Configurable livelock detection max attempts. *)
val turn_livelock_max_attempts : unit -> int

(** Configurable livelock detection stuck threshold (seconds). *)
val turn_livelock_stuck_after_sec : unit -> float
