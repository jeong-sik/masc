(* Keeper_turn_liveness — phase-buffer runtime liveness decisions and turn
   livelock configuration.

   Provider-specific probe knowledge lives in
   [Runtime_capacity_probe]; this module routes probeable URLs through
   that registry without naming any single provider.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* runtime→Runtime 숙청: phase-buffer liveness probe 기계
   (phase_buffer_liveness_decision / decide_phase_buffer_liveness /
   fail_open_phase_buffer_when_unavailable) 제거. 단일 runtime 에서 effective ==
   base 라 probe 분기가 죽은 코드였다. *)

(** Configurable livelock detection max attempts. *)
val turn_livelock_max_attempts : unit -> int

(** Configurable livelock detection stuck threshold (seconds). *)
val turn_livelock_stuck_after_sec : unit -> float
