(* Keeper_turn_liveness — local-only cascade liveness decisions, ollama
   saturation pre-skip, and turn liveload configuration.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_types

(** Deterministic decision for the local-only phase fallback boundary. This
    does not probe runtime liveness; it only decides whether the selected
    labels warrant an Ollama liveness check before preserving [local_only]. *)
type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of {
      effective_cascade : string;
      fallback_cascade : string;
      ollama_base_urls : string list;
    }

val decide_local_only_liveness :
  ?resolve_label:(string -> Llm_provider.Provider_config.t option) ->
  base_cascade:string ->
  effective_cascade:string ->
  string list ->
  local_only_liveness_decision

val fail_open_local_only_when_unavailable :
  ?resolve_label:(string -> Llm_provider.Provider_config.t option) ->
  ?probe_ollama_base_url:(string -> bool) ->
  base_cascade:string ->
  effective_cascade:string ->
  string list ->
  string
(** When phase routing temporarily forces the phase-buffer route, fail open to the
    keeper's configured base cascade if the local Ollama endpoint is
    unavailable. Legacy [local_only] aliases normalize through
    [routes.phase_buffer]. *)

val resolve_ollama_only_base_url :
  ?resolve_label:(string -> Llm_provider.Provider_config.t option) ->
  string list ->
  string option
(** PR-B: when every label in the resolved cascade points at the
    same ollama [base_url] return [Some url], else [None]. Purely
    structural: does not probe the network. *)

val is_ollama_saturated :
  ?capacity_lookup:(string -> Cascade_throttle.capacity_info option) ->
  string ->
  bool
(** Read the [Cascade_ollama_probe] cache and report whether the endpoint
    is saturated (no available slots while at least one request is active
    or queued). No cache / failed probe returns [false] (fail-open) so a
    flaky probe never starves the keeper. *)

val saturation_skip_backoff_sec : float
(** Backoff sleep applied after a saturation skip (seconds). *)

val saturation_skip_jitter_factor : float
(** Jitter factor for saturation skip sleep. *)

val saturation_skip_sleep_duration : unit -> float
(** Compute a jittered sleep duration for saturation skip. *)

val turn_livelock_max_attempts : unit -> int
(** Configurable livelock detection max attempts. *)

val turn_livelock_stuck_after_sec : unit -> float
(** Configurable livelock detection stuck threshold (seconds). *)
