(** Session lifecycle and metadata for agent executions.

    Tracks turn count, timestamps, and cross-turn state via
    {!Context.t}. Each session has a unique ID and optional
    resume lineage.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Session type} *)

type t =
  { id : string
  ; started_at : float
  ; last_active_at : float
  ; turn_count : int
  ; resumed_from : string option
  ; cwd : string option
  ; metadata : Context.t
  }

(** {1 Lifecycle} *)

(** Raised when the operating-system entropy source cannot mint a session ID. *)
exception Entropy_unavailable of string

(** Generate a session ID from operating-system entropy.
    @raise Entropy_unavailable if the entropy source is unavailable. *)
val generate_id : unit -> string

(** Create a new session.
    @raise Entropy_unavailable when [id] is omitted and the entropy source is
    unavailable. *)
val create
  :  ?id:string
  -> ?resumed_from:string
  -> ?cwd:string
  -> ?metadata:Context.t
  -> unit
  -> t

(** Record a completed turn: increments turn_count, updates last_active_at. *)
val record_turn : t -> t

(** Update last_active_at without incrementing turn_count. *)
val touch : t -> t

(** Elapsed seconds since session start. *)
val elapsed : t -> float

(** Resume a session from a checkpoint.
    @raise Entropy_unavailable if the entropy source is unavailable. *)
val resume_from : Checkpoint.t -> t

(** {1 Serialization} *)

(** Serialize session to JSON. *)
val to_json : t -> Yojson.Safe.t

(** Deserialize session from JSON. *)
val of_json : Yojson.Safe.t -> (t, Error.sdk_error) result
