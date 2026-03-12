(** Sentinel — MASC default resident agent.

    Ensures at least one housekeeping agent is always alive.
    Integrates Guardian zombie/gc consumers and adds board patrol,
    task hygiene, and keeper health monitoring.

    Opt-out: MASC_SENTINEL_ENABLED=false *)

(** The sentinel agent's room identity. *)
val agent_name : string

(** Start the sentinel agent. Joins the room and spawns all pulse consumers.
    No-op if MASC_SENTINEL_ENABLED=false.
    When sentinel is active, Guardian.start should NOT be called separately
    (sentinel already includes zombie + gc consumers). *)
val start :
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  net:'b Eio.Net.t ->
  Room_utils.config ->
  unit

(** Test helper: clears in-memory sentinel runtime markers. *)
val reset_runtime_state_for_tests : unit -> unit

(** Test helper: marks sentinel as started without spawning runtime fibers. *)
val mark_started_for_tests : unit -> unit

(** JSON status for /health and dashboard. *)
val status_json : unit -> Yojson.Safe.t
