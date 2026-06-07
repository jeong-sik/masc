(** Holder pool and wait-timeout payload for keeper turn admission.

    Pure types + small [_to_string] helpers + the [Semaphore_wait_timeout]
    exception.

    The exception is defined here so it has a single identity across
    the module boundary; the parent re-exports it via
    [exception Semaphore_wait_timeout = Keeper_turn_admission_types.Semaphore_wait_timeout]
    so existing [try ... with Semaphore_wait_timeout _ -> ...]
    patterns continue to match. *)

type holder_pool =
  | Turn_holder
  | Autonomous_holder
  | Reactive_holder

let holder_pool_to_string = function
  | Turn_holder -> "turn"
  | Autonomous_holder -> "autonomous"
  | Reactive_holder -> "reactive"
;;

exception Semaphore_wait_timeout of float

type admission_wait_phase =
  | Autonomous_queue_head
  | Autonomous_admission
  | Reactive_admission
  | Global_admission

let admission_wait_phase_to_string = function
  | Autonomous_queue_head -> "autonomous_queue_head"
  | Autonomous_admission -> "autonomous_admission"
  | Reactive_admission -> "reactive_admission"
  | Global_admission -> "global_admission"
;;

type semaphore_wait_timeout =
  { timeout_wait_sec : float
  ; timeout_phase : admission_wait_phase
  ; timeout_autonomous_available : int
  ; timeout_reactive_available : int
  ; timeout_turn_available : int
  ; timeout_queue_depth : int
  ; timeout_queue_ahead : int option
  ; timeout_holders : (string * float) list
  }

(* RFC-0085 PR-11 — Dropped the [~deprecated] fallback; the typo legacy
   env MASC_KEEPER_AUTOBOT_MAX is no longer recognised. Operators
   must set MASC_KEEPER_AUTOBOOT_MAX. *)
let clamp_int value ~min_v ~max_v =
  max min_v (min max_v value)
;;

let int_of_env_default ~primary ~default ~min_v ~max_v =
  match Sys.getenv_opt primary with
  | None -> default
  | Some raw when String.trim raw = "" -> default
  | Some raw ->
    let v = Option.value ~default (int_of_string_opt (String.trim raw)) in
    clamp_int v ~min_v ~max_v
;;
