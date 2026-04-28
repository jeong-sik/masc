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
[@@deriving show]

(** {1 Safe ID Modules — Parse, Don't Validate} *)

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

(** {1 Records — Mandatory TTL} *)

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
  hearth : string option;
  thread_id : string option;
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

(** {1 Limits — Enforced, Not Optional}

    All values resolved from [MASC_BOARD_*] env vars at module init,
    falling back to the hardcoded defaults shown inline in the .ml. *)

module Limits : sig
  val max_posts : int
  val max_comments_per_post : int
  val max_content_length : int
  val default_ttl_hours : int
  (** [0] — permanent (no expiry). *)
  val automation_ttl_hours : int
  val max_ttl_hours : int
  val sweeper_interval_sec : int
  val sweeper_batch_size : int
  val author_post_cap : int
end

(** {1 Vote Direction} *)

type vote_direction = Up | Down

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
  mutable karma_cache : (string * int) list option;
  (** [None] = stale. *)
  mutable sorted_posts_cache : post list option;
  (** [None] = stale. *)
  comments_by_post : (string, string list) Hashtbl.t;
  (** post_id -> comment_id list. *)
  mutable dirty_posts : bool;
  mutable dirty_comments : bool;
  mutable last_flush : float;
  flusher_inbox : flusher_msg Eio.Stream.t;
}
