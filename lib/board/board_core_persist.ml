(** Board Core — JSONL store logic and persistence. Types are in Board_types. *)
include Board_core_classify
include Board_core_payload

module Post_publication_failure = Board_post_publication_failure

open Result.Syntax

module Expired_target_set = Set.Make (struct
  type t = [ `Post | `Comment ] * string

  let compare (k1, id1) (k2, id2) =
    let rank = function `Post -> 0 | `Comment -> 1 in
    let c = Int.compare (rank k1) (rank k2) in
    if c <> 0 then c else String.compare id1 id2
end)

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

let persist_io_error ~where msg =
  record_persist_error ~where msg;
  Error (Io_error (Printf.sprintf "%s: %s" where msg))
;;

let create_store_with_source_io ~base_path posts_source_io comments_source_io sub_boards_source_io votes_source_io reactions_source_io deletion_source_io () =
  let workspace_binding = Board_workspace_binding.capture ~base_path in
  { posts_source = Posts_unobserved
  ; posts_source_io
  ; comments_source = Comments_unobserved
  ; comments_source_io
  ; sub_boards_source = Policy_unobserved
  ; sub_boards_source_io
  ; votes_source = Votes_unobserved
  ; votes_source_io
  ; reactions_source = Reactions_unobserved
  ; reactions_source_io
  ; deletion_source_io
  ; workspace_binding
  ; posts = Hashtbl.create 1024
  ; comments = Hashtbl.create 4096
  ; vote_log = Hashtbl.create 2048
  ; post_count = ref 0
  ; last_sweep = Time_compat.now ()
  ; mutex = Eio.Mutex.create ()
  ; persist_mutex = Eio.Mutex.create ()
  ; origin_create_mutex = Eio.Mutex.create ()
  ; karma_cache = None
  ; hot_post_index = Hot_post_set.empty
  ; recent_post_index = Recent_post_set.empty
  ; comments_by_post = Hashtbl.create 1024
  ; reactions = Hashtbl.create 4096
  ; dirty_posts = false
  ; dirty_comments = false
  ; deletion_state = Deletion_unobserved
  ; dirty_post_ids = Hashtbl.create 256
  ; dirty_comment_ids = Hashtbl.create 512
  ; post_rows = Hashtbl.create 1024
  ; comment_rows = Hashtbl.create 4096
  ; last_flush = Time_compat.now ()
  ; flusher_inbox = Eio.Stream.create flusher_inbox_capacity
  ; sub_boards = Hashtbl.create 64
  ; sub_boards_by_slug = Hashtbl.create 64
  ; posts_by_turn_ref = Hashtbl.create 256
  ; posts_by_run_id = Hashtbl.create 256
  }
;;

let create_store ~base_path () =
  create_store_with_source_io ~base_path { posts = None } None None None None None ()
let create_store_with_source_io_for_testing ~base_path ~io () =
  create_store_with_source_io ~base_path io None None None None None ()
let create_store_with_comments_io_for_testing ~base_path ~io () =
  create_store_with_source_io ~base_path { posts = None } (Some io) None None None None ()
let create_store_with_sub_boards_io_for_testing ~base_path ~io () =
  create_store_with_source_io ~base_path { posts = None } None (Some io) None None None ()
let create_store_with_votes_io_for_testing ~base_path ~io () =
  create_store_with_source_io ~base_path { posts = None } None None (Some io) None None ()
let create_store_with_reactions_io_for_testing ~base_path ~io () =
  create_store_with_source_io ~base_path { posts = None } None None None (Some io) None ()
let create_store_with_deletion_io_for_testing ~base_path ~io () =
  create_store_with_source_io ~base_path { posts = None } None None None None (Some io) ()

let require_comments_source_readable = Board_comments_source.require_readable

let require_persisted_snapshot_readable = function
  | Ok () -> Ok ()
  | Error detail -> Error (Io_error detail)
;;

let require_model_reload_allowed store ~path = match store.deletion_state with
  | Deletion_unobserved | Deletion_readable { plan = None; _ } -> Ok ()
  | Deletion_readable { plan = Some _; _ } | Deletion_pending _
  | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _ ->
    Error (path, Failure "Pending Board deletion requires fresh-store initialization.")
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
    let pid = Post_id.to_string post.id in
    (match o.turn_ref with
     | Some tr ->
       let key = Ids.Turn_ref.to_string tr in
       (match Hashtbl.find_opt store.posts_by_turn_ref key with
        | Some indexed_pid when String.equal indexed_pid pid ->
          Hashtbl.remove store.posts_by_turn_ref key
        | Some _ | None -> ())
     | None -> ());
    (match o.fusion_run_id with
     | Some run_id ->
       (match Hashtbl.find_opt store.posts_by_run_id run_id with
        | Some indexed_pid when String.equal indexed_pid pid ->
          Hashtbl.remove store.posts_by_run_id run_id
        | Some _ | None -> ())
     | None -> ())
;;

let index_hot_post store (post : post) =
  store.hot_post_index <-
    Hot_post_set.add (hot_post_key_of_post post) store.hot_post_index;
  store.recent_post_index <-
    Recent_post_set.add (recent_post_key_of_post post) store.recent_post_index
;;

let unindex_hot_post store (post : post) =
  store.hot_post_index <-
    Hot_post_set.remove (hot_post_key_of_post post) store.hot_post_index;
  store.recent_post_index <-
    Recent_post_set.remove (recent_post_key_of_post post) store.recent_post_index
;;

let reindex_hot_post store ~(previous : post) ~(updated : post) =
  let prev_key = hot_post_key_of_post previous in
  let next_key = hot_post_key_of_post updated in
  if compare_hot_post_key prev_key next_key <> 0
  then
    store.hot_post_index <-
      store.hot_post_index
      |> Hot_post_set.remove prev_key
      |> Hot_post_set.add next_key;
  let prev_recent = recent_post_key_of_post previous in
  let next_recent = recent_post_key_of_post updated in
  if compare_recent_post_key prev_recent next_recent <> 0
  then
    store.recent_post_index <-
      store.recent_post_index
      |> Recent_post_set.remove prev_recent
      |> Recent_post_set.add next_recent
;;

let put_post store (post : post) =
  let key = Post_id.to_string post.id in
  let previous = Hashtbl.find_opt store.posts key in
  Hashtbl.replace store.posts key post;
  match previous with
  | None -> index_hot_post store post
  | Some previous -> reindex_hot_post store ~previous ~updated:post
;;

let rebuild_hot_post_index store =
  let hot_index, recent_index =
    Hashtbl.fold
      (fun _ (post : post) (hot_acc, recent_acc) ->
         ( Hot_post_set.add (hot_post_key_of_post post) hot_acc
         , Recent_post_set.add (recent_post_key_of_post post) recent_acc ))
      store.posts
      (Hot_post_set.empty, Recent_post_set.empty)
  in
  store.hot_post_index <- hot_index;
  store.recent_post_index <- recent_index
;;

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
  store.karma_cache <- None
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

exception Deferred_persist_observer of exn * Printexc.raw_backtrace

let with_lock store f =
  let result = Eio.Mutex.use_rw ~protect:true store.mutex (fun () ->
    try Ok (f ()) with
    | Board_posts_source.Reserved_settlement settlement -> Error settlement) in
  match result with
  | Ok value -> value
  | Error settlement -> raise (Board_posts_source.Reserved_settlement settlement)

(** Serialize JSONL writes. Callers must never hold the state mutex while
    acquiring [persist_mutex]. Acquire the persist lock before taking a state
    snapshot, and retain it until the snapshot has been written.

    The lock body only measures. Both metric observers run after
    [persist_mutex] is released, so an observer may call back into Board, and
    the held duration covers [f] alone. The acquire-wait sample is therefore
    reported after [f]: an observer exception follows the write instead of
    preventing it. *)
let with_persist_lock_internal ~defer_settlement store f =
  let observe f =
    try f (); Ok () with
    | exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  let started = Time_compat.now () in
  let acquired_at = ref None in
  let measured =
    try
      Eio.Mutex.use_rw ~protect:true store.persist_mutex (fun () ->
        let acquired = Time_compat.now () in
        acquired_at := Some acquired;
        (* Reserved settlement travels as a carrier and leaves the lock
           cleanly so an uncertain store retains its evidence. Only an explicit
           non-reserved exception crossing [use_rw] poisons it. *)
        let result =
          try Ok (f ()) with
          | Board_posts_source.Reserved_settlement settlement -> Error settlement
        in
        let released = Time_compat.now () in
        result, acquired, released)
    with
    | exn ->  (* cancel-guard-ok: re-raises the original exception below *)
      (* [f] poisoned the lock, or the lock was never acquired. A wait that
         ended in acquisition is still reported; the original exception wins
         over an observer failure. *)
      let backtrace = Printexc.get_raw_backtrace () in
      (match !acquired_at with
       | None -> ()
       | Some acquired ->
         let (_ : (unit, exn * Printexc.raw_backtrace) result) =
           observe (fun () ->
             Board_metrics_hooks.observe_persist_lock_acquire_sec
               (acquired -. started))
         in
         ());
      Printexc.raise_with_backtrace exn backtrace
  in
  let result, acquired, released = measured in
  let acquire_observation =
    observe (fun () ->
      Board_metrics_hooks.observe_persist_lock_acquire_sec (acquired -. started))
  in
  let held_observation =
    observe (fun () ->
      Board_metrics_hooks.observe_persist_lock_held_sec (released -. acquired))
  in
  match result, acquire_observation, held_observation with
  | Ok result, Ok (), Ok () -> result
  | Error settlement, (Ok () | Error _), (Ok () | Error _) ->
    if defer_settlement then raise (Board_posts_source.Reserved_settlement settlement)
    else Printexc.raise_with_backtrace settlement.exception_ settlement.backtrace
  | Ok _, Error (exn, backtrace), (Ok () | Error _)
  | Ok _, Ok (), Error (exn, backtrace) ->
    (* [persist_mutex] is already released. Fusion still owns its origin lock:
       carry reserved observer failures through that lock too, without
       inventing a write receipt. *)
    (match defer_settlement, Board_posts_source.reserved_exception (exn, backtrace) with
     | true, Some (exception_, original_backtrace) ->
       raise (Deferred_persist_observer (exception_, original_backtrace))
     | true, None | false, _ -> ());
    Printexc.raise_with_backtrace exn backtrace
;;

let with_persist_lock store f = with_persist_lock_internal ~defer_settlement:false store f

(** {1 Sweeper - Aggressive Cleanup} *)
let vote_key_target key =
  match Board_vote_key.of_string key with
  | None -> None
  | Some vote ->
    let target_id = Board_vote_key.target_id vote in
    (match Board_vote_key.target_kind vote with
     | Board_vote_key.Post -> Some (`Post, target_id)
     | Board_vote_key.Comment -> Some (`Comment, target_id))
;;

let sweep store =
  with_persist_lock store (fun () ->
  with_lock store (fun () ->
    (* Best-effort loaded rows remain readable, but cannot authorize deletion
       of a target and its dependents until all four sources loaded fully.
       The loader retains the typed failures for diagnosis and healthy reload. *)
    match Board_posts_source.require_readable store, require_comments_source_readable store,
          Board_votes_source.require_readable store, Board_reactions_source.require_readable store with
    | Error _, _, _, _ | _, Error _, _, _
    | _, _, Error _, _ | _, _, _, Error _ -> 0, 0
    | Ok (), Ok (), Ok (), Ok () ->
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
    (* Both ordinary expiry and a partial post cascade must update the
       surviving post's reply count and index before the next snapshot. *)
    let remove_comment cid =
      (match Hashtbl.find_opt store.comments cid with
       | Some c ->
         let post_key = Post_id.to_string c.post_id in
         remove_from_list_index store.comments_by_post post_key cid;
         (match Hashtbl.find_opt store.posts post_key with
          | Some post ->
            Hashtbl.replace store.posts post_key
              { post with reply_count = post.reply_count - 1 };
            mark_dirty_post store post_key
          | None -> ())
       | None -> ());
      Hashtbl.remove store.comments cid;
      mark_dirty_comment store cid
    in
    (* Drain each expired post's comments within the shared comment batch.
       Keep the post until its last comment is removed, so even a cascade
       larger than the batch converges without stranding replies. *)
    let swept_posts = ref [] in
    let cascaded_comment_ids = ref [] in
    List.iter
      (fun id ->
         let remaining_budget = Limits.sweeper_batch_size - !removed_comments in
         let cascade_ids, cascade_count, comments_remain =
           Hashtbl.fold
             (fun key (c : comment) (ids, count, remain) ->
                if not (String.equal (Post_id.to_string c.post_id) id) then
                  ids, count, remain
                else if count < remaining_budget then
                  key :: ids, count + 1, remain
                else ids, count, true)
             store.comments
             ([], 0, false)
         in
         List.iter remove_comment cascade_ids;
         removed_comments := !removed_comments + cascade_count;
         cascaded_comment_ids := cascade_ids @ !cascaded_comment_ids;
         if comments_remain then
           Stdlib.decr removed_posts
         else (
           (match Hashtbl.find_opt store.posts id with
            | Some p ->
              unindex_post_origin store p;
              unindex_hot_post store p
            | None -> ());
           Hashtbl.remove store.posts id;
           Hashtbl.remove store.comments_by_post id;
           swept_posts := id :: !swept_posts;
           Stdlib.decr store.post_count;
           mark_dirty_post store id))
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
    (* [reply_count] is kept by the write that adds a comment and rebuilt
       from the comments on load; a comment the sweeper removes has to take
       its count with it, or the post keeps announcing a reply nobody can
       read until the next restart. Each removal is marked dirty the way
       [add_comment] marks its write, so the next flush writes the snapshot
       without the expired rows instead of waiting for an unrelated edit. *)
    List.iter remove_comment expired_comments;
    (* Dependent rows die with their target, at the moment the target dies:
       the expired ids are in hand right here. The previous pass instead
       scanned for rows whose target is missing from the in-memory tables,
       which cannot tell a deleted target from one that failed to load or
       loaded empty; on 2026-09-19 a board that came up with no posts read
       every vote as an orphan. A row whose target is absent is left alone —
       [recalculate_vote_counts] never counts it, and the target may still
       arrive on the next load. *)
    let expired_targets =
      let acc =
        List.fold_left
          (fun acc id -> Expired_target_set.add (`Post, id) acc)
          Expired_target_set.empty !swept_posts
      in
      let acc =
        List.fold_left
          (fun acc id -> Expired_target_set.add (`Comment, id) acc)
          acc expired_comments
      in
      List.fold_left
        (fun acc id -> Expired_target_set.add (`Comment, id) acc)
        acc !cascaded_comment_ids
    in
    let removed_reactions, removed_votes =
      if Expired_target_set.is_empty expired_targets
      then 0, 0
      else begin
        let expired_reaction_keys =
          Hashtbl.fold
            (fun key (reaction : reaction) acc ->
               let target =
                 match reaction.target_type with
                 | Reaction_post -> `Post, reaction.target_id
                 | Reaction_comment -> `Comment, reaction.target_id
               in
               if Expired_target_set.mem target expired_targets then key :: acc else acc)
            store.reactions
            []
        in
        let expired_vote_keys =
          Hashtbl.fold
            (fun key _ acc ->
               match vote_key_target key with
               | Some target when Expired_target_set.mem target expired_targets -> key :: acc
               | Some _ | None -> acc)
            store.vote_log
            []
        in
        List.iter (Hashtbl.remove store.reactions) expired_reaction_keys;
        List.iter (Hashtbl.remove store.vote_log) expired_vote_keys;
        List.length expired_reaction_keys, List.length expired_vote_keys
      end
    in
    if removed_reactions > 0 || removed_votes > 0 then
      Log.BoardLog.debug
        "sweep removed %d reactions and %d votes of expired targets"
        removed_reactions
        removed_votes;
    (* The sorted post cache holds post records, so a changed [reply_count]
       invalidates it as much as a removed post does. *)
    if !removed_posts > 0 || !removed_comments > 0 then invalidate_post_caches store;
    if !removed_comments > 0 then invalidate_comment_caches store;
    store.last_sweep <- now;
    !removed_posts, !removed_comments))
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
let workspace_masc_dir = Board_paths.workspace_masc_dir
let persist_path = Board_paths.persist_path
let comments_path = Board_paths.comments_path
let reactions_path = Board_paths.reactions_path
let sub_boards_path = Board_paths.sub_boards_path
let ensure_dir = Board_paths.ensure_dir
let ensure_masc_dir ~where store =
  match Board_paths.ensure_masc_dir store with
  | Ok () -> Ok ()
  | Error rejection ->
    let message = Board_workspace_binding.rejection_to_string rejection in
    let result = Error (Io_error (Printf.sprintf "%s: %s" where message)) in
    (match Option.bind (Board_workspace_binding.raised rejection)
             Board_posts_source.reserved_exception with
     | Some (exception_, backtrace) ->
       (* Do not invoke a logger after observing cancellation/another reserved
          cause. Retain the single requested-operation error count and carry
          the result through the enclosing Board locks. *)
       Atomic.incr persist_errors;
       Board_posts_source.defer_reserved ~result exception_ backtrace;
       result
     | None -> record_persist_error ~where message; result)
include Board_core_json

(** {1 Rewrite Helpers} *)
type posts_snapshot = Board_posts_source.snapshot
let capture_posts_snapshot = Board_posts_source.capture
let save_posts_snapshot = Board_posts_source.rewrite
let append_post = Board_posts_source.append
let require_posts_source_readable = Board_posts_source.require_readable
let posts_source_failure_to_board_error = Board_posts_source.failure_to_board_error
let read_posts_source = Board_posts_source.read
let publish_posts_read = Board_posts_source.publish_read
let finish_posts_write outcome =
  let diagnostics = Board_posts_source.write_diagnostics outcome in
  match Board_posts_source.reserved_diagnostics diagnostics with
  | Some _ ->
    (* Match ordinary counting without invoking a logger after cancellation or
       another reserved cause has already been observed. *)
    (match outcome with
     | Posts_written _ -> List.iter (fun _ -> Atomic.incr persist_errors) diagnostics
     | Posts_not_written _ | Posts_write_unknown _ -> Atomic.incr persist_errors);
    Board_posts_source.finish_write outcome
  | None ->
    let result = Board_posts_source.finish_write outcome in
    (try
      (match outcome with
       | Posts_written _ ->
         List.iter (fun diagnostic -> record_persist_error ~where:"posts settlement"
           (Board_posts_source.diagnostic_to_string diagnostic)) diagnostics
       | Posts_not_written { failure; _ } | Posts_write_unknown { failure; _ } ->
         record_persist_error ~where:"posts source"
           (show_board_error (posts_source_failure_to_board_error failure)));
      result
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      Board_posts_source.defer_reserved ~result exception_ backtrace;
      Printexc.raise_with_backtrace exception_ backtrace)
let finish_posts_read outcome =
  let diagnostics = Board_posts_source.read_diagnostics outcome in
  match Board_posts_source.reserved_diagnostics diagnostics with
  | Some _ ->
    List.iter (fun _ -> Atomic.incr persist_errors) diagnostics;
    Board_posts_source.finish_read outcome
  | None ->
    Board_posts_source.finish_read outcome;
    List.iter (fun diagnostic -> record_persist_error ~where:"posts read settlement"
      (Board_posts_source.diagnostic_to_string diagnostic)) diagnostics
type posts_inspection_framing = Board_posts_inspection.posts_inspection_framing =
  | Complete_rows
  | Torn_tail of { rows_end : int; end_offset : int }

type posts_inspection_observation = Board_posts_inspection.posts_inspection_observation =
  | Observed_missing
  | Observed_present of {
      accepted_rows : int;
      errors : posts_row_error list;
      framing : posts_inspection_framing;
    }

type posts_inspection = Board_posts_inspection.posts_inspection =
  | Inspected of {
      observation : posts_inspection_observation;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }
  | Inspection_failed of {
      error : Fs_compat.Private_jsonl_unique_fold.error;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }


let finish_posts_inspection inspection =
  let settlement_diagnostic = match inspection with
    | Inspected { settlement_diagnostic; _ }
    | Inspection_failed { settlement_diagnostic; _ } -> settlement_diagnostic in
  Option.iter (fun failure ->
    record_persist_error ~where:"posts inspection settlement"
      (Fs_compat.private_jsonl_operation_failure_to_string failure)) settlement_diagnostic;
  Board_posts_inspection.finish inspection;
  inspection

let inspect_posts_source ~workspace_masc_dir =
  Board_posts_inspection.read ~workspace_masc_dir |> finish_posts_inspection

let inspect_posts_source_with_io_for_testing ~workspace_masc_dir ~io =
  Board_posts_inspection.read_with_io_for_testing ~workspace_masc_dir ~io
  |> finish_posts_inspection
;;
let finish_comments_write outcome =
  let diagnostics = Board_comments_source.write_diagnostics outcome in
  match Board_comments_source.reserved_diagnostics diagnostics with
  | Some _ ->
    (match outcome with
     | Board_comments_source.Written _ -> List.iter (fun _ -> Atomic.incr persist_errors) diagnostics
     | Not_written _ | Unknown _ -> Atomic.incr persist_errors);
    Board_comments_source.finish_write outcome
  | None ->
    let result = Board_comments_source.finish_write outcome in
    (try
       (match outcome with
        | Board_comments_source.Written _ ->
          List.iter (fun diagnostic -> record_persist_error ~where:"comments settlement"
            (Board_comments_source.diagnostic_to_string diagnostic)) diagnostics
        | Not_written { failure; _ } | Unknown { failure; _ } ->
          record_persist_error ~where:"comments source"
            (show_board_error (Board_comments_source.failure_to_board_error failure)));
       result
     with exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result) exception_ backtrace;
       Printexc.raise_with_backtrace exception_ backtrace)

type comments_snapshot = Board_comments_source.snapshot
type comment_append_receipt = Board_comments_source.append_receipt
let capture_comments_snapshot = Board_comments_source.capture
let save_comments_snapshot store snapshot =
  finish_comments_write (Board_comments_source.rewrite store snapshot)
let settle_comments_source store = finish_comments_write (Board_comments_source.settle store)
let acknowledge_comments_recovery = Board_comments_source.acknowledge_recovery
let append_comment store ~reader comment =
  let* () = Board_comments_source.require_readable store in
  let* admission = with_lock store (fun () -> Board_comment_admission.capture store ~reader comment) in
  match Board_comments_source.append store ~admission comment with
  | Written { value; _ } -> Ok value
  | (Not_written _ | Unknown _) as outcome -> finish_comments_write outcome
let publish_comment_append store receipt =
  finish_comments_write (Board_comments_source.publish_append store receipt)

let rewrite_comments_under_persistence store =
    let snapshot = with_lock store (fun () -> capture_comments_snapshot store) in
    match save_comments_snapshot store snapshot with
    | Ok () -> ()
    | Error _ ->
      with_lock store (fun () ->
        store.dirty_comments <- true;
        Hashtbl.iter
          (fun key _ -> Hashtbl.replace store.dirty_comment_ids key ())
          store.comments)
;;
let rewrite_comments store =
  with_persist_lock store (fun () -> rewrite_comments_under_persistence store)
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
(* Deletion/flush captured an already-installed model in this persistence
   interval. Acknowledge only the exact known-success file receipt. *)
let save_reactions_jsonl_result store content =
  let module Source = Board_reactions_source in
  let outcome = Source.rewrite store content in
  let result = match outcome with
    | Source.Written { publication; _ } -> Source.acknowledge_publication store publication
    | Source.Not_written _ | Source.Unknown _ -> Error (Io_error "Board data is unavailable.")
  in
  let result = Source.finish_write outcome result in
  try
    (match result with
     | Ok () -> ()
     | Error error -> record_persist_error ~where:"rewrite_reactions" (show_board_error error));
    result
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Board_posts_source.defer_reserved ~result exception_ backtrace;
    Printexc.raise_with_backtrace exception_ backtrace
;;

let sub_board_access_to_string = Board_sub_board_json.sub_board_access_to_string
let sub_board_access_of_string_opt = Board_sub_board_json.sub_board_access_of_string_opt
let sub_board_access_field_of_yojson =
  Board_sub_board_json.sub_board_access_field_of_yojson
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
let sub_board_post_count_for_slug_unlocked store slug =
  Hashtbl.fold
    (fun _ (p : post) count ->
       match p.hearth with
       | Some post_slug when String.equal post_slug slug -> count + 1
       | Some _ | None -> count)
    store.posts
    0
;;
let sub_board_with_post_count_unlocked store (sb : sub_board) =
  { sb with post_count = sub_board_post_count_for_slug_unlocked store sb.slug }
;;
let sub_board_with_post_count counts (sb : sub_board) =
  { sb with post_count = sub_board_post_count_from_counts counts sb.slug }
;;
let sub_board_author_allowed sb ~author_id = Board_access.can_post_in_sub_board ~author_id sb
;;
let validate_sub_board_post_policy_unlocked store ~author_id ~hearth =
  match hearth with
  | None -> Ok ()
  | Some slug ->
    Result.bind
      (Board_sub_boards_source.require_readable store)
      (fun () ->
        match Hashtbl.find_opt store.sub_boards_by_slug slug with
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
                  (Printf.sprintf "Sub-board %S is %s; %s cannot post"
                     sb.slug access author))))
;;

(** {1 Post Operations} *)
type post_publication_phase =
  | Before_append
  | Append_started
  | Post_committed of post_creation

let validate_post_origin_for_author ~author_id (origin : post_origin option)
  : (post_origin option, board_error) Result.t
  =
  match origin with
  | None -> Ok None
  | Some o ->
    (match o.fusion_run_id, o.fusion_producer with
     | None, None -> Ok (Some o)
     | Some run_id, Some producer when String.trim run_id <> "" ->
       (match Agent_id.of_string producer with
        | Error _ as error -> error
        | Ok producer_id ->
          if not (String.equal (Agent_id.to_string author_id) (Agent_id.to_string producer_id))
          then
            Error
              (Validation_error
                 (Printf.sprintf
                    "origin.fusion_producer %S must match post author %S"
                    (Agent_id.to_string producer_id)
                    (Agent_id.to_string author_id)))
          else
            Ok
              (Some
                 { o with
                   fusion_producer = Some (Agent_id.to_string producer_id)
                 }))
     | Some _, None ->
       Error
         (Validation_error
            "origin.fusion_run_id requires matching origin.fusion_producer")
     | None, Some _ ->
       Error
         (Validation_error
            "origin.fusion_producer requires non-empty origin.fusion_run_id")
     | Some _, Some _ ->
       Error
         (Validation_error "origin.fusion_run_id must not be empty"))
;;

let create_post_with_audience_internal
      ~defer_settlement
      store
      ~lookup
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
  : (post_creation, Post_publication_failure.t) Result.t
  =
  let phase = ref Before_append in
  let failure cause =
    match !phase with
    | Before_append -> Post_publication_failure.before_effect cause
    | Append_started -> Post_publication_failure.unknown cause
    | Post_committed creation -> Post_publication_failure.after_commit creation cause
  in
  try
  let result =
  maybe_sweep store;
  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->
    match validate_post_origin_for_author ~author_id origin with
    | Error e -> Error e
    | Ok origin ->
    if ttl_hours < 0
    then Error (Validation_error "ttl_hours must be non-negative")
    else
    let hearth =
      match hearth with
      | None -> None
      | Some h ->
        let normalized = String.lowercase_ascii (String.trim h) in
        if String.equal normalized "" then None else Some normalized
    in
    let expires_at =
      let now = Time_compat.now () in
      if ttl_hours = 0
      then 0.0
      else now +. (Stdlib.Float.of_int ttl_hours *. Masc_time_constants.hour)
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
    if String.length normalized_body = 0
    then Error (Validation_error "Content cannot be empty")
    else
      match
        Board_audience.audience_for_post
          ~lookup
          ~post_kind:normalized_kind
          ~visibility
          ~title:normalized_title
          ~content:normalized_body
      with
      | Error _ as error -> error
      | Ok (audience, unresolved) ->
      (* Stage under the state lock without mutation. The final policy check,
         append and memory commit share the persistence lock with runtime
         sub-board mutations and snapshot writers. *)
      let staged =
        with_lock store (fun () ->
          match validate_sub_board_post_policy_unlocked store ~author_id ~hearth with
            | Error e -> Error e
            | Ok () ->
              let now = Time_compat.now () in
              Ok
                { id = Post_id.generate ()
                ; author = author_id
                ; title = normalized_title
                ; body = normalized_body
                ; post_kind = normalized_kind
                ; meta_json = normalized_meta
                ; visibility
                ; audience = Some audience
                ; created_at = now
                ; content_updated_at = now
                ; updated_at = now
                ; expires_at
                ; votes_up = 0
                ; votes_down = 0
                ; reply_count = 0
                ; pinned = false
                ; hearth
                ; thread_id
                ; origin
                ; closed = None
                })
      in
      match staged with
      | Error _ as e -> e
      | Ok post ->
        let creation = { post; audience; unresolved } in
        with_persist_lock_internal ~defer_settlement store (fun () ->
          (* Capture canonical policy authority before IO. Scoped creation
             retains Posts -> Policy locks through the append; same-store
             persistence alone cannot serialize another store's policy write. *)
          match
            with_lock store (fun () ->
              Board_policy_admission.capture store ~author_id ~hearth)
          with
          | Error _ as error -> error
          | Ok policy ->
            phase := Append_started;
            let outcome = match policy with
              | None -> append_post store post
              | Some policy ->
                (match Board_posts_source.append_creation_with_policy store ~policy post with
                 | Board_posts_source.Creation_append_outcome outcome -> outcome
                 | Board_posts_source.Creation_policy_refused { failure; outcome } ->
                   phase := Before_append;
                   Board_sub_boards_source.observe_guard_refusal store policy failure;
                   outcome) in
            match outcome with
            | (Posts_not_written _ as outcome) ->
              phase := Before_append;
              finish_posts_write outcome |> Result.map (fun () -> creation)
            | (Posts_write_unknown _ as outcome) ->
              finish_posts_write outcome |> Result.map (fun () -> creation)
            | (Posts_written _ as outcome) ->
              with_lock store (fun () ->
                Hashtbl.add store.posts (Post_id.to_string post.id) post;
                index_post_origin store post;
                index_hot_post store post;
                Stdlib.incr store.post_count;
                invalidate_post_caches store;
                phase := Post_committed creation);
              finish_posts_write outcome |> Result.map (fun () -> creation))
  in
  Result.map_error (fun error -> failure (Post_publication_failure.Board_error error)) result
  with
  | Board_posts_source.Reserved_settlement _ as carrier -> raise carrier
  | Deferred_persist_observer _ as carrier -> raise carrier
  | (Eio.Cancel.Cancelled _ | Eio.Time.Timeout
     | Out_of_memory | Stack_overflow | Sys.Break) as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn backtrace
  | exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Board_posts_source.propagate_reserved exn backtrace;
    Error (failure (Post_publication_failure.Raised exn))
;;

let create_post_with_audience store ~lookup ~author ~content ?title ?body
      ~post_kind ?meta_json ?visibility ?ttl_hours ?hearth ?thread_id ?origin () =
  create_post_with_audience_internal ~defer_settlement:false store ~lookup ~author
    ~content ?title ?body ~post_kind ?meta_json ?visibility ?ttl_hours ?hearth
    ?thread_id ?origin ()
;;

let create_post store ~lookup ~author ~content ?title ?body ~post_kind ?meta_json
      ?visibility ?ttl_hours ?hearth ?thread_id ?origin ()
  =
  create_post_with_audience
    store
    ~lookup
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
  |> Result.map (fun creation -> creation.post)
;;

type create_post_once_result =
  | Post_created of post_creation
  | Post_already_present of post

type post_edit =
  { edited : post
  ; recorded_audience : audience
  ; unresolved : string list
  ; content_changed : bool
  }

let create_post_once_by_fusion_run_id
      store
      ~lookup
      ~fusion_run_id
      ~author
      ~content
      ~post_kind
      ?meta_json
      ~visibility
      ~ttl_hours
      ~origin
      ()
  =
  let pre_effect error =
    Error (Post_publication_failure.before_effect
      (Post_publication_failure.Board_error error))
  in
  let option_equal equal left right =
    match left, right with
    | None, None -> true
    | Some left, Some right -> equal left right
    | None, Some _ | Some _, None -> false
  in
  let origin_equal left right =
    option_equal Ids.Turn_ref.equal left.turn_ref right.turn_ref
    && option_equal String.equal left.source right.source
    && option_equal String.equal left.fusion_run_id right.fusion_run_id
    && option_equal String.equal left.fusion_producer right.fusion_producer
  in
  let post_kind_equal left right =
    match left, right with
    | Human_post, Human_post
    | Automation_post, Automation_post
    | System_post, System_post -> true
    | Human_post, (Automation_post | System_post)
    | Automation_post, (Human_post | System_post)
    | System_post, (Human_post | Automation_post) -> false
  in
  let visibility_equal left right =
    match left, right with
    | Public, Public
    | Unlisted, Unlisted
    | Internal, Internal
    | Direct, Direct -> true
    | Public, (Unlisted | Internal | Direct)
    | Unlisted, (Public | Internal | Direct)
    | Internal, (Public | Unlisted | Direct)
    | Direct, (Public | Unlisted | Internal) -> false
  in
  if String.equal fusion_run_id ""
  then pre_effect (Validation_error "fusion_run_id must not be empty")
  else if ttl_hours < 0
  then pre_effect (Validation_error "ttl_hours must be non-negative")
  else
    match origin.fusion_run_id, origin.fusion_producer with
    | Some origin_run_id, Some producer
      when String.equal origin_run_id fusion_run_id && String.trim producer <> "" ->
      (match
         Agent_id.of_string author,
         Agent_id.of_string producer,
         normalize_post_payload ~content ~post_kind ?meta_json ()
       with
       | Error error, _, _ -> pre_effect error
       | _, Error error, _ -> pre_effect error
       | _, _, Error (Meta_not_assoc payload) ->
         pre_effect
           (Validation_error
              (Printf.sprintf
                 "Malformed meta_json: expected JSON object, got %s"
                 (Yojson.Safe.to_string payload)))
       | Ok author_id, Ok producer_id, Ok (title, body, post_kind, meta_json) ->
         if not (String.equal (Agent_id.to_string author_id) (Agent_id.to_string producer_id))
         then
           pre_effect
             (Validation_error
                (Printf.sprintf
                   "origin.fusion_producer %S must match post author %S"
                   (Agent_id.to_string producer_id)
                   (Agent_id.to_string author_id)))
         else
         let origin = { origin with fusion_producer = Some (Agent_id.to_string producer_id) } in
         if String.equal body ""
         then pre_effect (Validation_error "Content cannot be empty")
         else
           let result = Eio.Mutex.use_rw ~protect:true store.origin_create_mutex (fun () ->
             try Ok (
             maybe_sweep store;
             let existing_post =
               with_lock store (fun () ->
                 match Hashtbl.find_opt store.posts_by_run_id fusion_run_id with
                 | None -> None
                 | Some post_id -> Hashtbl.find_opt store.posts post_id)
             in
             match existing_post with
             | Some post ->
               let exact_replay =
                 String.equal post.title title
                 && String.equal post.body body
                 && post_kind_equal post.post_kind post_kind
                 && option_equal Yojson.Safe.equal post.meta_json meta_json
                 && visibility_equal post.visibility visibility
                 && option_equal origin_equal post.origin (Some origin)
                 (* [author] is checked via [origin.fusion_producer] above so an
                    idempotent sink replay still succeeds after post ownership is
                    transferred via [update_post]. [hearth]/[thread_id] are also
                    excluded: this creation path never sets them, so a
                    post-*creation* hearth binding is out-of-band metadata and
                    must not turn a legitimate replay into an [Already_exists]
                    conflict. *)
               in
               if exact_replay
               then Ok (Post_already_present post)
               else
                 pre_effect
                   (Already_exists
                      (Printf.sprintf
                         "conflicting Fusion Board projection for run_id=%S"
                         fusion_run_id))
             | None ->
               create_post_with_audience_internal ~defer_settlement:true
                 store ~lookup ~author ~content ~post_kind
                 ?meta_json ~visibility ~ttl_hours ~origin ()
               |> Result.map (fun creation -> Post_created creation))
             with
             | Board_posts_source.Reserved_settlement settlement ->
               Error (settlement.exception_, settlement.backtrace)
             | Deferred_persist_observer (exn, backtrace) -> Error (exn, backtrace)) in
           match result with
           | Ok result -> result
           | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace)
    | Some origin_run_id, (None | Some _)
      when String.equal origin_run_id fusion_run_id ->
      pre_effect
        (Validation_error
           "create_post_once_by_fusion_run_id requires non-empty origin.fusion_producer")
    | Some origin_run_id, _ ->
      pre_effect
        (Validation_error
           (Printf.sprintf
              "fusion_run_id mismatch: argument=%S origin=%S"
              fusion_run_id
              origin_run_id))
    | None, _ ->
      pre_effect
        (Validation_error
           "create_post_once_by_fusion_run_id requires typed fusion origin")
;;

(* Owner-gated in-place edit of an existing post's title/body. The edited content is
   normalized exactly like [create_post], with the existing
   metadata passed through [normalize_meta_json] so an edit cannot silently
   lose it. [post_kind]/[visibility]/[hearth]/[thread_id]/[origin] are
   preserved. Author mismatch returns [Unauthorized] (no silent ignore).
   Normalization and the audience depend on the existing post's [post_kind],
   [visibility] and [meta_json], and the audience asks the recipient lookup,
   which reads Keeper settings from disk. They are worked out before the locks
   on the post as it stands. Under the locks that result is used only if what
   it was worked out from is unchanged; otherwise both locks are released and
   it is worked out again, so no write is based on a post it did not see.
   Repeated concurrent changes can delay the edit; yielding between attempts
   lets other fibers run and permits cancellation without holding either lock.
   An edit that leaves the text alone keeps a recorded audience. If no
   audience was recorded, even unchanged text needs an audience calculated;
   resolving its address candidates may ask the lookup and fail. *)
let update_post_with_outcome
      store
      ~lookup
      ~post_id
      ~editor
      ~content
      ?title
      ?body
      ?new_author
      ()
  : (post_edit, board_error) Result.t
  =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
  match Agent_id.of_string editor with
  | Error e -> Error e
  | Ok editor_id ->
    let key = Post_id.to_string pid in
    (* What the edit stores for [existing], leaving out who owns it: the
       normalized text, its meta and the audience the text names. Seeded with
       the existing post's metadata so body edits cannot erase it. *)
    let plan (existing : post) =
      match
        normalize_post_payload
          ~content
          ?title
          ?body
          ~post_kind:existing.post_kind
          ?meta_json:existing.meta_json
          ()
      with
      | Error (Board_core_payload.Meta_not_assoc payload) ->
        Error
          (Validation_error
             (Printf.sprintf
                "Malformed meta_json: expected JSON object, got %s"
                (Yojson.Safe.to_string payload)))
      | Ok (normalized_title, normalized_body, _kind, normalized_meta) ->
        if String.length normalized_body = 0
        then Error (Validation_error "Content cannot be empty")
        else (
          match existing.audience with
          | Some recorded
            when String.equal existing.title normalized_title
                 && String.equal existing.body normalized_body ->
            (* The text is the one the recorded audience was worked out from.
               An edit that leaves it alone does not address anybody anew, so
               the audience stays as written and the lookup is not asked: a
               declaration that changed since then does not rewrite it. *)
            Ok (normalized_title, normalized_body, normalized_meta, recorded, [])
          | Some _ | None ->
            Board_audience.audience_for_post
              ~lookup
              ~post_kind:existing.post_kind
              ~visibility:existing.visibility
              ~title:normalized_title
              ~content:normalized_body
            |> Result.map (fun (audience, unresolved) ->
              normalized_title, normalized_body, normalized_meta, audience, unresolved))
    in
    (* What [plan] read from the post.  A vote or a comment replaces the record
       and leaves these alone, so it does not spoil a plan; a write that changes
       one of them does. *)
    let same_plan_inputs (seen : post) (existing : post) =
      seen.post_kind = existing.post_kind
      && seen.visibility = existing.visibility
      && seen.meta_json == existing.meta_json
      && seen.audience == existing.audience
      && String.equal seen.title existing.title
      && String.equal seen.body existing.body
    in
    (* The first plan is made only for the owner of the snapshot. If ownership
       changes after a snapshot, a plan based on it may still ask the lookup;
       the editor must own the current post under the locks before any save. *)
    let owned_by_editor (existing : post) =
      String.equal (Agent_id.to_string existing.author) (Agent_id.to_string editor_id)
    in
    let planned =
      match with_lock store (fun () -> Hashtbl.find_opt store.posts key) with
      | Some existing when owned_by_editor existing -> Some (existing, plan existing)
      | Some _ | None -> None
    in
    (* Persist-before-commit: acquire persistence first, then state. Keeping
       state locked through the write preserves unrelated concurrent fields
       without a rollback or a stale staged-row replacement. *)
    let rec commit planned =
      let outcome =
        with_persist_lock store (fun () ->
          with_lock store (fun () ->
            match Hashtbl.find_opt store.posts key with
            | None -> `Finished (Error (Post_not_found post_id))
            | Some existing ->
              let owner = Agent_id.to_string existing.author in
              let editor_str = Agent_id.to_string editor_id in
              if not (String.equal owner editor_str)
              then
                `Finished
                  (Error
                     (Unauthorized
                        (Printf.sprintf
                           "agent %s cannot edit post %s owned by %s"
                           editor_str
                           key
                           owner)))
              else
                let next_author_result =
                  match new_author with
                  | None -> Ok existing.author
                  | Some value -> Agent_id.of_string value
                in
                (match next_author_result with
                 | Error e -> `Finished (Error e)
                 | Ok next_author ->
                   (* Normalized identically to create. [post_kind] is passed
                      through and the existing post's kind is preserved. *)
                   match planned with
                   | Some (seen, result) when same_plan_inputs seen existing ->
                     `Finished
                       (match result with
                        | Error error -> Error error
                        | Ok (_, _, _, audience, _)
                          when (match existing.visibility with
                            | Direct -> existing.audience <> Some audience
                              || not (String.equal (Agent_id.to_string existing.author) (Agent_id.to_string next_author))
                            | Public | Unlisted | Internal -> false) ->
                          Error (Validation_error "Direct post readership cannot change during editing")
                        | Ok (normalized_title, normalized_body, normalized_meta, audience, unresolved) ->
                          let content_changed =
                            not (String.equal existing.title normalized_title
                                 && String.equal existing.body normalized_body
                                 && String.equal (Agent_id.to_string existing.author)
                                      (Agent_id.to_string next_author))
                          in
                          let now = Time_compat.now () in
                          let updated =
                            { existing with
                              author = next_author
                            ; title = normalized_title
                            ; body = normalized_body
                            ; meta_json = normalized_meta
                            ; audience = Some audience
                            ; content_updated_at =
                                if content_changed then now else existing.content_updated_at
                            ; updated_at = now
                            }
                          in
                          let snapshot = capture_posts_snapshot ~replacement:updated store in
                          match save_posts_snapshot store snapshot with
                          | (Posts_not_written _ | Posts_write_unknown _) as outcome ->
                            finish_posts_write outcome |> Result.map (fun () ->
                              { edited = updated; recorded_audience = audience; unresolved; content_changed })
                          | (Posts_written _ as outcome) ->
                            Hashtbl.replace store.posts key updated;
                            mark_dirty_post store key;
                            invalidate_post_caches store;
                            finish_posts_write outcome |> Result.map (fun () ->
                              { edited = updated
                              ; recorded_audience = audience
                              ; unresolved
                              ; content_changed
                              }))
                   | Some _ | None -> `Replan existing)))
      in
      match outcome with
      | `Finished result -> result
      | `Replan existing ->
        Eio.Fiber.yield ();
        commit (Some (existing, plan existing))
    in
    commit planned
;;
