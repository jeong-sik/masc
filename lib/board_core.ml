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
  karma_cache = None;
  sorted_posts_cache = None;
  comments_by_post = Hashtbl.create 1024;
  dirty_posts = false;
  dirty_comments = false;
  last_flush = Time_compat.now ();
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
            compare a.created_at b.created_at
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
            decr store.post_count;
            incr cap_evicted
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
let deferred_flush_fn : (store -> unit) ref = ref (fun _ -> ())

(** Auto-sweep if needed, also triggers deferred flush via callback *)
let maybe_sweep store =
  let now = Time_compat.now () in
  if now -. store.last_sweep > float_of_int Limits.sweeper_interval_sec then
    (try ignore (sweep store)
     with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.BoardLog.warn "sweep failed: %s" (Printexc.to_string exn));
  if now -. store.last_flush > flush_interval_sec then
    !deferred_flush_fn store

(** {1 Persistence Paths} *)

let board_base_path () =
  Env_config_core.base_path ()

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

(** {1 Rewrite Helpers} *)

let rewrite_posts store =
  try
    ensure_masc_dir ();
    let path = persist_path () in
    let buf = Buffer.create 4096 in
    Hashtbl.iter (fun _ (pst : post) ->
      Buffer.add_string buf (Yojson.Safe.to_string (post_to_yojson pst) ^ "\n")
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
      Buffer.add_string buf (Yojson.Safe.to_string (comment_to_yojson cmt) ^ "\n")
    ) store.comments;
    (match Fs_compat.save_file_atomic path (Buffer.contents buf) with
     | Ok () -> ()
     | Error msg -> record_persist_error ~where:"rewrite_comments" msg)
  with Sys_error msg -> record_persist_error ~where:"rewrite_comments" msg

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
  : (post, board_error) result =
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
    if ttl = 0 then 0.0 else now +. (float_of_int ttl *. 3600.0)
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
        incr store.post_count;
        invalidate_post_caches store;
        append_post post;
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
       (match Agent_economy.earn
          ~base_path:(board_base_path ()) ~agent_name:author
          ~kind:Earn_board_post ~reason:"board post" () with
        | Ok _ -> ()
        | Error msg -> Log.BoardLog.warn "economy earn (post): %s" msg);
       Ok post
   | Error _ as e -> e)

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

let reclassify_posts store ?(limit = 5200) ?(dry_run = true) () =
  maybe_sweep store;
  with_lock store (fun () ->
    let scan_limit = max 0 (min limit 5200) in
    let json_string name json =
      match Yojson.Safe.Util.member name json with
      | `String value when String.trim value <> "" -> Some value
      | _ -> None
    in
    let json_float name json =
      match Yojson.Safe.Util.member name json with
      | `Float value -> Some value
      | `Int value -> Some (float_of_int value)
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
                       if expires_at > 0.0 && expires_at <= now then None
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
           compare created_b created_a)
    |> List.filteri (fun idx _ -> idx < scan_limit)
    |> List.iter (fun (post_id, _, stored_kind, canonical_kind) ->
           incr scanned;
           if stored_kind = Some canonical_kind then
             incr unchanged
           else begin
             incr changed;
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
            expires_at = if ttl = 0 then 0.0 else now +. (float_of_int ttl *. 3600.0);
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
        let comment_ids = Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[] in
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
