(* Keeper_turn_liveness — local-only cascade liveness decisions, local
   provider saturation pre-skip, and turn liveload configuration.

   Provider-specific probe knowledge lives in
   [Cascade_capacity_probe]; this module routes probeable URLs through
   that registry without naming any single provider.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_types

(** Deterministic decision for the local-only phase fallback boundary. This
    does not probe runtime liveness; it only decides whether the selected
    labels resolve to URLs that [Cascade_capacity_probe.can_probe] before
    preserving [local_only]. *)
type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of
      { effective_cascade : string
      ; fallback_cascade : string
      ; probeable_base_urls : string list
      }

val decide_local_only_liveness
  :  ?resolve_label:(string -> Llm_provider.Provider_config.t option)
  -> base_cascade:string
  -> effective_cascade:string
  -> string list
  -> local_only_liveness_decision

(** When phase routing temporarily forces the phase-buffer route, fail open to the
    keeper's configured base cascade if no registered local-capable probe
    reports the endpoint as serving. Legacy [local_only] aliases
    normalize through [routes.phase_buffer]. *)
val fail_open_local_only_when_unavailable
  :  ?resolve_label:(string -> Llm_provider.Provider_config.t option)
  -> ?probe_base_url:(string -> bool)
  -> base_cascade:string
  -> effective_cascade:string
  -> string list
  -> string

(** PR-B: when every label in the resolved cascade points at the same
    [base_url] AND a registered [Cascade_capacity_probe] recognises
    that URL, return [Some url]; otherwise [None]. Purely structural:
    does not probe the network. Provider variant is never inspected —
    the probe registry is the boundary that decides which URLs are
    probeable. *)
val resolve_shared_probeable_base_url
  :  ?resolve_label:(string -> Llm_provider.Provider_config.t option)
  -> ?can_probe:(string -> bool)
  -> string list
  -> string option

(** Read the [Cascade_capacity_probe] cache and report whether the endpoint
    is saturated (no available slots while at least one request is active
    or queued). No cache / failed probe returns [false] (fail-open) so a
    flaky probe never starves the keeper. *)
val is_base_url_saturated
  :  ?capacity_lookup:(string -> Cascade_throttle.capacity_info option)
  -> string
  -> bool

(** Backoff sleep applied after a saturation skip (seconds). *)
val saturation_skip_backoff_sec : float

(** Jitter factor for saturation skip sleep. *)
val saturation_skip_jitter_factor : float

(** Compute a jittered sleep duration for saturation skip. *)
val saturation_skip_sleep_duration : unit -> float

(** Configurable livelock detection max attempts. *)
val turn_livelock_max_attempts : unit -> int

(** Configurable livelock detection stuck threshold (seconds). *)
val turn_livelock_stuck_after_sec : unit -> float

(** Upper bound on consecutive saturation skips per keeper (env
    [MASC_MAX_CONSECUTIVE_SATURATION_SKIPS], default 5, floored at
    1).  When a keeper exceeds this count its next dispatch escapes
    the saturation pre-skip path so a stuck or stale probe cannot
    starve the keeper indefinitely. *)
val max_consecutive_saturation_skips : unit -> int

(** Current consecutive-skip count for [keeper_name].  Returns 0 when
    the keeper has no recorded skips. *)
val saturation_skip_count_get : keeper_name:string -> int

(** Increment and return the new consecutive-skip count for
    [keeper_name].  Caller decides whether to act on the new count
    (compare against {!max_consecutive_saturation_skips}). *)
val saturation_skip_count_inc : keeper_name:string -> int

(** Reset [keeper_name]'s consecutive-skip count to zero.  Called on
    every non-skip path (probe reports unsaturated, non-probeable
    cascade, force-dispatch escape). *)
val saturation_skip_count_reset : keeper_name:string -> unit

(** Test helper: clear all per-keeper consecutive-skip counters. *)
val saturation_skip_count_clear_all : unit -> unit
