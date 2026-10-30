(** Ephemeral activity for the running Keeper turn. Created at Task entry or
    standalone agent entry;
    the turns route reads only the writer bound to its actual Owner slot.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Tool_observed | Failed

type preparation_phase = Task_preparation | World_preparation | Context_preparation | Prompt_preparation
  | Tool_preparation | Skill_preparation
  | Lane_inputs_preparation | Workspace_memory_preparation | Wiki_preparation
type preparation_outcome = Prepared | Rejected | Raised | Cancelled
type preparation_state =
  | Preparation_active
  | Preparation_finished of
      { outcome : preparation_outcome; elapsed_ns : int64; finished_at : float }
type preparation =
  { phase : preparation_phase
  ; turn_ref : Ids.Turn_ref.t option
      (** Absent only when this producer has not established the turn identity. *)
  ; started_at : float
  ; state : preparation_state
  }

type preparation_scope_id = private int
type preparation_span =
  { scope_id : preparation_scope_id
  ; parent_scope_id : preparation_scope_id option
  ; preparation : preparation
  }
(** IDs identify actual scopes within this writer, in start order. A parent
    identifies a proven active enclosing scope in the inherited Eio fiber
    binding, not a dependency or an ownership decision. Without that binding
    (including non-Eio calls), no parent is asserted. IDs are meaningful only
    with the original writer's execution scope/turn identity. *)

type preparation_timeline
val empty_preparation_timeline : preparation_timeline
val preparation_spans : preparation_timeline -> preparation_span list
(** Immutable start-ordered snapshot. Active scopes and completed outcomes stay
    available after provider activity while this writer is retained. A new
    writer starts empty; this is neither durable history nor execution authority.
    Nested elapsed times overlap and must not be added into total latency. *)
val preparation_timeline_is_empty : preparation_timeline -> bool
val preparation_timeline_of_json : Yojson.Safe.t -> (preparation_timeline, string) result
(** Strict scope list decoder: unique increasing IDs, earlier existing parents
    and valid preparation observations. *)
val preparation_timeline_to_json : preparation_timeline -> Yojson.Safe.t
(** Serialize this immutable snapshot without consulting the displayed writer. *)

type source_position = { generation : int; start_byte : int }
(** Byte offsets in the text this writer's redactor actually released.
    Attempts and full-text replacements create a new generation. *)

type t =
  { text_position : source_position
  ; text_tail : string
        (** Last {!tail_bytes} of the newest response text, cut on a UTF-8
            boundary. [""] when the turn has produced no text yet. *)
  ; last_tool : string option
        (** Most recently observed tool name, including requests before validation
            and returned calls. This does not claim a tool is executing. *)
  ; updated_at : float
  ; runtime_id : string option
  ; activity : activity
  ; last_failure : string option
  ; preparation : preparation option
  ; preparation_timeline : preparation_timeline
  ; execution_scope : Keeper_execution_scope_id.t option
  }

val tail_bytes : int

(** A write capability for exactly one preview and its redaction state. Older
    writers never resolve the currently displayed preview by Keeper name. *)
type writer

val snapshot : writer -> t
(** Read this exact writer under the preview lock. The immutable result stays
    valid after another execution replaces the displayed preview. No I/O or
    timeline traversal occurs while the lock is held. *)

val current : keeper_name:string -> t option
(** Last installed snapshot for diagnostics; not proof of a running owner. *)
val current_for_turn : keeper_name:string -> interrupt_token:Keeper_interrupt_token.t -> t option
(** Only the exact Owner slot can read its preview. Before its writer is
    installed, an older writer remains unreadable regardless of update time. *)

val note_text : writer:writer option -> now:float -> string -> unit
(** Record the newest response text's tail, redacted with the snapshot
    {!reset} armed. Blank text is ignored — a tool-only turn must not erase
    the last visible words. A missing writer records nothing. *)

val note_tool : writer:writer option -> now:float -> string -> unit

val with_preparation_result :
  writer:writer option -> turn_ref:Ids.Turn_ref.t option -> phase:preparation_phase ->
  (unit -> ('a, 'e) result) -> ('a, 'e) result
(** Publish the active scope before calling its operation, then record its
    result, exception or cancellation without changing that result. Nested
    scopes restore the still-active parent. Provider/Tool activity retires
    older scopes, so their late completion cannot replace newer activity.
    This is ephemeral observation, not a dispatch or completion decision. *)

val with_preparation :
  writer:writer option -> turn_ref:Ids.Turn_ref.t option -> phase:preparation_phase ->
  (unit -> 'a) -> 'a
(** Same owned scope for a value-returning preparation operation. Exceptions
    and cancellation still settle the observation and propagate unchanged. *)

val reset : keeper_name:string -> execution_scope:Keeper_execution_scope_id.t option ->
  turn_ref:Ids.Turn_ref.t option ->
  now:float -> redaction:Keeper_secret_redaction.t -> writer
(** Install a new displayed preview and return its writer. Every response text the turn records passes
    through [redaction] first; streamed deltas pass through one
    {!Keeper_stream_text_redaction} per provider attempt, so the tail grows a
    line at a time and a secret split between deltas never reaches it. *)

val original_turn_ref : writer -> Ids.Turn_ref.t option
(** Identity explicitly supplied at writer creation, never inferred from its
    last activity or found by Keeper name. [None] before an owner establishes it. *)

val note_attempt : writer:writer option -> now:float -> runtime_id:string -> unit
val note_failure : writer:writer option -> now:float -> runtime_id:string -> string -> unit
val note_stream : writer:writer option -> now:float -> Agent_core.Types.sse_event -> unit
val status_text : t -> string

val to_json : ?include_preparation_timeline:bool -> t -> Yojson.Safe.t
(** The actual turns-route preview payload, including released-source position.
    The default sends [null] for the unrequested timeline without traversing it;
    explicit detail selection includes the actual start-ordered records. *)

val preparation_of_json : Yojson.Safe.t -> (preparation, string) result
(** Strict inverse for the preparation object in [to_json]. Unknown states,
    duplicate/extra fields and incomplete or invalid clock data are errors. *)
