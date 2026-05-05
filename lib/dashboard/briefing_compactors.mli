(** Briefing_compactors — Reduce raw domain JSON into the shape the
    mission-briefing dashboard consumes.

    Each [compact_*] returns a [`Assoc _] with a fixed key set so
    downstream renderers can treat the output as a stable contract. *)

(** [relevant_sessions_for_briefing ~current_namespace ~now_ts
    sessions] keeps sessions that either match [current_namespace]
    (project/room id) and are in a live status, or have a
    [recent_events] entry within the last hour of [now_ts]. *)
val relevant_sessions_for_briefing :
  current_namespace:string ->
  now_ts:float ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list

val compact_session_json : Yojson.Safe.t -> Yojson.Safe.t

val compact_keeper_json : Yojson.Safe.t -> Yojson.Safe.t

val compact_agent_json : Masc_domain.agent -> Yojson.Safe.t
