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
  ; flusher_inbox = Eio.Stream.create 1000
  ; sub_boards = Hashtbl.create 64
  ; sub_boards_by_slug = Hashtbl.create 64
  }
;;

(** {1 Comment Rate Limiting}

    Per-author sliding-window tracker extracted to
    [Board_comment_rate_limit] (godfile decomp). Module-level Hashtbl
    avoids changing the store type; all access is inside the existing
    [with_lock store] in [add_comment_with_status]. *)

let check_comment_rate_limit = Board_comment_rate_limit.check
let record_comment_timestamp = Board_comment_rate_limit.record
let reset_comment_rate_tracker = Board_comment_rate_limit.reset

(** Remove [value] from the string list stored at [key] in [tbl].
    Removes the key entirely when the list becomes empty. *)
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

(** Execute f with mutex held, using Eio.Mutex for proper concurrency *)
let with_lock store f = Eio.Mutex.use_rw ~protect:true store.mutex (fun () -> f ())

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
;;

(** {1 Sweeper - Aggressive Cleanup} *)

let sweep store =
  with_lock store (fun () ->
    let now = Time_compat.now () in
    let removed_posts = ref 0 in
    let removed_comments = ref 0 in
    (* Sweep posts - with batch limit; skip permanent posts (expires_at = 0) *)
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
         Hashtbl.remove store.posts id;
         Hashtbl.remove store.comments_by_post id;
         Stdlib.decr store.post_count)
      expired_posts;
    (* Sweep comments - skip permanent (expires_at = 0) *)
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
    (* Author cap enforcement: evict oldest posts from authors exceeding the cap *)
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
                  Hashtbl.remove store.posts id;
                  Hashtbl.remove store.comments_by_post id;
                  Stdlib.decr store.post_count;
                  Stdlib.incr cap_evicted)
               to_evict))
        author_posts);
    (* Prune stale rate-limit entries *)
    let window = Stdlib.Float.of_int Limits.comment_rate_window_sec in
    Board_comment_rate_limit.sweep_stale ~now ~window;
    (* Invalidate caches if anything was swept *)
    if !removed_posts > 0 || !cap_evicted > 0 then invalidate_post_caches store;
    if !removed_comments > 0 then invalidate_comment_caches store;
    store.last_sweep <- now;
    !removed_posts, !removed_comments)
;;

(* Deferred flush callback — set after rewrite helpers are defined.
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
  if
    Stdlib.Float.compare
      (now -. store.last_sweep)
      (Stdlib.Float.of_int Limits.sweeper_interval_sec)
    > 0
  then (
    store.last_sweep <- now;
    Eio.Stream.add store.flusher_inbox Sweep);
  if Stdlib.Float.compare (now -. store.last_flush) flush_interval_sec > 0
  then (
    store.last_flush <- now;
    Eio.Stream.add store.flusher_inbox Flush)
;;

(** {1 Persistence Paths} *)

(* Paths + JSONL rotation extracted to [Board_paths] (godfile decomp). *)
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

(** {1 Append Helpers}

    RFC-0091: [append_post] / [append_comment] are *create-only fast paths*.
    Callers must guarantee the post/comment has never been written before
    (the create flow in this module satisfies that via the [Dedup_hit] check
    above). Mutation/vote flushes MUST go through [save_jsonl_snapshot] in
    [board_votes.flush_dirty], not these helpers — otherwise the JSONL grows
    one line per mutation per id (the dup vector RFC-0091 closes). *)

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

let sub_board_access_to_string = function
  | Open -> "open"
  | Members_only -> "members_only"
  | Owner_only -> "owner_only"
;;

let sub_board_access_of_string_opt = function
  | "open" -> Some Open
  | "members_only" -> Some Members_only
  | "owner_only" -> Some Owner_only
  | _ -> None
;;

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

let post_of_create_post_outcome = function
  | Fresh_post post | Dedup_hit post -> post
;;

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
  ()
  : (create_post_outcome, board_error) Result.t
  =
  maybe_sweep store;
  (* Validate author *)
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
    (* Normalize hearth: lowercase + trim *)
    let hearth = Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth in
    let expires_at =
      let now = Time_compat.now () in
      if ttl = 0 then 0.0 else now +. (Stdlib.Float.of_int ttl *. 3600.0)
    in
    match
      normalize_post_payload ~content ?title ?body ~post_kind ?meta_json ()
    with
    | Error (Board_core_payload.Meta_not_assoc payload) ->
        (* Reject malformed meta_json instead of silently dropping it.
           Pre-fix behaviour at board_core_payload.ml:73 absorbed
           non-[`Assoc] payloads (`[`String _], [`Int _], …) into an
           empty meta object, hiding structural drift from callers. *)
        Error
          (Validation_error
             (Printf.sprintf
                "Malformed meta_json: expected JSON object, got %s"
                (Yojson.Safe.to_string payload)))
    | Ok (normalized_title, normalized_body, normalized_kind, normalized_meta)
      ->
    (* Validate body length *)
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
          (* Content dedup: reject identical (author, hearth, thread, body)
             within a short window.  Keeper turns sometimes emit the same
             board post N times (observed 6x at 0s gap).  The dedup key
             includes hearth + thread_id so the same body posted into a
             different hearth/thread is not collapsed onto an unrelated
             existing post.  Matching returns the existing post as
             [Dedup_hit] so the outer code skips [append_post] (no JSONL
             duplicate) and [Agent_economy.earn] (no extra credits). *)
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
              if !(store.post_count) >= Limits.max_posts
              then
                Error
                  (Capacity_exceeded
                     { current = !(store.post_count); max = Limits.max_posts })
              else
                let now = Time_compat.now () in
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
                  ; hearth
                  ; thread_id
                  }
                in
                Hashtbl.add store.posts (Post_id.to_string post.id) post;
                Stdlib.incr store.post_count;
                invalidate_post_caches store;
                Ok (`Fresh post)))
      in
      (* Agent Economy: earn credits for board post.  Moved OUTSIDE
     [with_lock] because [Agent_economy.earn] does its own disk I/O
     against a ledger file unrelated to the board store, and modifies
     no board state — holding [store.mutex] across it was pure
     contention that blocked every other board reader/writer while
     the ledger write landed.  If the earn fails we log at warn; the
     post itself is already in the store and on disk.

     Dedup hits skip both [append_post] (avoids duplicate JSONL post id)
     and [Agent_economy.earn] (avoids granting extra credits for retries). *)
      match board_result with
      | Ok (`Fresh post) ->
        with_persist_lock store (fun () -> append_post post);
        (match
           Agent_economy.earn
             ~base_path:(board_base_path ())
             ~agent_name:author
             ~kind:Earn_board_post
             ~reason:"board post"
             ()
         with
         | Ok _ -> ()
         | Error msg -> Log.BoardLog.warn "economy earn (post): %s" msg);
        Ok (Fresh_post post)
      | Ok (`Dedup_hit existing) -> Ok (Dedup_hit existing)
      | Error _ as e -> e)
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
      ()
  with
  | Ok outcome -> Ok (post_of_create_post_outcome outcome)
  | Error _ as err -> err
;;

let get_post store ~post_id : (post, board_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    with_lock store (fun () ->
      match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
      | Some post -> Ok post
      | None -> Error (Post_not_found post_id))
;;

(* Reads post + comments under a single critical section. The previous
   two-call sequence (get_post then get_comments) acquired
   [store.mutex] twice with [maybe_sweep] dispatching to the flusher
   actor between releases. That race window surfaces as
   [Mutex.lock: Resource deadlock avoided] under contended
   keeper_board_get traffic (e.g. ramarama keeper polling). Coalescing
   keeps the read atomic, removes one [maybe_sweep] dispatch, and
   eliminates the inter-call lock churn. *)
let get_post_and_comments store ~post_id : (post * comment list, board_error) Result.t =
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
          Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[]
        in
        let comments =
          List.filter_map (fun cid -> Hashtbl.find_opt store.comments cid) comment_ids
        in
        let sorted =
          List.sort
            (fun (a : comment) (b : comment) ->
               Stdlib.Float.compare a.created_at b.created_at)
            comments
        in
        Ok (post, sorted))
;;

let reclassify_posts store ?(limit = 5200) ?(dry_run = true) () =
  maybe_sweep store;
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
    if Fs_compat.file_exists path
    then
      Fs_compat.load_jsonl path
      |> List.filter_map (fun json ->
        match json_string "id" json, json_string "author" json with
        | Some id, Some author ->
          (match Option.bind (json_string "visibility" json) visibility_of_string with
           | Some visibility ->
             let expires_at = json_float "expires_at" json |> Option.value ~default:0.0 in
             if
               Stdlib.Float.compare expires_at 0.0 > 0
               && Stdlib.Float.compare expires_at now <= 0
             then None
             else (
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
                 legacy_migrate_post_kind
                   ~author
                   ~meta_json
                   ~visibility
                   ~expires_at
                   ~hearth
               in
               Some (id, created_at, stored_kind, canonical_kind))
           | None -> None)
        | _ -> None)
    else []
  in
  let total = List.length persisted_candidates in
  let selected_candidates =
    persisted_candidates
    |> List.sort (fun (_, created_a, _, _) (_, created_b, _, _) ->
      Stdlib.Float.compare created_b created_a)
    |> List.filteri (fun idx _ -> idx < scan_limit)
  in
  let report, post_snapshot =
    with_lock store (fun () ->
      let scanned = ref 0 in
      let changed = ref 0 in
      let unchanged = ref 0 in
      let changed_post_ids = ref [] in
      let record_changed_id id =
        if List.length !changed_post_ids < 20
        then changed_post_ids := id :: !changed_post_ids
      in
      selected_candidates
      |> List.iter (fun (post_id, _, stored_kind, canonical_kind) ->
        Stdlib.incr scanned;
        if Option.equal ( = ) stored_kind (Some canonical_kind)
        then Stdlib.incr unchanged
        else (
          Stdlib.incr changed;
          record_changed_id post_id;
          if not dry_run
          then (
            match Hashtbl.find_opt store.posts post_id with
            | Some post ->
              Hashtbl.replace store.posts post_id { post with post_kind = canonical_kind }
            | None -> ())));
      let post_snapshot =
        if (not dry_run) && !changed > 0
        then (
          invalidate_post_caches store;
          store.dirty_posts <- false;
          Hashtbl.clear store.dirty_post_ids;
          store.last_flush <- Time_compat.now ();
          Some (posts_jsonl_unlocked store))
        else None
      in
      ( { backend = "jsonl"
        ; dry_run
        ; scanned = !scanned
        ; changed = !changed
        ; unchanged = !unchanged
        ; skipped = max 0 (total - !scanned)
        ; apply_failures = 0
        ; changed_post_ids = List.rev !changed_post_ids
        }
      , post_snapshot ))
  in
  (match post_snapshot with
   | Some content -> with_persist_lock store (fun () -> save_posts_jsonl content)
   | None -> ());
  report
;;

let list_posts store ?(visibility_filter = None) ?hearth ?(limit = 50) () : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    (* Use cached sorted list if available (cache hit = skip sort) *)
    let sorted_all =
      match store.sorted_posts_cache with
      | Some cached -> cached
      | None ->
        let all = Hashtbl.fold (fun _ (post : post) acc -> post :: acc) store.posts [] in
        let sorted =
          List.sort
            (fun (a : post) (b : post) ->
               let score_a = a.votes_up - a.votes_down in
               let score_b = b.votes_up - b.votes_down in
               let cmp = Stdlib.Int.compare score_b score_a in
               if cmp <> 0 then cmp else Stdlib.Float.compare b.created_at a.created_at)
            all
        in
        store.sorted_posts_cache <- Some sorted;
        sorted
    in
    (* Apply filters on the pre-sorted list *)
    let filtered =
      match visibility_filter with
      | None -> sorted_all
      | Some v -> List.filter (fun (p : post) -> p.visibility = v) sorted_all
    in
    let filtered =
      match hearth with
      | None -> filtered
      | Some h ->
        let h_norm = String.lowercase_ascii (String.trim h) in
        List.filter
          (fun (p : post) -> Option.equal String.equal p.hearth (Some h_norm))
          filtered
    in
    (* Cap at Limits.max_posts (default 10_000) as an OOM guard. The
       previous inner cap of 100 was a duplicate of Board_dispatch.list_posts's
       fetch_limit guard (`max limit 200`) and broke offset-based pagination:
       when the dashboard requested offset=100 limit=100, Board_dispatch
       passed probe_fetch=201 here but we returned only 100, so fetched_len
       never exceeded window_end and has_more went stale at ~100-200 posts. *)
    take (min limit Limits.max_posts) filtered)
;;

(** Full-scan search over all posts (no limit on scan, only on results).
    Used by Board_dispatch.search to avoid the list_posts hard cap. *)
let search_posts store ~predicate ~limit : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    let matches =
      Hashtbl.fold
        (fun _ (p : post) acc -> if predicate p then p :: acc else acc)
        store.posts
        []
    in
    (* Sort by recency for search results *)
    let sorted =
      List.sort
        (fun (a : post) (b : post) -> Stdlib.Float.compare b.created_at a.created_at)
        matches
    in
    take limit sorted)
;;

(** {1 Comment Operations} *)

let add_comment_with_status
      store
      ~post_id
      ~author
      ~content
      ?parent_id
      ?(ttl_hours = Limits.default_ttl_hours)
      ()
  : (comment * [ `Fresh | `Dedup ], board_error) Result.t
  =
  maybe_sweep store;
  (* Validate all IDs first *)
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    (match Agent_id.of_string author with
     | Error e -> Error e
     | Ok author_id ->
       let parent_result =
         match parent_id with
         | None -> Ok None
         | Some p ->
           (match Comment_id.of_string p with
            | Ok cid -> Ok (Some cid)
            | Error e -> Error e)
       in
       (match parent_result with
        | Error e -> Error e
        | Ok parent_cid ->
          (* Validate content *)
          if String.length content > Limits.max_content_length
          then Error (Validation_error "Content too long")
          else if String.length content = 0
          then Error (Validation_error "Content cannot be empty")
          else (
            let board_result =
              with_lock store (fun () ->
                (* Verify post exists *)
                match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
                | None -> Error (Post_not_found post_id)
                | Some post ->
                  let post_key = Post_id.to_string pid in
                  let comment_ids =
                    Hashtbl.find_opt store.comments_by_post post_key
                    |> Option.value ~default:[]
                  in
                  let author_str = Agent_id.to_string author_id in
                  let parent_key = Option.map Comment_id.to_string parent_cid in
                  let dedup_match =
                    comment_ids
                    |> List.filter_map (fun cid -> Hashtbl.find_opt store.comments cid)
                    |> List.find_opt (fun (c : comment) ->
                      String.equal (Agent_id.to_string c.author) author_str
                      && Option.equal
                           String.equal
                           (Option.map Comment_id.to_string c.parent_id)
                           parent_key
                      && String.equal c.content content)
                  in
                  (match dedup_match with
                   | Some existing ->
                     Log.BoardLog.info
                       "dedup: skipping duplicate comment author=%s post_id=%s \
                        content_len=%d existing_id=%s"
                       author_str
                       post_key
                       (String.length content)
                       (Comment_id.to_string existing.id);
                     Ok (`Dedup_hit existing)
                   | None ->
                     (* PR #13490 enforced sub-board post policy for
                        [create_post] but left [add_comment] unguarded —
                        non-members could comment on [Members_only] /
                        [Owner_only] sub-boards through any parent post in
                        that sub-board. The author allowed predicate is
                        the same one [create_post] uses, applied to the
                        target post's [hearth].  We run this after the
                        dedup check (mirroring [create_post]) so an
                        author whose earlier comment is already on the
                        post stays idempotent — only fresh attempts hit
                        the policy gate. *)
                     (match
                        validate_sub_board_post_policy_unlocked
                          store
                          ~author_id
                          ~hearth:post.hearth
                      with
                      | Error e -> Error e
                      | Ok () ->
                     (* Check comment count using index after duplicate
                        detection so a retry of an existing comment remains
                        idempotent even on a full thread. *)
                     let post_comment_count = List.length comment_ids in
                     if post_comment_count >= Limits.max_comments_per_post
                     then
                       Error
                         (Capacity_exceeded
                            { current = post_comment_count
                            ; max = Limits.max_comments_per_post
                            })
                     else (
                    let now = Time_compat.now () in
                    match check_comment_rate_limit ~author:author_str ~now with
                    | Some retry_after ->
                      Error (Rate_limited { retry_after })
                    | None ->
                    let ttl =
                      match post.post_kind with
                      | Automation_post | System_post ->
                        let forced = Limits.automation_ttl_hours in
                        if ttl_hours = 0 then forced else min ttl_hours forced
                      | Human_post ->
                        if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours
                    in
                    let comment =
                      { id = Comment_id.generate ()
                      ; post_id = pid
                      ; parent_id = parent_cid
                      ; author = author_id
                      ; content
                      ; created_at = now
                      ; expires_at =
                          (if ttl = 0
                           then 0.0
                           else now +. (Stdlib.Float.of_int ttl *. 3600.0))
                      ; votes_up = 0
                      ; votes_down = 0
                      }
                    in
                    Hashtbl.add store.comments (Comment_id.to_string comment.id) comment;
                    (* Update comments_by_post index *)
                    let post_key = Post_id.to_string pid in
                    let existing =
                      Hashtbl.find_opt store.comments_by_post post_key
                      |> Option.value ~default:[]
                    in
                    Hashtbl.replace
                      store.comments_by_post
                      post_key
                      (Comment_id.to_string comment.id :: existing);
                    (* Update post reply count and updated_at *)
                    Hashtbl.replace
                      store.posts
                      post_key
                      { post with reply_count = post.reply_count + 1; updated_at = now };
                    record_comment_timestamp ~author:author_str ~now;
                    invalidate_post_caches store;
                    invalidate_comment_caches store;
                    Ok (`Fresh comment)))))
            in
            match board_result with
            | Ok (`Fresh comment) ->
              with_persist_lock store (fun () -> append_comment comment);
              Ok (comment, `Fresh)
            | Ok (`Dedup_hit existing) -> Ok (existing, `Dedup)
            | Error _ as e -> e)))
;;

let add_comment store ~post_id ~author ~content ?parent_id ?ttl_hours () :
  (comment, board_error) Result.t =
  match add_comment_with_status store ~post_id ~author ~content ?parent_id
          ?ttl_hours ()
  with
  | Ok (comment, _) -> Ok comment
  | Error _ as e -> e
;;

let get_comments store ~post_id : (comment list, board_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    with_lock store (fun () ->
      let post_key = Post_id.to_string pid in
      let comment_ids =
        Hashtbl.find_opt store.comments_by_post post_key |> Option.value ~default:[]
      in
      let comments =
        List.filter_map (fun cid -> Hashtbl.find_opt store.comments cid) comment_ids
      in
      Ok
        (List.sort
           (fun (a : comment) (b : comment) ->
              Stdlib.Float.compare a.created_at b.created_at)
           comments))
;;

(** List all comments (for profile aggregation) *)
let list_comments store ?(limit = 1000) () : comment list =
  maybe_sweep store;
  with_lock store (fun () ->
    let all = Hashtbl.fold (fun _ c acc -> c :: acc) store.comments [] in
    let sorted =
      List.sort
        (fun (a : comment) (b : comment) ->
           Stdlib.Float.compare b.created_at a.created_at)
        all
    in
    List.filteri (fun i _ -> i < limit) sorted)
;;

(** {1 Reactions} *)

let normalize_reaction_emoji raw =
  let emoji = String.trim raw in
  if List.exists (String.equal emoji) board_reaction_emojis
  then Ok emoji
  else
    Error (Validation_error (Printf.sprintf "Unsupported board reaction emoji: %s" emoji))
;;

let ensure_reaction_target_unlocked store ~target_type ~target_id =
  match target_type with
  | Reaction_post ->
    (match Post_id.of_string target_id with
     | Error e -> Error e
     | Ok pid ->
       if Hashtbl.mem store.posts (Post_id.to_string pid)
       then Ok ()
       else Error (Post_not_found target_id))
  | Reaction_comment ->
    (match Comment_id.of_string target_id with
     | Error e -> Error e
     | Ok cid ->
       if Hashtbl.mem store.comments (Comment_id.to_string cid)
       then Ok ()
       else Error (Comment_not_found target_id))
;;

type reaction_summary_bucket =
  { counts : (string, int) Hashtbl.t
  ; reacted : (string, bool) Hashtbl.t
  ; recent_users : (string, (string * float) list) Hashtbl.t
  }

let create_reaction_summary_bucket () =
  { counts = Hashtbl.create 8
  ; reacted = Hashtbl.create 8
  ; recent_users = Hashtbl.create 8
  }
;;

let add_reaction_to_summary_bucket bucket ?user_id (reaction : reaction) =
  let reaction_user_id = Agent_id.to_string reaction.user_id in
  let current =
    Hashtbl.find_opt bucket.counts reaction.emoji |> Option.value ~default:0
  in
  Hashtbl.replace bucket.counts reaction.emoji (current + 1);
  let users =
    Hashtbl.find_opt bucket.recent_users reaction.emoji |> Option.value ~default:[]
  in
  Hashtbl.replace
    bucket.recent_users
    reaction.emoji
    ((reaction_user_id, reaction.created_at) :: users);
  match user_id with
  | Some user when String.equal reaction_user_id user ->
    Hashtbl.replace bucket.reacted reaction.emoji true
  | Some _ | None -> ()
;;

let reaction_summaries_of_bucket bucket =
  List.filter_map
    (fun emoji ->
       let count = Hashtbl.find_opt bucket.counts emoji |> Option.value ~default:0 in
       if count = 0
       then None
       else
         Some
           { emoji
           ; count
           ; reacted =
               Hashtbl.find_opt bucket.reacted emoji |> Option.value ~default:false
           ; recent_user_ids =
               Hashtbl.find_opt bucket.recent_users emoji
               |> Option.value ~default:[]
               |> List.sort (fun (_, a_ts) (_, b_ts) -> Stdlib.Float.compare b_ts a_ts)
               |> List.map fst
               |> List.filteri (fun idx _ -> idx < 5)
           })
    board_reaction_emojis
;;

let reaction_summaries_unlocked store ~target_type ~target_id ?user_id () =
  let bucket = create_reaction_summary_bucket () in
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       if reaction.target_type = target_type && String.equal reaction.target_id target_id
       then add_reaction_to_summary_bucket bucket ?user_id reaction)
    store.reactions;
  reaction_summaries_of_bucket bucket
;;

let reaction_summaries_batch_unlocked store ~targets ?user_id () =
  let target_buckets = Hashtbl.create (List.length targets) in
  List.iter
    (fun target ->
       Hashtbl.replace target_buckets target (create_reaction_summary_bucket ()))
    targets;
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       match
         Hashtbl.find_opt target_buckets (reaction.target_type, reaction.target_id)
       with
       | None -> ()
       | Some bucket -> add_reaction_to_summary_bucket bucket ?user_id reaction)
    store.reactions;
  Hashtbl.fold
    (fun target bucket acc -> (target, reaction_summaries_of_bucket bucket) :: acc)
    target_buckets
    []
;;

let normalize_reaction_user_id = function
  | Some user when not (String.equal (String.trim user) "") -> Some (String.trim user)
  | Some _ | None -> None
;;

let list_reactions store ~target_type ~target_id ?user_id () =
  maybe_sweep store;
  let user_id = normalize_reaction_user_id user_id in
  with_lock store (fun () ->
    match ensure_reaction_target_unlocked store ~target_type ~target_id with
    | Error e -> Error e
    | Ok () -> Ok (reaction_summaries_unlocked store ~target_type ~target_id ?user_id ()))
;;

let list_reactions_batch store ~targets ?user_id () =
  maybe_sweep store;
  let user_id = normalize_reaction_user_id user_id in
  with_lock store (fun () -> reaction_summaries_batch_unlocked store ~targets ?user_id ())
;;

let toggle_reaction store ~target_type ~target_id ~user_id ~emoji
  : (reaction_toggle_result, board_error) Result.t
  =
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
          let key = reaction_key ~target_type ~target_id ~user_id:user_id_string ~emoji in
          let reacted =
            match Hashtbl.find_opt store.reactions key with
            | Some _ ->
              Hashtbl.remove store.reactions key;
              false
            | None ->
              Hashtbl.replace
                store.reactions
                key
                { target_type
                ; target_id
                ; user_id
                ; emoji
                ; created_at = Time_compat.now ()
                };
              true
          in
          let summary =
            reaction_summaries_unlocked
              store
              ~target_type
              ~target_id
              ~user_id:user_id_string
              ()
          in
          Ok { target_type; target_id; user_id = user_id_string; emoji; reacted; summary })
    in
    (match result with
     | Ok _ -> rewrite_reactions store
     | Error _ -> ());
    result
;;

(** {1 SubBoard Operations} *)

let sub_board_to_yojson (sb : sub_board) : Yojson.Safe.t =
  `Assoc
    [ "id", `String (Sub_board_id.to_string sb.id)
    ; "slug", `String sb.slug
    ; "name", `String sb.name
    ; "description", `String sb.description
    ; "owner", `String (Agent_id.to_string sb.owner)
    ; "members", `List (List.map (fun id -> `String (Agent_id.to_string id)) sb.members)
    ; "access", `String (sub_board_access_to_string sb.access)
    ; "created_at", `Float sb.created_at
    ; "post_count", `Int sb.post_count
    ]
;;

let dedupe_agent_ids ids =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | id :: rest ->
      let name = Agent_id.to_string id in
      if List.mem name seen
      then loop seen acc rest
      else loop (name :: seen) (id :: acc) rest
  in
  loop [] [] ids
;;

let parse_sub_board_members ~owner members =
  let rec loop acc = function
    | [] -> Ok (dedupe_agent_ids (owner :: List.rev acc))
    | member_name :: rest ->
      (match Agent_id.of_string member_name with
       | Ok member_id -> loop (member_id :: acc) rest
       | Error e -> Error e)
  in
  loop [] members
;;

let parse_sub_board_members_lenient ~owner members =
  members
  |> List.filter_map (fun member_name ->
    match Agent_id.of_string member_name with
    | Ok member_id -> Some member_id
    | Error _ -> None)
  |> fun parsed -> dedupe_agent_ids (owner :: parsed)
;;

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
    let member_names = json_string_list "members" json in
    (match
       ( Sub_board_id.of_string id_s
       , Agent_id.of_string owner_s
       , sub_board_access_of_string_opt access_s )
     with
     | Ok id, Ok owner, Some access when slug <> "" ->
       let members = parse_sub_board_members_lenient ~owner member_names in
       Some
         { id; slug; name; description; owner; members; access; created_at; post_count }
     | _ -> None)
  | _ -> None
;;

let sub_boards_jsonl_unlocked store =
  let buf = Buffer.create 1024 in
  Hashtbl.iter
    (fun _ (sb : sub_board) ->
       Buffer.add_string buf (Yojson.Safe.to_string (sub_board_to_yojson sb));
       Buffer.add_char buf '\n')
    store.sub_boards;
  Buffer.contents buf
;;

let save_sub_boards_jsonl content =
  try
    ensure_masc_dir ();
    let path = sub_boards_path () in
    match Fs_compat.save_file_atomic path content with
    | Ok () -> ()
    | Error msg -> record_persist_error ~where:"rewrite_sub_boards" msg
  with
  | Sys_error msg -> record_persist_error ~where:"rewrite_sub_boards" msg
;;

let rewrite_sub_boards store =
  let content = with_lock store (fun () -> sub_boards_jsonl_unlocked store) in
  with_persist_lock store (fun () -> save_sub_boards_jsonl content)
;;

let append_sub_board (sb : sub_board) =
  try
    ensure_masc_dir ();
    let path = sub_boards_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (sub_board_to_yojson sb) ^ "\n")
  with
  | Sys_error msg -> record_persist_error ~where:"append_sub_board" msg
;;

let valid_slug_pattern = Re.Pcre.re {|^[a-z0-9][a-z0-9_-]*$|} |> Re.compile

let create_sub_board
      store
      ~slug
      ~name
      ~description
      ~owner
      ?(members = [])
      ?(access = Open)
      ()
  : (sub_board, board_error) Result.t
  =
  let slug = String.lowercase_ascii (String.trim slug) in
  if
    String.length slug < 1
    || String.length slug > 64
    || not (Re.execp valid_slug_pattern slug)
  then
    Error
      (Validation_error
         (Printf.sprintf
            "Invalid sub-board slug %S: must be 1-64 lowercase alphanumeric/-/_"
            slug))
  else (
    match Agent_id.of_string owner with
    | Error e -> Error e
    | Ok owner_id ->
      (match parse_sub_board_members ~owner:owner_id members with
       | Error e -> Error e
       | Ok members ->
         let result =
           with_lock store (fun () ->
             if Hashtbl.mem store.sub_boards_by_slug slug
             then
               Error
                 (Already_exists (Printf.sprintf "Sub-board slug %S already exists" slug))
             else (
               let current = Hashtbl.length store.sub_boards in
               if current >= Limits.max_sub_boards
               then Error (Capacity_exceeded { current; max = Limits.max_sub_boards })
               else (
                 let id = Sub_board_id.generate () in
                 let sb =
                   { id
                   ; slug
                   ; name = String.trim name
                   ; description = String.trim description
                   ; owner = owner_id
                   ; members
                   ; access
                   ; created_at = Time_compat.now ()
                   ; post_count = 0
                   }
                 in
                 Hashtbl.replace store.sub_boards (Sub_board_id.to_string id) sb;
                 Hashtbl.replace store.sub_boards_by_slug slug (Sub_board_id.to_string id);
                 Ok sb)))
         in
         (match result with
          | Ok sb ->
            with_persist_lock store (fun () -> append_sub_board sb);
            Ok sb
          | Error _ as e -> e)))
;;


let update_sub_board
      store
      ~sub_board_id
      ?name
      ?description
      ?members
      ?access
      ()
  : (sub_board, board_error) Result.t
  =
  let result =
    with_lock store (fun () ->
      let sb_opt =
        match Hashtbl.find_opt store.sub_boards sub_board_id with
        | Some sb -> Some sb
        | None ->
          (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
           | Some id -> Hashtbl.find_opt store.sub_boards id
           | None -> None)
      in
      match sb_opt with
      | None ->
        Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))
      | Some sb ->
        let members =
          match members with
          | None -> sb.members
          | Some raw ->
            (match parse_sub_board_members ~owner:sb.owner raw with
             | Ok m -> m
             | Error _ -> sb.members)
        in
        let updated =
          { sb with
            name = Option.value ~default:sb.name (Option.map String.trim name)
          ; description = Option.value ~default:sb.description (Option.map String.trim description)
          ; members
          ; access = Option.value ~default:sb.access access
          }
        in
        Hashtbl.replace store.sub_boards (Sub_board_id.to_string sb.id) updated;
        Ok updated)
  in
  (match result with
   | Ok _ -> rewrite_sub_boards store
   | Error _ -> ());
  result
;;

let get_sub_board store ~sub_board_id : (sub_board, board_error) Result.t =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sub_boards sub_board_id with
    | Some sb -> Ok (sub_board_with_post_count_unlocked store sb)
    | None ->
      (* fallback: try slug *)
      (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
       | Some id ->
         (match Hashtbl.find_opt store.sub_boards id with
          | Some sb -> Ok (sub_board_with_post_count_unlocked store sb)
          | None ->
            Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id)))
       | None ->
         Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))))
;;

let list_sub_boards store : sub_board list =
  with_lock store (fun () ->
    let counts = sub_board_post_counts_unlocked store in
    Hashtbl.fold
      (fun _ sb acc -> sub_board_with_post_count counts sb :: acc)
      store.sub_boards
      []
    |> List.sort (fun (a : sub_board) (b : sub_board) ->
      compare a.created_at b.created_at))
;;

let delete_sub_board store ~sub_board_id : (unit, board_error) Result.t =
  with_persist_lock store (fun () ->
    let snapshot =
      with_lock store (fun () ->
        let resolved_opt =
          match Hashtbl.find_opt store.sub_boards sub_board_id with
          | Some sb -> Some (sub_board_id, sb.slug)
          | None ->
            (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
             | None -> None
             | Some id ->
               (match Hashtbl.find_opt store.sub_boards id with
                | Some sb -> Some (id, sb.slug)
                | None -> None))
        in
        match resolved_opt with
        | None ->
          Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))
        | Some (id, slug) ->
          Hashtbl.remove store.sub_boards id;
          Hashtbl.remove store.sub_boards_by_slug slug;
          (* Orphan policy: clear hearth on posts that belonged to this sub-board *)
          Hashtbl.iter
            (fun _ (post : post) ->
               match post.hearth with
               | Some h when String.equal h slug ->
                 let updated = { post with hearth = None } in
                 Hashtbl.replace store.posts (Post_id.to_string post.id) updated;
                 store.dirty_posts <- true;
                 Hashtbl.replace store.dirty_post_ids (Post_id.to_string post.id) ()
               | _ -> ())
            store.posts;
          invalidate_post_caches store;
          Ok (sub_boards_jsonl_unlocked store))
    in
    match snapshot with
    | Error _ as e -> e
    | Ok content ->
      save_sub_boards_jsonl content;
      Ok ())
;;

(** {1 Voting - Deduplicated} *)
