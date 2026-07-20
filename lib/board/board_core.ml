(* Board Core — JSONL store logic and persistence.
   Types in Board_types. Persist + sweep extracted to
   [Board_core_persist] (godfile decomp). *)

include Board_core_persist

let rollback_fresh_comment store ~(comment : comment) ~(previous_post : post) =
  with_lock store (fun () ->
    let post_key = Post_id.to_string comment.post_id in
    let comment_key = Comment_id.to_string comment.id in
    Hashtbl.remove store.comments comment_key;
    Hashtbl.remove store.pending_comment_durability comment_key;
    Hashtbl.remove store.pending_parent_projection_repairs comment_key;
    (match Hashtbl.find_opt store.comments_by_post post_key with
     | None -> ()
     | Some ids ->
       (match List.filter (fun id -> not (String.equal id comment_key)) ids with
        | [] -> Hashtbl.remove store.comments_by_post post_key
        | filtered -> Hashtbl.replace store.comments_by_post post_key filtered));
    (match Hashtbl.find_opt store.posts post_key with
     | None -> ()
     | Some current ->
       let updated_at =
         if Stdlib.Float.equal current.updated_at comment.created_at
         then previous_post.updated_at
         else current.updated_at
       in
       Hashtbl.replace
         store.posts
         post_key
         { current with reply_count = max 0 (current.reply_count - 1); updated_at });
    invalidate_post_caches store;
    invalidate_comment_caches store)
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

(* RFC-0233 §7 guard #2: exact O(1) index lookups, mirroring [get_post] by
   primary key. The index is keyed on the full join string (turn_ref =
   "trace#turn", or the fusion run_id) — never a meta_json substring or a
   time-window heuristic. A miss returns [None] (no scan, no false positive). *)
let find_post_by_turn_ref store ~turn_ref : post option =
  maybe_sweep store;
  with_lock store (fun () ->
    match Hashtbl.find_opt store.posts_by_turn_ref turn_ref with
    | None -> None
    | Some pid -> Hashtbl.find_opt store.posts pid)
;;

let find_post_by_run_id store ~run_id : post option =
  maybe_sweep store;
  with_lock store (fun () ->
    match Hashtbl.find_opt store.posts_by_run_id run_id with
    | None -> None
    | Some pid -> Hashtbl.find_opt store.posts pid)
;;

(* Reads post + comments under a single critical section. The previous
   two-call sequence (get_post then get_comments) acquired
   [store.mutex] twice with [maybe_sweep] dispatching to the flusher
   actor between releases. That race window surfaces as
   [Mutex.lock: Resource deadlock avoided] under contended
   repeated agent board-read traffic. Coalescing
   keeps the read atomic, removes one [maybe_sweep] dispatch, and
   eliminates the inter-call lock churn. *)
let normalize_comment_page ?comment_offset ?comment_limit total_comments =
  match comment_offset, comment_limit with
  | None, None -> None
  | Some _, _ | _, Some _ ->
    let offset =
      (match comment_offset with
       | None -> 0
       | Some value -> value)
      |> max 0
      |> fun value -> min value total_comments
    in
    let limit =
      (match comment_limit with
       | None -> Limits.default_comment_page_limit
       | Some value -> value)
      |> max 1
      |> min Limits.max_comment_page_limit
    in
    Some (offset, limit)
;;

let get_post_and_comments store ~post_id ?comment_offset ?comment_limit () : (post * comment list, board_error) Result.t =
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
        let sliced =
          match
            normalize_comment_page
              ?comment_offset
              ?comment_limit
              (List.length sorted)
          with
          | None -> sorted
          | Some (offset, limit) ->
            List.filteri (fun i _ -> i >= offset && i < offset + limit) sorted
        in
        Ok (post, sliced))
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
        (* Hot formula lives in [Board_sort] (SSOT) — shared with
           [Board_dispatch.sort_posts_in_memory] to prevent drift. *)
        let sorted = List.sort Board_sort.hot_compare all in
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
    take limit filtered)
;;

let current_post_cursor store =
  maybe_sweep store;
  with_lock store (fun () ->
    match
      Hashtbl.fold
        (fun _ (candidate : post) latest ->
           match latest with
           | None -> Some candidate
           | Some (current : post) ->
             let updated_cmp =
               Stdlib.Float.compare candidate.updated_at current.updated_at
             in
             if updated_cmp > 0
                || (updated_cmp = 0
                    && String.compare
                         (Post_id.to_string candidate.id)
                         (Post_id.to_string current.id)
                       > 0)
             then Some candidate
             else latest)
        store.posts
        None
    with
    | Some post -> post.updated_at, Some (Post_id.to_string post.id)
    | None -> Time_compat.now (), None)
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

let prepare_comment
      store
      ?comment_id
      ~post_id
      ~author
      ~content
      ?parent_id
      ?(ttl_hours = Limits.default_ttl_hours)
      ()
  : (comment * post, board_error) Result.t
  =
  maybe_sweep store;
  (* Validate all IDs first *)
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    (match Agent_id.of_string author with
     | Error e -> Error e
     | Ok author_id ->
       let comment_id = Option.value ~default:(Comment_id.generate ()) comment_id in
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
          if ttl_hours < 0
          then Error (Validation_error "ttl_hours must be non-negative")
          else if String.length content = 0
          then Error (Validation_error "Content cannot be empty")
          else
            with_lock store (fun () ->
              match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
              | None -> Error (Post_not_found post_id)
              | Some post ->
                let comment_id_string = Comment_id.to_string comment_id in
                if Hashtbl.mem store.comments comment_id_string
                then Error (Already_exists comment_id_string)
                else
                  match
                    validate_sub_board_post_policy_unlocked
                      store
                      ~author_id
                      ~hearth:post.hearth
                  with
                  | Error e -> Error e
                  | Ok () ->
                    let created_at = Time_compat.now () in
                    let comment =
                      { id = comment_id
                      ; post_id = pid
                      ; parent_id = parent_cid
                      ; author = author_id
                      ; content
                      ; created_at
                      ; expires_at =
                          (if ttl_hours = 0
                           then 0.0
                           else
                             created_at
                             +. (Stdlib.Float.of_int ttl_hours
                                 *. Masc_time_constants.hour))
                      ; votes_up = 0
                      ; votes_down = 0
                      }
                    in
                    Ok (comment, post))))
;;

let same_comment_creation (left : comment) (right : comment) =
  String.equal (Comment_id.to_string left.id) (Comment_id.to_string right.id)
  && String.equal (Post_id.to_string left.post_id) (Post_id.to_string right.post_id)
  && Option.equal
       (fun left_parent right_parent ->
          String.equal
            (Comment_id.to_string left_parent)
            (Comment_id.to_string right_parent))
       left.parent_id
       right.parent_id
  && String.equal (Agent_id.to_string left.author) (Agent_id.to_string right.author)
  && String.equal left.content right.content
  && Float.equal left.created_at right.created_at
  && Float.equal left.expires_at right.expires_at
;;

let apply_prepared_comment store ~parent_reply_count_before (comment : comment)
  : (comment mutation_application, board_error) result
  =
  if parent_reply_count_before < 0
  then Error (Validation_error "parent_reply_count_before must be non-negative")
  else with_persist_lock store (fun () ->
    let comment_id = Comment_id.to_string comment.id in
    let persist_parent_projection posts_jsonl =
      with_lock store (fun () ->
        Hashtbl.replace store.pending_parent_projection_repairs comment_id ());
      match save_posts_jsonl_result posts_jsonl with
      | Error _ as error -> error
      | Ok () ->
        with_lock store (fun () ->
          Hashtbl.remove store.pending_parent_projection_repairs comment_id);
        Ok ()
    in
    let insertion =
      with_lock store (fun () ->
      let post_id = Post_id.to_string comment.post_id in
      match Hashtbl.find_opt store.comments comment_id with
      | Some existing when same_comment_creation existing comment ->
        (match Hashtbl.find_opt store.posts post_id with
         | None -> Error (Post_not_found post_id)
         | Some post ->
           let previous_index = Hashtbl.find_opt store.comments_by_post post_id in
           let indexed =
             previous_index
             |> Option.value ~default:[]
             |> List.exists (String.equal comment_id)
           in
           let expected_reply_count = parent_reply_count_before + 1 in
           let repaired_post =
             { post with
               reply_count = Int.max post.reply_count expected_reply_count;
               updated_at = Float.max post.updated_at comment.created_at
             }
           in
           let repair_pending =
             Hashtbl.mem store.pending_parent_projection_repairs comment_id
           in
           let primary_pending =
             Hashtbl.find_opt store.pending_comment_durability comment_id
           in
           if
             indexed
             && repaired_post = post
             && not repair_pending
             && Option.is_none primary_pending
           then Ok (`Replay (Already_applied existing))
           else (
             if not indexed
             then
               Hashtbl.replace
                 store.comments_by_post
                 post_id
                 (comment_id :: Option.value ~default:[] previous_index);
             Hashtbl.replace store.posts post_id repaired_post;
             mark_dirty_post store post_id;
             invalidate_post_caches store;
             invalidate_comment_caches store;
             Ok
               (`Repair
                   ( existing
                   , primary_pending
                   , comments_jsonl_unlocked store
                   , posts_jsonl_unlocked store ))))
      | Some _ -> Error (Already_exists comment_id)
      | None ->
        (match Hashtbl.find_opt store.posts post_id with
         | None -> Error (Post_not_found post_id)
         | Some post ->
           Hashtbl.add store.comments comment_id comment;
           let existing =
             Hashtbl.find_opt store.comments_by_post post_id
             |> Option.value ~default:[]
           in
           Hashtbl.replace store.comments_by_post post_id (comment_id :: existing);
           Hashtbl.replace
             store.posts
             post_id
             { post with
               reply_count = post.reply_count + 1;
               updated_at = comment.created_at
             };
           mark_dirty_post store post_id;
           mark_dirty_comment store comment_id;
           invalidate_post_caches store;
           invalidate_comment_caches store;
           Ok
             (`Applied
                 ( post
                 , comments_jsonl_unlocked store
                 , posts_jsonl_unlocked store ))))
    in
    match insertion with
    | Error _ as error -> error
    | Ok (`Replay replayed) -> Ok replayed
    | Ok (`Repair (existing, primary_pending, comments_jsonl, posts_jsonl)) ->
      let settlement =
        match primary_pending with
        | None -> persist_parent_projection posts_jsonl
        | Some initial_detail ->
          settle_unknown_durable_snapshot
            store
            ~initial_detail
            ~retry:(fun () ->
              Result.bind
                (persist_parent_projection posts_jsonl)
                (fun () -> save_comments_jsonl_result comments_jsonl))
            ~on_settled:(fun () ->
              with_lock store (fun () ->
                Hashtbl.remove store.pending_comment_durability comment_id))
      in
      Result.map (fun () -> Repaired_partial_apply existing) settlement
    | Ok (`Applied (previous_post, comments_jsonl, posts_jsonl)) ->
      let persistence =
        match append_comment comment with
        | Error error -> `Comment_append_failed error
        | Ok () ->
          (match persist_parent_projection posts_jsonl with
           | Ok () -> `Persisted
           | Error error -> `Parent_projection_failed error)
      in
      (match persistence with
     | `Comment_append_failed (Persistence_commit_unknown initial_detail) ->
       with_lock store (fun () ->
         Hashtbl.replace store.pending_comment_durability comment_id initial_detail;
         Hashtbl.replace store.pending_parent_projection_repairs comment_id ());
       (match
          settle_unknown_durable_snapshot
            store
            ~initial_detail
            ~retry:(fun () ->
              Result.bind
                (persist_parent_projection posts_jsonl)
                (fun () -> save_comments_jsonl_result comments_jsonl))
            ~on_settled:(fun () ->
              with_lock store (fun () ->
                Hashtbl.remove store.pending_comment_durability comment_id))
        with
        | Error _ as error -> error
        | Ok () -> Ok (Applied comment))
     | `Comment_append_failed error ->
       rollback_fresh_comment store ~comment ~previous_post;
       Error error
     | `Parent_projection_failed error ->
       (* The comment row is already durable.  Retaining the exact in-memory
          command makes the next replay enter the repair branch and rewrite only
          the parent projection; rolling it back here would append the same
          durable comment again on every same-process retry. *)
       with_lock store (fun () ->
         Hashtbl.replace
           store.pending_parent_projection_repairs
           comment_id
           ());
       Error error
     | `Persisted ->
       with_lock store (fun () ->
         mark_dirty_post store (Post_id.to_string comment.post_id);
         mark_dirty_comment store comment_id);
       Ok (Applied comment)))
;;

let add_comment store ?comment_id ~post_id ~author ~content ?parent_id
      ?ttl_hours ()
  =
  Result.bind
    (prepare_comment
       store
       ?comment_id
       ~post_id
       ~author
       ~content
       ?parent_id
       ?ttl_hours
       ())
    (fun (comment, post) ->
       Result.map
         (function
           | Applied applied
           | Already_applied applied
           | Repaired_partial_apply applied -> applied)
         (apply_prepared_comment
            store
            ~parent_reply_count_before:post.reply_count
            comment))
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

let get_comment store ~comment_id : (comment, board_error) Result.t =
  maybe_sweep store;
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
    with_lock store (fun () ->
      let comment_key = Comment_id.to_string cid in
      match Hashtbl.find_opt store.comments comment_key with
      | Some comment -> Ok comment
      | None -> Error (Comment_not_found comment_id))
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

let prepare_reaction_toggle store ~target_type ~target_id ~user_id ~emoji =
  maybe_sweep store;
  match Agent_id.of_string user_id, normalize_reaction_emoji emoji with
  | Error error, _ | _, Error error -> Error error
  | Ok user_id, Ok emoji ->
    let user_id = Agent_id.to_string user_id in
    with_lock store (fun () ->
      match ensure_reaction_target_unlocked store ~target_type ~target_id with
      | Error error -> Error error
      | Ok () ->
        let key = reaction_key ~target_type ~target_id ~user_id ~emoji in
        Ok
          { user_id
          ; emoji
          ; reacted = not (Hashtbl.mem store.reactions key)
          ; created_at = Time_compat.now ()
          })
;;

let mutate_reaction store ~target_type ~target_id ~user_id ~emoji ~created_at ~decide
  : (reaction_toggle_result, board_error) Result.t
  =
  match Agent_id.of_string user_id, normalize_reaction_emoji emoji with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok user_id, Ok emoji ->
    let user_id_string = Agent_id.to_string user_id in
    with_persist_lock store (fun () ->
      let mutation =
        with_lock store (fun () ->
        match ensure_reaction_target_unlocked store ~target_type ~target_id with
        | Error e -> Error e
        | Ok () ->
          let key = reaction_key ~target_type ~target_id ~user_id:user_id_string ~emoji in
          let previous = Hashtbl.find_opt store.reactions key in
          let reacted = decide (Option.is_some previous) in
          let applied =
            if reacted
            then
              match previous with
              | Some reaction -> Some reaction
              | None ->
                Some
                  { target_type
                  ; target_id
                  ; user_id
                  ; emoji
                  ; created_at
                  }
            else None
          in
          if not (Option.equal ( = ) previous applied)
          then (
            match applied with
            | None -> Hashtbl.remove store.reactions key
            | Some reaction ->
              Hashtbl.replace
                store.reactions
                key
                reaction);
          let summary =
            reaction_summaries_unlocked
              store
              ~target_type
              ~target_id
              ~user_id:user_id_string
              ()
          in
          let result =
            { target_type; target_id; user_id = user_id_string; emoji; reacted; summary }
          in
          let changed = not (Option.equal ( = ) previous applied) in
          let pending_detail =
            Hashtbl.find_opt store.pending_reaction_durability key
          in
          let content =
            if changed || Option.is_some pending_detail
            then Some (reactions_jsonl_unlocked store)
            else None
          in
          Ok (result, key, previous, applied, changed, pending_detail, content))
      in
      match mutation with
      | Error _ as error -> error
      | Ok (result, _key, _previous, _applied, _changed, _pending, None) ->
        Ok result
      | Ok (result, key, previous, applied, changed, pending_detail, Some content) ->
        let settle initial_detail =
          settle_unknown_durable_snapshot
            store
            ~initial_detail
            ~retry:(fun () -> save_reactions_jsonl_result content)
            ~on_settled:(fun () ->
              with_lock store (fun () ->
                Hashtbl.remove store.pending_reaction_durability key))
        in
        (match pending_detail with
         | Some initial_detail -> Result.map (fun () -> result) (settle initial_detail)
         | None ->
           (match save_reactions_jsonl_result content with
            | Ok () -> Ok result
            | Error (Persistence_commit_unknown initial_detail) ->
              with_lock store (fun () ->
                Hashtbl.replace
                  store.pending_reaction_durability
                  key
                  initial_detail;
                store.dirty_posts <- true);
              Result.map (fun () -> result) (settle initial_detail)
            | Error error ->
              if changed
              then
                with_lock store (fun () ->
                  let current = Hashtbl.find_opt store.reactions key in
                  if Option.equal ( = ) current applied
                  then
                    match previous with
                    | None -> Hashtbl.remove store.reactions key
                    | Some reaction -> Hashtbl.replace store.reactions key reaction);
              Error error)))
;;

let set_reaction store ~target_type ~target_id ~user_id ~emoji ~reacted ~created_at =
  mutate_reaction
    store
    ~target_type
    ~target_id
    ~user_id
    ~emoji
    ~created_at
    ~decide:(fun _current -> reacted)
;;

let toggle_reaction store ~target_type ~target_id ~user_id ~emoji =
  maybe_sweep store;
  mutate_reaction
    store
    ~target_type
    ~target_id
    ~user_id
    ~emoji
    ~created_at:(Time_compat.now ())
    ~decide:not
;;

(** {1 SubBoard Operations} *)

let sub_board_to_yojson = Board_sub_board_json.sub_board_to_yojson
let dedupe_agent_ids = Board_sub_board_json.dedupe_agent_ids
let parse_sub_board_members = Board_sub_board_json.parse_sub_board_members
let sub_board_of_yojson = Board_sub_board_json.sub_board_of_yojson

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
    rewrite_jsonl_durable_result ~where:"rewrite_sub_boards" path content
  with
  | Sys_error msg -> persist_io_error ~where:"rewrite_sub_boards" msg
;;

let settle_unknown_sub_board_commit store content ~initial_detail =
  with_lock store (fun () -> store.dirty_sub_boards <- true);
  match save_sub_boards_jsonl content with
  | Ok () ->
    with_lock store (fun () -> store.dirty_sub_boards <- false);
    Ok ()
  | Error retry_error ->
    request_flush store;
    Error
      (Persistence_commit_unknown
         (Printf.sprintf
            "%s; idempotent snapshot settlement failed: %s; dirty snapshot \
             admitted to the Board flusher"
            initial_detail
            (show_board_error retry_error)))
;;

let append_sub_board (sb : sub_board) =
  try
    ensure_masc_dir ();
    let path = sub_boards_path () in
    (match
       Fs_compat.append_private_jsonl_durable_stable_locked_result
         path
         (Yojson.Safe.to_string (sub_board_to_yojson sb) ^ "\n")
     with
     | Ok () -> Ok ()
     | Error error -> persist_transaction_error ~where:"append_sub_board" error)
  with
  | Sys_error msg -> persist_io_error ~where:"append_sub_board" msg
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
         with_persist_lock store (fun () ->
           let result =
             with_lock store (fun () ->
             if Hashtbl.mem store.sub_boards_by_slug slug
             then
               Error
                 (Already_exists (Printf.sprintf "Sub-board slug %S already exists" slug))
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
                 Ok sb))
           in
           match result with
           | Error _ as error -> error
           | Ok sb ->
             (match append_sub_board sb with
              | Ok () -> Ok sb
              | Error (Persistence_commit_unknown initial_detail) ->
                let content =
                  with_lock store (fun () -> sub_boards_jsonl_unlocked store)
                in
                (match
                   settle_unknown_sub_board_commit store content ~initial_detail
                 with
                 | Ok () -> Ok sb
                 | Error _ as error -> error)
              | Error error ->
                with_lock store (fun () ->
                  let id = Sub_board_id.to_string sb.id in
                  match Hashtbl.find_opt store.sub_boards id with
                  | Some current when current = sb ->
                    Hashtbl.remove store.sub_boards id;
                    Hashtbl.remove store.sub_boards_by_slug sb.slug
                  | Some _ | None -> ());
                Error error))))
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
  with_persist_lock store (fun () ->
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
        let members_result =
          match members with
          | None -> Ok sb.members
          | Some raw -> parse_sub_board_members ~owner:sb.owner raw
        in
        Result.map
          (fun members ->
             let updated =
               { sb with
                 name = Option.value ~default:sb.name (Option.map String.trim name)
               ; description =
                   Option.value
                     ~default:sb.description
                     (Option.map String.trim description)
               ; members
               ; access = Option.value ~default:sb.access access
               }
             in
             Hashtbl.replace store.sub_boards (Sub_board_id.to_string sb.id) updated;
             sb, updated, sub_boards_jsonl_unlocked store)
          members_result)
    in
    match result with
    | Error _ as error -> error
    | Ok (previous, updated, content) ->
      (match save_sub_boards_jsonl content with
       | Ok () ->
         with_lock store (fun () -> store.dirty_sub_boards <- false);
         Ok updated
       | Error (Persistence_commit_unknown initial_detail) ->
         (match
            settle_unknown_sub_board_commit store content ~initial_detail
          with
          | Ok () -> Ok updated
          | Error _ as error -> error)
       | Error error ->
         with_lock store (fun () ->
           let id = Sub_board_id.to_string previous.id in
           match Hashtbl.find_opt store.sub_boards id with
           | Some current when current = updated -> Hashtbl.replace store.sub_boards id previous
           | Some _ | None -> ());
         Error error))
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
      let removed = Hashtbl.find store.sub_boards id in
      let affected_posts =
        Hashtbl.fold
          (fun key (post : post) affected ->
             if Option.equal String.equal post.hearth (Some slug)
             then (key, post) :: affected
             else affected)
          store.posts
          []
      in
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
      let content = sub_boards_jsonl_unlocked store in
      Ok (id, slug, removed, affected_posts, content))
    in
    match snapshot with
    | Error _ as error -> error
    | Ok (id, slug, removed, affected_posts, content) ->
      (match save_sub_boards_jsonl content with
       | Ok () ->
         with_lock store (fun () -> store.dirty_sub_boards <- false);
         Ok ()
       | Error (Persistence_commit_unknown initial_detail) ->
         (match
            settle_unknown_sub_board_commit store content ~initial_detail
          with
          | Ok () -> Ok ()
          | Error _ as error -> error)
       | Error error ->
         with_lock store (fun () ->
           Hashtbl.replace store.sub_boards id removed;
           Hashtbl.replace store.sub_boards_by_slug slug id;
           List.iter
             (fun (key, post) -> Hashtbl.replace store.posts key post)
             affected_posts;
           invalidate_post_caches store);
         Error error))
;;

(** {1 Voting - Deduplicated} *)
