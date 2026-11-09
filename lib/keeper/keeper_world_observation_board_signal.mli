(** Board signal payload parser for keeper world observation. *)

type match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

type board_observation_kind =
  | Observed_post_created
  | Observed_post_updated of { content_updated_at : float }
  | Observed_comment_added of Board_dispatch.board_comment_identity
  | Observed_reaction_changed of Board_dispatch.board_reaction_change
  | Observed_vote_cast of Board_dispatch.board_vote_change

type board_observation =
  { kind : board_observation_kind
  ; post_id : string
  ; author : string
  ; title : string
  ; content : string
  ; hearth : string option
  ; updated_at : float option
  ; audience : Board.audience
  }
(** Durable queue observation, including the producer-issued comment identity.

    The [audience] is the event-time audience the producer pinned to the
    queue row alongside its content. *)

type board_read_operation =
  | Get_post
  | Get_comments
  | Parse_queued_comment_identity
  | Parse_queued_audience
  | Record_attention_candidate

(** A Board observation unavailable because an identifier is invalid, a row
    is absent, or the Board source cannot be read. *)
type board_unavailable =
  { operation : board_read_operation
  ; post_id : string
  ; error : Board.board_read_error
  }

type 'a board_read =
  | Available of 'a
  | Unavailable of board_unavailable

(** The comments after the keeper's latest comment on a post, which are by
    definition all written by someone else. They run to the end of the thread
    in {!Board_dispatch.read_comments} order, the order [masc_board_post_get]
    pages through. There is at least one: [oldest] always exists and [newer]
    holds the rest, oldest first. *)
type replies_after_own_comment =
  { comment_offset : int
    (** Where [oldest] sits in the thread: the [comment_offset] that makes
        [masc_board_post_get] start its page at it. *)
  ; oldest : Board.Comment_id.t
  ; newer : Board.Comment_id.t list
  }

type comment_state =
  [ `Never
  | `No_new_external
  | `New_external of replies_after_own_comment * string * string
    (** The replies after the keeper's latest comment, then the author and a
        preview of the newest one. *)
  ]

type comment_status = comment_state board_read

(* [board_read_operation_to_string] renders the operation inside
   [unavailable_to_string] below, which is this module's only use of it. *)
val unavailable_to_string : board_unavailable -> string

val board_observation_of_board_stimulus
  :  post_id:string
  -> Keeper_event_queue.board_stimulus
  -> (board_observation, board_unavailable) result
(** Preserve the queued signal. The queued comment and parent identities are
    wire strings; they are parsed here into {!Board.Comment_id.t}, and one
    that does not parse is [Error] with [Parse_queued_comment_identity].
    The queued audience mirror becomes {!Board.audience}; a target that does
    not parse is [Error] with [Parse_queued_audience]. *)

val board_stimulus_of_board_signal
  :  Board_dispatch.addressed_board_signal
  -> Keeper_event_queue.board_stimulus
(** Preserve live signal identity, content, and event-time audience in the
    durable queue. *)

val addressed_signal_of_observation : board_observation -> Board_dispatch.addressed_board_signal
(** Reconstruct the exact producer signal after the durable queue has parsed
    its identities and audience. No current post content is substituted. *)

val board_routing_pending_stimulus
  : arrived_at:float -> Board_dispatch.addressed_board_signal -> Keeper_event_queue.stimulus
(** Retain an event whose routing evidence is temporarily unavailable. This
    creates no wake or model input; intake must resolve its original audience. *)

val queue_audience_of_board : Board.audience -> Keeper_event_queue.board_audience
(** Mirror a Board audience into the queue leaf DTO. *)

val board_stimulus_of_signal_with_audience
  :  signal:Board_dispatch.board_signal
  -> audience:Board.audience
  -> Keeper_event_queue.board_stimulus
(** Preserve a signal with its pinned audience. Candidates use this with
    their stored audience. *)

(* [post_id_string] is how [cursor_token_of_post] below keys a post; that is
   its only caller. *)
val compare_cursor_token : float * string -> float * string -> int
val cursor_token_of_post : Board.post -> float * string
val list_posts_after_cursor : float * string option -> Board.post list
val text : Board_dispatch.board_signal -> string
val address_text : Board_dispatch.board_signal -> string
(** Text authored by the current signal producer and therefore allowed to
    carry addressing authority. A post uses its title/content (never the
    category [hearth]), a
    comment uses only the new comment body, and a reaction or vote carries no
    textual address. Inherited post display fields never re-address later
    events. *)
val mention_ids_of_signal : Board_dispatch.board_signal -> Keeper_identity.Keeper_id.t list

val match_signal
  :  meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> match_result

val match_observation
  :  post_kind:Board.post_kind
  -> audience:Board.audience
  -> meta:Keeper_meta_contract.keeper_meta
  -> observation:board_observation
  -> match_result
(** Match the recorded [audience] of a Board post or comment against [meta]
    without re-parsing [@name] tokens from text (RFC-at-name-resolves-to-declared-recipient L2d).
    A [System_post] matches no lane. *)

val check_self_comment_status
  :  self_ids:Keeper_identity.Keeper_id.t list
  -> post_id:string
  -> comment_status

type wake_reason =
  | Explicit_mention
  | Broadcast
  | Comment_on_self_post
  | Reply_to_self_comment
  | Reaction_after_self_activity
  | Vote_on_self_post
  | Vote_on_self_comment
(** Closed set of reasons a keeper wakes for a board signal (RFC-0020).
    Replaces the prior [string option] contract; consumers match exhaustively
    so the previously dead ["board_activity"] generic bucket is gone. Semantic
    relatedness is intentionally absent: it must enter through an LLM/Judge
    attention boundary, not through board-publish keyword matching. *)

val board_signal_stimulus :
  arrived_at:float -> reason:wake_reason -> Board_dispatch.addressed_board_signal -> Keeper_event_queue.stimulus
(** Shared live/catchup stimulus construction; identity and urgency remain identical. *)

val wake_reason_label : wake_reason -> string
(** Stable string label for logs/metrics. *)

type wake_assessment =
  | Wake of wake_reason
  | Unaddressed_comment of Board.visibility
  | Not_addressed
(** An unaddressed comment carries its parent post's visibility from the same
    read used to check authorship. The caller decides whether it is discoverable. *)

val wake_reason
  :  meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> wake_assessment board_read
(** Assess a recorded [Thread_participants] audience without reinterpreting the
    signal text as an address. [Not_addressed] and [Unaddressed_comment _] mean
    the structural reactive pipeline found no deterministic address for this keeper. [Unavailable _]
    names the Board read that answered no row (the post was swept or an id does
    not parse); reading again gives the same answer, so callers consume the source. *)
