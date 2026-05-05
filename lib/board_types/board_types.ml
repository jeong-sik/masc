(** Board - MASC Internal Board (Mastodon-style federation ready)

    Zero-tolerance implementation:
    - ID validation (no path traversal)
    - TTL optional (0 = permanent, default)
    - Max limits enforced (no OOM)
    - Cryptographic IDs (no prediction)
    - Atomic writes (no corruption)
    - Automatic sweeper (no manual cleanup)

    Eio Best Practices:
    - Switch.on_release for cleanup (not Fun.protect)
    - Structured concurrency

    @since 0.5.0 - Replaces social.ml with hardened implementation
*)

(** {1 Error Types - No Silent Failures} *)

type board_error =
  | Invalid_id of string
  | Post_not_found of string
  | Comment_not_found of string
  | Rate_limited of { retry_after: float }
  | Capacity_exceeded of { current: int; max: int }
  | Io_error of string
  | Validation_error of string
  | Already_voted of string
  [@@deriving show]

(** {1 Safe ID Module - Parse Don't Validate} *)

module Post_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
  val generate : unit -> t
end = struct
  type t = string

  (* Only alphanumeric, dash, underscore. Max 64 chars. *)
  let valid_pattern = Re.Pcre.re {|^[a-zA-Z0-9_-]+$|} |> Re.compile

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 64 && Re.execp valid_pattern s then Ok s
    else Error (Invalid_id (Printf.sprintf "Invalid post_id: %s" s))

  let to_string t = t

  let generate () = Random_id.prefixed ~prefix:"p-" ~bytes:16
end

module Comment_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
  val generate : unit -> t
end = struct
  type t = string

  let valid_pattern = Re.Pcre.re {|^[a-zA-Z0-9_-]+$|} |> Re.compile

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 64 && Re.execp valid_pattern s then Ok s
    else Error (Invalid_id (Printf.sprintf "Invalid comment_id: %s" s))

  let to_string t = t

  let generate () = Random_id.prefixed ~prefix:"c-" ~bytes:16
end

module Agent_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
end = struct
  type t = string

  (* Issue #8633: pattern was [^[a-zA-Z0-9._-]+$] which rejected the
     [keeper:foo] colon-namespacing supported by the canonical
     [Validation.Agent_id] (used by masc_join / masc_claim_next).
     Real callers exist (server_routes_http_keeper_stream:413,
     server_openai_compat:153). Pattern is now a strict superset of
     both: optional single colon namespace + previously-allowed dots.

     Issue #8625: length cap was 32 — also raised to 64 to match
     [Validation.Agent_id.validate]. Generated worker IDs like
     [codex-task-claimer-20260419t102609z] (36 chars) joined fine but
     were rejected by board posts. (Supersedes PR #8631.) *)
  let max_agent_id_len = 64
  let valid_pattern =
    Re.Pcre.re {|^[a-zA-Z0-9._-]+(:[a-zA-Z0-9._-]+)?$|} |> Re.compile

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= max_agent_id_len && Re.execp valid_pattern s then
      Ok s
    else
      Error
        (Validation_error
           (Printf.sprintf
              "Invalid agent_id: %s (max %d chars, must match \
               [a-zA-Z0-9._-]+(:[a-zA-Z0-9._-]+)?)"
              s max_agent_id_len))

  let to_string t = t
end

(** {1 Types with Mandatory TTL} *)

type visibility =
  | Public      (* Visible to federation *)
  | Unlisted    (* Not in feeds, but accessible *)
  | Internal    (* This MASC instance only *)
  | Direct      (* Mentioned agents only *)

type post_kind =
  | Human_post [@tla.symbol "human_post"]
  | Automation_post [@tla.symbol "automation_post"]
  | System_post [@tla.symbol "system_post"]
[@@deriving tla]

type post = {
  id: Post_id.t;
  author: Agent_id.t;
  title: string;
  body: string;
  content: string;
  post_kind: post_kind;
  meta_json: Yojson.Safe.t option;
  visibility: visibility;
  created_at: float;
  updated_at: float;   (* Last activity: vote, comment, edit *)
  expires_at: float;   (* MANDATORY - no eternal posts *)
  votes_up: int;
  votes_down: int;
  reply_count: int;
  hearth: string option;     (* Topic category within the Board *)
  thread_id: string option;  (* Linked Conversation thread *)
}

type comment = {
  id: Comment_id.t;
  post_id: Post_id.t;
  parent_id: Comment_id.t option;
  author: Agent_id.t;
  content: string;
  created_at: float;
  expires_at: float;   (* MANDATORY *)
  votes_up: int;
  votes_down: int;
}

type reaction_target_type =
  | Reaction_post
  | Reaction_comment

type reaction = {
  target_type: reaction_target_type;
  target_id: string;
  user_id: Agent_id.t;
  emoji: string;
  created_at: float;
}

type reaction_summary = {
  emoji: string;
  count: int;
  reacted: bool;
  recent_user_ids: string list;
}

type reaction_toggle_result = {
  target_type: reaction_target_type;
  target_id: string;
  user_id: string;
  emoji: string;
  reacted: bool;
  summary: reaction_summary list;
}

(** {1 Limits - Enforced, Not Optional} *)

module Limits = struct
  let env_int name default = Env_config_core.get_int ~default name

  let max_posts = env_int "MASC_BOARD_MAX_POSTS" 10_000
  let max_comments_per_post = env_int "MASC_BOARD_MAX_COMMENTS_PER_POST" 1_000
  let max_content_length = env_int "MASC_BOARD_MAX_CONTENT_LENGTH" 4_000
  let default_ttl_hours = 0    (* 0 = permanent (no expiry) *)
  let automation_ttl_hours = env_int "MASC_BOARD_AUTOMATION_TTL_HOURS" 168
  let max_ttl_hours = env_int "MASC_BOARD_MAX_TTL_HOURS" 720
  let sweeper_interval_sec = env_int "MASC_BOARD_SWEEPER_INTERVAL_SEC" 10
  let sweeper_batch_size = env_int "MASC_BOARD_SWEEPER_BATCH_SIZE" 100
  let author_post_cap = env_int "MASC_BOARD_AUTHOR_POST_CAP" 100
end

(** {1 Vote Direction} *)

type vote_direction = Up | Down

(** {1 In-Memory Store with Enforced Limits} *)

type flusher_msg =
  | Flush
  | Sweep

type store = {
  posts: (string, post) Hashtbl.t;
  comments: (string, comment) Hashtbl.t;
  (* #10086: value carries [(direction, cast_ts)] so
     [rewrite_vote_log] persists the original vote timestamp on
     every flush instead of overwriting it with the wall clock.
     The float is Unix seconds at which the vote was first cast,
     or the flip time on a direction change. *)
  vote_log: (string, vote_direction * float) Hashtbl.t;
  post_count: int ref;
  mutable last_sweep: float;
  mutex: Eio.Mutex.t;
  persist_mutex: Eio.Mutex.t;
  (* Phase 2 caches *)
  mutable karma_cache: (string * int) list option;       (** None = stale *)
  mutable sorted_posts_cache: post list option;           (** None = stale *)
  comments_by_post: (string, string list) Hashtbl.t;      (** post_id -> comment_id list *)
  reactions: (string, reaction) Hashtbl.t;                 (** unique target/user/emoji reactions *)
  mutable dirty_posts: bool;                               (** Deferred flush flag *)
  mutable dirty_comments: bool;                            (** Deferred flush flag *)
  dirty_post_ids: (string, unit) Hashtbl.t;                 (** Deferred post snapshots *)
  dirty_comment_ids: (string, unit) Hashtbl.t;              (** Deferred comment snapshots *)
  mutable last_flush: float;
  flusher_inbox: flusher_msg Eio.Stream.t;                               (** Last deferred flush time *)
}
