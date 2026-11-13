(** Board — MASC internal board (Mastodon-style federation ready).

    Type SSOT for the board subsystem. All public types are surfaced
    here; the implementations live in [board_core.ml] / [board.ml] /
    [board_dispatch.ml].

    Design properties (enforced by callers, documented for readers):
    - ID validation (no path traversal; see {!Post_id} / {!Comment_id})
    - TTL optional (0 = permanent, default)
    - Explicit persistence errors
    - Cryptographic IDs (no prediction)
    - Atomic writes (no corruption)
    - Automatic sweeper (no manual cleanup)

    @since 0.5.0 — replaces social.ml with hardened implementation *)

(** {1 Error Types — No Silent Failures} *)

type board_error =
  | Invalid_id of string
  | Post_not_found of string
  | Comment_not_found of string
  | Io_error of string
  | Validation_error of string
  | Already_voted of string
  | Already_exists of string
  | Unauthorized of string
    (** Actor attempted an owner-gated mutation (e.g. editing a post they
        do not own). Distinct from [Validation_error] so callers can map it
        to a 403-class rejection rather than a generic input error. *)
  | Recipient_lookup_failed of string
    (** The declared-recipient lookup could not answer for a name in the
        text: a Keeper's settings could not be read, or two Keepers claim one
        alias. The write is refused and nothing is stored. *)
[@@deriving show]

(** Reads that require a complete source distinguish unavailable data from
    an invalid or absent ID. *)
type board_read_error =
  | Read_invalid_id of string
  | Read_post_not_found of string
  | Read_comment_not_found of string
  | Read_source_unavailable of board_error
      (** A required source cannot establish the requested row or complete list. *)
[@@deriving show]

val board_error_of_read_error : board_read_error -> board_error
(** Public-safe projection for callers carrying reads and writes in one
    [board_error] result. Source failures become a fixed [Io_error] message;
    raw parser fragments, paths and exceptions remain in the internal read
    error and source diagnostics, never in this public error. *)

(** {1 Safe ID Modules — Parse, Don't Validate} *)

(* The shared alphanumeric regex [^[a-zA-Z0-9_-]+$] is not exported.
   [Post_id] and [Sub_board_id] apply it and hand back a parsed value; a
   caller holding the raw regex could validate without parsing, which is the
   split those modules exist to remove. [Comment_id] carries its own, stricter
   shape.

   The doc this replaces named [Board_id] and [Board_attachment_meta.Id], which
   do not use it. *)

module Post_id : sig
  type t
  val of_string : string -> (t, board_error) result
  (** Validates [a-zA-Z0-9_-]+, length 1–64. *)
  val of_string_for_read : string -> (t, board_read_error) result
  (** The same parse, answered as a read error. *)
  val to_string : t -> string
  val generate : unit -> t
  (** Cryptographic random id, prefix ["p-"]. *)
  val json_schema_pattern : string
  (** The [of_string] shape as a JSON Schema pattern. It mirrors the parser
      exactly, so it never rejects an id [of_string] accepts. *)
end

module Comment_id : sig
  type t
  val of_string : string -> (t, board_error) result
  (** Accepts exactly the shape {!generate} mints: ["c-"] followed by 32
      lowercase hex characters (trimmed). Anything else is [Invalid_id] with
      {!accepted_format} in the message. *)
  val of_string_for_read : string -> (t, board_read_error) result
  (** The same parse, answered as a read error. *)
  val to_string : t -> string
  val generate : unit -> t
  (** Cryptographic random id, prefix ["c-"], 16 random bytes as 32 hex
      characters. *)
  val accepted_format : string
  (** Human-readable shape for error messages and tool descriptions. *)
  val json_schema_pattern : string
  (** The same shape as a JSON Schema [pattern] regex, for tool input
      schemas that take a comment id. *)
end

module Deletion_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
  val generate : unit -> t
  (** One decision identity: [d-] and 32 lowercase hexadecimal characters. *)
end

module Agent_id : sig
  type t
  val parse : string -> (t, board_error) result
  (** Pure parsing of a trimmed Board identity, using {!Validation.Id_shape.parse}.
      Rejected prose candidates do not emit validation diagnostics. *)
  val of_string : string -> (t, board_error) result
  (** Validates [a-zA-Z0-9._-]+(:[a-zA-Z0-9._-]+)?, length 1–64.
      Trims input, delegates to {!Validation.Id_shape.validate}, and records
      rejections. Use at external author or actor input boundaries. *)
  val to_string : t -> string
end

(** {1 Visibility & Post Kinds} *)

type visibility =
  | Public      (** Visible to federation. *)
  | Unlisted    (** Not in feeds, but accessible. *)
  | Internal    (** This MASC instance only. *)
  | Direct      (** Mentioned agents only. *)

type audience =
  | Targets of Agent_id.t list
  | Broadcast
  | Thread_participants
  | Discoverable
(** Closed Board routing authority. Target identities remain Board-level
    {!Agent_id.t}; no Keeper dependency crosses into this library. *)

type post_kind =
  | Human_post
  | Automation_post
  | System_post
[@@deriving tla]

(** {1 Records — Mandatory TTL} *)

(** RFC-0233 §7: typed provenance of a board post — which keeper turn produced
    it and through which channel.  [source] is the channel's
    [Surface_ref.lane_label] string (not the typed [Surface_ref.t], which lives
    in the [masc] umbrella that depends on [masc_board]).  [turn_ref] and
    [fusion_run_id] are distinct (RFC §7.6 guard #5).  Fusion run identity requires its original producer; other sub-fields are optional;
    an all-[None] origin is represented as [origin = None]. *)
type post_origin = {
  turn_ref : Ids.Turn_ref.t option;
  source : string option;
  fusion_run_id : string option;
  fusion_producer : string option;
  (** Actual Fusion caller, immutable with the origin even when post.author changes. *)
}

val keeper_authored_origin :
  ?turn_ref:Ids.Turn_ref.t -> source:string -> unit -> post_origin
(** RFC-0233 §7: build the [origin] of a keeper-authored board post.
    [fusion_run_id] is always [None] (fusion has its own origin at the sink);
    [source] names the producing channel; [turn_ref] is the turn-level join key
    and is [None] only when no mint-once-safe reference is reachable. *)

type post_close_state = {
  closed_by : Agent_id.t;
  (** Who closed the post: the author, the operator, or a configured
      moderator. Reopening replaces this with [None]; it does not mutate
      the record in place. *)
  closed_at : float;
  successor_id : Post_id.t option;
  (** The post that continues this thread, when the closer names one. A
      reader following a closed thread lands here instead of a dead end. *)
  summary : string option;
  (** Why the thread closed / where it continues, for a reader who was not
      there when it happened. *)
}

(** Replaced in [posts], never changed in place: a snapshot reuses the row
    it rendered while the table holds the same physical post, so a field
    that could change in place would leave that row stale. *)
type post = {
  id : Post_id.t;
  author : Agent_id.t;
  title : string;
  body : string;
  post_kind : post_kind;
  meta_json : Yojson.Safe.t option;
  visibility : visibility;
  audience : audience option;
  (** Persisted write-boundary audience. [None] grants no recipient access. *)
  created_at : float;
  content_updated_at: float; (* Last title, body or author change. *)
  updated_at : float;
  expires_at : float;
  votes_up : int;
  votes_down : int;
  reply_count : int;
  pinned : bool;
  hearth : string option;
  thread_id : string option;
  origin : post_origin option;
  closed : post_close_state option;
  (** [None] means open (the default for every post minted before this
      field existed, and for every open post since). A row stored without
      this key decodes to [None]; the key is only ever written when the
      post is actually closed. *)
}

(** Replaced in [comments], never changed in place, as [post] is. *)
type comment = {
  id : Comment_id.t;
  post_id : Post_id.t;
  parent_id : Comment_id.t option;
  author : Agent_id.t;
  content : string;
  audience : audience option;
  (** Persisted write-boundary audience. [None] grants no recipient access. *)
  created_at : float;
  expires_at : float;
  votes_up : int;
  votes_down : int;
}

type source_completeness =
  | Source_complete
  | Source_incomplete of board_error

type comments_observation = {
  comments : comment list;
  completeness : source_completeness;
}
(** Rows and source status captured together under persistence then state
    locks. Incomplete rows remain available for display; neither their absence
    nor their count establishes the contents of the complete thread. *)

type post_creation = {
  post : post;
  audience : audience;
  unresolved : string list;
}
(** Successful post write together with the audience fixed at the same write
    boundary. Consumers must not re-derive routing from mutable projections.
    [unresolved] holds the names in the text that looked like addresses but
    no Keeper declares, as the author wrote them. It is for the write
    response only and is never stored. *)

type comment_creation = {
  comment : comment;
  audience : audience;
  unresolved : string list;
}
(** Successful comment write and its write-boundary routing authority.
    [unresolved] is as in {!post_creation}. *)

type reaction_target_type =
  | Reaction_post
  | Reaction_comment

type reaction = {
  target_type : reaction_target_type;
  target_id : string;
  user_id : Agent_id.t;
  emoji : string;
  created_at : float;
}

type reaction_summary = {
  emoji : string;
  count : int;
  reacted : bool;
  recent_user_ids : string list;
}

type reaction_toggle_result = {
  post_id : Post_id.t; (** Canonical parent admitted for this exact write. *)
  target_type : reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
  summary : reaction_summary list;
}

(** {1 SubBoard — Named spaces within the board} *)

module Sub_board_id : sig
  type t
  val of_string : string -> (t, board_error) result
  (** Validates [a-zA-Z0-9_-]+, length 1–64. *)
  val to_string : t -> string
  val generate : unit -> t
  (** Cryptographic random id, prefix ["sb-"]. *)
end

type sub_board_access =
  | Open          (** Anyone can post and read. *)
  | Members_only  (** Only listed members can post; anyone can read. *)
  | Owner_only    (** Only the owner can post; anyone can read. *)
[@@deriving enumerate]

type sub_board = {
  id : Sub_board_id.t;
  slug : string;
  (** URL-safe lowercase identifier, e.g. ["announcements"]. *)
  name : string;
  description : string;
  owner : Agent_id.t;
  members : Agent_id.t list;
  (** Agents allowed to post when [access = Members_only].  The owner is
      always included. *)
  access : sub_board_access;
  created_at : float;
  post_count : int;
}

(** {1 Read pagination and sweeper defaults} *)

module Limits : sig
  val default_comment_page_limit : int
  (** Default number of comments returned by [masc_board_post_get] when the
      caller names no page: the newest comments, since a reader that does not
      know the thread yet wants its tail. *)
  val max_comment_page_limit : int
  (** Maximum comments returned by one [masc_board_post_get] page. *)
  val default_ttl_hours : int
  (** [0] — permanent (no expiry). *)
  val sweeper_interval_sec : int
  val sweeper_batch_size : int
  val comment_count_cap : int
  (** Once a post holds this many comments, the next comment is refused
      with a successor hint ([#39356] scope extension). The count is the
      live per-post comment list at the moment of the check, so expired
      comments free slots again. [MASC_BOARD_COMMENT_COUNT_CAP] overrides
      the default of 100. A value [<= 0] is an explicit opt-out: the cap
      check is skipped and threads grow without limit. *)
  val cap_warning_message : cap:int -> unit -> string option
  (** [None] when [cap > 0]; otherwise [Some message] naming
      [MASC_BOARD_COMMENT_COUNT_CAP] and the value read, so the opt-out is
      recorded at load instead of silently doing nothing
      (issuecomment-5858752752). Pure: takes the parsed value, touches
      nothing else. *)
end

(** {1 Comment pages}

    The one place a comment thread is cut into pages. [masc_board_post_get]
    and the verifier's read of a submitted Board snapshot both page through
    it, so an offset means the same thing on either surface. *)
module Comment_page : sig
  (** Where a page starts. [From_offset] counts from the oldest comment;
      [Latest] is the page that ends at the newest comment; [After_comment]
      starts right after the named comment, wherever it sits on this read. *)
  type start =
    | From_offset of int
    | Latest
    | After_comment of Comment_id.t

  type request = private
    { start : start
    ; limit : int
    }
  (** Built only by {!request_of_args}: a [From_offset] is [>= 0] and
      [1 <= limit <= Limits.max_comment_page_limit]. For [Latest], [limit] is
      the [comment_tail] count, or {!Limits.default_comment_page_limit} when
      the caller named no page at all; a [comment_tail] of [0] gives a
      [Latest] request with [limit = 0], an empty page beside the post body. *)

  type argument =
    | Comment_offset
    | Comment_limit
    | Comment_tail
    | After_comment_id

  type request_error =
    | Arguments_not_an_object
    | Not_an_integer of
        { argument : argument
        ; given : string
          (** The JSON kind that arrived, as {!Json_util.kind_name} names it. *)
        }
    | Integer_out_of_range of
        { argument : argument
        ; literal : string
        }
    | Not_a_string of
        { argument : argument
        ; given : string
        }
    | Not_a_comment_id of string
        (** [after_comment_id] is not in the shape {!Comment_id} mints. *)
    | Negative_offset of int
    | Limit_out_of_bounds of int
    | Tail_out_of_bounds of int
    | Conflicting_arguments of
        { given : argument
        ; conflicts_with : argument
        }
        (** Two arguments that each say where the page starts, or
            [comment_tail] beside [comment_limit]. Neither wins. *)

  val request_of_args : Yojson.Safe.t -> (request, request_error) result
  (** Reads [comment_offset], [comment_limit] (absent:
      {!Limits.default_comment_page_limit}), [comment_tail] and
      [after_comment_id] from a tool call's arguments. With none of the three
      start arguments the page starts at the newest comment ([Latest]); an
      explicit [comment_offset] (including [0]) starts at that offset, so the
      head of a thread is read with [comment_offset=0]. A count or offset that
      is present but is not a JSON integer is refused, so [null], ["abc"],
      [true] and [2.9] never turn into a page; [after_comment_id] must be a
      string in the shape {!Comment_id} mints. [comment_tail] goes alone;
      [after_comment_id] takes a [comment_limit] and no [comment_offset]. *)

  val request_error_to_string : request_error -> string

  type 'a page =
    { offset : int
    ; items : 'a list
    ; total : int
    ; next_offset : int option
      (** [None] when [items] reaches the last comment. *)
    }

  type 'a t =
    | Page of 'a page
    | Offset_out_of_range of
        { requested : int
        ; total : int
        }
        (** [requested] is past the end of the thread. Offset [total] is the
            end itself: a [Page] with no items whose {!Position.line} names
            [total], so it is never mistaken for a thread without comments.
            Nothing past it is clamped to it. Offsets are positions in the
            thread as it is at the read; a sweep that removes comments moves
            every later one down, at the end as anywhere else. *)
    | Comment_not_found of
        { comment_id : Comment_id.t
        ; total : int
        }
        (** No comment of this thread has the [After_comment] id: it was
            never here, or a sweep removed it. *)

  val select
    :  ?fits:('a page -> bool)
    -> comment_id_of:('a -> string option)
    -> request
    -> 'a list
    -> 'a t
  (** At most [limit] items from where [request] starts: the longest page
      [fits] accepts, [next_offset] included, found by halving ([fits]
      defaults to accepting every page). [comment_id_of] names an item's
      comment id for an [After_comment] start. A [Latest] page ends at the
      last item, so the budget trims its oldest items; a page from any other
      start is trimmed at its end. A page never stops before its first item:
      an item larger than the budget is delivered whole and the tool-output
      boundary decides how it travels, so no comment becomes unreadable.
      Every page returned is one [fits] accepted; the halving finds the
      longest such page when [fits] stays false once it turns false, which a
      page whose size grows with each item satisfies. A page read forward
      grows with each item. A [Latest] page need not: an older item added to
      it can be the parent of replies already on it, and a reply printed under
      its parent is shorter than one that names it. Such a page may then hold
      fewer items than would fit, never more. *)

  (** Where a page sits in its thread. Both reading surfaces return it, and a
      caller reads it back without parsing the page's text. *)
  module Position : sig
    type t =
      { offset : int
      ; returned : int
      ; total : int
      ; next_offset : int option
      }

    val of_page : 'a page -> t

    val to_yojson : t -> Yojson.Safe.t
    (** [{offset, returned, total, has_more, next_offset}]; [next_offset] is
        [null] on the last page. *)

    val of_yojson : Yojson.Safe.t -> t option
    (** Total decoder: [None] for anything this module did not write. *)

    val line : t -> string
    (** The one line a text page carries, naming its range, a forward
        [comment_offset] when present, and the preceding non-overlapping
        [comment_offset]/[comment_limit] when older comments exist. A page at
        the end of a non-empty thread names the thread's size at the read.
        Every text rendering of a page uses this printer. *)

    val metadata_key : string
    (** ["masc.comment_page"]. *)

    val to_metadata : t -> Yojson.Safe.t
    (** The metadata object carrying the position under {!metadata_key}, for a
        handler with no other metadata to merge. A tool result's text is for
        the model; this rides beside it for a caller that continues the read. *)

    val of_metadata : Yojson.Safe.t option -> t option
    (** The position in a result's metadata: [None] for absent metadata, an
        absent key, or a value this module did not write. *)
  end
end

(** {1 Vote Direction} *)

type vote_direction = Up | Down

(** {1 Incremental Hot-Post & Recent-Post Indexes} *)

type hot_post_key =
  { net_vote : int
  ; created_at : float
  ; post_id : string
  }

val hot_post_key_of_post : post -> hot_post_key
val compare_hot_post_key : hot_post_key -> hot_post_key -> int

module Hot_post_set : Set.S with type elt = hot_post_key

type recent_post_key =
  { recent_created_at : float
  ; recent_post_id : string
  }

val recent_post_key_of_post : post -> recent_post_key
val compare_recent_post_key : recent_post_key -> recent_post_key -> int

module Recent_post_set : Set.S with type elt = recent_post_key

(** {1 In-Memory Store} *)

type flusher_msg =
  | Flush
  | Sweep

type posts_source_observation = {
  source_path : string;
  snapshot : Fs_compat.private_jsonl_snapshot;
  workspace_observation : Board_workspace_binding.observation;
}

type posts_source_history =
  | No_observation
  | Posts_observed of posts_source_observation

type posts_row_error =
  | Invalid_posts_json of { line : int; detail : string }
  | Invalid_posts_row of { line : int }

type posts_source_file = Posts_file

type posts_source_stage =
  | Read_posts | Decode_posts | Encode_posts
  | Write_posts | Project_posts | Report_source

type posts_source_diagnostic =
  | File_diagnostic of {
      file : posts_source_file;
      error : Fs_compat.private_jsonl_transaction_error;
    }
  | Workspace_diagnostic of Board_workspace_binding.rejection
  | Posts_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Raised_diagnostic of {
      stage : posts_source_stage;
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
(** One chronological trace for the current operation. Transaction entries
    retain their original primary/cleanup order; prior operations are not replayed. *)

type posts_source_failure =
  | Posts_not_observed
  | Posts_rows_rejected of posts_row_error list
  | Posts_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Posts_missing
  | Posts_source_binding_mismatch
  | Posts_policy_source_is_posts_source
  | Posts_snapshot_stale
  | Posts_workspace_binding_refused of Board_workspace_binding.rejection
  | Posts_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type posts_unsettled_write_kind =
  | Append_write
  | Rewrite_write
(** How the unknown write attempted to publish [intended_bytes]: appended
    after [expected]'s cursor, or a full-file replacement of it. *)

type posts_unsettled_write = {
  expected : posts_source_observation;
  kind : posts_unsettled_write_kind;
  intended_bytes : string;
}
(** Settlement evidence retained when a write outcome is unknown. [expected]
    is the pre-write observation the write was issued against, and
    [intended_bytes] is the exact full-file content the write attempted to
    publish. A nonwrite verdict must consult the recorded transaction
    failure together with both [expected]'s bytes and [intended_bytes];
    comparing current bytes against one earlier snapshot alone cannot rule
    out a late completion from a cancelled call's worker. *)

type posts_source_state =
  | Posts_unobserved
  | Posts_readable of {
      observation : posts_source_observation;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_refused of {
      last_observed : posts_source_history;
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_unsettled of {
      last_observed : posts_source_history;
      failure : posts_source_failure;
      pending : posts_unsettled_write;
      diagnostics : posts_source_diagnostic list;
    }

type posts_write_outcome =
  | Posts_written of { diagnostics : posts_source_diagnostic list }
  | Posts_not_written of {
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_write_unknown of {
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }

type posts_source_read =
  | Posts_complete of {
      observation : posts_source_observation;
      posts : post list;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_partial of {
      observation : posts_source_observation;
      posts : post list;
      errors : posts_row_error list;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_unavailable of {
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }

type posts_source_io = {
  posts : Fs_compat.private_jsonl_transaction_io_for_testing option;
}
(** Immutable real-transaction seam for the posts file. None selects
    production IO. *)

type comments_source_observation = {
  source_path : string;
  snapshot : Fs_compat.private_jsonl_snapshot;
  workspace_observation : Board_workspace_binding.observation;
}

type comments_source_history =
  | No_comments_observation
  | Comments_observed of comments_source_observation
  | Comments_present_without_snapshot
(** A validated nonauthoritative read can prove Present without granting an
    exact snapshot for mutation. This still prevents later Missing from being
    treated as an uninitialized source. *)

type comments_row_error =
  | Invalid_comments_json of { line : int; detail : string }
  | Invalid_comments_row of { line : int }

type comments_source_stage =
  | Read_comments | Decode_comments | Encode_comments
  | Write_comments | Project_comments | Report_comments

type comments_source_diagnostic =
  | Comments_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Comments_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Comments_workspace_diagnostic of Board_workspace_binding.rejection
  | Comments_display_diagnostic of Fs_compat.Private_jsonl_unique_fold.error
  | Comments_display_cleanup_diagnostic of Fs_compat.private_jsonl_operation_failure
  | Comments_raised_diagnostic of {
      stage : comments_source_stage;
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }

type comments_source_failure =
  | Comments_not_observed
  | Comments_rows_rejected of comments_row_error list
  | Comments_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Comments_missing
  | Comments_source_binding_mismatch
  | Comments_snapshot_stale
  | Comments_publication_pending
  | Comments_reload_required
  | Comments_workspace_refused of Board_workspace_binding.rejection
  | Comments_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type comments_write_kind = Comments_append | Comments_rewrite

type comments_unsettled_write = {
  expected : comments_source_observation;
  kind : comments_write_kind;
  intended_bytes : string;
}

type comments_recovery_receipt = {
  interrupted : comments_unsettled_write;
  prior_failure : comments_source_failure;
  fence : comments_source_observation;
  diagnostics : comments_source_diagnostic list;
}
(** Explicit storage recovery superseded an interrupted attempt. This is not
    a verdict that the original operation was written or not written. *)

type comments_publication = {
  observation : comments_source_observation;
  diagnostics : comments_source_diagnostic list;
}
(** The actual successful append receipt, retained before model publication.
    Only its owning store may acknowledge it after a normal publication or
    after recording the exact appended row's rejected-publication cleanup. *)

type comments_source_state =
  | Comments_unobserved
  | Comments_readable of comments_publication
  | Comments_publishing of comments_publication
  | Comments_recovered of comments_recovery_receipt
  (** Completed recovery, retained before finishing can raise. Repeated settle
      returns this same receipt without IO or replaying historical exceptions;
      acknowledge it explicitly before a full model reload. *)
  | Comments_refused of {
      last_observed : comments_source_history;
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
  | Comments_unsettled of {
      pending : comments_unsettled_write;
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
(** [No_comments_observation] means this store has never observed this source.
    A first observed Missing source is legitimate empty input;
    losing a source this store observed Present is refused. This lifetime
    evidence does not prove absence across different processes. *)

type sub_boards_source_observation = {
  policy_path : string;
  policy_snapshot : Fs_compat.private_jsonl_snapshot;
  policy_workspace : Board_workspace_binding.observation;
}

type sub_boards_source_history =
  | No_policy_observation
  | Policy_observed of sub_boards_source_observation
  | Policy_present_without_snapshot

type sub_boards_row_error =
  | Invalid_policy_json of { line : int; detail : string }
  | Invalid_policy_row of { line : int }

type sub_boards_source_diagnostic =
  | Policy_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Policy_workspace_diagnostic of Board_workspace_binding.rejection
  | Policy_raised_diagnostic of {
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }

type sub_boards_source_failure =
  | Policy_not_observed
  | Policy_rows_rejected of sub_boards_row_error list
  | Policy_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Policy_missing
  | Policy_binding_mismatch
  | Policy_publication_pending
  | Policy_workspace_refused of Board_workspace_binding.rejection
  | Policy_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type sub_boards_write_kind = Policy_append | Policy_rewrite

type sub_boards_pending_write = {
  policy_before : sub_boards_source_observation;
  policy_kind : sub_boards_write_kind;
  policy_intended_bytes : string;
}

type sub_boards_publication = {
  policy_after : sub_boards_source_observation;
  policy_cleanup : sub_boards_source_diagnostic list;
}

type sub_boards_source_state =
  | Policy_unobserved
  | Policy_readable of sub_boards_source_observation
  | Policy_publishing of sub_boards_publication
  | Policy_refused of {
      policy_history : sub_boards_source_history;
      policy_failure : sub_boards_source_failure;
      policy_diagnostics : sub_boards_source_diagnostic list;
    }
  | Policy_unsettled of {
      policy_pending : sub_boards_pending_write;
      policy_failure : sub_boards_source_failure;
      policy_diagnostics : sub_boards_source_diagnostic list;
    }
(** Policy authority belongs to persist_mutex. Unknown writes and interrupted
    model publication remain fail-stop for this store, with the exact pending
    bytes or known-success receipt retained. Only a fresh store can reload
    them. This is not multi-source crash recovery; see #26378. *)

type reactions_source_observation = {
  reaction_path : string;
  reaction_snapshot : Fs_compat.private_jsonl_snapshot;
  reaction_workspace : Board_workspace_binding.observation;
}

type reactions_source_history =
  | No_reactions_observation
  | Reactions_observed of reactions_source_observation
  | Reactions_present_without_snapshot

type reactions_row_error =
  | Invalid_reaction_json of { line : int; detail : string }
  | Invalid_reaction_row of { line : int }

type reactions_source_diagnostic =
  | Reaction_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Reaction_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Reaction_workspace_diagnostic of Board_workspace_binding.rejection
  | Reaction_raised_diagnostic of {
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
  | Reaction_projection_diagnostic of board_error

type reactions_source_failure =
  | Reactions_not_observed
  | Reactions_rows_rejected of reactions_row_error list
  | Reactions_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Reactions_missing
  | Reactions_binding_mismatch
  | Reactions_publication_pending
  | Reactions_workspace_refused of Board_workspace_binding.rejection
  | Reactions_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type reactions_pending_write = {
  reaction_before : reactions_source_observation;
  reaction_intended_bytes : string;
}

type reactions_publication = {
  reaction_after : reactions_source_observation;
  reaction_cleanup : reactions_source_diagnostic list;
}

type reactions_source_state =
  | Reactions_unobserved
  | Reactions_readable of reactions_source_observation
  | Reactions_publishing of reactions_publication
  | Reactions_refused of {
      reaction_history : reactions_source_history;
      reaction_failure : reactions_source_failure;
      reaction_diagnostics : reactions_source_diagnostic list;
    }
  | Reactions_unsettled of {
      reaction_pending : reactions_pending_write;
      reaction_failure : reactions_source_failure;
      reaction_diagnostics : reactions_source_diagnostic list;
    }
(** Reaction authority belongs to persist_mutex. Known file success remains owned
    until model publication is acknowledged. Unknown writes and unfinished
    publication require a fresh store; an ordinary reload cannot clear them. *)


type deletion_outcome =
  | Durable_deletion
  | Deletion_decision_pending of string
  | Deletion_persistence_pending of string
(** Decision_pending does not establish model application. Persistence_pending
    does; neither authorizes replay or claims durable completion. *)

type sub_board_deletion_authorization =
  | Operator_sub_board_deletion
  | Owner_sub_board_deletion of Agent_id.t
(** Authority supplied by the calling boundary, never decoded from a marker. *)

type deletion_operation =
  | Delete_post of {
      deleted_post : Post_id.t;
      deleted_comments : Comment_id.t list;
    }
  | Delete_sub_board of {
      deleted_sub_board : Sub_board_id.t;
      deleted_slug : string;
      unlinked_posts : Post_id.t list;
    }

type deletion_plan = {
  decision_id : Deletion_id.t;
  operation : deletion_operation;
}
(** Fixed original identities. Recovery never expands the selected children or
    posts by looking up a slug again. Later boards and posts remain outside it. *)

type deletion_observation = {
  decision_path : string;
  decision_snapshot : Fs_compat.private_jsonl_snapshot;
  decision_workspace : Board_workspace_binding.observation;
}

type deletion_diagnostic =
  | Deletion_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Deletion_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Deletion_workspace_diagnostic of Board_workspace_binding.rejection
  | Deletion_raised_diagnostic of {
      exception_ : exn; backtrace : Printexc.raw_backtrace;
    }

type deletion_failure =
  | Deletion_invalid_decision of string
  | Deletion_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Deletion_workspace_refused of Board_workspace_binding.rejection
  | Deletion_marker_missing
  | Deletion_binding_mismatch
  | Deletion_projection_rejected of board_error
  | Deletion_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type deletion_receipt = {
  decision : deletion_plan;
  decision_after : deletion_observation;
  decision_cleanup : deletion_diagnostic list;
}
(** Known durable marker publication, retained before any model change. *)

type deletion_progress =
  | Decision_recorded
  | Model_applied
  | Sources_uncertain
  | Sources_written
(** Sources_uncertain retains an unknown source effect and requires fresh-store
    recovery. Same-store reload and ordinary flush do not replay that effect.
    Sources_written means all sources selected by the recorded operation have
    known durable receipts: four for a post, Posts and Policy for a sub-board. *)

type deletion_work = {
  decision_receipt : deletion_receipt;
  deletion_progress : deletion_progress;
  deletion_last_failure : deletion_failure option;
  deletion_diagnostics : deletion_diagnostic list;
}

type deletion_attempt =
  | Recording_decision of deletion_plan
  | Retiring_decision of deletion_receipt

type deletion_state =
  | Deletion_unobserved
  | Deletion_readable of {
      observation : deletion_observation;
      plan : deletion_plan option;
      diagnostics : deletion_diagnostic list;
    }
  | Deletion_pending of deletion_work
  | Deletion_unsettled of {
      before : deletion_observation;
      attempt : deletion_attempt;
      intended_bytes : string;
      failure : deletion_failure;
      diagnostics : deletion_diagnostic list;
    }
  | Deletion_refused of {
      last_observed : deletion_observation option;
      failure : deletion_failure;
      diagnostics : deletion_diagnostic list;
    }
  | Deletion_projection_failed of {
      receipt : deletion_receipt;
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
(** Sole deletion owner under persist_mutex. Ordinary flush/reload cannot settle
    an unknown record/retirement or an exceptional model publication. A fresh
    initializer durably fences an observed decision before applying its fixed
    IDs to fresh complete models. All selected known writes precede retirement. *)

type votes_source_observation = {
  vote_path : string;
  vote_snapshot : Fs_compat.private_jsonl_snapshot;
  vote_workspace : Board_workspace_binding.observation;
}

type votes_source_history =
  | No_votes_observation
  | Votes_observed of votes_source_observation
  | Votes_present_without_snapshot

type votes_row_error =
  | Invalid_vote_json of { line : int; detail : string }
  | Invalid_vote_row of { line : int }

type votes_source_diagnostic =
  | Vote_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Vote_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Vote_workspace_diagnostic of Board_workspace_binding.rejection
  | Vote_raised_diagnostic of {
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
  | Vote_projection_diagnostic of board_error

type votes_source_failure =
  | Votes_not_observed
  | Votes_rows_rejected of votes_row_error list
  | Votes_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Votes_missing
  | Votes_binding_mismatch
  | Votes_publication_pending
  | Votes_workspace_refused of Board_workspace_binding.rejection
  | Votes_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type votes_write_kind = Vote_append | Vote_rewrite

type votes_pending_write = {
  vote_before : votes_source_observation;
  vote_kind : votes_write_kind;
  vote_intended_bytes : string;
}

type votes_publication = {
  vote_after : votes_source_observation;
  vote_cleanup : votes_source_diagnostic list;
}

type votes_source_state =
  | Votes_unobserved
  | Votes_readable of votes_source_observation
  | Votes_publishing of votes_publication
  | Votes_refused of {
      vote_history : votes_source_history;
      vote_failure : votes_source_failure;
      vote_diagnostics : votes_source_diagnostic list;
    }
  | Votes_unsettled of {
      vote_pending : votes_pending_write;
      vote_failure : votes_source_failure;
      vote_diagnostics : votes_source_diagnostic list;
    }
(** Vote authority belongs to persist_mutex. Known file success remains owned
    until model publication is acknowledged. Unknown writes and unfinished
    publication require a fresh store; an ordinary reload cannot clear them. *)

type store = {
  (** Canonical posts observation/refusal/uncertainty, owned by persist_mutex.
      Successful loads and writes advance it; dirty cards need not equal its bytes. *)
  mutable posts_source : posts_source_state;
  posts_source_io : posts_source_io;
  (** Comments' source, uncertainty and unfinished model publication are owned
      by persist_mutex; no separate load-success flag grants authority. *)
  mutable comments_source : comments_source_state;
  comments_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  (** None selects production comments IO. *)
  mutable sub_boards_source : sub_boards_source_state;
  sub_boards_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  (** Vote-file observation and unfinished effects are owned by persist_mutex. *)
  mutable votes_source : votes_source_state;
  votes_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  (** None selects production vote-file IO. *)
  mutable reactions_source : reactions_source_state;
  reactions_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  deletion_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  mutable workspace_binding : Board_workspace_binding.t;
  (** One explicit BasePath capture attempt, refined with actual Present
      state-directory observations under persist_mutex or quiescent loading.
      Each binding value is immutable; refinement cannot heal a failed capture.
      Path projection creates nothing and grants no loaded-source authority. *)
  posts : (string, post) Hashtbl.t;
  comments : (string, comment) Hashtbl.t;
  vote_log : (string, vote_direction * float) Hashtbl.t;
  (** #10086: value carries [(direction, cast_ts)] so the rewriter
      preserves the original cast time on every flush. *)
  post_count : int ref;
  mutable last_sweep : float;
  mutex : Eio.Mutex.t;
  persist_mutex : Eio.Mutex.t;
  origin_create_mutex : Eio.Mutex.t;
  mutable karma_cache : ((string * int) list * (string * (string * int) list) list) option;
  (** [None] = stale. *)
  mutable hot_post_index : Hot_post_set.t;
  (** Incremental immutable Hot-ordered index ([net_vote DESC, created_at DESC, post_id ASC]). *)
  mutable recent_post_index : Recent_post_set.t;
  (** Incremental immutable Recent-ordered index ([created_at DESC, post_id ASC]). *)
  comments_by_post : (string, string list) Hashtbl.t;
  (** post_id -> comment_id list. *)
  reactions : (string, reaction) Hashtbl.t;
  (** Unique reactions keyed by target type, target id, user id, and emoji. *)
  mutable dirty_posts : bool;
  mutable dirty_comments : bool;
  mutable deletion_state : deletion_state;
  dirty_post_ids : (string, unit) Hashtbl.t;
  dirty_comment_ids : (string, unit) Hashtbl.t;
  post_rows : (string, post * string) Hashtbl.t;
  (** post_id -> the post last rendered into a snapshot and its JSONL row.
      Posts are replaced in [posts], never changed in place, so a row kept
      with the same physical post is still that post's row. Only the
      snapshot writers read or change it, under [mutex]. *)
  comment_rows : (string, comment * string) Hashtbl.t;
  (** The same for [comments]. *)
  mutable last_flush : float;
  flusher_inbox : flusher_msg Eio.Stream.t;
  sub_boards : (string, sub_board) Hashtbl.t;
  (** Sub-board id -> sub_board record. *)
  sub_boards_by_slug : (string, string) Hashtbl.t;
  (** slug -> sub_board id index for O(1) slug lookup. *)
  posts_by_turn_ref : (string, string) Hashtbl.t;
  (** RFC-0233 §7: [Ids.Turn_ref.to_string] -> post id. Maintained on
      create, rebuilt on load. *)
  posts_by_run_id : (string, string) Hashtbl.t;
  (** RFC-0233 §7: fusion run_id -> post id. Maintained on create, rebuilt
      on load. *)
}
