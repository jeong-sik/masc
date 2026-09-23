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
[@@deriving show]

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
  val to_string : t -> string
  val generate : unit -> t
  (** Cryptographic random id, prefix ["p-"]. *)
end

module Comment_id : sig
  type t
  val of_string : string -> (t, board_error) result
  (** Accepts exactly the shape {!generate} mints: ["c-"] followed by 32
      lowercase hex characters (trimmed). Anything else is [Invalid_id] with
      {!accepted_format} in the message. *)
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

type post = {
  id : Post_id.t;
  author : Agent_id.t;
  title : string;
  body : string;
  post_kind : post_kind;
  meta_json : Yojson.Safe.t option;
  visibility : visibility;
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
}

type comment = {
  id : Comment_id.t;
  post_id : Post_id.t;
  parent_id : Comment_id.t option;
  author : Agent_id.t;
  content : string;
  created_at : float;
  expires_at : float;
  votes_up : int;
  votes_down : int;
}

type post_creation = {
  post : post;
  audience : audience;
}
(** Successful post write together with the audience fixed at the same write
    boundary. Consumers must not re-derive routing from mutable projections. *)

type comment_creation = {
  comment : comment;
  audience : audience;
}
(** Successful comment write and its write-boundary routing authority. *)

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
  (** Default number of comments returned by [masc_board_post_get]. *)
  val max_comment_page_limit : int
  (** Maximum comments returned by one [masc_board_post_get] page. *)
  val default_ttl_hours : int
  (** [0] — permanent (no expiry). *)
  val sweeper_interval_sec : int
  val sweeper_batch_size : int
end

(** {1 Comment pages}

    The one place a comment thread is cut into pages. [masc_board_post_get]
    and the verifier's read of a submitted Board snapshot both page through
    it, so an offset means the same thing on either surface. *)
module Comment_page : sig
  type request = private
    { offset : int
    ; limit : int
    }
  (** Built only by {!request_of_args}: [offset >= 0] and
      [1 <= limit <= Limits.max_comment_page_limit]. *)

  type argument =
    | Comment_offset
    | Comment_limit

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
    | Negative_offset of int
    | Limit_out_of_bounds of int

  val request_of_args : Yojson.Safe.t -> (request, request_error) result
  (** Reads [comment_offset] (absent: [0]) and [comment_limit] (absent:
      {!Limits.default_comment_page_limit}) from a tool call's arguments. A
      value that is present but is not a JSON integer literal is refused, so
      [null], ["abc"], [true] and [2.9] never turn into a page. *)

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
        (** [requested] names no comment. Offset [0] of an empty thread is a
            [Page] with no items; every other offset at or past [total] is
            this case, so an empty page is never mistaken for a thread that
            lost its comments. *)

  val select : ?fits:('a page -> bool) -> request -> 'a list -> 'a t
  (** Items from [offset], at most [limit] of them: the longest page [fits]
      accepts, [next_offset] included, found by halving ([fits] defaults to
      accepting every page). A page never stops before its first item: an item
      larger than the budget is delivered whole and the tool-output boundary
      decides how it travels, so no comment becomes unreadable. Every page
      returned is one [fits] accepted; the halving finds the longest such page
      when [fits] stays false once it turns false, which a page whose size
      grows with each item satisfies. *)

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
    (** The one line a text page carries, naming the range it holds and the
        [comment_offset] that continues it. Every text rendering of a page
        uses this printer, so the sentence cannot drift between surfaces. *)

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

(** {1 Karma Ledger Contract} *)

(** A single attributed karma event.  One event is generated per upvote
    received by an agent.  Downvotes do not generate karma events
    (scoring rule: [Up] = +1, [Down] = 0). *)
type karma_event = {
  recipient : string;
  (** Agent who earned the karma — author of the upvoted post or comment. *)
  voter : string;
  (** Agent who cast the upvote. *)
  target_kind : string;
  (** Content kind: ["post"] or ["comment"]. *)
  target_id : string;
  (** Identifier of the upvoted post or comment. *)
  delta : int;
  (** Karma delta.  Always [+1] per upvote under the current scoring
      contract.  Stored explicitly so future rule changes are backward
      compatible — older events keep their original delta value. *)
  ts : float;
  (** Unix timestamp at which the upvote was cast (seconds since epoch). *)
}

(** {1 In-Memory Store} *)

type flusher_msg =
  | Flush
  | Sweep

type store = {
  (** Derived last full-load outcomes; never persisted as another authority.
      A failed snapshot read blocks mutations that could rewrite that source. *)
  mutable posts_load_result : (unit, string) result;
  mutable comments_load_result : (unit, string) result;
  mutable votes_load_result : (unit, string) result;
  mutable reactions_load_result : (unit, string) result;
  mutable sub_boards_load_result : (unit, string) result;
  workspace_masc_dir : string option;
  (** Canonical workspace directory captured before the global store is loaded.
      Unlike environment-derived path helpers, this identity does not change
      when a later config resolution selects another workspace. [None] denotes
      a standalone in-memory store with no workspace review authority. *)
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
  mutable karma_cache : (string * int) list option;
  (** [None] = stale. *)
  mutable sorted_posts_cache : post list option;
  (** [None] = stale. *)
  comments_by_post : (string, string list) Hashtbl.t;
  (** post_id -> comment_id list. *)
  reactions : (string, reaction) Hashtbl.t;
  (** Unique reactions keyed by target type, target id, user id, and emoji. *)
  mutable dirty_posts : bool;
  mutable dirty_comments : bool;
  dirty_post_ids : (string, unit) Hashtbl.t;
  dirty_comment_ids : (string, unit) Hashtbl.t;
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
