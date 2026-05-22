(** Slot/pool/phase variants + wait-timeout payload for the keeper
    turn slot machinery.

    Pure types + small [_to_string] helpers + the [Semaphore_wait_timeout]
    exception. Verbatim extract from the head of [Keeper_turn_slot].

    The exception is defined here so it has a single identity across
    the module boundary; the parent re-exports it via
    [exception Semaphore_wait_timeout = Keeper_turn_slot_types.Semaphore_wait_timeout]
    so existing [try ... with Semaphore_wait_timeout _ -> ...]
    patterns continue to match. *)

type slot_pool =
  | Turn_pool
  | Autonomous_pool
  | Reactive_pool

let slot_pool_to_string = function
  | Turn_pool -> "turn"
  | Autonomous_pool -> "autonomous"
  | Reactive_pool -> "reactive"
;;

exception Semaphore_wait_timeout of float

type semaphore_wait_phase =
  | Autonomous_queue_head
  | Autonomous_slot
  | Reactive_slot
  | Turn_slot

let semaphore_wait_phase_to_string = function
  | Autonomous_queue_head -> "autonomous_queue_head"
  | Autonomous_slot -> "autonomous_slot"
  | Reactive_slot -> "reactive_slot"
  | Turn_slot -> "turn_slot"
;;

type semaphore_wait_timeout =
  { timeout_wait_sec : float
  ; timeout_phase : semaphore_wait_phase
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
let int_of_env_default ~primary ~default ~min_v ~max_v =
  match Sys.getenv_opt primary with
  | None -> default
  | Some raw when String.trim raw = "" -> default
  | Some raw ->
    let v = Option.value ~default (int_of_string_opt (String.trim raw)) in
    Keeper_config.clamp_int v ~min_v ~max_v
;;
