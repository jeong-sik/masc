(** TRPG Rule Slot Implementation

    D&D 5e Lite rules implementation wrapped as a TRPG_SLOT.
    Provides dice rolling mechanics, HP management, and inventory handling.

    @since 2.68.0
*)

(** {1 Rule Slot Module} *)

module Dnd5e_lite = Trpg_rule_dnd5e_lite

module Rule_slot : Trpg_slot.TRPG_SLOT = struct
  (* Legacy rule module implements Trpg_rule.S, use Lift_legacy *)
  module Legacy = Trpg_slot.Lift_legacy (Dnd5e_lite)

  let slot_info = Legacy.slot_info

  let init_state = Legacy.init_state

  let apply_event = Legacy.apply_event

  let derive_state = Legacy.derive_state
end

(** {1 Self-registration} *)

let () =
  Trpg_slot.Registry.register (module Rule_slot : Trpg_slot.TRPG_SLOT)
