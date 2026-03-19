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

  (* Only alphanumeric, dash, underscore. Max 64 chars.
     Note: OCaml Str does not support \{n,m\} quantifiers, so we use + with length check *)
  let valid_pattern = Str.regexp "^[a-zA-Z0-9_-]+$"

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 64 && Str.string_match valid_pattern s 0 then Ok s
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

  let valid_pattern = Str.regexp "^[a-zA-Z0-9_-]+$"

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 64 && Str.string_match valid_pattern s 0 then Ok s
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
  let valid_pattern = Str.regexp "^[a-zA-Z0-9._-]+$"

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 32 && Str.string_match valid_pattern s 0 then Ok s
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
  hearth: string option;     (* Topic category within the Lodge *)
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
  let max_posts = 10_000
  let max_comments_per_post = 1_000
  let max_content_length = 4_000
  let default_ttl_hours = 0    (* 0 = permanent (no expiry) *)
  let max_ttl_hours = 720      (* 30 days max; ignored when ttl=0 *)
  let sweeper_interval_sec = 10  (* Much more aggressive than OpenClaw's 60s *)
  let sweeper_batch_size = 100   (* Backpressure: don't delete too many at once *)
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

(** Flush interval in seconds - configurable via MASC_BOARD_FLUSH_INTERVAL_SEC env var *)
let flush_interval_sec =
  match Sys.getenv_opt "MASC_BOARD_FLUSH_INTERVAL_SEC" with
  | Some s -> (try float_of_string s with Failure _ -> 30.0)
  | None -> 30.0

let create_store () = {
  posts = Hashtbl.create 1024;
  comments = Hashtbl.create 4096;
  vote_log = Hashtbl.create 2048;
  post_count = ref 0;
  last_sweep = Time_compat.now ();
  mutex = Eio.Mutex.create ();
  karma_cache = None;
  sorted_posts_cache = None;
  comments_by_post = Hashtbl.create 1024;
  dirty_posts = false;
  dirty_comments = false;
  last_flush = Time_compat.now ();
}

(** Invalidate caches that depend on post data *)
let invalidate_post_caches store =
  store.karma_cache <- None;
  store.sorted_posts_cache <- None

(** Invalidate caches that depend on comment data *)
let invalidate_comment_caches store =
  store.karma_cache <- None

(** {1 Eio-style Locking with Switch.on_release} *)

(** Execute f with mutex held, using Eio.Mutex for proper concurrency *)
let with_lock store f =
  Eio.Mutex.use_rw ~protect:true store.mutex (fun () -> f ())

(** {1 Sweeper - Aggressive Cleanup} *)

let sweep store =
  with_lock store (fun () ->
    let now = Time_compat.now () in
    let removed_posts = ref 0 in
    let removed_comments = ref 0 in

    (* Sweep posts - with batch limit; skip permanent posts (expires_at = 0) *)
    let expired_posts = Hashtbl.fold (fun id (post : post) acc ->
      if post.expires_at > 0.0 && post.expires_at < now && !removed_posts < Limits.sweeper_batch_size then begin
        incr removed_posts;
        id :: acc
      end else acc
    ) store.posts [] in
    List.iter (fun id ->
      Hashtbl.remove store.posts id;
      Hashtbl.remove store.comments_by_post id;
      decr store.post_count
    ) expired_posts;

    (* Sweep comments - skip permanent (expires_at = 0) *)
    let expired_comments = Hashtbl.fold (fun id (comment : comment) acc ->
      if comment.expires_at > 0.0 && comment.expires_at < now && !removed_comments < Limits.sweeper_batch_size then begin
        incr removed_comments;
        id :: acc
      end else acc
    ) store.comments [] in
    List.iter (fun cid ->
      (match Hashtbl.find_opt store.comments cid with
       | Some c ->
           let post_key = Post_id.to_string c.post_id in
           (match Hashtbl.find_opt store.comments_by_post post_key with
            | Some ids ->
                let filtered = List.filter (fun id -> not (String.equal id cid)) ids in
                if filtered = [] then Hashtbl.remove store.comments_by_post post_key
                else Hashtbl.replace store.comments_by_post post_key filtered
            | None -> ())
       | None -> ());
      Hashtbl.remove store.comments cid
    ) expired_comments;

    (* Invalidate caches if anything was swept *)
    if !removed_posts > 0 then invalidate_post_caches store;
    if !removed_comments > 0 then invalidate_comment_caches store;

    store.last_sweep <- now;
    (!removed_posts, !removed_comments)
  )

(** Deferred flush callback — set after rewrite helpers are defined.
    Avoids forward-reference issue (maybe_sweep is defined before rewrite_posts).

    Thread-safety note: This ref is safe in Eio because:
    - OCaml 5.x domains cannot share mutable state without explicit synchronization
    - Eio runs all fibers within a single domain (structured concurrency)
    - All board operations execute sequentially within the same domain
    - The ref is written exactly once at module load time (line ~939)
    If multi-domain becomes needed, replace with Domain.DLS or atomic ref. *)
let deferred_flush_fn : (store -> unit) ref = ref (fun _ -> ())

(** Auto-sweep if needed, also triggers deferred flush via callback *)
let maybe_sweep store =
  let now = Time_compat.now () in
  if now -. store.last_sweep > float_of_int Limits.sweeper_interval_sec then
    (try ignore (sweep store)
     with exn -> Log.BoardLog.warn "sweep failed: %s" (Printexc.to_string exn));
  if now -. store.last_flush > flush_interval_sec then
    !deferred_flush_fn store

(** {1 Persistence Paths} *)

let board_base_path () =
  match Sys.getenv_opt "MASC_BASE_PATH" with
  | Some p when String.trim p <> "" -> p
  | _ ->
      (match Sys.getenv_opt "ME_ROOT" with
       | Some p -> p
       | None -> Sys.getcwd ())

let persist_path () =
  let base = board_base_path () in
  Filename.concat base ".masc/board_posts.jsonl"

let comments_path () =
  let base = board_base_path () in
  Filename.concat base ".masc/board_comments.jsonl"

let ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else Fs_compat.mkdir_p path

let ensure_masc_dir () =
  let base = board_base_path () in
  let dir = Filename.concat base ".masc" in
  ensure_dir base;
  ensure_dir dir

(** {1 JSONL File Rotation} *)

(** Max JSONL file size before rotation (10 MB).
    Prevents unbounded disk growth from agent feedback loops. *)
let max_jsonl_bytes = 10 * 1024 * 1024

(** Rotate a JSONL file if it exceeds [max_jsonl_bytes].
    Keeps one backup (.1) and truncates the active file.
    Safe: uses rename (atomic on same filesystem). *)
let rotate_if_needed path =
  try
    let st = Unix.stat path in
    if st.Unix.st_size > max_jsonl_bytes then begin
      let backup = path ^ ".1" in
      (try Sys.rename backup (path ^ ".2") with Sys_error _ -> ());
      Sys.rename path backup;
      Log.BoardLog.info "rotated %s (was %d bytes)" path st.Unix.st_size
    end
  with
  | Unix.Unix_error (e, fn, arg) ->
      Log.BoardLog.warn "rotate error: %s(%s): %s" fn arg (Unix.error_message e)
  | Sys_error msg ->
      Log.BoardLog.warn "rotate error: %s" msg

(** {1 JSON Serialization} *)

let visibility_to_string = function
  | Public -> "public"
  | Unlisted -> "unlisted"
  | Internal -> "internal"
  | Direct -> "direct"

let post_kind_to_string = function
  | Human_post -> "human"
  | Automation_post -> "automation"
  | System_post -> "system"

let post_kind_of_string = function
  | "human" -> Some Human_post
  | "automation" -> Some Automation_post
  | "system" -> Some System_post
  | _ -> None

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop idx =
      if idx + needle_len > hay_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let author_looks_automation author =
  String.starts_with ~prefix:"auto-" author
  || String.starts_with ~prefix:"qa-" author
  || contains_substring author "researcher"
  || contains_substring author "harness"
  || contains_substring author "smoke"
  || contains_substring author "probe"

let infer_post_kind ~author ~visibility ~expires_at ~hearth =
  let author = String.lowercase_ascii author in
  let hearth =
    match hearth with
    | Some value -> String.lowercase_ascii (String.trim value)
    | None -> ""
  in
  if author = "lodge-system" || author = "team-session"
     || author = "sentinel" || author = "gardener" || author = "ecosystem" then
    System_post
  else if visibility = Internal && expires_at > 0.0 && hearth <> ""
          && (String.starts_with ~prefix:"mdal" hearth
              || contains_substring hearth "harness")
  then
    Automation_post
  else if author_looks_automation author then
    Automation_post
  else
    Human_post

let classify_post_kind (p : post) =
  let inferred =
    infer_post_kind
      ~author:(Agent_id.to_string p.author)
      ~visibility:p.visibility
      ~expires_at:p.expires_at
      ~hearth:p.hearth
  in
  match p.post_kind, inferred with
  | Human_post, (Automation_post | System_post as upgraded) -> upgraded
  | Automation_post, System_post -> System_post
  | stored, _ -> stored

let state_start_marker = "[STATE]"
let state_end_marker = "[/STATE]"

let extract_state_block (text : string) : string option * string =
  let start_re = Str.regexp_string state_start_marker in
  let end_re = Str.regexp_string state_end_marker in
  try
    let start_idx = Str.search_forward start_re text 0 in
    let block_body_start = start_idx + String.length state_start_marker in
    let end_idx =
      try Str.search_forward end_re text block_body_start
      with Not_found -> String.length text
    in
    let block_end =
      min (String.length text) (end_idx + String.length state_end_marker)
    in
    let state_block =
      String.sub text start_idx (block_end - start_idx) |> String.trim
    in
    let before =
      if start_idx = 0 then "" else String.sub text 0 start_idx
    in
    let after =
      if block_end >= String.length text then ""
      else String.sub text block_end (String.length text - block_end)
    in
    Some state_block, String.trim (before ^ after)
  with Not_found -> None, String.trim text

let meta_state_block (meta_json : Yojson.Safe.t option) =
  match meta_json with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "state_block" fields with
      | Some (`String value) ->
          let value = String.trim value in
          if value = "" then None else Some value
      | _ -> None)
  | _ -> None

let merge_meta_json ?state_block (meta_json : Yojson.Safe.t option) :
    Yojson.Safe.t option =
  let fields =
    match meta_json with
    | Some (`Assoc assoc) -> assoc
    | _ -> []
  in
  let fields =
    match state_block with
    | Some block when block <> "" && not (List.mem_assoc "state_block" fields) ->
        ("state_block", `String block) :: fields
    | _ -> fields
  in
  match fields with
  | [] -> None
  | _ -> Some (`Assoc fields)

let derive_post_title (body : string) =
  let first_line =
    body
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.find_opt (fun line -> line <> "")
    |> Option.value ~default:"Untitled post"
  in
  if String.length first_line <= 80 then first_line
  else String.sub first_line 0 77 ^ "..."

let normalize_post_payload ~author ~content ?title ?body ?post_kind ?meta_json
    ~visibility ~expires_at ~hearth () =
  let raw_body = Option.value body ~default:content in
  let extracted_state, stripped_body = extract_state_block raw_body in
  let normalized_body = String.trim stripped_body in
  let normalized_title =
    match title with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> derive_post_title normalized_body
  in
  let normalized_kind =
    match post_kind with
    | Some kind -> kind
    | None -> infer_post_kind ~author ~visibility ~expires_at ~hearth
  in
  let merged_meta = merge_meta_json ?state_block:extracted_state meta_json in
  normalized_title, normalized_body, normalized_kind, merged_meta

let post_to_yojson (p : post) : Yojson.Safe.t =
  `Assoc ([
    ("id", `String (Post_id.to_string p.id));
    ("author", `String (Agent_id.to_string p.author));
    ("title", `String p.title);
    ("body", `String p.body);
    ("post_kind", `String (post_kind_to_string (classify_post_kind p)));
    ("content", `String p.content);
    ("visibility", `String (visibility_to_string p.visibility));
    ("created_at", `Float p.created_at);
    ("updated_at", `Float p.updated_at);
    ("expires_at", `Float p.expires_at);
    ("votes_up", `Int p.votes_up);
    ("votes_down", `Int p.votes_down);
    ("score", `Int (p.votes_up - p.votes_down));
    ("reply_count", `Int p.reply_count);
  ] @ (match p.hearth with Some h -> [("hearth", `String h)] | None -> [])
    @ (match p.thread_id with Some t -> [("thread_id", `String t)] | None -> [])
    @ (match p.meta_json with Some meta -> [("meta", meta)] | None -> []))

let comment_to_yojson (c : comment) : Yojson.Safe.t =
  `Assoc [
    ("id", `String (Comment_id.to_string c.id));
    ("post_id", `String (Post_id.to_string c.post_id));
    ("parent_id", match c.parent_id with Some p -> `String (Comment_id.to_string p) | None -> `Null);
    ("author", `String (Agent_id.to_string c.author));
    ("content", `String c.content);
    ("created_at", `Float c.created_at);
    ("expires_at", `Float c.expires_at);
    ("votes_up", `Int c.votes_up);
    ("votes_down", `Int c.votes_down);
    ("score", `Int (c.votes_up - c.votes_down));
  ]

(** {1 Rewrite Helpers} *)

let rewrite_posts store =
  try
    ensure_masc_dir ();
    let path = persist_path () in
    let tmp_path = path ^ ".tmp" in
    let buf = Buffer.create 4096 in
    Hashtbl.iter (fun _ (pst : post) ->
      Buffer.add_string buf (Yojson.Safe.to_string (post_to_yojson pst) ^ "\n")
    ) store.posts;
    Fs_compat.save_file tmp_path (Buffer.contents buf);
    Sys.rename tmp_path path
  with Sys_error msg -> Log.BoardLog.error "persist error (rewrite_posts): %s" msg

let rewrite_comments store =
  try
    ensure_masc_dir ();
    let path = comments_path () in
    let tmp_path = path ^ ".tmp" in
    let buf = Buffer.create 4096 in
    Hashtbl.iter (fun _ (cmt : comment) ->
      Buffer.add_string buf (Yojson.Safe.to_string (comment_to_yojson cmt) ^ "\n")
    ) store.comments;
    Fs_compat.save_file tmp_path (Buffer.contents buf);
    Sys.rename tmp_path path
  with Sys_error msg -> Log.BoardLog.error "persist error (rewrite_comments): %s" msg

(** {1 Append Helpers} *)

let append_post (p : post) =
  try
    ensure_masc_dir ();
    let path = persist_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (post_to_yojson p) ^ "\n");
    rotate_if_needed path
  with Sys_error msg -> Log.BoardLog.error "persist error (append_post): %s" msg

let append_comment (c : comment) =
  try
    ensure_masc_dir ();
    let path = comments_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (comment_to_yojson c) ^ "\n");
    rotate_if_needed path
  with Sys_error msg -> Log.BoardLog.error "persist error (append_comment): %s" msg

(** {1 Post Operations} *)

let create_post store ~author ~content ?title ?body ?post_kind ?meta_json
    ?(visibility=Internal) ?(ttl_hours=Limits.default_ttl_hours) ?hearth ?thread_id ()
  : (post, board_error) result =
  maybe_sweep store;

  (* Validate author *)
  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->

  let ttl = if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours in

  (* Normalize hearth: lowercase + trim *)
  let hearth = Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth in
  let expires_at =
    let now = Time_compat.now () in
    if ttl = 0 then 0.0 else now +. (float_of_int ttl *. 3600.0)
  in
  let normalized_title, normalized_body, normalized_kind, normalized_meta =
    normalize_post_payload ~author ~content ?title ?body ?post_kind ?meta_json
      ~visibility ~expires_at ~hearth ()
  in

  (* Validate body length *)
  if String.length normalized_body > Limits.max_content_length then
    Error (Validation_error (Printf.sprintf "Content too long: %d > %d"
      (String.length normalized_body) Limits.max_content_length))
  else if String.length normalized_body = 0 then
    Error (Validation_error "Content cannot be empty")
  else

  with_lock store (fun () ->
    (* Check capacity *)
    if !(store.post_count) >= Limits.max_posts then
      Error (Capacity_exceeded { current = !(store.post_count); max = Limits.max_posts })
    else begin
      let now = Time_compat.now () in
      let post = {
        id = Post_id.generate ();
        author = author_id;
        title = normalized_title;
        body = normalized_body;
        content = normalized_body;
        post_kind = normalized_kind;
        meta_json = normalized_meta;
        visibility;
        created_at = now;
        updated_at = now;  (* Initially same as created_at *)
        expires_at;
        votes_up = 0;
        votes_down = 0;
        reply_count = 0;
        hearth;
        thread_id;
      } in
      Hashtbl.add store.posts (Post_id.to_string post.id) post;
      incr store.post_count;
      invalidate_post_caches store;
      append_post post;
      (* Agent Economy: earn credits for board post *)
      (match Agent_economy.earn
         ~base_path:(board_base_path ()) ~agent_name:author
         ~kind:Earn_board_post ~reason:"board post" () with
       | Ok _ -> ()
       | Error msg -> Log.BoardLog.warn "economy earn (post): %s" msg);
      Ok post
    end
  )

let get_post store ~post_id : (post, board_error) result =
  maybe_sweep store;
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
        | Some post -> Ok post
        | None -> Error (Post_not_found post_id)
      )

let list_posts store ?(visibility_filter=None) ?hearth ?(limit=50) () : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    (* Use cached sorted list if available (cache hit = skip sort) *)
    let sorted_all = match store.sorted_posts_cache with
      | Some cached -> cached
      | None ->
          let all = Hashtbl.fold (fun _ (post : post) acc -> post :: acc) store.posts [] in
          let sorted = List.sort (fun (a : post) (b : post) ->
            let score_a = a.votes_up - a.votes_down in
            let score_b = b.votes_up - b.votes_down in
            let cmp = compare score_b score_a in
            if cmp <> 0 then cmp
            else compare b.created_at a.created_at
          ) all in
          store.sorted_posts_cache <- Some sorted;
          sorted
    in
    (* Apply filters on the pre-sorted list *)
    let filtered = match visibility_filter with
      | None -> sorted_all
      | Some v -> List.filter (fun (p : post) -> p.visibility = v) sorted_all
    in
    let filtered = match hearth with
      | None -> filtered
      | Some h ->
          let h_norm = String.lowercase_ascii (String.trim h) in
          List.filter (fun (p : post) -> p.hearth = Some h_norm) filtered
    in
    (* Take first N *)
    let rec take n lst = match n, lst with
      | 0, _ | _, [] -> []
      | n, x :: xs -> x :: take (n-1) xs
    in
    take (min limit 100) filtered  (* Hard cap at 100 *)
  )

(** Full-scan search over all posts (no limit on scan, only on results).
    Used by Board_dispatch.search to avoid the list_posts hard cap. *)
let search_posts store ~predicate ~limit : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    let matches = Hashtbl.fold (fun _ (p : post) acc ->
      if predicate p then p :: acc else acc
    ) store.posts [] in
    (* Sort by recency for search results *)
    let sorted = List.sort (fun (a : post) (b : post) ->
      compare b.created_at a.created_at
    ) matches in
    let rec take n lst = match n, lst with
      | 0, _ | _, [] -> []
      | n, x :: xs -> x :: take (n-1) xs
    in
    take limit sorted
  )

(** {1 Comment Operations} *)

let add_comment store ~post_id ~author ~content ?parent_id ?(ttl_hours=Limits.default_ttl_hours) ()
  : (comment, board_error) result =
  maybe_sweep store;

  (* Validate all IDs first *)
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->

  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->

  let parent_result = match parent_id with
    | None -> Ok None
    | Some p -> match Comment_id.of_string p with
        | Ok cid -> Ok (Some cid)
        | Error e -> Error e
  in
  match parent_result with
  | Error e -> Error e
  | Ok parent_cid ->

  (* Validate content *)
  if String.length content > Limits.max_content_length then
    Error (Validation_error "Content too long")
  else if String.length content = 0 then
    Error (Validation_error "Content cannot be empty")
  else

  with_lock store (fun () ->
    (* Verify post exists *)
    match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
    | None -> Error (Post_not_found post_id)
    | Some post ->
        (* Check comment count using index *)
        let post_key = Post_id.to_string pid in
        let post_comment_count =
          try List.length (Hashtbl.find store.comments_by_post post_key)
          with Not_found -> 0
        in
        if post_comment_count >= Limits.max_comments_per_post then
          Error (Capacity_exceeded { current = post_comment_count; max = Limits.max_comments_per_post })
        else begin
          let now = Time_compat.now () in
          let ttl = if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours in
          let comment = {
            id = Comment_id.generate ();
            post_id = pid;
            parent_id = parent_cid;
            author = author_id;
            content;
            created_at = now;
            expires_at = if ttl = 0 then 0.0 else now +. (float_of_int ttl *. 3600.0);
            votes_up = 0;
            votes_down = 0;
          } in
          Hashtbl.add store.comments (Comment_id.to_string comment.id) comment;
          (* Update comments_by_post index *)
          let post_key = Post_id.to_string pid in
          let existing = try Hashtbl.find store.comments_by_post post_key with Not_found -> [] in
          Hashtbl.replace store.comments_by_post post_key (Comment_id.to_string comment.id :: existing);
          (* Update post reply count and updated_at *)
          Hashtbl.replace store.posts post_key
            { post with reply_count = post.reply_count + 1; updated_at = now };
          invalidate_post_caches store;
          invalidate_comment_caches store;
          append_comment comment;
          Ok comment
        end
  )

let get_comments store ~post_id : (comment list, board_error) result =
  maybe_sweep store;
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        let post_key = Post_id.to_string pid in
        let comment_ids = try Hashtbl.find store.comments_by_post post_key with Not_found -> [] in
        let comments = List.filter_map (fun cid ->
          Hashtbl.find_opt store.comments cid
        ) comment_ids in
        Ok (List.sort (fun (a : comment) (b : comment) -> compare a.created_at b.created_at) comments)
      )

(** List all comments (for profile aggregation) *)
let list_comments store ?(limit=1000) () : comment list =
  maybe_sweep store;
  with_lock store (fun () ->
    let all = Hashtbl.fold (fun _ c acc -> c :: acc) store.comments [] in
    let sorted = List.sort (fun (a : comment) (b : comment) ->
      compare b.created_at a.created_at
    ) all in
    List.filteri (fun i _ -> i < limit) sorted
  )

(** {1 Voting - Deduplicated} *)
