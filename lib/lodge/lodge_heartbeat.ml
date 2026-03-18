(** Lodge_heartbeat -- DEPRECATED stub (#1596, Phase 3).
    Lodge heartbeat removed; Keeper is the sole autonomous runtime.
    This stub preserves the API surface used by Gardener and dashboard modules. *)

(** Deprecated: Lodge heartbeat status. Returns empty status. *)
let lodge_status () = `Assoc [("status", `String "deprecated"); ("message", `String "Lodge heartbeat removed (#1596)")]
let lodge_status_to_json s = s

(** Deprecated: current KST hour. Uses Time_compat. *)
let current_hour_kst () =
  let tm = Unix.localtime (Time_compat.now ()) in
  (* KST = UTC+9 *)
  (tm.Unix.tm_hour + 9) mod 24

(** Deprecated: gap signal type (retained for Gardener type compatibility). *)
type gap_signal_t = {
  gs_topic : string;
  gs_detected_by : string;
  gs_context : string;
  gs_timestamp : float;
}

(** Deprecated: agent type (retained for Gardener type compatibility). *)
type agent = {
  name : string;
  traits : string list;
  preferred_hours : int list;
  activity_level : string;
}

(** Deprecated: always returns empty list. Gap signals removed. *)
let get_signals_for_topic ~topic:_ = ([] : gap_signal_t list)

(** Deprecated: always returns false. Spawn via Gardener directly. *)
let spawn_agent_from_gap ~topic:_ ~signals:_ = false

(** Deprecated: no-op. *)
let clear_gap_signals ~topic:_ = ()

(** Deprecated: always returns empty list. Gap threshold removed. *)
let check_gap_threshold () = ([] : (string * int) list)

(** Deprecated: always returns empty list. Use Room.get_agents_raw_in_room. *)
let get_agents () = ([] : agent list)

(** Deprecated: always returns Error. Use Agent_neo4j or GraphQL directly. *)
let load_lodge_agents_full () = Error "Lodge heartbeat deprecated (#1596)"
