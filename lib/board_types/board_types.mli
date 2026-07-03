(** Board — MASC internal board (Mastodon-style federation ready).

    Type SSOT for the board subsystem. All public types are surfaced
    here; the implementations live in [board_core.ml] / [board.ml] /
    [board_dispatch.ml].

    Design properties (enforced by callers, documented for readers):
    - ID validation (no path traversal; see {!Post_id} / {!Comment_id})
    - TTL optional (0 = permanent, default)
    - Max limits enforced (no OOM; see {!Limits})
    - Cryptographic IDs (no prediction)
    - Atomic writes (no corruption)
    - Automatic sweeper (no manual cleanup)

    @since 0.5.0 — replaces social.ml with hardened implementation *)

(** {1 Error Types — No Silent Failures} *)

type board_error =
  | Invalid_id of string
  | Post_not_found of string
  | Comment_not_found of string
  | Rate_limited of { retry_after : float }
  | Capacity_exceeded of { current : int; max : int }
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

val alphanumeric_id_re : Re.re
(** Shared regex [^[a-zA-Z0-9_-]+$] for alphanumeric ID validation.
    Used by [Post_id], [Board_id], [Sub_board_id], and [Board_attachment_meta.Id]. *)

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
  (** Validates [a-zA-Z0-9_-]+, length 1–64. *)
  val to_string : t -> string
  val generate : unit -> t
  (** Cryptographic random id, prefix ["c-"]. *)
end

module Agent_id : sig
  type t
  val of_string : string -> (t, board_error) result
  (** Validates [a-zA-Z0-9._-]+(:[a-zA-Z0-9._-]+)?, length 1–64.
      Strict superset of {!Validation.Agent_id} — see #8633 for the
      colon-namespace fix and #8625 for the 32→64 length raise. *)
  val to_string : t -> string
end

(** {1 Visibility & Post Kinds} *)

type visibility =
  | Public      (** Visible to federation. *)
  | Unlisted    (** Not in feeds, but accessible. *)
  | Internal    (** This MASC instance only. *)
  | Direct      (** Mentioned agents only. *)

type post_kind =
  | Human_post
  | Automation_post
  | System_post
[@@deriving tla]

(** Legacy automation-author classification (RFC-0089 §4-3 G2). Defined
    here so the board metric hook surface can reference it without a
    dependency cycle through [Board_core_classify]; [Board_core_classify]
    re-exports it via [include Board_types]. *)
type automation_label =
  | Auto_prefixed       (** Author starts with ["auto-"]. *)
  | Qa_prefixed         (** Author starts with ["qa-"]. *)
  | Researcher_named    (** Author contains ["researcher"]. *)
  | Harness_named       (** Author contains ["harness"]. *)
  | Smoke_named         (** Author contains ["smoke"]. *)
  | Probe_named         (** Author contains ["probe"]. *)

(** {1 Records — Mandatory TTL} *)

(** RFC-0233 §7: typed provenance of a board post — which keeper turn produced
    it and through which channel.  [source] is the channel's
    [Surface_ref.lane_label] string (not the typed [Surface_ref.t], which lives
    in the [masc] umbrella that depends on [masc_board]).  [turn_ref] and
    [fusion_run_id] are distinct (RFC §7.6 guard #5).  All sub-fields optional;
    an all-[None] origin is represented as [origin = None]. *)
type post_origin = {
  turn_ref : Ids.Turn_ref.t option;
  source : string option;
  fusion_run_id : string option;
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
  content : string;
  post_kind : post_kind;
  meta_json : Yojson.Safe.t option;
  visibility : visibility;
  created_at : float;
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

(** {1 Limits — Enforced, Not Optional}

    All values resolved from [MASC_BOARD_*] env vars at module init,
    falling back to the hardcoded defaults shown inline in the .ml. *)

module Limits : sig
  val max_posts : int
  val max_comments_per_post : int
  val max_content_length : int
  val default_comment_page_limit : int
  (** Default number of comments returned by [masc_board_post_get]. *)
  val max_comment_page_limit : int
  (** Maximum comments returned by one [masc_board_post_get] page. *)
  val default_ttl_hours : int
  (** [0] — permanent (no expiry). *)
  val automation_ttl_hours : int
  val max_ttl_hours : int
  val sweeper_interval_sec : int
  val sweeper_batch_size : int
  val author_post_cap : int
  val max_sub_boards : int
  (** Maximum number of sub-boards. Default 256. *)
  val comment_rate_limit : int
  (** Max comments per author within [comment_rate_window_sec]. 0 = disabled. Default 30. *)
  val comment_rate_window_sec : int
  (** Sliding window duration in seconds. Default 300 (5 min). *)
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
  posts : (string, post) Hashtbl.t;
  comments : (string, comment) Hashtbl.t;
  vote_log : (string, vote_direction * float) Hashtbl.t;
  (** #10086: value carries [(direction, cast_ts)] so the rewriter
      preserves the original cast time on every flush. *)
  post_count : int ref;
  mutable last_sweep : float;
  mutex : Eio.Mutex.t;
  persist_mutex : Eio.Mutex.t;
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
