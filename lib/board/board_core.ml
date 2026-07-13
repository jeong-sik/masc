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

let add_comment
      store
      ~post_id
      ~author
      ~content
      ?parent_id
      ?(ttl_hours = Limits.default_ttl_hours)
      ()
  : (comment, board_error) Result.t
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
          if ttl_hours < 0
          then Error (Validation_error "ttl_hours must be non-negative")
          else if String.length content = 0
          then Error (Validation_error "Content cannot be empty")
          else (
            let board_result =
              with_lock store (fun () ->
                (* Verify post exists *)
                match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
                | None -> Error (Post_not_found post_id)
                | Some post ->
                  match
                    validate_sub_board_post_policy_unlocked
                      store
                      ~author_id
                      ~hearth:post.hearth
                  with
                      | Error e -> Error e
                      | Ok () ->
                    let now = Time_compat.now () in
                    let comment =
                      { id = Comment_id.generate ()
                      ; post_id = pid
                      ; parent_id = parent_cid
                      ; author = author_id
                      ; content
                      ; created_at = now
                      ; expires_at =
                          (if ttl_hours = 0
                           then 0.0
                           else
                             now
                             +. (Stdlib.Float.of_int ttl_hours
                                 *. Masc_time_constants.hour))
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
                    Ok (comment, post, posts_jsonl_unlocked store))
            in
            match board_result with
            | Ok (comment, previous_post, posts_jsonl) ->
              (match
                 with_persist_lock store (fun () ->
                   match append_comment comment with
                   | Error _ as e -> e
                   | Ok () ->
                     save_posts_jsonl posts_jsonl;
                     Ok ())
               with
               | Ok () ->
                 with_lock store (fun () ->
                   mark_dirty_post store (Post_id.to_string comment.post_id);
                   mark_dirty_comment store (Comment_id.to_string comment.id));
                 Ok comment
               | Error e ->
                 rollback_fresh_comment store ~comment ~previous_post;
                 Error e)
            | Error _ as e -> e)))
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

let sub_board_to_yojson = Board_sub_board_json.sub_board_to_yojson
let dedupe_agent_ids = Board_sub_board_json.dedupe_agent_ids
let parse_sub_board_members = Board_sub_board_json.parse_sub_board_members
let parse_sub_board_members_lenient = Board_sub_board_json.parse_sub_board_members_lenient
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
      let content = sub_boards_jsonl_unlocked store in
      Ok content)
  in
  match snapshot with
  | Error _ as e -> e
  | Ok content ->
    with_persist_lock store (fun () -> save_sub_boards_jsonl content);
    Ok ()
;;

(** {1 Voting - Deduplicated} *)
