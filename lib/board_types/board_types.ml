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

  (* Cryptographically random ID using mirage-crypto *)
  let generate () =
    let rnd = Mirage_crypto_rng.generate 16 in
    let hex = String.concat "" (
      List.init (String.length rnd) (fun i ->
        Printf.sprintf "%02x" (Char.code (String.get rnd i))
      )
    ) in
    Printf.sprintf "p-%s" hex
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

  let generate () =
    let rnd = Mirage_crypto_rng.generate 16 in
    let hex = String.concat "" (
      List.init (String.length rnd) (fun i ->
        Printf.sprintf "%02x" (Char.code (String.get rnd i))
      )
    ) in
    Printf.sprintf "c-%s" hex
end

module Agent_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
end = struct
  type t = string

  (* Agent names: alphanumeric, dash, underscore, dot. Max 32 chars *)
  let valid_pattern = Re.Pcre.re {|^[a-zA-Z0-9._-]+$|} |> Re.compile

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 32 && Re.execp valid_pattern s then Ok s
    else Error (Validation_error (Printf.sprintf "Invalid agent_id: %s" s))

  let to_string t = t
end

(** {1 Types with Mandatory TTL} *)

type visibility =
  | Public      (* Visible to federation *)
  | Unlisted    (* Not in feeds, but accessible *)
  | Internal    (* This MASC instance only *)
  | Direct      (* Mentioned agents only *)

type post_kind =
  | Human_post
  | Automation_post
  | System_post

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

(** {1 Limits - Enforced, Not Optional} *)

module Limits = struct
  let env_int name default =
    match Sys.getenv_opt name with
    | Some s -> (match int_of_string_opt s with Some n -> n | None -> default)
    | None -> default

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

type store = {
  posts: (string, post) Hashtbl.t;
  comments: (string, comment) Hashtbl.t;
  vote_log: (string, vote_direction) Hashtbl.t;
  post_count: int ref;
  mutable last_sweep: float;
  mutex: Eio.Mutex.t;
  (* Phase 2 caches *)
  mutable karma_cache: (string * int) list option;       (** None = stale *)
  mutable sorted_posts_cache: post list option;           (** None = stale *)
  comments_by_post: (string, string list) Hashtbl.t;      (** post_id -> comment_id list *)
  mutable dirty_posts: bool;                               (** Deferred flush flag *)
  mutable dirty_comments: bool;                            (** Deferred flush flag *)
  mutable last_flush: float;                               (** Last deferred flush time *)
}

