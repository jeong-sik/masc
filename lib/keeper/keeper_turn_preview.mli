(** Ephemeral activity for the running Keeper turn. Created at Task entry or
    standalone agent entry;
    the turns route reads only the writer bound to its actual Owner slot.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Tool_observed | Failed
(** What the turn is doing now, computed from {!open_activities} on every
    write. [Tool_observed] means a tool call is open, not that one was seen. *)

type response_channel = No_content | Thinking | Text
(** What the model's open response is emitting. [No_content] until its first
    content delta. *)

type tool_stage = Tool_requested | Tool_executing
(** [Tool_requested]: the model is calling the tool and nothing says it runs.
    [Tool_executing]: it is running. The before-tool hook said so, or the
    stream opened a native block, which is the official client running its own
    tool from that block to its stop. *)

type open_response = { channel : response_channel; started_at : float; since : float }

type open_tool =
  { tool_use_id : string option  (** [None] when the stream showed no id *)
  ; tool_name : string
  ; stage : tool_stage
  ; started_at : float
  ; since : float
  ; cohort : Agent_core.Tool_contract.schedule option
      (** Where agent core planned this call: its batch, the batch's size and
          whether the batch runs at once. Copied from the before-tool hook's
          invocation. [None] until that hook names the call, and for a call
          whose loop plans no batches (an official client, a native run). *)
  }

type open_activity = Response_open of open_response | Tool_open of open_tool
(** Work that began in the running turn and has not ended. An event is a
    point; an open activity lasts from its start to its end. [started_at] is
    when the work began. [since] is when its channel or stage last changed. *)

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

type work_context = { task_id : string option; start_reasons : string list }

type t =
  { text_position : source_position
  ; text_tail : string
        (** Last {!tail_bytes} of the newest response text, cut on a UTF-8
            boundary. [""] when the turn has produced no text yet. *)
  ; last_tool : string option
        (** Most recently observed tool name, including requests before validation
            and returned calls. This does not claim a tool is executing. *)
  ; updated_at : float
  ; revision : int
        (** Process-local ordering of preview writes, including writer replacement.
            Wall-clock timestamps can move backwards. *)
  ; runtime_id : string option
  ; activity : activity
  ; open_activities : open_activity list
        (** Started and not ended, oldest first. A response, when one is open,
            is the head. Parallel tool calls stay separate entries. *)
  ; attempt_failed : bool
        (** The running attempt's provider request failed and no later request
            went out. [last_failure] outlives it as text. *)
  ; last_failure : string option
  ; preparation : preparation option
  ; preparation_timeline : preparation_timeline
  ; execution_scope : Keeper_execution_scope_id.t option
  ; work_context : work_context option
  }

val tail_bytes : int

(** A write capability for exactly one preview and its redaction state. Older
    writers never resolve the currently displayed preview by Keeper name. *)
type writer

val note_work_context : writer:writer -> work_context -> unit
(** Publish the Task reference and the decision reasons for this writer's run. *)

val snapshot : writer -> t
(** Read this exact writer under the preview lock. The immutable result stays
    valid after another execution replaces the displayed preview. No I/O or
    timeline traversal occurs while the lock is held. *)

val current : keeper_name:string -> t option
(** Last installed snapshot for diagnostics; not proof of a running owner. *)
val current_for_turn : keeper_name:string -> interrupt_token:Keeper_interrupt_token.t -> t option
(** Only the exact Owner slot can read its preview. Before its writer is
    installed, an older writer remains unreadable regardless of update time. *)

val current_for_turn_with_revision :
  keeper_name:string -> interrupt_token:Keeper_interrupt_token.t -> int * t option
(** Read under one lock. For an installed preview, return its revision. A
    missing preview is observed through the latest process preview revision. *)

val note_text : writer:writer option -> now:float -> string -> unit
(** Record the newest response text's tail, redacted with the snapshot
    {!reset} armed, and end the open response: [after_turn] calls this once
    the model's turn is over. Blank text is ignored — a tool-only turn must
    not erase the last visible words. A missing writer records nothing. *)

val note_tool_started :
  writer:writer option ->
  now:float ->
  tool_use_id:string option ->
  tool_name:string ->
  cohort:Agent_core.Tool_contract.schedule option ->
  unit
(** The before-tool hook ran, so the host is executing this call. A call the
    stream already opened moves from requested to executing; one it never
    showed opens here. The open response ends with that move: the model's
    message that called the tool is over. Hearing it again while the call is
    open changes nothing. *)

val note_tool_finished :
  writer:writer option -> now:float -> tool_use_id:string option -> tool_name:string -> unit
(** The after-tool hook ran, with a result or with a failure. The oldest open
    call that fits ends. In an official client's attempt, when nothing else is
    open the next response opens with no content yet, counted from here: the
    result goes back to the model and the client announces no request. The
    agent loop opens it at its own request instead. A call that was not open
    only becomes the last observed tool. *)

val note_turn_over : writer:writer option -> now:float -> unit
(** The turn's run is over, at the tool boundary where the agent loop yields
    or once it has returned, so nothing it began is still open. No model
    response or turn text follows to close what the last tool return opened,
    or a stream block whose end never came. *)

val note_request : writer:writer option -> now:float -> unit
(** A provider request of the running attempt goes out. Every earlier tool
    call settled before it, so they all end here, and the response opens with
    no content yet. The turn waits on the provider until that request's
    stream says otherwise, so a tool that ran before it stays shown as the
    last observed tool, not as the turn's activity. *)

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

val reset : base_path:string -> keeper_name:string -> execution_scope:Keeper_execution_scope_id.t option ->
  turn_ref:Ids.Turn_ref.t option ->
  now:float -> redaction:Keeper_secret_redaction.t -> writer
(** Install a new displayed preview and return its writer. The install and
    every later write to this writer while it is displayed call
    {!Keeper_turn_preview_signal.changed} with [base_path] and [keeper_name].
    Every response text the turn records passes
    through [redaction] first; streamed deltas pass through one
    {!Keeper_stream_text_redaction} per provider attempt, so the tail grows a
    line at a time and a secret split between deltas never reaches it. *)

val original_turn_ref : writer -> Ids.Turn_ref.t option
(** Identity explicitly supplied at writer creation, never inferred from its
    last activity or found by Keeper name. [None] before an owner establishes it. *)

val note_attempt :
  writer:writer option -> now:float -> runtime_id:string ->
  checkpoint_owner:Runtime_execution.checkpoint_owner -> unit
(** A new attempt of the running turn, run by [checkpoint_owner]'s loop: text,
    tools and every open activity of the earlier attempt end here, and the
    attempt is not failed. The loop decides what a tool block's stop means and
    whether a tool's return opens the next response. *)

val note_failure : writer:writer option -> now:float -> runtime_id:string -> string -> unit
(** Store a bounded failure preview after applying the writer's secret snapshot.
    Every open activity ends with the failed attempt. *)

val note_stream : writer:writer option -> now:float -> Agent_core.Types.sse_event -> unit
(** One provider event. Besides the text it releases, the event says what
    opened, moved or ended: a message opens the response, a content delta sets
    its channel to reasoning or text, a tool block opens a tool call as
    requested, and the message stop ends the response. A native tool block
    ({!Runtime_native_tools.stream_content_type}) is the official client
    running its own tool: its start opens the run as executing and ends the
    open response, and its stop ends the run. In an official client's attempt
    a MASC tool block wraps the host's whole call, so its stop ends that call.
    In the agent loop's attempt the block is only the model's call, and its
    stop changes nothing but the last observed tool. *)
val status_text : t -> string

val to_json : ?include_preparation_timeline:bool -> t -> Yojson.Safe.t
(** The actual turns-route preview payload, including released-source position
    and [open_activities]. The default sends [null] for the unrequested
    timeline without traversing it; explicit detail selection includes the
    actual start-ordered records. *)

val preparation_of_json : Yojson.Safe.t -> (preparation, string) result
(** Strict inverse for the preparation object in [to_json]. Unknown states,
    duplicate/extra fields and incomplete or invalid clock data are errors. *)
