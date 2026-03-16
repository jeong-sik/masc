(** Room checkpoint and restore

    Captures a complete room snapshot (state, tasks, agents) as JSON.
    Enables rollback after failed operations.

    @since 2.95.0
*)

(** A checkpoint is an opaque JSON snapshot. *)
type t = Yojson.Safe.t

(** [capture ~room_state ~tasks ~agents] creates a checkpoint from
    the current room components.

    @param room_state JSON from [Room_eio.room_state_to_json]
    @param tasks JSON array of task objects
    @param agents JSON array of agent status objects *)
val capture
  :  room_state:Yojson.Safe.t
  -> tasks:Yojson.Safe.t
  -> agents:Yojson.Safe.t
  -> t

(** [timestamp checkpoint] returns when the checkpoint was created. *)
val timestamp : t -> float

(** [room_state checkpoint] extracts the room state JSON. *)
val room_state : t -> Yojson.Safe.t option

(** [tasks checkpoint] extracts the tasks JSON. *)
val tasks : t -> Yojson.Safe.t option

(** [agents checkpoint] extracts the agents JSON. *)
val agents : t -> Yojson.Safe.t option

(** [to_string checkpoint] serializes for storage. *)
val to_string : t -> string

(** [of_string s] deserializes.  Returns [None] on invalid input. *)
val of_string : string -> t option

(** [diff a b] returns a JSON object describing what changed between
    two checkpoints (field-level comparison). *)
val diff : t -> t -> Yojson.Safe.t
