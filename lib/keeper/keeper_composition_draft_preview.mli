(** Model-facing preview of one prepared draft. The edge adds the canonical
    executor schedule to the draft's immutable metadata without dispatching
    any node or acquiring a runtime. *)

val preview : Keeper_composition_draft.t -> Yojson.Safe.t
