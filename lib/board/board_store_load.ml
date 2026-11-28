open Board_core

let load_persisted_posts = Board_votes_json.load_persisted_posts
let load_persisted_comments = Board_votes_json.load_persisted_comments

(** Recalculate reply_count for all posts based on actual comments, and
    restore each post's [updated_at] high-water mark from its comments'
    [created_at]. This ensures data consistency after loading from disk:
    the posts snapshot can predate comment WAL rows appended after the
    last flush, so both the count and the timestamp are re-derived. *)
let recalculate_reply_counts store =
  let stats = Hashtbl.create (max 16 (Hashtbl.length store.posts)) in
  Hashtbl.iter (fun _ (c : comment) ->
    let post_key = Post_id.to_string c.post_id in
    match Hashtbl.find_opt stats post_key with
    | None -> Hashtbl.add stats post_key (1, c.created_at)
    | Some (count, latest_ts) ->
      Hashtbl.replace stats post_key (count + 1, Stdlib.Float.max latest_ts c.created_at)
  ) store.comments;
  let changed = ref false in
  let total = ref 0 in
  Hashtbl.iter (fun key (p : post) ->
    let new_count, new_updated_at =
      match Hashtbl.find_opt stats key with
      | None -> 0, p.updated_at
      | Some (count, latest_ts) -> count, Stdlib.Float.max p.updated_at latest_ts
    in
    total := !total + new_count;
    if p.reply_count <> new_count || not (Stdlib.Float.equal p.updated_at new_updated_at) then begin
      changed := true;
      Hashtbl.replace store.posts key
        { p with reply_count = new_count; updated_at = new_updated_at }
    end
  ) store.posts;
  if !changed then rebuild_hot_post_index store;
  Log.BoardLog.debug "recalculated reply_counts: %d total comments across posts" !total

let recalculate_vote_counts store =
  let post_votes = Hashtbl.create 256 in
  let comment_votes = Hashtbl.create 256 in
  Hashtbl.iter
    (fun key (direction, ts) ->
       match Board_vote_key.of_string key with
       | None -> ()
       | Some vote ->
         let target_id = Board_vote_key.target_id vote in
         let du, dd = match direction with Up -> 1, 0 | Down -> 0, 1 in
         (match Board_vote_key.target_kind vote with
          | Board_vote_key.Post ->
            (match Hashtbl.find_opt post_votes target_id with
             | None -> Hashtbl.add post_votes target_id (du, dd, ts)
             | Some (u, d, max_ts) ->
               Hashtbl.replace post_votes target_id (u + du, d + dd, Stdlib.Float.max max_ts ts))
          | Board_vote_key.Comment ->
            (match Hashtbl.find_opt comment_votes target_id with
             | None -> Hashtbl.add comment_votes target_id (du, dd)
             | Some (u, d) ->
               Hashtbl.replace comment_votes target_id (u + du, d + dd))))
    store.vote_log;
  let posts_changed = ref false in
  Hashtbl.iter
    (fun key (post : post) ->
       let new_up, new_down, new_updated_at =
         match Hashtbl.find_opt post_votes key with
         | None -> 0, 0, post.updated_at
         | Some (u, d, max_ts) -> u, d, Stdlib.Float.max post.updated_at max_ts
       in
       if post.votes_up <> new_up
          || post.votes_down <> new_down
          || not (Stdlib.Float.equal post.updated_at new_updated_at)
       then begin
         posts_changed := true;
         Hashtbl.replace
           store.posts
           key
           { post with votes_up = new_up; votes_down = new_down; updated_at = new_updated_at }
       end)
    store.posts;
  Hashtbl.iter
    (fun key (comment : comment) ->
       let new_up, new_down =
         match Hashtbl.find_opt comment_votes key with
         | None -> 0, 0
         | Some (u, d) -> u, d
       in
       if comment.votes_up <> new_up || comment.votes_down <> new_down then
         Hashtbl.replace
           store.comments
           key
           { comment with votes_up = new_up; votes_down = new_down })
    store.comments;
  if !posts_changed then rebuild_hot_post_index store;
  invalidate_post_caches store;
  invalidate_comment_caches store
;;

let load_persisted_votes store =
  let module Source = Board_votes_source in
  with_persist_lock store (fun () ->
    let path = Board_paths.store_file_path store Board_paths.Votes in
    let open Result.Syntax in
    let* () = Board_core_persist.require_model_reload_allowed store ~path in
    let t0 = Time_compat.now () in
    let outcome = Source.read store in
    let install rows =
      List.iter (fun (vote, direction, ts) ->
        (* Target absence is not authority to discard an accepted vote. *)
        Hashtbl.replace store.vote_log (Board_vote_key.to_string vote) (direction, ts)) rows;
      store.karma_cache <- None in
    let outcome =
      try
        with_lock store (fun () ->
          match outcome with
          | Source.Complete { rows; _ } ->
            Hashtbl.clear store.vote_log;
            install rows;
            recalculate_vote_counts store
          | Source.Partial { rows; _ } -> install rows
          | Source.Unavailable _ -> ());
        Source.publish_read store outcome;
        outcome
      with exception_ ->
        Source.fail_read store outcome exception_ (Printexc.get_raw_backtrace ()) in
    let finish outcome =
      Source.finish_read outcome
      |> Result.map_error (fun error -> path, Failure (show_board_error error)) in
    try
      (* Preserve a reserved read/cleanup cause before invoking the logger. *)
      let result = finish outcome in
      let loaded = match outcome with
        | Source.Complete { rows; _ } | Source.Partial { rows; _ } -> List.length rows
        | Source.Unavailable _ -> 0 in
      Board_votes_json.log_loaded ~noun:"vote entries" ~loaded ~path
        ~elapsed:(Time_compat.now () -. t0) (Result.map (fun _ -> ()) result);
      result
    with
    | Board_posts_source.Reserved_settlement _ as carrier -> raise carrier
    | exception_ ->
      let outcome = Source.fail_read store outcome exception_ (Printexc.get_raw_backtrace ()) in
      finish outcome)

let load_persisted_reactions store =
  let module Source = Board_reactions_source in
  let path = Board_paths.store_file_path store Board_paths.Reactions in
  Board_core_persist.with_persist_lock store (fun () ->
    let open Result.Syntax in
    let* () = Board_core_persist.require_model_reload_allowed store ~path in
    let t0 = Time_compat.now () in
    let outcome = Source.read store in
    let add_rows rows = List.iter (fun (reaction : reaction) ->
      let key = reaction_key ~target_type:reaction.target_type
        ~target_id:reaction.target_id ~user_id:(Agent_id.to_string reaction.user_id)
        ~emoji:reaction.emoji in
      Hashtbl.replace store.reactions key reaction) rows in
    let outcome =
      try Board_core_persist.with_lock store (fun () ->
        (match outcome with
         | Source.Complete { rows; _ } -> Hashtbl.clear store.reactions; add_rows rows
         | Source.Partial { rows; _ } -> add_rows rows
         | Source.Unavailable _ -> ());
        Source.publish_read store outcome;
        outcome)
      with exception_ -> Source.fail_read store outcome exception_ (Printexc.get_raw_backtrace ()) in
    let finish outcome = Source.finish_read outcome
      |> Result.map_error (fun error -> path, Failure (show_board_error error)) in
    try
      let result = finish outcome in
      let loaded = match outcome with
        | Source.Complete { rows; _ } | Source.Partial { rows; _ } -> List.length rows
        | Source.Unavailable _ -> 0 in
      Board_votes_json.log_loaded ~noun:"reactions" ~loaded ~path
        ~elapsed:(Time_compat.now () -. t0) (Result.map (fun _ -> ()) result);
      result
    with
    | Board_posts_source.Reserved_settlement _ as carrier -> raise carrier
    | exception_ ->
      let outcome = Source.fail_read store outcome exception_ (Printexc.get_raw_backtrace ()) in
      finish outcome)

(* task-4036: a posts write refused by a stale observation (another writer
   moved the file) must not refuse every later write. Re-read
   the file once under persistence, install a complete read as the posts model
   with counts re-derived as at startup, and publish it as the new observation. *)
let reobserve_posts store =
  match store.posts_source with
  | Posts_unobserved | Posts_readable _ -> Ok ()
  | Posts_refused _ | Posts_unsettled _ ->
    with_persist_lock store (fun () ->
      let path = Board_paths.persist_path store in
      match Board_core_persist.require_model_reload_allowed store ~path with
      | Error (_, exn) -> Error (Io_error (Printexc.to_string exn))
      | Ok () ->
        match Board_posts_source.reobserve store with
        | Board_posts_source.Reobservation_not_due -> Ok ()
        | Board_posts_source.Unsettled_write_pending ->
          Error (Io_error (Printf.sprintf
            "posts source %s has an earlier write whose outcome is unknown, so Board \
             writes stay refused while listing keeps the loaded posts. Restart the \
             server to reload the Board from the file." path))
        | Board_posts_source.Reobserved outcome ->
          let outcome =
            try
              with_lock store (fun () ->
                (match outcome with
                 | Posts_complete { posts; _ } ->
                   Board_votes_json.replace_loaded_posts store posts;
                   recalculate_reply_counts store;
                   recalculate_vote_counts store
                 | Posts_partial _ | Posts_unavailable _ -> ());
                publish_posts_read store outcome);
              outcome
            with exception_ ->
              fst (Board_posts_source.fail_read store outcome ~stage:Project_posts
                exception_ (Printexc.get_raw_backtrace ())) in
          finish_posts_read outcome;
          require_posts_source_readable store)

(* #55449: the other four sources refuse on a stale observation as posts did
   and were read again only at startup. On 2026-11-24 every comment write was
   refused for 123 minutes, until the restart. Each is read again by the
   function that loads it at startup, and only when its refusal is one a fresh
   read can clear. The check runs before persistence is taken, so two calls
   that arrive together may each read once; either read is complete. *)
let reloaded result =
  result
  |> Result.map (fun (_ : int) -> ())
  |> Result.map_error (fun ((_ : string), exn) -> Io_error (Printexc.to_string exn))

let reobserve_comments store =
  if Board_comments_source.reobservation_due store
  then
    (* As at startup, and in the interval that replaces the comments: reply
       counts are held on posts, and the vote counts of the comments just
       loaded come from the vote ledger. *)
    reloaded
      (Board_votes_json.load_comments_deriving store ~derive:(fun () ->
         recalculate_reply_counts store;
         recalculate_vote_counts store))
  else Ok ()

let reobserve_votes store =
  if Board_votes_source.reobservation_due store
  then reloaded (load_persisted_votes store)
  else Ok ()

let reobserve_reactions store =
  if Board_reactions_source.reobservation_due store
  then reloaded (load_persisted_reactions store)
  else Ok ()

let reobserve_sub_boards store =
  if Board_sub_boards_source.reobservation_due store
  then reloaded (Board_core.reload_sub_boards store)
  else Ok ()

(* Startup order: comments re-derive counts held on posts, votes re-derive
   counts held on posts and comments. *)
let reobserve store =
  List.filter_map
    (fun (source, reobserve_source) ->
       match reobserve_source store with
       | Ok () -> None
       | Error error -> Some (source, error))
    [ Board_paths.Posts, reobserve_posts
    ; Board_paths.Comments, reobserve_comments
    ; Board_paths.Votes, reobserve_votes
    ; Board_paths.Reactions, reobserve_reactions
    ; Board_paths.Sub_boards, reobserve_sub_boards
    ]
