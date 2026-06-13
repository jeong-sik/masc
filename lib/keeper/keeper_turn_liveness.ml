(* Keeper_turn_liveness — phase-buffer runtime liveness decisions and turn
   livelock configuration.

   Provider-specific knowledge lives in [Runtime_capacity_probe]; this
   module routes probeable URLs through that registry without naming
   any single provider.

   Extracted from keeper_unified_turn.ml (L328-499) during the god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* runtime→Runtime 숙청: phase-buffer liveness probe 기계 제거.
   per-phase runtime override 가 사라진 뒤(단일 runtime) effective_runtime 는
   항상 base_runtime 와 같으므로 decide_phase_buffer_liveness 의 probe 분기
   (effective == phase_buffer && base != phase_buffer 일 때만 발동)는 죽은
   코드였다. fail_open_phase_buffer_when_unavailable 도 항상 effective_runtime
   를 그대로 반환 — 호출자(resolve_runtime)가 직접 base 를 쓴다. *)

(** PR-B: saturation pre-skip support (provider-agnostic).

    When every label in the resolved runtime points at the same
    [base_url] AND a registered [Runtime_capacity_probe] recognises
    that URL, we can pre-check the probe cache before paying an
    [Agent.run] dispatch.  If the probe reports
    [process_available <= 0] the request would queue on a busy slot
    and very likely blow the keeper turn budget, causing a cascading
    FAILED cycle.  Skipping the turn here keeps the keeper alive
    without burning the budget.

    No provider variant is named — the probe registry is the
    boundary that decides which URLs are probeable.  Adding a new
    local backend (vllm, lmstudio, …) only needs a new probe
    registration. *)

let turn_livelock_max_attempts () =
  Int.max 1 (Env_config_core.get_int ~default:3 "MASC_KEEPER_TURN_LIVELOCK_MAX_ATTEMPTS")
;;

let turn_livelock_stuck_after_sec () =
  Float.max
    1.0
    (Env_config_core.get_float
       ~default:1800.0
       "MASC_KEEPER_TURN_LIVELOCK_STUCK_AFTER_SEC")
;;
