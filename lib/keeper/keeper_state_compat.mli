(** Keeper State Compat — Backward-compatible 5-state projection (RFC-0002).

    Maps the 10-state [Keeper_state_machine.phase] to the legacy 5-state enum
    that existing API consumers expect. *)

(** The legacy 5-state enum matching the original [keeper_state]. *)
type legacy_state =
  | Running
  | Paused
  | Stopped
  | Crashed
  | Dead

val legacy_to_string : legacy_state -> string
val legacy_of_string : string -> legacy_state option

(** Project a fine-grained phase to the legacy 5-state enum.
    Buffer states map to their "parent" stable state:
    - [Failing | Compacting | HandingOff | Draining] -> [Running]
    - [Restarting] -> [Crashed]
    - [Offline] -> [Stopped] *)
val to_legacy : Keeper_state_machine.phase -> legacy_state
