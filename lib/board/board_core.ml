(* Board Core — JSONL store logic and persistence.
   Types in Board_types. Persist + sweep extracted to
   [Board_core_persist] (godfile decomp). *)

include Board_core_persist

let rollback_fresh_comment store ~(comment : comment) ~(previous_post : post) =
  with_lock store (fun () ->
    let post_key = Post_id.to_string comment.post_id in
    let comment_key = Comment_id.to_string comment.id in
    Hashtbl.remove store.comments comment_key;
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

let reclassify_posts store ?(limit = 5200) ?(dry_run = true) () =
  maybe_sweep store;
  let scan_limit = max 0 (min limit 5200) in
  let json_string name json =
    match Json_util.assoc_member_opt name json with
    | Some (`String value) when not (String.equal (String.trim value) "") -> Some value
    | _ -> None
  in
  let json_float name json =
    match Json_util.assoc_member_opt name json with
    | Some (`Float value) -> Some value
    | Some (`Int value) -> Some (Stdlib.Float.of_int value)
    | _ -> None
  in
  let post_kind_status json =
    match json_string "id" json with
    | None -> None
    | Some id ->
      let created_at = json_float "created_at" json |> Option.value ~default:0.0 in
      let status =
        match Option.bind (json_string "post_kind" json) post_kind_of_string with
        | Some _ -> `Valid
        | None -> `Invalid
      in
      Some (id, created_at, status)
  in
  let persisted_candidates =
    let path = persist_path () in
    if Fs_compat.file_exists path
    then
      Fs_compat.load_jsonl path |> List.filter_map post_kind_status
    else []
  in
  let total = List.length persisted_candidates in
  let selected_candidates =
    persisted_candidates
    |> List.sort (fun (_, created_a, _) (_, created_b, _) ->
      Stdlib.Float.compare created_b created_a)
    |> List.filteri (fun idx _ -> idx < scan_limit)
  in
  let scanned = List.length selected_candidates in
  let invalid_count =
    selected_candidates
    |> List.fold_left
         (fun acc (_, _, status) ->
            match status with
            | `Valid -> acc
            | `Invalid -> acc + 1)
         0
  in
  let invalid_post_ids =
    selected_candidates
    |> List.filter_map (fun (post_id, _, status) ->
      match status with
      | `Valid -> None
      | `Invalid -> Some post_id)
    |> take 20
  in
  { backend = "jsonl"
  ; dry_run
  ; scanned
  ; changed = 0
  ; unchanged = scanned - invalid_count
  ; skipped = invalid_count + max 0 (total - scanned)
  ; apply_failures = 0
  ; changed_post_ids = []
  ; invalid_post_ids
  }
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
                      ; mention_ids = Mention_id.mention_ids_of_content content
                      ; created_at = now
                      ; expires_at =
                          (if ttl = 0
                           then 0.0
                           else now +. (Stdlib.Float.of_int ttl *. Masc_time_constants.hour))
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
                    mark_dirty_post store post_key;
                    mark_dirty_comment store (Comment_id.to_string comment.id);
                    invalidate_post_caches store;
                    invalidate_comment_caches store;
                    Ok (`Fresh (comment, post, posts_jsonl_unlocked store))))))
            in
            match board_result with
            | Ok (`Fresh (comment, previous_post, posts_jsonl)) ->
              (match with_persist_lock store (fun () -> append_comment comment) with
               | Error e ->
                 rollback_fresh_comment store ~comment ~previous_post;
                 Error e
               | Ok () ->
                 (match with_persist_lock store (fun () -> save_posts_jsonl posts_jsonl) with
                  | Error _ as e -> e
                  | Ok () ->
                 record_comment_timestamp
                   ~author:(Agent_id.to_string comment.author)
                   ~now:comment.created_at;
                 with_lock store (fun () ->
                   mark_dirty_post store (Post_id.to_string comment.post_id);
                   mark_dirty_comment store (Comment_id.to_string comment.id));
                 Ok (comment, `Fresh)))
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
      match Hashtbl.find_opt store.posts post_key with
      | None -> Error (Post_not_found post_id)
      | Some _ ->
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

let restore_reaction_after_rewrite_failure store ~key previous =
  with_lock store (fun () ->
    match previous with
    | Some reaction -> Hashtbl.replace store.reactions key reaction
    | None -> Hashtbl.remove store.reactions key)
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
	          let previous = Hashtbl.find_opt store.reactions key in
	          let reacted =
	            match previous with
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
	          Ok
	            ( key
	            , previous
	            , { target_type; target_id; user_id = user_id_string; emoji; reacted; summary } ))
	    in
	    (match result with
	     | Error _ as e -> e
	     | Ok (key, previous, toggled) ->
	       (match rewrite_reactions store with
	        | Ok () -> Ok toggled
	        | Error _ as e ->
	          restore_reaction_after_rewrite_failure store ~key previous;
	          e))
;;

(** {1 SubBoard Operations} *)

let sub_board_to_yojson = Board_sub_board_json.sub_board_to_yojson
let dedupe_agent_ids = Board_sub_board_json.dedupe_agent_ids

type sub_board_member_parse_error =
  Board_sub_board_json.sub_board_member_parse_error =
  { member_name : string
  ; error : board_error
  }

type sub_board_members_parse_report =
  Board_sub_board_json.sub_board_members_parse_report =
  { members : Agent_id.t list
  ; errors : sub_board_member_parse_error list
  }

type sub_board_json_report =
  Board_sub_board_json.sub_board_json_report =
  { sub_board : sub_board option
  ; member_errors : sub_board_member_parse_error list
  }

let parse_sub_board_members = Board_sub_board_json.parse_sub_board_members
let parse_sub_board_members_lenient = Board_sub_board_json.parse_sub_board_members_lenient
let parse_sub_board_members_lenient_report =
  Board_sub_board_json.parse_sub_board_members_lenient_report

let sub_board_of_yojson_report = Board_sub_board_json.sub_board_of_yojson_report
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

let save_sub_boards_jsonl_result content =
  try
    ensure_masc_dir ();
    let path = sub_boards_path () in
    match Fs_compat.save_file_atomic path content with
    | Ok () -> Ok ()
    | Error msg -> persist_io_error ~where:"rewrite_sub_boards" msg
  with
  | Sys_error msg -> persist_io_error ~where:"rewrite_sub_boards" msg
;;

let rewrite_sub_boards store =
  let content = with_lock store (fun () -> sub_boards_jsonl_unlocked store) in
  with_persist_lock store (fun () -> save_sub_boards_jsonl_result content)
;;

let append_sub_board_result (sb : sub_board) =
  try
    ensure_masc_dir ();
    let path = sub_boards_path () in
    Fs_compat.append_file path (Yojson.Safe.to_string (sub_board_to_yojson sb) ^ "\n");
    Ok ()
  with
  | Sys_error msg -> persist_io_error ~where:"append_sub_board" msg
;;

let rollback_sub_board_create store (sb : sub_board) =
  with_lock store (fun () ->
    Hashtbl.remove store.sub_boards (Sub_board_id.to_string sb.id);
    Hashtbl.remove store.sub_boards_by_slug sb.slug)
;;

let restore_sub_board store (sb : sub_board) =
  with_lock store (fun () ->
    Hashtbl.replace store.sub_boards (Sub_board_id.to_string sb.id) sb;
    Hashtbl.replace store.sub_boards_by_slug sb.slug (Sub_board_id.to_string sb.id))
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
            (match with_persist_lock store (fun () -> append_sub_board_result sb) with
             | Ok () -> Ok sb
             | Error _ as e ->
               rollback_sub_board_create store sb;
               e)
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
        let members_result =
          match members with
          | None -> Ok sb.members
          | Some raw -> parse_sub_board_members ~owner:sb.owner raw
        in
        (match members_result with
         | Error _ as e -> e
         | Ok members ->
           let updated =
             { sb with
               name = Option.value ~default:sb.name (Option.map String.trim name)
             ; description =
                 Option.value ~default:sb.description (Option.map String.trim description)
             ; members
             ; access = Option.value ~default:sb.access access
             }
           in
           Hashtbl.replace store.sub_boards (Sub_board_id.to_string sb.id) updated;
           Ok (sb, updated)))
  in
  match result with
  | Error _ as e -> e
  | Ok (previous, updated) ->
    (match rewrite_sub_boards store with
     | Ok () -> Ok updated
     | Error _ as e ->
       restore_sub_board store previous;
       e)
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

type delete_sub_board_snapshot =
  { sub_board_id : string
  ; sub_board_slug : string
  ; sub_board : sub_board
  ; affected_posts : post list
  ; sub_board_content : string
  }

let restore_deleted_sub_board store snapshot =
  with_lock store (fun () ->
    Hashtbl.replace store.sub_boards snapshot.sub_board_id snapshot.sub_board;
    Hashtbl.replace store.sub_boards_by_slug snapshot.sub_board_slug snapshot.sub_board_id;
    List.iter
      (fun (post : post) ->
         Hashtbl.replace store.posts (Post_id.to_string post.id) post)
      snapshot.affected_posts;
    invalidate_post_caches store)
;;

let delete_sub_board store ~sub_board_id : (unit, board_error) Result.t =
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
      let sub_board = Hashtbl.find store.sub_boards id in
      let affected_posts = ref [] in
      Hashtbl.remove store.sub_boards id;
      Hashtbl.remove store.sub_boards_by_slug slug;
      (* Orphan policy: clear hearth on posts that belonged to this sub-board *)
      Hashtbl.iter
        (fun _ (post : post) ->
           match post.hearth with
           | Some h when String.equal h slug ->
             affected_posts := post :: !affected_posts;
             let updated = { post with hearth = None } in
             Hashtbl.replace store.posts (Post_id.to_string post.id) updated;
             store.dirty_posts <- true;
             Hashtbl.replace store.dirty_post_ids (Post_id.to_string post.id) ()
           | _ -> ())
        store.posts;
      invalidate_post_caches store;
      let content = sub_boards_jsonl_unlocked store in
      Ok
        { sub_board_id = id
        ; sub_board_slug = slug
        ; sub_board
        ; affected_posts = !affected_posts
        ; sub_board_content = content
        })
  in
  match snapshot with
  | Error _ as e -> e
  | Ok snapshot ->
    (match
       with_persist_lock store (fun () ->
         save_sub_boards_jsonl_result snapshot.sub_board_content)
     with
     | Ok () -> Ok ()
     | Error _ as e ->
       restore_deleted_sub_board store snapshot;
       e)
;;

(** {1 Voting - Deduplicated} *)
