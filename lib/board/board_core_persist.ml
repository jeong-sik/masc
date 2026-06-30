module Hashtbl = Stdlib.Hashtbl
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module String = Stdlib.String

(** Board Core — JSONL store logic and persistence. Types are in Board_types. *)
include Board_core_classify
include Board_core_payload

let flush_interval_sec = Env_config.Board.flush_interval_sec
let flusher_inbox_capacity = Env_config.Board.flusher_inbox_capacity

(** Monotonic count of sweep/flush schedule messages skipped because the
    bounded flusher inbox had no room for the whole batch. *)
let flusher_schedule_dropped = Atomic.make 0
let flusher_schedule_dropped_count () = Atomic.get flusher_schedule_dropped

let record_flusher_schedule_drop scheduled_count =
  (* Single atomic add instead of N increments, so a concurrent reader cannot
     observe a partial count. [scheduled_count] is a [List.length], so it is
     non-negative. *)
  Atomic.fetch_and_add flusher_schedule_dropped scheduled_count |> ignore
;;

(** Monotonic counter of persist failures (disk full, permission errors, etc.). *)
let persist_errors = Atomic.make 0
let persist_error_count () = Atomic.get persist_errors
let record_persist_error ~where msg =
  Atomic.incr persist_errors;
  Log.BoardLog.error "persist error (%s): %s" where msg
;;
let create_store () =
  { posts = Hashtbl.create 1024
  ; comments = Hashtbl.create 4096
  ; vote_log = Hashtbl.create 2048
  ; post_count = ref 0
  ; last_sweep = Time_compat.now ()
  ; mutex = Eio.Mutex.create ()
  ; persist_mutex = Eio.Mutex.create ()
  ; karma_cache = None
  ; sorted_posts_cache = None
  ; comments_by_post = Hashtbl.create 1024
  ; reactions = Hashtbl.create 4096
  ; dirty_posts = false
  ; dirty_comments = false
  ; dirty_post_ids = Hashtbl.create 256
  ; dirty_comment_ids = Hashtbl.create 512
  ; last_flush = Time_compat.now ()
  ; flusher_inbox = Eio.Stream.create flusher_inbox_capacity
  ; sub_boards = Hashtbl.create 64
  ; sub_boards_by_slug = Hashtbl.create 64
  ; posts_by_turn_ref = Hashtbl.create 256
  ; posts_by_run_id = Hashtbl.create 256
  }
;;

(* RFC-0233 §7: maintain the origin secondary indexes. Shared by the create
   path (create_fresh) and the load path (load_persisted_posts) so the two
   stay in lockstep — a single maintenance site, not an N-of-M copy. *)
let index_post_origin store (post : post) =
  match post.origin with
  | None -> ()
  | Some (o : post_origin) ->
    let pid = Post_id.to_string post.id in
    (match o.turn_ref with
     | Some tr -> Hashtbl.replace store.posts_by_turn_ref (Ids.Turn_ref.to_string tr) pid
     | None -> ());
    (match o.fusion_run_id with
     | Some run_id -> Hashtbl.replace store.posts_by_run_id run_id pid
     | None -> ())
;;

(* Prune the origin indexes when a post is swept / cap-evicted, mirroring the
   [comments_by_post] cleanup in the sweeper. Without this the index tables
   would grow unbounded over the store lifetime (the double-lookup in
   [find_post_by_*] keeps a stale key from returning a wrong post, but the
   entry would still leak). Single-valued [remove] matches the single-valued
   [replace] in [index_post_origin]. *)
let unindex_post_origin store (post : post) =
  match post.origin with
  | None -> ()
  | Some (o : post_origin) ->
    (match o.turn_ref with
     | Some tr -> Hashtbl.remove store.posts_by_turn_ref (Ids.Turn_ref.to_string tr)
     | None -> ());
    (match o.fusion_run_id with
     | Some run_id -> Hashtbl.remove store.posts_by_run_id run_id
     | None -> ())
;;

(** {1 Comment Rate Limiting}  Per-author sliding-window tracker extracted to [Board_comment_rate_limit] (godfile decomp). Module-level Hashtbl avoids changing the store type; all access is inside the ... *)
let check_comment_rate_limit = Board_comment_rate_limit.check
let record_comment_timestamp = Board_comment_rate_limit.record
let reset_comment_rate_tracker = Board_comment_rate_limit.reset

(** Remove [value] from the string list stored at [key] in [tbl]. Removes the key entirely when the list becomes empty. *)
let remove_from_list_index tbl key value =
  match Hashtbl.find_opt tbl key with
  | None -> ()
  | Some ids ->
    (match List.filter (fun id -> not (String.equal id value)) ids with
     | [] -> Hashtbl.remove tbl key
     | filtered -> Hashtbl.replace tbl key filtered)
;;

(** Invalidate caches that depend on post data *)
let invalidate_post_caches store =
  store.karma_cache <- None;
  store.sorted_posts_cache <- None
;;

(** Invalidate caches that depend on comment data *)
let invalidate_comment_caches store = store.karma_cache <- None
let mark_dirty_post store post_id =
  store.dirty_posts <- true;
  Hashtbl.replace store.dirty_post_ids post_id ()
;;
let mark_dirty_comment store comment_id =
  store.dirty_comments <- true;
  Hashtbl.replace store.dirty_comment_ids comment_id ()
;;

(** {1 Eio-style Locking with Switch.on_release} *)

let with_lock store f = Eio.Mutex.use_rw ~protect:true store.mutex (fun () -> f ())

(** Serialize JSONL writes. Callers must never hold the state mutex while
    acquiring [persist_mutex]; compute snapshots under [with_lock], release it,
    then call [with_persist_lock]. *)
let with_persist_lock store f =
  let started = Time_compat.now () in
  Eio.Mutex.use_rw ~protect:true store.persist_mutex (fun () ->
    let acquired = Time_compat.now () in
    Board_metrics_hooks.observe_persist_lock_acquire_sec
      (acquired -. started);
    let result = f () in
    let released = Time_compat.now () in
    Board_metrics_hooks.observe_persist_lock_held_sec
      (released -. acquired);
    result)
;;

(** {1 Sweeper - Aggressive Cleanup} *)
let sweep store =
  with_lock store (fun () ->
    let now = Time_compat.now () in
    let removed_posts = ref 0 in
    let removed_comments = ref 0 in
    let expired_posts =
      Hashtbl.fold
        (fun id (post : post) acc ->
           if
             Stdlib.Float.compare post.expires_at 0.0 > 0
             && Stdlib.Float.compare post.expires_at now < 0
             && !removed_posts < Limits.sweeper_batch_size
           then (
             Stdlib.incr removed_posts;
             id :: acc)
           else acc)
        store.posts
        []
    in
    List.iter
      (fun id ->
         (match Hashtbl.find_opt store.posts id with
          | Some p -> unindex_post_origin store p
          | None -> ());
         Hashtbl.remove store.posts id;
         Hashtbl.remove store.comments_by_post id;
         Stdlib.decr store.post_count)
      expired_posts;
    let expired_comments =
      Hashtbl.fold
        (fun id (comment : comment) acc ->
           if
             Stdlib.Float.compare comment.expires_at 0.0 > 0
             && Stdlib.Float.compare comment.expires_at now < 0
             && !removed_comments < Limits.sweeper_batch_size
           then (
             Stdlib.incr removed_comments;
             id :: acc)
           else acc)
        store.comments
        []
    in
    List.iter
      (fun cid ->
         (match Hashtbl.find_opt store.comments cid with
          | Some c ->
            remove_from_list_index
              store.comments_by_post
              (Post_id.to_string c.post_id)
              cid
          | None -> ());
         Hashtbl.remove store.comments cid)
      expired_comments;
    let cap_evicted = ref 0 in
    if Limits.author_post_cap > 0
    then (
      let author_posts = Hashtbl.create 64 in
      Hashtbl.iter
        (fun _ (post : post) ->
           let key = Agent_id.to_string post.author in
           let existing = Hashtbl.find_opt author_posts key |> Option.value ~default:[] in
           Hashtbl.replace author_posts key (post :: existing))
        store.posts;
      Hashtbl.iter
        (fun _author posts ->
           if List.length posts > Limits.author_post_cap
           then (
             let sorted =
               List.sort
                 (fun (a : post) (b : post) ->
                    Stdlib.Float.compare a.created_at b.created_at)
                 posts
             in
             let excess = List.length sorted - Limits.author_post_cap in
             let rec take_first n = function
               | _ when n <= 0 -> []
               | [] -> []
               | x :: xs -> x :: take_first (n - 1) xs
             in
             let to_evict = take_first excess sorted in
             List.iter
               (fun (post : post) ->
                  let id = Post_id.to_string post.id in
                  unindex_post_origin store post;
                  Hashtbl.remove store.posts id;
                  Hashtbl.remove store.comments_by_post id;
                  Stdlib.decr store.post_count;
                  Stdlib.incr cap_evicted)
               to_evict))
        author_posts);
    let window = Stdlib.Float.of_int Limits.comment_rate_window_sec in
    Board_comment_rate_limit.sweep_stale ~now ~window;
    if !removed_posts > 0 || !cap_evicted > 0 then invalidate_post_caches store;
    if !removed_comments > 0 then invalidate_comment_caches store;
    store.last_sweep <- now;
    !removed_posts, !removed_comments)
;;

(** Auto-sweep if needed, delegates to flusher actor inbox *)
type scheduled_flusher_msg =
  { msg : flusher_msg
  ; previous_ts : float
  ; reserved_ts : float
  }

let rollback_scheduled_msg store scheduled =
  with_lock store (fun () ->
    match scheduled.msg with
    | Sweep ->
      if Stdlib.Float.equal store.last_sweep scheduled.reserved_ts
      then store.last_sweep <- scheduled.previous_ts
    | Flush ->
      if Stdlib.Float.equal store.last_flush scheduled.reserved_ts
      then store.last_flush <- scheduled.previous_ts)
;;

let enqueue_scheduled_msg store scheduled =
  try Eio.Stream.add store.flusher_inbox scheduled.msg
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let bt = Printexc.get_raw_backtrace () in
    rollback_scheduled_msg store scheduled;
    Printexc.raise_with_backtrace exn bt
;;

let enqueue_scheduled_msgs store scheduled =
  let scheduled_count = List.length scheduled in
  let inbox_len = Eio.Stream.length store.flusher_inbox in
  if scheduled_count = 0
  then ()
  else if scheduled_count > flusher_inbox_capacity - inbox_len
  then (
    record_flusher_schedule_drop scheduled_count;
    List.iter (rollback_scheduled_msg store) scheduled;
    Log.BoardLog.warn
      "board flusher inbox full; skipped scheduling sweep/flush messages \
       (queued=%d, requested=%d, capacity=%d)"
      inbox_len scheduled_count flusher_inbox_capacity)
  else (
    (* [maybe_sweep] is the only producer of these messages and reserves
       timestamps under [store.mutex] before this check. Once there is room for
       the whole batch, these adds should not block on capacity. *)
    List.iter (enqueue_scheduled_msg store) scheduled)
;;

let maybe_sweep store =
  let scheduled =
    with_lock store (fun () ->
      let now = Time_compat.now () in
      let scheduled = [] in
      let scheduled =
        if
          Stdlib.Float.compare
            (now -. store.last_sweep)
            (Stdlib.Float.of_int Limits.sweeper_interval_sec)
          > 0
        then (
          let previous_ts = store.last_sweep in
          store.last_sweep <- now;
          { msg = Sweep; previous_ts; reserved_ts = now } :: scheduled)
        else scheduled
      in
      let scheduled =
        if Stdlib.Float.compare (now -. store.last_flush) flush_interval_sec > 0
        then (
          let previous_ts = store.last_flush in
          store.last_flush <- now;
          { msg = Flush; previous_ts; reserved_ts = now } :: scheduled)
        else scheduled
      in
      List.rev scheduled)
  in
  enqueue_scheduled_msgs store scheduled
;;

let reset_sweep_schedule_for_test store =
  with_lock store (fun () ->
    store.last_sweep <- 0.0;
    store.last_flush <- 0.0)
;;

let sweep_schedule_timestamps_for_test store =
  with_lock store (fun () -> store.last_sweep, store.last_flush)
;;

(** {1 Persistence Paths} *)
let board_base_path = Board_paths.board_base_path
let board_masc_dir = Board_paths.board_masc_dir
let persist_path = Board_paths.persist_path
let comments_path = Board_paths.comments_path
let reactions_path = Board_paths.reactions_path
let sub_boards_path = Board_paths.sub_boards_path
let ensure_dir = Board_paths.ensure_dir
let ensure_masc_dir = Board_paths.ensure_masc_dir
let max_jsonl_bytes = Board_paths.max_jsonl_bytes
let rotate_if_needed = Board_paths.rotate_if_needed
include Board_core_json

(** {1 Rewrite Helpers} *)
let posts_jsonl_unlocked store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun _ (pst : post) ->
       Buffer.add_string buf (Yojson.Safe.to_string (post_to_yojson pst));
       Buffer.add_char buf '\n')
    store.posts;
  Buffer.contents buf
;;
let save_posts_jsonl content =
  try
    ensure_masc_dir ();
    let path = persist_path () in
    match Fs_compat.save_file_atomic path content with
    | Ok () -> ()
    | Error msg -> record_persist_error ~where:"rewrite_posts" msg
  with
  | Sys_error msg -> record_persist_error ~where:"rewrite_posts" msg
;;
let rewrite_posts store =
  let content = with_lock store (fun () -> posts_jsonl_unlocked store) in
  with_persist_lock store (fun () -> save_posts_jsonl content)
;;
let rewrite_comments store =
  try
    ensure_masc_dir ();
    let path = comments_path () in
    let buf = Buffer.create 4096 in
    Hashtbl.iter
      (fun _ (cmt : comment) ->
         Buffer.add_string buf (Yojson.Safe.to_string (comment_to_yojson cmt));
         Buffer.add_char buf '\n')
      store.comments;
    match Fs_compat.save_file_atomic path (Buffer.contents buf) with
    | Ok () -> ()
    | Error msg -> record_persist_error ~where:"rewrite_comments" msg
  with
  | Sys_error msg -> record_persist_error ~where:"rewrite_comments" msg
;;
let reactions_jsonl_unlocked store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       Buffer.add_string buf (Yojson.Safe.to_string (reaction_to_yojson reaction));
       Buffer.add_char buf '\n')
    store.reactions;
  Buffer.contents buf
;;
let save_reactions_jsonl content =
  try
    ensure_masc_dir ();
    let path = reactions_path () in
    match Fs_compat.save_file_atomic path content with
    | Ok () -> ()
    | Error msg -> record_persist_error ~where:"rewrite_reactions" msg
  with
  | Sys_error msg -> record_persist_error ~where:"rewrite_reactions" msg
;;
let rewrite_reactions_unlocked store =
  save_reactions_jsonl (reactions_jsonl_unlocked store)
;;
let rewrite_reactions store =
  let content = with_lock store (fun () -> reactions_jsonl_unlocked store) in
  with_persist_lock store (fun () -> save_reactions_jsonl content)
;;

(** {1 Append Helpers}  RFC-0091: [append_post] / [append_comment] are *create-only fast paths*. *)
let append_post (p : post) =
  try
    ensure_masc_dir ();
    let path = persist_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (post_to_yojson p) ^ "\n");
    rotate_if_needed path
  with
  | Sys_error msg -> record_persist_error ~where:"append_post" msg
;;
let append_comment (c : comment) =
  try
    ensure_masc_dir ();
    let path = comments_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (comment_to_yojson c) ^ "\n");
    rotate_if_needed path
  with
  | Sys_error msg -> record_persist_error ~where:"append_comment" msg
;;
let sub_board_access_to_string = Board_sub_board_json.sub_board_access_to_string
let sub_board_access_of_string_opt = Board_sub_board_json.sub_board_access_of_string_opt
let sub_board_post_counts_unlocked store =
  let counts = Hashtbl.create 64 in
  Hashtbl.iter
    (fun _ (p : post) ->
       match p.hearth with
       | None -> ()
       | Some slug ->
         let count = Hashtbl.find_opt counts slug |> Option.value ~default:0 in
         Hashtbl.replace counts slug (count + 1))
    store.posts;
  counts
;;
let sub_board_post_count_from_counts counts slug =
  Hashtbl.find_opt counts slug |> Option.value ~default:0
;;
let sub_board_with_post_count_unlocked store (sb : sub_board) =
  let counts = sub_board_post_counts_unlocked store in
  { sb with post_count = sub_board_post_count_from_counts counts sb.slug }
;;
let sub_board_with_post_count counts (sb : sub_board) =
  { sb with post_count = sub_board_post_count_from_counts counts sb.slug }
;;
let sub_board_author_allowed (sb : sub_board) ~author_id =
  let author = Agent_id.to_string author_id in
  let owner = Agent_id.to_string sb.owner in
  match sb.access with
  | Open -> true
  | Owner_only -> String.equal author owner
  | Members_only ->
    String.equal author owner
    || List.exists
         (fun member_id -> String.equal author (Agent_id.to_string member_id))
         sb.members
;;
let validate_sub_board_post_policy_unlocked store ~author_id ~hearth =
  match hearth with
  | None -> Ok ()
  | Some slug ->
    (match Hashtbl.find_opt store.sub_boards_by_slug slug with
     | None -> Ok ()
     | Some id ->
       (match Hashtbl.find_opt store.sub_boards id with
        | None -> Ok ()
        | Some sb when sub_board_author_allowed sb ~author_id -> Ok ()
        | Some sb ->
          let author = Agent_id.to_string author_id in
          let access = sub_board_access_to_string sb.access in
          Error
            (Validation_error
               (Printf.sprintf "Sub-board %S is %s; %s cannot post" sb.slug access author))))
;;

(** {1 Post Operations} *)
type create_post_outcome =
  | Fresh_post of post
  | Dedup_hit of post
  | Rolled_up_post of post
let post_of_create_post_outcome = function
  | Fresh_post post | Dedup_hit post | Rolled_up_post post -> post
;;
let status_rollup_task_id = Board_core_status_rollup.status_rollup_task_id
let is_status_rollup_candidate = Board_core_status_rollup.is_status_rollup_candidate
let find_status_rollup_target_unlocked = Board_core_status_rollup.find_status_rollup_target_unlocked
let create_post_with_outcome
      store
      ~author
      ~content
      ?title
      ?body
      ~post_kind
      ?meta_json
      ?(visibility = Internal)
      ?(ttl_hours = Limits.default_ttl_hours)
  ?hearth
  ?thread_id
  ?origin
  ()
  : (create_post_outcome, board_error) Result.t
  =
  maybe_sweep store;
  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->
    let ttl =
      match post_kind with
      | Automation_post | System_post ->
        let forced = Limits.automation_ttl_hours in
        if ttl_hours = 0 then forced else min ttl_hours forced
      | Human_post -> if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours
    in
    let hearth = Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth in
    let expires_at =
      let now = Time_compat.now () in
      if ttl = 0 then 0.0 else now +. (Stdlib.Float.of_int ttl *. Masc_time_constants.hour)
    in
    match
      normalize_post_payload ~content ?title ?body ~post_kind ?meta_json ()
    with
    | Error (Board_core_payload.Meta_not_assoc payload) ->
        Error
          (Validation_error
             (Printf.sprintf
                "Malformed meta_json: expected JSON object, got %s"
                (Yojson.Safe.to_string payload)))
    | Ok (normalized_title, normalized_body, normalized_kind, normalized_meta)
      ->
    if String.length normalized_body > Limits.max_content_length
    then
      Error
        (Validation_error
           (Printf.sprintf
              "Content too long: %d > %d"
              (String.length normalized_body)
              Limits.max_content_length))
    else if String.length normalized_body = 0
    then Error (Validation_error "Content cannot be empty")
    else (
      let board_result =
        with_lock store (fun () ->
(* Content dedup: reject identical (author, hearth, thread, body) within a short window.
   Agent automation can emit the same board post repeatedly under retry; the dedup key
   includes hearth/thread so unrelated posts from the same author still pass. *)
          let author_str = Agent_id.to_string author_id in
          let hearth_part = Option.value ~default:"" hearth in
          let thread_part = Option.value ~default:"" thread_id in
          let dedup_key =
            String.concat "\x00"
              [ author_str; hearth_part; thread_part; normalized_body ]
          in
          let dedup_match =
            Hashtbl.fold
              (fun _ (p : post) acc ->
                 let p_key =
                   String.concat "\x00"
                     [ Agent_id.to_string p.author
                     ; Option.value ~default:"" p.hearth
                     ; Option.value ~default:"" p.thread_id
                     ; p.body
                     ]
                 in
                 if String.equal p_key dedup_key then Some p else acc)
              store.posts None
          in
          match dedup_match with
          | Some existing ->
            Log.BoardLog.info
              "dedup: skipping duplicate post author=%s body_len=%d \
               existing_id=%s"
              author_str (String.length normalized_body)
              (Post_id.to_string existing.id);
            Ok (`Dedup_hit existing)
          | None ->
            (match validate_sub_board_post_policy_unlocked store
                     ~author_id ~hearth
             with
            | Error e -> Error e
            | Ok () ->
              let now = Time_compat.now () in
              let create_fresh () =
                if !(store.post_count) >= Limits.max_posts
                then
                  Error
                    (Capacity_exceeded
                       { current = !(store.post_count); max = Limits.max_posts })
                else
                  let post =
                    { id = Post_id.generate ()
                    ; author = author_id
                    ; title = normalized_title
                    ; body = normalized_body
                    ; content = normalized_body
                    ; post_kind = normalized_kind
                    ; meta_json = normalized_meta
                    ; visibility
                    ; created_at = now
                    ; updated_at = now
                    ; expires_at
                    ; votes_up = 0
                    ; votes_down = 0
                    ; reply_count = 0
                    ; pinned = false
                    ; hearth
                    ; thread_id
                    ; origin
                    }
                  in
                  Hashtbl.add store.posts (Post_id.to_string post.id) post;
                  index_post_origin store post;
                  Stdlib.incr store.post_count;
                  invalidate_post_caches store;
                  Ok (`Fresh post)
              in
              let rollup_task_id =
                if
                  is_status_rollup_candidate
                    ~post_kind:normalized_kind
                    ~title:normalized_title
                    ~body:normalized_body
                    ~meta_json:normalized_meta
                then
                  status_rollup_task_id
                    ~title:normalized_title
                    ~body:normalized_body
                    ~meta_json:normalized_meta
                else None
              in
              (match rollup_task_id with
               | Some task_id ->
                 (match
                    find_status_rollup_target_unlocked
                      store
                      ~author_id
                      ~hearth
                      ~visibility
                      ~task_id
                      ~now
                  with
                  | Some existing ->
                    let updated =
                      { existing with
                        title = normalized_title
                      ; body = normalized_body
                      ; content = normalized_body
                      ; post_kind = normalized_kind
                      ; meta_json = normalized_meta
                      ; updated_at = now
                      ; expires_at
                      }
                    in
                    let existing_id = Post_id.to_string existing.id in
                    Hashtbl.replace store.posts existing_id updated;
                    mark_dirty_post store existing_id;
                    invalidate_post_caches store;
                    Log.BoardLog.info
                      "status-rollup: updated automation progress post \
                       author=%s task_id=%s existing_id=%s body_len=%d"
                      author_str
                      task_id
                      existing_id
                      (String.length normalized_body);
                    Ok (`Rolled_up (updated, posts_jsonl_unlocked store))
                  | None -> create_fresh ())
               | None -> create_fresh ())))
      in
      match board_result with
      | Ok (`Fresh post) ->
        with_persist_lock store (fun () -> append_post post);
        (match
           Board_effect_hooks.earn
             ~base_path:(board_base_path ())
             ~agent_name:author
             ~kind:Board_post
             ~reason:"board post"
             ()
         with
         | Ok () -> ()
         | Error msg -> Log.BoardLog.warn "economy earn (post): %s" msg);
        Ok (Fresh_post post)
      | Ok (`Rolled_up (post, posts_jsonl)) ->
        with_persist_lock store (fun () -> save_posts_jsonl posts_jsonl);
        Ok (Rolled_up_post post)
      | Ok (`Dedup_hit existing) -> Ok (Dedup_hit existing)
      | Error _ as e -> e)
;;

(* Owner-gated in-place edit of an existing post's title/body. Mirrors the
   status-rollup update path (find -> [{ existing with ... }] -> [Hashtbl.replace]
   -> [mark_dirty_post] -> snapshot save) but is initiated by an explicit edit
   request rather than a same-key automation re-post. [post_kind]/[meta_json]/
   [visibility]/[hearth]/[thread_id]/[origin] are intentionally immutable here;
   edit only touches the textual content + [updated_at]. Author mismatch returns
   [Unauthorized] (no silent ignore). *)
let update_post_with_outcome
      store
      ~post_id
      ~editor
      ~content
      ?title
      ?body
      ()
  : (post, board_error) Result.t
  =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
  match Agent_id.of_string editor with
  | Error e -> Error e
  | Ok editor_id ->
  (* [post_kind] is required by [normalize_post_payload] but the result kind is
     discarded — the existing post's kind is preserved via [{ existing with }]. *)
  match
    normalize_post_payload ~content ?title ?body ~post_kind:Human_post ()
  with
  | Error (Board_core_payload.Meta_not_assoc payload) ->
      Error
        (Validation_error
           (Printf.sprintf
              "Malformed meta_json: expected JSON object, got %s"
              (Yojson.Safe.to_string payload)))
  | Ok (normalized_title, normalized_body, _kind, _meta) ->
    if String.length normalized_body > Limits.max_content_length
    then
      Error
        (Validation_error
           (Printf.sprintf
              "Content too long: %d > %d"
              (String.length normalized_body)
              Limits.max_content_length))
    else if String.length normalized_body = 0
    then Error (Validation_error "Content cannot be empty")
    else (
      let snapshot_result =
        with_lock store (fun () ->
          let key = Post_id.to_string pid in
          match Hashtbl.find_opt store.posts key with
          | None -> Error (Post_not_found post_id)
          | Some existing ->
            let owner = Agent_id.to_string existing.author in
            let editor_str = Agent_id.to_string editor_id in
            if not (String.equal owner editor_str)
            then
              Error
                (Unauthorized
                   (Printf.sprintf
                      "agent %s cannot edit post %s owned by %s"
                      editor_str
                      key
                      owner))
            else (
              let now = Time_compat.now () in
              let updated =
                { existing with
                  title = normalized_title
                ; body = normalized_body
                ; content = normalized_body
                ; updated_at = now
                }
              in
              Hashtbl.replace store.posts key updated;
              mark_dirty_post store key;
              invalidate_post_caches store;
              Ok (updated, posts_jsonl_unlocked store)))
      in
      match snapshot_result with
      | Error _ as e -> e
      | Ok (updated, posts_jsonl) ->
        with_persist_lock store (fun () -> save_posts_jsonl posts_jsonl);
        Ok updated)
;;
let create_post
      store
      ~author
      ~content
      ?title
      ?body
      ~post_kind
      ?meta_json
      ?visibility
      ?ttl_hours
      ?hearth
      ?thread_id
      ?origin
      ()
  =
  match
    create_post_with_outcome
      store
      ~author
      ~content
      ?title
      ?body
      ~post_kind
      ?meta_json
      ?visibility
      ?ttl_hours
      ?hearth
      ?thread_id
      ?origin
      ()
  with
  | Ok outcome -> Ok (post_of_create_post_outcome outcome)
  | Error _ as err -> err
;;
