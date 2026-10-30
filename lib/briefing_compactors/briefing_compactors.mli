(** Briefing_compactors — Reduce raw domain JSON into the shape the
    mission-briefing dashboard consumes.

    Each [compact_*] returns a [`Assoc _] with a fixed key set so
    downstream renderers can treat the output as a stable contract. *)

val compact_keeper_json : Yojson.Safe.t -> Yojson.Safe.t

val compact_agent_json : Masc_domain.agent -> Yojson.Safe.t
