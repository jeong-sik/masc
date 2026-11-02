(** Skill evidence received or observed in one exact physical Keeper turn.
    Retained origin ledgers remain the authority, including when their trace
    differs from the receiving turn. Observation does not dispatch or settle
    any work. *)
val project : config:Workspace.config -> turn_ref:Ids.Turn_ref.t -> Yojson.Safe.t
(** Fold the retained trace inventory and return matching original activation
    frames, physical async handoffs and causal action links. The original
    ledger revision identifies provenance, not a fabricated filtered ledger.
    Empty results prove absence only within a complete retained snapshot. *)

val project_string : config:Workspace.config -> string -> (Yojson.Safe.t, string) result
(** Parse an untrusted complete turn reference before selecting evidence. *)
