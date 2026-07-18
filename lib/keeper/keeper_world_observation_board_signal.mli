(** Board signal payload parser for keeper world observation. *)

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

type board_read_operation =
  | Get_post
  | Get_comments

type board_unavailable =
  { operation : board_read_operation
  ; post_id : string
  ; error : Board.board_error
  }

type 'a board_read =
  | Available of 'a
  | Unavailable of board_unavailable

type board_evidence =
  { post : Board.post
  ; comments : Board.comment list
  }

type board_stimulus_materialization_error =
  | Source_unavailable of board_unavailable
  | Post_identity_mismatch of {
      signal_post_id : string;
      snapshot_post_id : string;
    }
  | Invalid_snapshot of Keeper_event_queue.board_stimulus_error

type comment_state =
  [ `Never
  | `No_new_external
  | `New_external of int * string * string
  ]

type comment_status = comment_state board_read

(** Whether a failed board read is worth retrying (RFC board-unavailable-result).
    Closed set: adding a new {!Board.board_error} variant forces a
    classification decision in {!disposition_of_error} rather than defaulting
    to "retry forever" or "silently drop". *)
type disposition =
  | Permanent
      (** Retrying the same read reproduces the same error (e.g. the post
          was deleted). Callers must consume/drop the affected stimulus and
          must not requeue it. *)
  | Transient
      (** An environment-level hiccup unrelated to whether the target
          exists. Callers may retain the stimulus for a later cycle. *)

val disposition_of_error : Board.board_error -> disposition
val disposition_of_unavailable : board_unavailable -> disposition

val board_read_operation_to_string : board_read_operation -> string
val unavailable_to_string : board_unavailable -> string
val materialization_error_to_string : board_stimulus_materialization_error -> string

val board_signal_of_board_stimulus
  :  post_id:string
  -> Keeper_event_queue.board_stimulus
  -> Board_dispatch.board_signal
(** Total conversion from the typed event-queue board payload to the
    [Board_dispatch.board_signal] the matchers consume (RFC-0020). *)

val board_stimulus_of_board_evidence :
  meta:Keeper_meta_contract.keeper_meta ->
  signal:Board_dispatch.board_signal ->
  post:Board.post ->
  comments:Board.comment list ->
  (Keeper_event_queue.board_stimulus, board_stimulus_materialization_error) result
(** Purely materialize the immutable queue delivery snapshot from one exact
    Board evidence set. No Board read occurs in this function. *)

val read_board_evidence : Board_dispatch.board_signal -> board_evidence board_read
(** Capture the source post and relevant comment stream exactly once for one
    Board occurrence. The returned evidence is immutable input for every
    Keeper-lane projection of that occurrence. *)

val board_stimulus_of_projection :
  signal:Board_dispatch.board_signal ->
  title:string ->
  preview:string ->
  hearth:string option ->
  post_kind:Board.post_kind ->
  updated_at:float ->
  explicit_mention:bool ->
  matched_targets:string list ->
  thread_snapshot:Keeper_event_queue.board_thread_snapshot ->
  (Keeper_event_queue.board_stimulus, board_stimulus_materialization_error) result
(** Canonical pure constructor shared by live delivery, cursor scans, and
    attention candidates. Every durable Board payload uses this one mapping. *)

val materialize_board_stimulus :
  meta:Keeper_meta_contract.keeper_meta ->
  Board_dispatch.board_signal ->
  (Keeper_event_queue.board_stimulus, board_stimulus_materialization_error) result
(** Read the source Board only at the producer/admission boundary, then return
    the complete typed payload. Intake must use {!board_signal_of_board_stimulus}
    and never call this function. *)

val post_id_string : Board.post -> string
val compare_cursor_token : float * string -> float * string -> int
val cursor_token_of_post :
  Board.post -> (float * string, Keeper_reaction_store.error) result
val list_posts_after_cursor :
  float * string option -> (Board.post list, Keeper_reaction_store.error) result
val text : Board_dispatch.board_signal -> string
val mention_ids_of_signal : Board_dispatch.board_signal -> Keeper_identity.Keeper_id.t list

val match_signal
  :  meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> match_result

val check_self_comment_status
  :  self_ids:Keeper_identity.Keeper_id.t list
  -> post_id:string
  -> comment_status

type wake_reason =
  | Explicit_mention
  | Thread_reply_after_self_comment
  | Reaction_after_self_activity
(** Closed set of reasons a keeper wakes for a board signal (RFC-0020).
    Replaces the prior [string option] contract; consumers match exhaustively
    so the previously dead ["board_activity"] generic bucket is gone. Semantic
    relatedness is intentionally absent: it must enter through an LLM/Judge
    attention boundary, not through board-publish keyword matching. *)

val wake_reason_label : wake_reason -> string
(** Stable string label for logs/metrics. *)

val wake_reason_of_board_evidence
  :  meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> board_evidence
  -> wake_reason option
(** Pure lane-specific wake decision over one captured Board evidence set. *)

val wake_reason
  :  meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> wake_reason option board_read
(** [Available None] means the structural reactive pipeline found no
    deterministic address for this keeper. [Unavailable _] preserves a typed
    Board read failure so callers can retain durable work and avoid acking it. *)
