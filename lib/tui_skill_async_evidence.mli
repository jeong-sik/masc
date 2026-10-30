(** Display decisions from canonical, selected async evidence. This does not
    authenticate new facts or change execution/activation authority. *)
type action_group = private
  { first : Keeper_skill_async_action.t
  ; additional_links : Keeper_skill_async_action.t list
  }

type t = private
  { result_deliveries : Keeper_skill_async_delivery.t list
  ; action_link_count : int
  ; actions : action_group list
  }

val project : Keeper_skill_activation_ledger.async_evidence -> t
(** One group per physical occurrence, in first-observed ledger order. All
    causal links and their individual observation clocks are retained.
    SDK results and native starts remain their original closed facts. *)
