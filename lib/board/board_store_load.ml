open Board_core

let load_persisted_posts = Board_votes_json.load_persisted_posts
let load_persisted_comments = Board_votes_json.load_persisted_comments

(** Recalculate reply_count for all posts based on actual comments, and
    restore each post's [updated_at] high-water mark from its comments'
    [created_at]. This ensures data consistency after loading from disk:
    the posts snapshot can predate comment WAL rows appended after the
    last flush, so both the count and the timestamp are re-derived. *)
let recalculate_reply_counts store =
  (* First, reset all reply_counts to 0 *)
  Hashtbl.iter (fun key (p : post) ->
    Hashtbl.replace store.posts key { p with reply_count = 0 }
  ) store.posts;
  (* Then, count actual comments per post *)
  Hashtbl.iter (fun _ (c : comment) ->
    let post_key = Post_id.to_string c.post_id in
    match Hashtbl.find_opt store.posts post_key with
    | Some p ->
        Hashtbl.replace store.posts post_key
          { p with
            reply_count = p.reply_count + 1
          ; updated_at = Stdlib.Float.max p.updated_at c.created_at }
    | None -> ()
  ) store.comments;
  let total = Hashtbl.fold (fun _ (p : post) acc -> acc + p.reply_count) store.posts 0 in
  Log.BoardLog.debug "recalculated reply_counts: %d total comments across posts" total

let recalculate_vote_counts store =
  Hashtbl.iter
    (fun key (post : post) ->
       Hashtbl.replace store.posts key { post with votes_up = 0; votes_down = 0 })
    store.posts;
  Hashtbl.iter
    (fun key (comment : comment) ->
       Hashtbl.replace store.comments key { comment with votes_up = 0; votes_down = 0 })
    store.comments;
  Hashtbl.iter
    (fun key (direction, ts) ->
       match Board_vote_key.of_string key with
       | None -> ()
       | Some vote ->
         let target_id = Board_vote_key.target_id vote in
         (match Board_vote_key.target_kind vote with
          | Board_vote_key.Post ->
            (match Hashtbl.find_opt store.posts target_id with
             | None -> ()
             | Some post ->
               let votes_up, votes_down =
                 match direction with
                 | Up -> post.votes_up + 1, post.votes_down
                 | Down -> post.votes_up, post.votes_down + 1
               in
               Hashtbl.replace
                 store.posts
                 target_id
                 { post
                   with
                   votes_up
                 ; votes_down
                 ; updated_at = Float.max post.updated_at ts
                 })
          | Board_vote_key.Comment ->
            (match Hashtbl.find_opt store.comments target_id with
             | None -> ()
             | Some comment ->
               let votes_up, votes_down =
                 match direction with
                 | Up -> comment.votes_up + 1, comment.votes_down
                 | Down -> comment.votes_up, comment.votes_down + 1
               in
               Hashtbl.replace
                 store.comments
                 target_id
                 { comment with votes_up; votes_down })))
    store.vote_log;
  rebuild_hot_post_index store;
  invalidate_post_caches store;
  invalidate_comment_caches store
;;

let load_persisted_votes store =
  let path = Board_paths.store_file_path store Board_paths.Votes in
  let workspace_check = Board_paths.check_workspace store in
  let result = match workspace_check with
    | Error rejection -> Error (path, Failure (Board_workspace_binding.rejection_to_string rejection))
    | Ok () ->
    if not (Fs_compat.file_exists path)
    then (
      recalculate_vote_counts store;
      Ok 0)
    else begin
      try
      let t0 = Time_compat.now () in
      let loaded = ref 0 in
      let parsed =
        Board_votes_json.load_source_rows
          path
          ~decode:Board_vote_row.of_yojson
          ~accept:(fun (vote, direction, ts) ->
            (* A vote is kept whether or not its post or comment is loaded.
               The snapshot writes [store.vote_log] back whole, so a vote
               skipped here is gone from disk at the next flush. On
               2026-09-19 the posts file had been renamed away, the board
               loaded no posts, and all 225 votes were skipped and then
               overwritten. Deleting a post already removes its votes
               ([delete_post]); a vote whose target is absent at load is not
               stale data but a sign the target failed to load, and
               [recalculate_vote_counts] leaves it out of every count. *)
            Hashtbl.replace
              store.vote_log
              (Board_vote_key.to_string vote)
              (direction, ts);
            Stdlib.incr loaded)
      in
      if Result.is_ok parsed then recalculate_vote_counts store;
      let elapsed = Time_compat.now () -. t0 in
      Board_votes_json.log_loaded ~noun:"vote entries" ~loaded:!loaded ~path ~elapsed parsed;
      Result.map (fun () -> !loaded) parsed
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (path, e)
    end
  in
  let result = Board_votes_json.record_load_result
    (fun result -> store.votes_load_result <- result) result in
  Board_votes_json.propagate_workspace_check workspace_check;
  result

let load_persisted_reactions store =
  let path = Board_paths.store_file_path store Board_paths.Reactions in
  let workspace_check = Board_paths.check_workspace store in
  let result = match workspace_check with
    | Error rejection -> Error (path, Failure (Board_workspace_binding.rejection_to_string rejection))
    | Ok () ->
    if not (Fs_compat.file_exists path) then Ok 0
    else begin
      try
      let t0 = Time_compat.now () in
      let loaded = ref 0 in
      let parsed =
        Board_votes_json.load_source_rows
          path
          ~decode:reaction_of_yojson
          ~accept:(fun reaction ->
            let user_id = Agent_id.to_string reaction.user_id in
            let key =
              reaction_key
                ~target_type:reaction.target_type
                ~target_id:reaction.target_id
                ~user_id
                ~emoji:reaction.emoji
            in
            Hashtbl.replace store.reactions key reaction;
            Stdlib.incr loaded)
      in
      let elapsed = Time_compat.now () -. t0 in
      Board_votes_json.log_loaded ~noun:"reactions" ~loaded:!loaded ~path ~elapsed parsed;
      Result.map (fun () -> !loaded) parsed
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (path, e)
    end
  in
  let result = Board_votes_json.record_load_result
    (fun result -> store.reactions_load_result <- result) result in
  Board_votes_json.propagate_workspace_check workspace_check;
  result
