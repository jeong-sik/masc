(** Sentinel — MASC default resident agent (OAS-integrated).

    Ensures at least one housekeeping agent is always alive.
    Integrates Guardian zombie/gc consumers and adds board patrol,
    task hygiene, and keeper health monitoring.

    OAS integration: exports Agent Card, publishes events via Event_bus.

    Opt-out: MASC_SENTINEL_ENABLED=false *)

(** The sentinel agent's room identity. *)
val agent_name : string

(** A2A v0.3 Agent Card for sentinel. *)
val agent_card : Agent_card.agent_card

(** Start the sentinel agent. Joins the room and spawns all pulse consumers.
    No-op if MASC_SENTINEL_ENABLED=false.
    When sentinel is active, Guardian.start should NOT be called separately
    (sentinel already includes zombie + gc consumers). *)
val start :
  ?bus:Agent_sdk.Event_bus.t ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  net:'b Eio.Net.t ->
  Room_utils.config ->
  unit

(** Test helper: clears in-memory sentinel runtime markers. *)
val reset_runtime_state_for_tests : unit -> unit

(** Test helper: marks sentinel as started without spawning runtime fibers. *)
val mark_started_for_tests : unit -> unit

(** Parsed board-patrol decision from the sentinel LLM. *)
type board_patrol_decision = {
  needs_attention : bool;
  reason : string option;
  board_post : string option;
}

(** Parse the sentinel board-patrol LLM JSON contract. *)
val board_patrol_decision_of_llm_json : Yojson.Safe.t -> board_patrol_decision

(** Test helper: records the latest board patrol outcome for status_json. *)
val note_board_patrol_result_for_tests :
  ?checked_at:float ->
  action:string ->
  ?reason:string ->
  ?stale_count:int ->
  unit ->
  unit

(** Test helper: reads the persisted daily-post dedupe key from .masc state. *)
val read_board_patrol_day_key_for_tests :
  Room_utils.config -> string option

(** Test helper: persists the daily-post dedupe key into .masc state. *)
val write_board_patrol_day_key_for_tests :
  Room_utils.config -> string -> unit

(** Ensures the room root/current room state exists before sentinel joins. *)
val ensure_room_initialized_for_start : Room_utils.config -> unit

(** JSON status for /health and dashboard. *)
val status_json : unit -> Yojson.Safe.t
