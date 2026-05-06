module Hashtbl = Stdlib.Hashtbl
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module String = Stdlib.String

(** Board Core — JSONL store logic and persistence.
    Types are in Board_types. *)

include Board_core_classify
include Board_core_payload

(** Flush interval in seconds - configurable via MASC_BOARD_FLUSH_INTERVAL_SEC env var *)
let flush_interval_sec = Env_config.Board.flush_interval_sec

(** Monotonic counter of persist failures (disk full, permission errors, etc.).
    Callers of [rewrite_posts]/[rewrite_comments] cannot propagate these
    errors, but operators need visibility. Surface via [persist_error_count ()]
    in health dashboards and Prometheus exporters. *)
let persist_errors = Atomic.make 0

let persist_error_count () = Atomic.get persist_errors

let record_persist_error ~where msg =
  Atomic.incr persist_errors;
  Log.BoardLog.error "persist error (%s): %s" where msg

let create_store () = {
  posts = Hashtbl.create 1024;
  comments = Hashtbl.create 4096;
  vote_log = Hashtbl.create 2048;
  post_count = ref 0;
  last_sweep = Time_compat.now ();
  mutex = Eio.Mutex.create ();
  persist_mutex = Eio.Mutex.create ();
  karma_cache = None;
  sorted_posts_cache = None;
  comments_by_post = Hashtbl.create 1024;
  reactions = Hashtbl.create 4096;
  dirty_posts = false;
  dirty_comments = false;
  dirty_post_ids = Hashtbl.create 256;
  dirty_comment_ids = Hashtbl.create 512;
  last_flush = Time_compat.now ();
  flusher_inbox = Eio.Stream.create 1000;
  sub_boards = Hashtbl.create 64;
  sub_boards_by_slug = Hashtbl.create 64;
}

(** Remove [value] from the string list stored at [key] in [tbl].
    Removes the key entirely when the list becomes empty. *)
let remove_from_list_index tbl key value =
  match Hashtbl.find_opt tbl key with
  | None -> ()
  | Some ids ->
    match List.filter (fun id -> not (String.equal id value)) ids with
    | [] -> Hashtbl.remove tbl key
    | filtered -> Hashtbl.replace tbl key filtered

(** Invalidate caches that depend on post data *)
let invalidate_post_caches store =
  store.karma_cache <- None;
  store.sorted_posts_cache <- None

(** Invalidate caches that depend on comment data *)
let invalidate_comment_caches store =
  store.karma_cache <- None

let mark_dirty_post store post_id =
  store.dirty_posts <- true;
  Hashtbl.replace store.dirty_post_ids post_id ()

let mark_dirty_comment store comment_id =
  store.dirty_comments <- true;
  Hashtbl.replace store.dirty_comment_ids comment_id ()

(** {1 Eio-style Locking with Switch.on_release} *)

(** Execute f with mutex held, using Eio.Mutex for proper concurrency *)
let with_lock store f =
  Eio.Mutex.use_rw ~protect:true store.mutex (fun () -> f ())

(** Serialize JSONL writes without holding the state mutex.

    #10569 diagnostic: split the timing into [acquire_sec] (wait
    for mutex) and [held_sec] (disk I/O inside the lock).  The two
    histograms together let operators decide whether the
    keeper_board_* 60s timeout cluster is driven by writer-side
    queueing or by individual-syscall stall — without this
    decomposition the issue's root cause hypothesis ("mutex SPOF")
    cannot be confirmed against the field evidence. *)
let with_persist_lock store f =
  let started = Time_compat.now () in
  Eio.Mutex.use_rw ~protect:true store.persist_mutex (fun () ->
    let acquired = Time_compat.now () in
    Prometheus.observe_histogram
      Prometheus.metric_board_persist_lock_acquire_sec
      (acquired -. started);
    let result = f () in
    let released = Time_compat.now () in
    Prometheus.observe_histogram
      Prometheus.metric_board_persist_lock_held_sec
      (released -. acquired);
    result)

(** {1 Sweeper - Aggressive Cleanup} *)

let sweep store =
  with_lock store (fun () ->
    let now = Time_compat.now () in
    let removed_posts = ref 0 in
    let removed_comments = ref 0 in

    (* Sweep posts - with batch limit; skip permanent posts (expires_at = 0) *)
    let expired_posts = Hashtbl.fold (fun id (post : post) acc ->
      if Stdlib.Float.compare post.expires_at 0.0 > 0 && Stdlib.Float.compare post.expires_at now < 0 && !removed_posts < Limits.sweeper_batch_size then begin
        Stdlib.incr removed_posts;
        id :: acc
      end else acc
    ) store.posts [] in
    List.iter (fun id ->
      Hashtbl.remove store.posts id;
      Hashtbl.remove store.comments_by_post id;
      Stdlib.decr store.post_count
    ) expired_posts;

    (* Sweep comments - skip permanent (expires_at = 0) *)
    let expired_comments = Hashtbl.fold (fun id (comment : comment) acc ->
      if Stdlib.Float.compare comment.expires_at 0.0 > 0 && Stdlib.Float.compare comment.expires_at now < 0 && !removed_comments < Limits.sweeper_batch_size then begin
        Stdlib.incr removed_comments;
        id :: acc
      end else acc
    ) store.comments [] in
    List.iter (fun cid ->
      (match Hashtbl.find_opt store.comments cid with
       | Some c ->
           remove_from_list_index store.comments_by_post
             (Post_id.to_string c.post_id) cid
       | None -> ());
      Hashtbl.remove store.comments cid
    ) expired_comments;

    (* Author cap enforcement: evict oldest posts from authors exceeding the cap *)
    let cap_evicted = ref 0 in
    if Limits.author_post_cap > 0 then begin
      let author_posts = Hashtbl.create 64 in
      Hashtbl.iter (fun _ (post : post) ->
        let key = Agent_id.to_string post.author in
        let existing = Hashtbl.find_opt author_posts key |> Option.value ~default:[] in
        Hashtbl.replace author_posts key (post :: existing)
      ) store.posts;
      Hashtbl.iter (fun _author posts ->
        if List.length posts > Limits.author_post_cap then begin
          let sorted = List.sort (fun (a : post) (b : post) ->
            Stdlib.Float.compare a.created_at b.created_at
          ) posts in
          let excess = List.length sorted - Limits.author_post_cap in
          let rec take_first n = function
            | _ when n <= 0 -> []
            | [] -> []
            | x :: xs -> x :: take_first (n - 1) xs
          in
          let to_evict = take_first excess sorted in
          List.iter (fun (post : post) ->
            let id = Post_id.to_string post.id in
            Hashtbl.remove store.posts id;
            Hashtbl.remove store.comments_by_post id;
            Stdlib.decr store.post_count;
            Stdlib.incr cap_evicted
          ) to_evict
        end
      ) author_posts
    end;

    (* Invalidate caches if anything was swept *)
    if !removed_posts > 0 || !cap_evicted > 0 then invalidate_post_caches store;
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
(** Auto-sweep if needed, delegates to flusher actor inbox *)
let maybe_sweep store =
  let now = Time_compat.now () in
  if Stdlib.Float.compare (now -. store.last_sweep) (Stdlib.Float.of_int Limits.sweeper_interval_sec) > 0 then begin
    store.last_sweep <- now;
    Eio.Stream.add store.flusher_inbox Sweep
  end;
  if Stdlib.Float.compare (now -. store.last_flush) flush_interval_sec > 0 then begin
    store.last_flush <- now;
    Eio.Stream.add store.flusher_inbox Flush
  end

(** {1 Persistence Paths} *)

let board_base_path () =
  Env_config_core.base_path ()

let board_masc_dir () =
  Coord_utils.masc_root_dir_from
    ~base_path:(board_base_path ())
    ~cluster_name:(Env_config_core.cluster_name ())

let persist_path () =
  Filename.concat (board_masc_dir ()) "board_posts.jsonl"

let comments_path () =
  Filename.concat (board_masc_dir ()) "board_comments.jsonl"

let reactions_path () =
  Filename.concat (board_masc_dir ()) "board_reactions.jsonl"

let sub_boards_path () =
  Filename.concat (board_masc_dir ()) "board_sub_boards.jsonl"

let ensure_dir path =
  if String.equal path "" || String.equal path "." || String.equal path "/" then ()
  else Fs_compat.mkdir_p path

let ensure_masc_dir () =
  let base = board_base_path () in
  let dir = board_masc_dir () in
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

let post_to_yojson (p : post) : Yojson.Safe.t =
  `Assoc ([
    ("id", `String (Post_id.to_string p.id));
    ("author", `String (Agent_id.to_string p.author));
    ("title", `String p.title);
    ("body", `String p.body);
    ("post_kind", `String (post_kind_to_string p.post_kind));
    ("classification_reason", `String (post_classification_reason p));
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
    ("parent_id", Json_util.string_opt_to_json (Option.map Comment_id.to_string c.parent_id));
    ("author", `String (Agent_id.to_string c.author));
    ("content", `String c.content);
    ("created_at", `Float c.created_at);
    ("expires_at", `Float c.expires_at);
    ("votes_up", `Int c.votes_up);
    ("votes_down", `Int c.votes_down);
    ("score", `Int (c.votes_up - c.votes_down));
  ]

let reaction_target_type_to_string = function
  | Reaction_post -> "post"
  | Reaction_comment -> "comment"

let reaction_target_type_of_string_opt raw =
  match String.lowercase_ascii (String.trim raw) with
  | "post" -> Some Reaction_post
  | "comment" -> Some Reaction_comment
  | _ -> None

let valid_reaction_target_type_strings = [ "post"; "comment" ]

let board_reaction_emojis =
  [ "👍"; "❤️"; "🎉"; "🚀"; "👀"; "😕"; "👏"; "🔥" ]

let reaction_key ~target_type ~target_id ~user_id ~emoji =
  String.concat ":"
    [ reaction_target_type_to_string target_type; target_id; user_id; emoji ]

let reaction_to_yojson (r : reaction) : Yojson.Safe.t =
  `Assoc [
    ("target_type", `String (reaction_target_type_to_string r.target_type));
    ("target_id", `String r.target_id);
    ("user_id", `String (Agent_id.to_string r.user_id));
    ("emoji", `String r.emoji);
    ("created_at", `Float r.created_at);
  ]

let reaction_summary_to_yojson (summary : reaction_summary) : Yojson.Safe.t =
  `Assoc [
    ("emoji", `String summary.emoji);
    ("count", `Int summary.count);
    ("reacted", `Bool summary.reacted);
    ("has_reacted", `Bool summary.reacted);
    ( "recent_user_ids",
      `List (List.map (fun user_id -> `String user_id) summary.recent_user_ids)
    );
  ]

let reaction_toggle_result_to_yojson (result : reaction_toggle_result) :
    Yojson.Safe.t =
  `Assoc [
    ("target_type", `String (reaction_target_type_to_string result.target_type));
    ("target_id", `String result.target_id);
    ("user_id", `String result.user_id);
    ("emoji", `String result.emoji);
    ("reacted", `Bool result.reacted);
    ("summary", `List (List.map reaction_summary_to_yojson result.summary));
  ]

let reaction_of_yojson (json : Yojson.Safe.t) : reaction option =
  match
    Safe_ops.json_string_opt "target_type" json,
    Safe_ops.json_string_opt "target_id" json,
    Safe_ops.json_string_opt "user_id" json,
    Safe_ops.json_string_opt "emoji" json,
    Safe_ops.json_float_opt "created_at" json
  with
  | Some target_type_raw, Some target_id, Some user_id_raw, Some emoji,
    Some created_at ->
      (match
         reaction_target_type_of_string_opt target_type_raw,
         Agent_id.of_string user_id_raw
       with
       | Some target_type, Ok user_id ->
           Some { target_type; target_id; user_id; emoji; created_at }
       | _ -> None)
  | _ -> None

(** {1 Rewrite Helpers} *)

let rewrite_posts store =
  try
    ensure_masc_dir ();
    let path = persist_path () in
    let buf = Buffer.create 4096 in
    Hashtbl.iter (fun _ (pst : post) ->
      Buffer.add_string buf (Yojson.Safe.to_string (post_to_yojson pst));
      Buffer.add_char buf '\n'
    ) store.posts;
    (match Fs_compat.save_file_atomic path (Buffer.contents buf) with
     | Ok () -> ()
     | Error msg -> record_persist_error ~where:"rewrite_posts" msg)
  with Sys_error msg -> record_persist_error ~where:"rewrite_posts" msg

let rewrite_comments store =
  try
    ensure_masc_dir ();
    let path = comments_path () in
    let buf = Buffer.create 4096 in
    Hashtbl.iter (fun _ (cmt : comment) ->
      Buffer.add_string buf (Yojson.Safe.to_string (comment_to_yojson cmt));
      Buffer.add_char buf '\n'
    ) store.comments;
    (match Fs_compat.save_file_atomic path (Buffer.contents buf) with
     | Ok () -> ()
     | Error msg -> record_persist_error ~where:"rewrite_comments" msg)
  with Sys_error msg -> record_persist_error ~where:"rewrite_comments" msg

let reactions_jsonl_unlocked store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       Buffer.add_string buf (Yojson.Safe.to_string (reaction_to_yojson reaction));
       Buffer.add_char buf '\n')
    store.reactions;
  Buffer.contents buf

let save_reactions_jsonl content =
  try
    ensure_masc_dir ();
    let path = reactions_path () in
    (match Fs_compat.save_file_atomic path content with
     | Ok () -> ()
     | Error msg -> record_persist_error ~where:"rewrite_reactions" msg)
  with Sys_error msg -> record_persist_error ~where:"rewrite_reactions" msg

let rewrite_reactions_unlocked store =
  save_reactions_jsonl (reactions_jsonl_unlocked store)

let rewrite_reactions store =
  let content = with_lock store (fun () -> reactions_jsonl_unlocked store) in
  with_persist_lock store (fun () -> save_reactions_jsonl content)

(** {1 Append Helpers} *)

let append_post (p : post) =
  try
    ensure_masc_dir ();
    let path = persist_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (post_to_yojson p) ^ "\n");
    rotate_if_needed path
  with Sys_error msg -> record_persist_error ~where:"append_post" msg

let append_comment (c : comment) =
  try
    ensure_masc_dir ();
    let path = comments_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (comment_to_yojson c) ^ "\n");
    rotate_if_needed path
  with Sys_error msg -> record_persist_error ~where:"append_comment" msg

(** {1 Post Operations} *)

let create_post store ~author ~content ?title ?body ~post_kind ?meta_json
    ?(visibility=Internal) ?(ttl_hours=Limits.default_ttl_hours) ?hearth ?thread_id ()
  : (post, board_error) Result.t =
  maybe_sweep store;

  (* Validate author *)
  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->

  let ttl =
    match post_kind with
    | Automation_post | System_post ->
        let forced = Limits.automation_ttl_hours in
        if ttl_hours = 0 then forced
        else min ttl_hours forced
    | Human_post ->
        if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours
  in

  (* Normalize hearth: lowercase + trim *)
  let hearth = Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth in
  let expires_at =
    let now = Time_compat.now () in
    if ttl = 0 then 0.0 else now +. (Stdlib.Float.of_int ttl *. 3600.0)
  in
  let normalized_title, normalized_body, normalized_kind, normalized_meta =
    normalize_post_payload ~content ?title ?body ~post_kind ?meta_json ()
  in

  (* Validate body length *)
  if String.length normalized_body > Limits.max_content_length then
    Error (Validation_error (Printf.sprintf "Content too long: %d > %d"
      (String.length normalized_body) Limits.max_content_length))
  else if String.length normalized_body = 0 then
    Error (Validation_error "Content cannot be empty")
  else

  let board_result =
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
        Stdlib.incr store.post_count;
        invalidate_post_caches store;
        Ok post
      end)
  in
  (* Agent Economy: earn credits for board post.  Moved OUTSIDE
     [with_lock] because [Agent_economy.earn] does its own disk I/O
     against a ledger file unrelated to the board store, and modifies
     no board state — holding [store.mutex] across it was pure
     contention that blocked every other board reader/writer while
     the ledger write landed.  If the earn fails we log at warn; the
     post itself is already in the store and on disk. *)
  (match board_result with
   | Ok post ->
       with_persist_lock store (fun () -> append_post post);
       (match Agent_economy.earn
          ~base_path:(board_base_path ()) ~agent_name:author
          ~kind:Earn_board_post ~reason:"board post" () with
        | Ok _ -> ()
        | Error msg -> Log.BoardLog.warn "economy earn (post): %s" msg);
       Ok post
   | Error _ as e -> e)

let get_post store ~post_id : (post, board_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
        | Some post -> Ok post
        | None -> Error (Post_not_found post_id)
      )

(* Reads post + comments under a single critical section. The previous
   two-call sequence (get_post then get_comments) acquired
   [store.mutex] twice with [maybe_sweep] dispatching to the flusher
   actor between releases. That race window surfaces as
   [Mutex.lock: Resource deadlock avoided] under contended
   keeper_board_get traffic (e.g. ramarama keeper polling). Coalescing
   keeps the read atomic, removes one [maybe_sweep] dispatch, and
   eliminates the inter-call lock churn. *)
let get_post_and_comments store ~post_id
    : (post * comment list, board_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        let post_key = Post_id.to_string pid in
        match Hashtbl.find_opt store.posts post_key with
        | None -> Error (Post_not_found post_id)
        | Some post ->
            let comment_ids =
              Hashtbl.find_opt store.comments_by_post post_key
              |> Option.value ~default:[]
            in
            let comments =
              List.filter_map
                (fun cid -> Hashtbl.find_opt store.comments cid)
                comment_ids
            in
            let sorted =
              List.sort
                (fun (a : comment) (b : comment) ->
                  Stdlib.Float.compare a.created_at b.created_at)
                comments
            in
            Ok (post, sorted)
      )

let reclassify_posts store ?(limit = 5200) ?(dry_run = true) () =
  maybe_sweep store;
  with_lock store (fun () ->
    let scan_limit = max 0 (min limit 5200) in
    let json_string name json =
      match Yojson.Safe.Util.member name json with
      | `String value when not (String.equal (String.trim value) "") -> Some value
      | _ -> None
    in
    let json_float name json =
      match Yojson.Safe.Util.member name json with
      | `Float value -> Some value
      | `Int value -> Some (Stdlib.Float.of_int value)
      | _ -> None
    in
    let persisted_candidates =
      let now = Time_compat.now () in
      let path = persist_path () in
      if Fs_compat.file_exists path then
        Fs_compat.load_jsonl path
        |> List.filter_map (fun json ->
               match json_string "id" json, json_string "author" json with
               | Some id, Some author -> (
                   match Option.bind (json_string "visibility" json) visibility_of_string with
                   | Some visibility ->
                       let expires_at =
                         json_float "expires_at" json |> Option.value ~default:0.0
                       in
                       if Stdlib.Float.compare expires_at 0.0 > 0 && Stdlib.Float.compare expires_at now <= 0 then None
                       else
                         let stored_kind =
                           Option.bind (json_string "post_kind" json) post_kind_of_string
                         in
                         let hearth = json_string "hearth" json in
                         let meta_json =
                           match Yojson.Safe.Util.member "meta" json with
                           | `Assoc _ as meta -> Some meta
                           | _ -> None
                         in
                         let created_at =
                           json_float "created_at" json |> Option.value ~default:0.0
                         in
                         let canonical_kind =
                           legacy_migrate_post_kind ~author ~meta_json ~visibility
                             ~expires_at ~hearth
                         in
                         Some (id, created_at, stored_kind, canonical_kind)
                   | None -> None)
               | _ -> None)
      else []
    in
    let total = List.length persisted_candidates in
    let scanned = ref 0 in
    let changed = ref 0 in
    let unchanged = ref 0 in
    let changed_post_ids = ref [] in
    let record_changed_id id =
      if List.length !changed_post_ids < 20 then
        changed_post_ids := id :: !changed_post_ids
    in
    persisted_candidates
    |> List.sort (fun (_, created_a, _, _) (_, created_b, _, _) ->
           Stdlib.Float.compare created_b created_a)
    |> List.filteri (fun idx _ -> idx < scan_limit)
    |> List.iter (fun (post_id, _, stored_kind, canonical_kind) ->
           Stdlib.incr scanned;
           if Option.equal (=) stored_kind (Some canonical_kind) then
             Stdlib.incr unchanged
           else begin
             Stdlib.incr changed;
             record_changed_id post_id;
             if not dry_run then
               match Hashtbl.find_opt store.posts post_id with
               | Some post ->
                   Hashtbl.replace store.posts post_id
                     { post with post_kind = canonical_kind }
               | None -> ()
           end);
    if not dry_run && !changed > 0 then begin
      invalidate_post_caches store;
      rewrite_posts store;
      store.dirty_posts <- false;
      Hashtbl.clear store.dirty_post_ids;
      store.last_flush <- Time_compat.now ()
    end;
    {
      backend = "jsonl";
      dry_run;
      scanned = !scanned;
      changed = !changed;
      unchanged = !unchanged;
      skipped = max 0 (total - !scanned);
      apply_failures = 0;
      changed_post_ids = List.rev !changed_post_ids;
    })

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
            let cmp = Stdlib.Int.compare score_b score_a in
            if cmp <> 0 then cmp
            else Stdlib.Float.compare b.created_at a.created_at
          ) all in
          store.sorted_posts_cache <- Some sorted;
          sorted
    in
    (* Apply filters on the pre-sorted list *)
    let filtered = match visibility_filter with
      | None -> sorted_all
      | Some v -> List.filter (fun (p : post) -> (=) p.visibility v) sorted_all
    in
    let filtered = match hearth with
      | None -> filtered
      | Some h ->
          let h_norm = String.lowercase_ascii (String.trim h) in
          List.filter (fun (p : post) -> Option.equal String.equal p.hearth (Some h_norm)) filtered
    in
    (* Cap at Limits.max_posts (default 10_000) as an OOM guard. The
       previous inner cap of 100 was a duplicate of Board_dispatch.list_posts's
       fetch_limit guard (`max limit 200`) and broke offset-based pagination:
       when the dashboard requested offset=100 limit=100, Board_dispatch
       passed probe_fetch=201 here but we returned only 100, so fetched_len
       never exceeded window_end and has_more went stale at ~100-200 posts. *)
    take (min limit Limits.max_posts) filtered
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
      Stdlib.Float.compare b.created_at a.created_at
    ) matches in
    take limit sorted
  )

(** {1 Comment Operations} *)

let add_comment store ~post_id ~author ~content ?parent_id ?(ttl_hours=Limits.default_ttl_hours) ()
  : (comment, board_error) Result.t =
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

  let board_result =
    with_lock store (fun () ->
      (* Verify post exists *)
      match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
      | None -> Error (Post_not_found post_id)
      | Some post ->
          (* Check comment count using index *)
          let post_key = Post_id.to_string pid in
          let post_comment_count =
            Hashtbl.find_opt store.comments_by_post post_key
            |> Option.value ~default:[] |> List.length
          in
          if post_comment_count >= Limits.max_comments_per_post then
            Error (Capacity_exceeded { current = post_comment_count; max = Limits.max_comments_per_post })
          else begin
            let now = Time_compat.now () in
            let ttl =
              match post.post_kind with
              | Automation_post | System_post ->
                  let forced = Limits.automation_ttl_hours in
                  if ttl_hours = 0 then forced
                  else min ttl_hours forced
              | Human_post ->
                  if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours
            in
            let comment = {
              id = Comment_id.generate ();
              post_id = pid;
              parent_id = parent_cid;
              author = author_id;
              content;
              created_at = now;
              expires_at = if ttl = 0 then 0.0 else now +. (Stdlib.Float.of_int ttl *. 3600.0);
              votes_up = 0;
              votes_down = 0;
            } in
            Hashtbl.add store.comments (Comment_id.to_string comment.id) comment;
            (* Update comments_by_post index *)
            let post_key = Post_id.to_string pid in
            let existing = Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[] in
            Hashtbl.replace store.comments_by_post post_key (Comment_id.to_string comment.id :: existing);
            (* Update post reply count and updated_at *)
            Hashtbl.replace store.posts post_key
              { post with reply_count = post.reply_count + 1; updated_at = now };
            invalidate_post_caches store;
            invalidate_comment_caches store;
            Ok comment
          end)
  in
  match board_result with
  | Ok comment ->
      with_persist_lock store (fun () -> append_comment comment);
      Ok comment
  | Error _ as e -> e

let get_comments store ~post_id : (comment list, board_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        let post_key = Post_id.to_string pid in
        let comment_ids = Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[] in
        let comments = List.filter_map (fun cid ->
          Hashtbl.find_opt store.comments cid
        ) comment_ids in
        Ok (List.sort (fun (a : comment) (b : comment) -> Stdlib.Float.compare a.created_at b.created_at) comments)
      )

(** List all comments (for profile aggregation) *)
let list_comments store ?(limit=1000) () : comment list =
  maybe_sweep store;
  with_lock store (fun () ->
    let all = Hashtbl.fold (fun _ c acc -> c :: acc) store.comments [] in
    let sorted = List.sort (fun (a : comment) (b : comment) ->
      Stdlib.Float.compare b.created_at a.created_at
    ) all in
    List.filteri (fun i _ -> i < limit) sorted
  )

(** {1 Reactions} *)

let normalize_reaction_emoji raw =
  let emoji = String.trim raw in
  if List.exists (String.equal emoji) board_reaction_emojis then Ok emoji
  else
    Error
      (Validation_error
         (Printf.sprintf "Unsupported board reaction emoji: %s" emoji))

let ensure_reaction_target_unlocked store ~target_type ~target_id =
  match target_type with
  | Reaction_post ->
      (match Post_id.of_string target_id with
       | Error e -> Error e
       | Ok pid ->
           if Hashtbl.mem store.posts (Post_id.to_string pid) then Ok ()
           else Error (Post_not_found target_id))
  | Reaction_comment ->
      (match Comment_id.of_string target_id with
       | Error e -> Error e
       | Ok cid ->
           if Hashtbl.mem store.comments (Comment_id.to_string cid) then Ok ()
           else Error (Comment_not_found target_id))

type reaction_summary_bucket = {
  counts : (string, int) Hashtbl.t;
  reacted : (string, bool) Hashtbl.t;
  recent_users : (string, (string * float) list) Hashtbl.t;
}

let create_reaction_summary_bucket () =
  {
    counts = Hashtbl.create 8;
    reacted = Hashtbl.create 8;
    recent_users = Hashtbl.create 8;
  }

let add_reaction_to_summary_bucket bucket ?user_id (reaction : reaction) =
  let reaction_user_id = Agent_id.to_string reaction.user_id in
  let current =
    Hashtbl.find_opt bucket.counts reaction.emoji |> Option.value ~default:0
  in
  Hashtbl.replace bucket.counts reaction.emoji (current + 1);
  let users =
    Hashtbl.find_opt bucket.recent_users reaction.emoji
    |> Option.value ~default:[]
  in
  Hashtbl.replace bucket.recent_users reaction.emoji
    ((reaction_user_id, reaction.created_at) :: users);
  match user_id with
  | Some user when String.equal reaction_user_id user ->
      Hashtbl.replace bucket.reacted reaction.emoji true
  | Some _ | None -> ()

let reaction_summaries_of_bucket bucket =
  List.filter_map
    (fun emoji ->
       let count = Hashtbl.find_opt bucket.counts emoji |> Option.value ~default:0 in
       if count = 0 then None
       else
         Some
           {
             emoji;
             count;
             reacted =
               Hashtbl.find_opt bucket.reacted emoji |> Option.value ~default:false;
             recent_user_ids =
               Hashtbl.find_opt bucket.recent_users emoji
               |> Option.value ~default:[]
               |> List.sort (fun (_, a_ts) (_, b_ts) ->
                      Stdlib.Float.compare b_ts a_ts)
               |> List.map fst
               |> List.filteri (fun idx _ -> idx < 5);
           })
    board_reaction_emojis

let reaction_summaries_unlocked store ~target_type ~target_id ?user_id () =
  let bucket = create_reaction_summary_bucket () in
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       if (=) reaction.target_type target_type
          && String.equal reaction.target_id target_id
       then add_reaction_to_summary_bucket bucket ?user_id reaction)
    store.reactions;
  reaction_summaries_of_bucket bucket

let reaction_summaries_batch_unlocked store ~targets ?user_id () =
  let target_buckets = Hashtbl.create (List.length targets) in
  List.iter
    (fun target ->
       Hashtbl.replace target_buckets target
         (create_reaction_summary_bucket ()))
    targets;
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       match
         Hashtbl.find_opt target_buckets
           (reaction.target_type, reaction.target_id)
       with
       | None -> ()
       | Some bucket ->
           add_reaction_to_summary_bucket bucket ?user_id reaction)
    store.reactions;
  Hashtbl.fold
    (fun target bucket acc ->
       (target, reaction_summaries_of_bucket bucket) :: acc)
    target_buckets []

let normalize_reaction_user_id = function
  | Some user when not (String.equal (String.trim user) "") ->
      Some (String.trim user)
  | Some _ | None -> None

let list_reactions store ~target_type ~target_id ?user_id () =
  maybe_sweep store;
  let user_id = normalize_reaction_user_id user_id in
  with_lock store (fun () ->
      match ensure_reaction_target_unlocked store ~target_type ~target_id with
      | Error e -> Error e
      | Ok () ->
          Ok
            (reaction_summaries_unlocked store ~target_type ~target_id ?user_id
               ()))

let list_reactions_batch store ~targets ?user_id () =
  maybe_sweep store;
  let user_id = normalize_reaction_user_id user_id in
  with_lock store (fun () ->
      reaction_summaries_batch_unlocked store ~targets ?user_id ())

let toggle_reaction store ~target_type ~target_id ~user_id ~emoji :
    (reaction_toggle_result, board_error) Result.t =
  maybe_sweep store;
  match Agent_id.of_string user_id, normalize_reaction_emoji emoji with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok user_id, Ok emoji ->
      let user_id_string = Agent_id.to_string user_id in
      let result =
        with_lock store (fun () ->
            match ensure_reaction_target_unlocked store ~target_type ~target_id with
            | Error e -> Error e
            | Ok () ->
                let key =
                  reaction_key ~target_type ~target_id ~user_id:user_id_string
                    ~emoji
                in
                let reacted =
                  match Hashtbl.find_opt store.reactions key with
                  | Some _ ->
                      Hashtbl.remove store.reactions key;
                      false
                  | None ->
                      Hashtbl.replace store.reactions key
                        {
                          target_type;
                          target_id;
                          user_id;
                          emoji;
                          created_at = Time_compat.now ();
                        };
                      true
                in
                let summary =
                  reaction_summaries_unlocked store ~target_type ~target_id
                    ~user_id:user_id_string ()
                in
                Ok
                  {
                    target_type;
                    target_id;
                    user_id = user_id_string;
                    emoji;
                    reacted;
                    summary;
                  })
      in
      (match result with
       | Ok _ -> rewrite_reactions store
       | Error _ -> ());
      result

(** {1 SubBoard Operations} *)

let sub_board_access_to_string = function
  | Open -> "open"
  | Members_only -> "members_only"
  | Owner_only -> "owner_only"

let sub_board_access_of_string_opt = function
  | "open" -> Some Open
  | "members_only" -> Some Members_only
  | "owner_only" -> Some Owner_only
  | _ -> None

let sub_board_to_yojson (sb : sub_board) : Yojson.Safe.t =
  `Assoc [
    ("id", `String (Sub_board_id.to_string sb.id));
    ("slug", `String sb.slug);
    ("name", `String sb.name);
    ("description", `String sb.description);
    ("owner", `String (Agent_id.to_string sb.owner));
    ("access", `String (sub_board_access_to_string sb.access));
    ("created_at", `Float sb.created_at);
    ("post_count", `Int sb.post_count);
  ]

let sub_board_of_yojson (json : Yojson.Safe.t) : sub_board option =
  let open Safe_ops in
  match json with
  | `Assoc _ ->
      let id_s = json_string_opt "id" json |> Option.value ~default:"" in
      let slug = json_string_opt "slug" json |> Option.value ~default:"" in
      let name = json_string_opt "name" json |> Option.value ~default:"" in
      let description = json_string_opt "description" json |> Option.value ~default:"" in
      let owner_s = json_string_opt "owner" json |> Option.value ~default:"" in
      let access_s = json_string_opt "access" json |> Option.value ~default:"open" in
      let created_at = json_float_opt "created_at" json |> Option.value ~default:0.0 in
      let post_count = json_int_opt "post_count" json |> Option.value ~default:0 in
      (match Sub_board_id.of_string id_s, Agent_id.of_string owner_s,
             sub_board_access_of_string_opt access_s with
       | Ok id, Ok owner, Some access when slug <> "" ->
           Some { id; slug; name; description; owner; access; created_at; post_count }
       | _ -> None)
  | _ -> None

let rewrite_sub_boards store =
  try
    ensure_masc_dir ();
    let path = sub_boards_path () in
    let buf = Buffer.create 1024 in
    Hashtbl.iter (fun _ (sb : sub_board) ->
      Buffer.add_string buf (Yojson.Safe.to_string (sub_board_to_yojson sb));
      Buffer.add_char buf '\n'
    ) store.sub_boards;
    (match Fs_compat.save_file_atomic path (Buffer.contents buf) with
     | Ok () -> ()
     | Error msg -> record_persist_error ~where:"rewrite_sub_boards" msg)
  with Sys_error msg -> record_persist_error ~where:"rewrite_sub_boards" msg

let append_sub_board (sb : sub_board) =
  try
    ensure_masc_dir ();
    let path = sub_boards_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (sub_board_to_yojson sb) ^ "\n")
  with Sys_error msg -> record_persist_error ~where:"append_sub_board" msg

let valid_slug_pattern = Re.Pcre.re {|^[a-z0-9][a-z0-9_-]*$|} |> Re.compile

let create_sub_board store ~slug ~name ~description ~owner
    ?(access = Open) () : (sub_board, board_error) Result.t =
  let slug = String.lowercase_ascii (String.trim slug) in
  if String.length slug < 1 || String.length slug > 64
     || not (Re.execp valid_slug_pattern slug) then
    Error (Validation_error
      (Printf.sprintf "Invalid sub-board slug %S: must be 1-64 lowercase alphanumeric/-/_" slug))
  else
    match Agent_id.of_string owner with
    | Error e -> Error e
    | Ok owner_id ->
        with_lock store (fun () ->
          if Hashtbl.mem store.sub_boards_by_slug slug then
            Error (Already_exists
              (Printf.sprintf "Sub-board slug %S already exists" slug))
          else begin
            let current = Hashtbl.length store.sub_boards in
            if current >= Limits.max_sub_boards then
              Error (Capacity_exceeded { current; max = Limits.max_sub_boards })
            else begin
              let id = Sub_board_id.generate () in
              let sb = {
                id;
                slug;
                name = String.trim name;
                description = String.trim description;
                owner = owner_id;
                access;
                created_at = Time_compat.now ();
                post_count = 0;
              } in
              Hashtbl.replace store.sub_boards (Sub_board_id.to_string id) sb;
              Hashtbl.replace store.sub_boards_by_slug slug (Sub_board_id.to_string id);
              append_sub_board sb;
              Ok sb
            end
          end)

let get_sub_board store ~sub_board_id : (sub_board, board_error) Result.t =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sub_boards sub_board_id with
    | Some sb -> Ok sb
    | None ->
        (* fallback: try slug *)
        match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
        | Some id ->
            (match Hashtbl.find_opt store.sub_boards id with
             | Some sb -> Ok sb
             | None -> Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id)))
        | None -> Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id)))

let list_sub_boards store : sub_board list =
  with_lock store (fun () ->
    Hashtbl.fold (fun _ sb acc -> sb :: acc) store.sub_boards []
    |> List.sort (fun (a : sub_board) (b : sub_board) ->
        compare a.created_at b.created_at))

let delete_sub_board store ~sub_board_id : (unit, board_error) Result.t =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sub_boards sub_board_id with
    | None ->
        (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
         | None -> Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))
         | Some id ->
             Hashtbl.remove store.sub_boards id;
             Hashtbl.remove store.sub_boards_by_slug sub_board_id;
             rewrite_sub_boards store;
             Ok ())
    | Some sb ->
        Hashtbl.remove store.sub_boards sub_board_id;
        Hashtbl.remove store.sub_boards_by_slug sb.slug;
        rewrite_sub_boards store;
        Ok ())

(** {1 Voting - Deduplicated} *)
