include Board_core

let vote_direction_to_string = function Up -> "up" | Down -> "down"

(* Variant witness used to derive the schema enum from the canonical encoder. *)
let all_vote_directions = [ Up; Down ]
let valid_vote_direction_strings =
  List.map vote_direction_to_string all_vote_directions

(* Sound partial parser — case-insensitive, trims whitespace, and
   rejects empty input. Missing direction defaults belong at the tool
   boundary, not in the wire-value parser. *)
let vote_direction_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "up" -> Some Up
  | "down" -> Some Down
  | _ -> None

let vote_log_path () =
  Filename.concat (Board_paths.board_masc_dir ()) "board_votes.jsonl"

(* Append and snapshot writers persist the cast timestamp stored for the exact
   [(target, voter)] vote identity. Returns [Error (Io_error _)] instead of
   swallowing the write failure, so a disk-full or permission error propagates
   to the caller instead of leaving the in-memory vote as the only copy. *)
let append_vote_log ~target ~voter ~direction ~ts : (unit, board_error) Result.t =
  try
    ensure_masc_dir ();
    let path = vote_log_path () in
    let json = `Assoc [
      ("target", `String target);
      ("voter", `String voter);
      ("direction", `String (vote_direction_to_string direction));
      ("ts", `Float ts);
    ] in
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n");
    Ok ()
  with Sys_error msg ->
    record_persist_error ~where:"append_vote_log" msg;
    Error (Io_error (Printf.sprintf "append_vote_log: %s" msg))

let vote_log_jsonl store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun target (direction, ts) ->
      let voter =
        match Board_vote_key.of_string target with
        | Some vote -> Board_vote_key.voter vote |> Agent_id.to_string
        | None -> invalid_arg (Printf.sprintf "invalid in-memory vote key: %S" target)
      in
      let json =
        `Assoc
          [
            ("target", `String target);
            ("voter", `String voter);
            ("direction", `String (vote_direction_to_string direction));
            (* Snapshot rewrites preserve the cast timestamp. *)
            ("ts", `Float ts);
          ]
      in
      Buffer.add_string buf (Yojson.Safe.to_string json);
      Buffer.add_char buf '\n')
    store.vote_log;
  Buffer.contents buf

(* Full snapshot rewrite of the vote log, used by [flush_dirty] (compaction)
   and [delete_post] (removing a target's votes). Returns
   [Error (Io_error _)] instead of only logging, on the same contract as
   [append_vote_log] — the previous unit-returning version logged via
   [Log.BoardLog.error] directly, which meant this write's failures never
   incremented [persist_errors], unlike every other persist path in this
   file. *)
let save_vote_log_jsonl content : (unit, board_error) Result.t =
  try
    ensure_masc_dir ();
    let path = vote_log_path () in
    match Fs_compat.save_file_atomic path content with
    | Ok () -> Ok ()
    | Error msg ->
      record_persist_error ~where:"save_vote_log_jsonl" msg;
      Error (Io_error (Printf.sprintf "save_vote_log_jsonl: %s" msg))
  with Sys_error msg ->
    record_persist_error ~where:"save_vote_log_jsonl" msg;
    Error (Io_error (Printf.sprintf "save_vote_log_jsonl: %s" msg))

let persisted_vote_direction_of_string_opt = function
  | "up" -> Some Up
  | "down" -> Some Down
  | _ -> None

let persisted_vote_row_of_yojson = function
  | `Assoc fields ->
    let has_exact_fields =
      let allowed = [ "target"; "voter"; "direction"; "ts" ] in
      let rec loop seen = function
        | [] -> true
        | (name, _) :: rest ->
          if List.mem name seen || not (List.mem name allowed)
          then false
          else loop (name :: seen) rest
      in
      loop [] fields
    in
    if not has_exact_fields
    then None
    else
      (match
         ( List.assoc_opt "target" fields
         , List.assoc_opt "voter" fields
         , List.assoc_opt "direction" fields
         , List.assoc_opt "ts" fields )
       with
       | ( Some (`String target)
         , Some (`String voter)
         , Some (`String direction_raw)
         , Some (`Float ts) )
         when Float.is_finite ts && Float.compare ts 0.0 > 0 ->
         (match
            Board_vote_key.of_string target,
            persisted_vote_direction_of_string_opt direction_raw
          with
          | Some vote, Some direction
            when String.equal voter (Agent_id.to_string (Board_vote_key.voter vote)) ->
            Some (vote, direction, ts)
          | Some _, Some _ | Some _, None | None, _ -> None)
       | _ -> None)
  | _ -> None

(* Durable append for one cast vote, outside [store.mutex] (it takes
   [store.persist_mutex] itself via [with_persist_lock]). Write-ahead design
   (PR #28934 review): this is called from [vote]/[vote_comment] {b before}
   any [store.posts]/[store.comments]/[store.vote_log] mutation, specifically
   so a racing [flush_dirty] can never snapshot-write a vote that turns out
   to have failed its durable append — mutating first and appending second
   (the original shape here, and still [add_comment_with_audience]'s shape
   for comments — a known, separately-tracked class of the same race) leaves
   a window where [flush_dirty] can pick up the not-yet-durable mutation
   before the append either confirms or rolls it back. *)
let record_vote_side_effect store ~target ~voter ~direction ~ts
    : (unit, board_error) Result.t =
  with_persist_lock store (fun () -> append_vote_log ~target ~voter ~direction ~ts)

let current_vote_for_post store ~voter ~post_id
    : (vote_direction option, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        let post_key = Post_id.to_string pid in
        if not (Hashtbl.mem store.posts post_key) then Error (Post_not_found post_id)
        else
          let vote_key =
            Board_vote_key.post ~post_id:pid ~voter:agent |> Board_vote_key.to_string
          in
          Ok (Option.map fst (Hashtbl.find_opt store.vote_log vote_key)))

(* Write-ahead: validate under [with_lock] with no mutation, durably append
   outside any lock, then commit under [with_lock] re-deciding the branch
   from a fresh read (not the stale staged one) so a concurrent unrelated
   post mutation is not clobbered and a same-key race is caught rather than
   silently overwritten. If step 1 rejects or step 2's append fails, nothing
   was ever mutated, so there is nothing to roll back. *)
let vote store ~voter ~post_id ~direction : (int, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  let voter = Agent_id.to_string agent in
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      let post_key = Post_id.to_string pid in
      let vote_key =
        Board_vote_key.post ~post_id:pid ~voter:agent |> Board_vote_key.to_string
      in
      let staged : (float, board_error) Result.t =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.posts post_key with
          | None -> Error (Post_not_found post_id)
          | Some _post ->
              match Hashtbl.find_opt store.vote_log vote_key with
              | Some (prev, _prev_ts) when (=) prev direction ->
                  Error (Already_voted (Printf.sprintf "%s already voted %s on %s"
                    voter (vote_direction_to_string direction) post_id))
              | Some _ | None -> Ok (Time_compat.now ()))
      in
      (match staged with
       | Error _ as e -> e
       | Ok ts ->
         (match record_vote_side_effect store ~target:vote_key ~voter ~direction ~ts with
          | Error _ as e -> e
          | Ok () ->
              with_lock store (fun () ->
                match Hashtbl.find_opt store.posts post_key with
                | None -> Error (Post_not_found post_id)
                | Some post ->
                  match Hashtbl.find_opt store.vote_log vote_key with
                  | Some (prev, _) when (=) prev direction ->
                      (* Another call for this exact voter+target committed
                         first while our append was in flight. Our append is
                         now an orphan row on disk; the winner's own
                         [mark_dirty_post] schedules a [flush_dirty] snapshot
                         rewrite that overwrites it with the committed truth
                         before a restart would ever replay it. *)
                      Error (Already_voted (Printf.sprintf "%s already voted %s on %s"
                        voter (vote_direction_to_string direction) post_id))
                  | Some (_opposite, _prev_ts) ->
                      let flipped = match direction with
                        | Up -> { post with votes_up = post.votes_up + 1;
                                            votes_down = max 0 (post.votes_down - 1);
                                            updated_at = ts }
                        | Down -> { post with votes_down = post.votes_down + 1;
                                              votes_up = max 0 (post.votes_up - 1);
                                              updated_at = ts }
                      in
                      Hashtbl.replace store.posts post_key flipped;
                      Hashtbl.replace store.vote_log vote_key (direction, ts);
                      mark_dirty_post store post_key;
                      invalidate_post_caches store;
                      Ok (flipped.votes_up - flipped.votes_down)
                  | None ->
                      let updated = match direction with
                        | Up -> { post with votes_up = post.votes_up + 1; updated_at = ts }
                        | Down -> { post with votes_down = post.votes_down + 1; updated_at = ts }
                      in
                      Hashtbl.replace store.posts post_key updated;
                      Hashtbl.replace store.vote_log vote_key (direction, ts);
                      mark_dirty_post store post_key;
                      invalidate_post_caches store;
                      Ok (updated.votes_up - updated.votes_down))))

let current_vote_for_comment store ~voter ~comment_id
    : (vote_direction option, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
      with_lock store (fun () ->
        let comment_key = Comment_id.to_string cid in
        if not (Hashtbl.mem store.comments comment_key) then
          Error (Comment_not_found comment_id)
        else
          let vote_key =
            Board_vote_key.comment ~comment_id:cid ~voter:agent
            |> Board_vote_key.to_string
          in
          Ok (Option.map fst (Hashtbl.find_opt store.vote_log vote_key)))

(** Vote on a comment. Same write-ahead shape as {!vote}. *)
let vote_comment store ~voter ~comment_id ~direction : (int, board_error) Result.t =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok agent ->
  let voter = Agent_id.to_string agent in
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
      let comment_key = Comment_id.to_string cid in
      let vote_key =
        Board_vote_key.comment ~comment_id:cid ~voter:agent |> Board_vote_key.to_string
      in
      let staged : (float, board_error) Result.t =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.comments comment_key with
          | None -> Error (Comment_not_found comment_id)
          | Some _cmt ->
              match Hashtbl.find_opt store.vote_log vote_key with
              | Some (prev, _prev_ts) when (=) prev direction ->
                  Error (Already_voted (Printf.sprintf "%s already voted %s on comment %s"
                    voter (vote_direction_to_string direction) comment_id))
              | Some _ | None -> Ok (Time_compat.now ()))
      in
      (match staged with
       | Error _ as e -> e
       | Ok ts ->
         (match record_vote_side_effect store ~target:vote_key ~voter ~direction ~ts with
          | Error _ as e -> e
          | Ok () ->
              with_lock store (fun () ->
                match Hashtbl.find_opt store.comments comment_key with
                | None -> Error (Comment_not_found comment_id)
                | Some cmt ->
                  match Hashtbl.find_opt store.vote_log vote_key with
                  | Some (prev, _) when (=) prev direction ->
                      Error (Already_voted (Printf.sprintf "%s already voted %s on comment %s"
                        voter (vote_direction_to_string direction) comment_id))
                  | Some (_opposite, _prev_ts) ->
                      let flipped = match direction with
                        | Up -> { cmt with votes_up = cmt.votes_up + 1;
                                           votes_down = max 0 (cmt.votes_down - 1) }
                        | Down -> { cmt with votes_down = cmt.votes_down + 1;
                                             votes_up = max 0 (cmt.votes_up - 1) }
                      in
                      Hashtbl.replace store.comments comment_key flipped;
                      Hashtbl.replace store.vote_log vote_key (direction, ts);
                      mark_dirty_comment store comment_key;
                      invalidate_comment_caches store;
                      Ok (flipped.votes_up - flipped.votes_down)
                  | None ->
                      let updated = match direction with
                        | Up -> { cmt with votes_up = cmt.votes_up + 1 }
                        | Down -> { cmt with votes_down = cmt.votes_down + 1 }
                      in
                      Hashtbl.replace store.comments comment_key updated;
                      Hashtbl.replace store.vote_log vote_key (direction, ts);
                      mark_dirty_comment store comment_key;
                      invalidate_comment_caches store;
                      Ok (updated.votes_up - updated.votes_down))))

(** {1 Stats} *)

let stats store =
  with_lock store (fun () ->
    let post_count = Hashtbl.length store.posts in
    let comment_count = Hashtbl.length store.comments in
    let now = Time_compat.now () in
    let expired_posts = Hashtbl.fold (fun _ (p : post) acc ->
      if Stdlib.Float.compare p.expires_at 0.0 > 0 && Stdlib.Float.compare p.expires_at now < 0 then acc + 1 else acc
    ) store.posts 0 in
    `Assoc [
      ("post_count", `Int post_count);
      ("comment_count", `Int comment_count);
      ("expired_pending", `Int expired_posts);
      ("last_sweep", `Float store.last_sweep);
      ("backend", `String "jsonl");
    ]
  )

let visibility_of_string = Board_votes_json.visibility_of_string
let post_of_yojson = Board_votes_json.post_of_yojson
let comment_of_yojson = Board_votes_json.comment_of_yojson
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

let vote_target_exists store vote =
  let target_id = Board_vote_key.target_id vote in
  match Board_vote_key.target_kind vote with
  | Board_vote_key.Post -> Hashtbl.mem store.posts target_id
  | Board_vote_key.Comment -> Hashtbl.mem store.comments target_id
;;

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
  invalidate_post_caches store;
  invalidate_comment_caches store
;;

let load_persisted_votes store =
  let path = vote_log_path () in
  if not (Fs_compat.file_exists path)
  then (
    recalculate_vote_counts store;
    Ok 0)
  else begin
    try
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter
        (fun json ->
           match persisted_vote_row_of_yojson json with
           | None -> ()
           | Some (vote, direction, ts) when vote_target_exists store vote ->
             Hashtbl.replace
               store.vote_log
               (Board_vote_key.to_string vote)
               (direction, ts);
             Stdlib.incr loaded
           | Some _ -> ())
        lines;
      recalculate_vote_counts store;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d vote entries from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 vote entries from %s" path;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  end

let load_persisted_reactions store =
  let path = reactions_path () in
  if not (Fs_compat.file_exists path) then Ok 0
  else begin
    try
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter
        (fun json ->
           match reaction_of_yojson json with
           | Some reaction ->
               let user_id = Agent_id.to_string reaction.user_id in
               let key =
                 reaction_key ~target_type:reaction.target_type
                   ~target_id:reaction.target_id ~user_id
                   ~emoji:reaction.emoji
               in
               Hashtbl.replace store.reactions key reaction;
               Stdlib.incr loaded
           | None -> ())
        lines;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d reactions from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 reactions from %s" path;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  end

let load_persisted_sub_boards store =
  let path = sub_boards_path () in
  if not (Fs_compat.file_exists path) then Ok 0
  else begin
    try
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter
        (fun json ->
           match sub_board_of_yojson json with
           | Some sb ->
               let id = Sub_board_id.to_string sb.id in
               Hashtbl.replace store.sub_boards id sb;
               Hashtbl.replace store.sub_boards_by_slug sb.slug id;
               Stdlib.incr loaded
           | None -> ())
        lines;
      if !loaded > 0 then
        Log.BoardLog.info "loaded %d sub-boards from %s" !loaded path
      else
        Log.BoardLog.debug "loaded 0 sub-boards from %s" path;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  end

(** {1 Hearth (topic) operations} *)

(** List active hearths with post counts for the requested post-kind axis. *)
let list_hearths store ?(exclude_system = false) ?(exclude_automation = false) ()
    : (string * int) list =
  with_lock store (fun () ->
    let counts = Hashtbl.create 16 in
    Hashtbl.iter (fun _ (p : post) ->
      if Board_core_classify.post_matches_filters
           ~exclude_system ~exclude_automation p
      then
        match p.hearth with
        | Some h ->
            let c = Hashtbl.find_opt counts h |> Option.value ~default:0 in
            Hashtbl.replace counts h (c + 1)
        | None -> ()
    ) store.posts;
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) counts []
    |> List.sort (fun (_, a) (_, b) -> compare b a)
  )

(** Update a post's thread_id (for linking Board post → Conversation thread) *)
let set_thread_id store ~post_id ~thread_id : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      with_lock store (fun () ->
        match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
        | None -> Error (Post_not_found post_id)
        | Some post ->
            let updated = { post with thread_id = Some thread_id } in
            Hashtbl.replace store.posts (Post_id.to_string pid) updated;
            Ok ()
      )

(** Set a post's [pinned] flag (operator-curated pin, owner-gated at the HTTP
    boundary). Persists immediately via [append_post] (like [create_post])
    rather than only marking dirty for the flusher: pinning is a low-frequency
    operator action that must survive a restart in the flush window, unlike
    [vote] (high-frequency, flusher-batched) or [set_thread_id] (in-memory). *)
let set_pinned store ~post_id ~pinned : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      let result =
        with_lock store (fun () ->
          match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
          | None -> Error (Post_not_found post_id)
          | Some post ->
              let now = Time_compat.now () in
              let updated = { post with pinned; updated_at = now } in
              Hashtbl.replace store.posts (Post_id.to_string pid) updated;
              invalidate_post_caches store;
              Ok (post, updated))
      in
      match result with
      | Error e -> Error e
      | Ok (previous, updated) ->
          (match with_persist_lock store (fun () -> append_post updated) with
           | Ok () -> Ok ()
           | Error e ->
               with_lock store (fun () ->
                 let key = Post_id.to_string previous.id in
                 (match Hashtbl.find_opt store.posts key with
                  | Some current
                    when current.pinned = updated.pinned
                         && Stdlib.Float.equal current.updated_at updated.updated_at ->
                    Hashtbl.replace store.posts key previous;
                    invalidate_post_caches store
                  | _ -> ()));
               Error e)

let posts_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter (fun _ (pst : post) ->
    Buffer.add_string buf (Yojson.Safe.to_string (post_to_yojson pst));
    Buffer.add_char buf '\n'
  ) store.posts;
  Buffer.contents buf

let comments_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter (fun _ (cmt : comment) ->
    Buffer.add_string buf (Yojson.Safe.to_string (comment_to_yojson cmt));
    Buffer.add_char buf '\n'
  ) store.comments;
  Buffer.contents buf

let reactions_jsonl_snapshot store =
  let buf = Buffer.create 4096 in
  Hashtbl.iter
    (fun _ (reaction : reaction) ->
       Buffer.add_string buf (Yojson.Safe.to_string (reaction_to_yojson reaction));
       Buffer.add_char buf '\n')
    store.reactions;
  Buffer.contents buf

let save_jsonl_snapshot_result ~where ~path content =
  try
    ensure_masc_dir ();
    match Fs_compat.save_file_atomic path content with
    | Ok () -> Ok ()
    | Error msg ->
      record_persist_error ~where msg;
      Error msg
  with Sys_error msg ->
    record_persist_error ~where msg;
    Error msg
;;

let save_jsonl_snapshot ~where ~path content =
  ignore (save_jsonl_snapshot_result ~where ~path content)

(* Re-mark everything dirty after a failed snapshot write, so the next flush
   rewrites the file instead of skipping an empty queue — the missing half of
   a log-and-continue failure (#26168). Callers hold the store lock. *)
let remark_all_posts_dirty store =
  store.dirty_posts <- true;
  Hashtbl.iter (fun key _ -> Hashtbl.replace store.dirty_post_ids key ()) store.posts
;;

let remark_all_comments_dirty store =
  store.dirty_comments <- true;
  Hashtbl.iter
    (fun key _ -> Hashtbl.replace store.dirty_comment_ids key ())
    store.comments
;;

let delete_post store ~post_id : (unit, board_error) Result.t =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    let snapshot =
      with_lock store (fun () ->
      let post_key = Post_id.to_string pid in
      match Hashtbl.find_opt store.posts post_key with
      | None -> Error (Post_not_found post_id)
      | Some _ ->
        let comment_ids =
          Hashtbl.fold
            (fun key (c : comment) acc ->
               if String.equal (Post_id.to_string c.post_id) post_key then key :: acc else acc)
            store.comments
            []
        in
        Hashtbl.remove store.posts post_key;
        Hashtbl.remove store.comments_by_post post_key;
        List.iter (fun comment_key -> Hashtbl.remove store.comments comment_key) comment_ids;
        let vote_keys =
          Hashtbl.fold
            (fun key _ acc ->
               match Board_vote_key.of_string key with
               | Some vote ->
                 let target_id = Board_vote_key.target_id vote in
                 (match Board_vote_key.target_kind vote with
                  | Board_vote_key.Post when String.equal target_id post_key ->
                    key :: acc
                  | Board_vote_key.Comment
                    when List.exists (String.equal target_id) comment_ids ->
                    key :: acc
                  | Board_vote_key.Post | Board_vote_key.Comment -> acc)
               | None -> acc)
            store.vote_log
            []
        in
        let reaction_keys =
          Hashtbl.fold
            (fun key (reaction : reaction) acc ->
               if
                 ((=) reaction.target_type Reaction_post
                  && String.equal reaction.target_id post_key)
                 || ((=) reaction.target_type Reaction_comment
                     && List.exists (String.equal reaction.target_id) comment_ids)
               then key :: acc
               else acc)
            store.reactions
            []
        in
        List.iter (fun key -> Hashtbl.remove store.vote_log key) vote_keys;
        List.iter (fun key -> Hashtbl.remove store.reactions key) reaction_keys;
        store.post_count := max 0 (!(store.post_count) - 1);
        invalidate_post_caches store;
        invalidate_comment_caches store;
        store.dirty_posts <- false;
        store.dirty_comments <- false;
        Hashtbl.clear store.dirty_post_ids;
        Hashtbl.clear store.dirty_comment_ids;
        store.last_flush <- Time_compat.now ();
        let posts_jsonl = posts_jsonl_snapshot store in
        let comments_jsonl = comments_jsonl_snapshot store in
        let votes_jsonl = vote_log_jsonl store in
        let reactions_jsonl = reactions_jsonl_snapshot store in
        Ok (posts_jsonl, comments_jsonl, votes_jsonl, reactions_jsonl))
    in
    (match snapshot with
     | Error _ as e -> e
     | Ok (posts_jsonl, comments_jsonl, votes_jsonl, reactions_jsonl) ->
       with_persist_lock store (fun () ->
         (* The in-memory deletion above is the authoritative step, but it
            also cleared the dirty flags inside the snapshot lock. Without
            re-marking, a failed rewrite here left nothing scheduled to
            repeat it — the deleted post resurfaced from disk on restart,
            the same shape #26168 fixed for [flush_dirty]. *)
         (match
            save_jsonl_snapshot_result ~where:"rewrite_posts" ~path:(persist_path ())
              posts_jsonl
          with
          | Ok () -> ()
          | Error _ -> with_lock store (fun () -> remark_all_posts_dirty store));
         (match
            save_jsonl_snapshot_result ~where:"rewrite_comments"
              ~path:(comments_path ())
              comments_jsonl
          with
          | Ok () -> ()
          | Error _ -> with_lock store (fun () -> remark_all_comments_dirty store));
         (* The vote log rides the posts dirty cycle, same as in [flush_dirty]. *)
         (match save_vote_log_jsonl votes_jsonl with
          | Ok () -> ()
          | Error _ -> with_lock store (fun () -> remark_all_posts_dirty store));
         (* Reactions have no dirty cycle of their own — [toggle_reaction]
            owns their durable path with a write-ahead snapshot. A failed
            rewrite here is logged + counted by [save_jsonl_snapshot_result]
            and leaves orphaned reaction rows on disk; re-queueing them needs
            a dirty home that does not exist yet. *)
         save_jsonl_snapshot ~where:"rewrite_reactions" ~path:(reactions_path ())
           reactions_jsonl);
       Ok ())

(** {1 Global Store}

    Uses [Eio.Lazy] for fiber-safe initialization.
    [cancel:`Protect] ensures store creation completes even if the
    forcing fiber is cancelled. *)

(* Loaders return [(int, string * exn) result] so the caller is forced to
   acknowledge persistence-load failures.  Best-effort semantics live here
   at the call site, not hidden inside the loader bodies. *)
let log_persistence_result ~kind = function
  | Ok _ -> ()
  | Error (path, e) ->
    Log.BoardLog.error
      "load %s failed: path=%s reason=%s (continuing with best-effort partial state)"
      kind path (Printexc.to_string e)

let load_all_persisted store =
  log_persistence_result ~kind:"posts" (load_persisted_posts store);
  log_persistence_result ~kind:"comments" (load_persisted_comments store);
  recalculate_reply_counts store;
  log_persistence_result ~kind:"votes" (load_persisted_votes store);
  log_persistence_result ~kind:"reactions" (load_persisted_reactions store);
  log_persistence_result ~kind:"sub-boards" (load_persisted_sub_boards store)

let global_lazy : store Eio.Lazy.t ref =
  ref (Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let store = create_store () in
    load_all_persisted store;
    store))

let global () = Eio.Lazy.force !global_lazy

(** Reset global store for test isolation. Next [global ()] call creates fresh store.
    Safe: only called from test setup before concurrent fibers exist. *)
let reset_global_for_test () =
  global_lazy := Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let store = create_store () in
    load_all_persisted store;
    store)

(** Flush any dirty state to disk. Call on shutdown to prevent data loss.

    RFC-0091 (board persistence path unification): mutation/vote flushes
    write a full snapshot via [save_jsonl_snapshot] instead of replaying
    the dirty list through [append_post]/[append_comment]. The previous
    [List.iter append_post posts] grew [board_posts.jsonl] by one line per
    vote/mutation per post, sharing the same .id, producing the dup vector
    that motivated the RFC. The snapshot path was already canonical for
    restart-load ([load_persisted_posts]), so promoting it to the
    flush-write path makes [board_posts.jsonl] a true snapshot file with
    one line per id and atomic rewrite semantics. *)
let flush_dirty store =
  let posts_jsonl, comments_jsonl, vote_log =
    with_lock store (fun () ->
      let had_dirty = store.dirty_posts || store.dirty_comments in
      let posts_jsonl = if had_dirty then Some (posts_jsonl_snapshot store) else None in
      let comments_jsonl =
        if had_dirty then Some (comments_jsonl_snapshot store) else None
      in
      let vote_log = if had_dirty then Some (vote_log_jsonl store) else None in
      Hashtbl.clear store.dirty_post_ids;
      Hashtbl.clear store.dirty_comment_ids;
      store.dirty_posts <- false;
      store.dirty_comments <- false;
      store.last_flush <- Time_compat.now ();
      (posts_jsonl, comments_jsonl, vote_log))
  in
  (* The dirty flags were cleared above, before the write. A failed write used
     to end there: the snapshot never reached disk and the change was no
     longer scheduled for any later flush, so an in-memory post carried an
     [updated_at] the file did not have until the next unrelated edit marked
     it dirty again -- or forever, if none came (#26168). Re-marking on
     failure puts the change back in the queue; the counter and the log line
     stay, they just are not the whole response. *)
  let remark_posts () = with_lock store (fun () -> remark_all_posts_dirty store) in
  let remark_comments () =
    with_lock store (fun () -> remark_all_comments_dirty store)
  in
  with_persist_lock store (fun () ->
    Option.iter
      (fun content ->
         match
           save_jsonl_snapshot_result ~where:"flush_posts" ~path:(persist_path ()) content
         with
         | Ok () -> ()
         | Error _ -> remark_posts ())
      posts_jsonl;
    Option.iter
      (fun content ->
         match
           save_jsonl_snapshot_result ~where:"flush_comments" ~path:(comments_path ()) content
         with
         | Ok () -> ()
         | Error _ -> remark_comments ())
      comments_jsonl;
    (* A vote marks its post dirty, so the vote log rides the same dirty cycle
       as the posts snapshot and recovers the same way: re-marking puts the
       write back in the queue for the next flush. Dropping the failure here
       left the log missing the votes of this cycle with nothing scheduled to
       write them, which is the shape the two writers above already fixed
       (#26168). The counter and log line inside [save_vote_log_jsonl] stay. *)
    Option.iter
      (fun content ->
         match save_vote_log_jsonl content with
         | Ok () -> ()
         | Error _ -> remark_posts ())
      vote_log)


(** {1 Karma & Flair - Reddit-style} *)

(** Scoring contract: returns the karma delta for a vote direction.
    Upvotes earn +1 karma; downvotes do not deduct karma (delta = 0).
    Callers that want to replay or rebuild the ledger must use this
    function as the single source of truth for karma scoring. *)
let karma_score_for_direction = function
  | Up -> 1
  | Down -> 0

let karma_event_of_vote store key (direction, ts) =
  let delta = karma_score_for_direction direction in
  if delta = 0 then None
  else
    match Board_vote_key.of_string key with
    | None -> None
    | Some vote ->
        let target_id = Board_vote_key.target_id vote in
        let voter = Board_vote_key.voter vote |> Agent_id.to_string in
        let kind, recipient_opt =
          match Board_vote_key.target_kind vote with
          | Board_vote_key.Post ->
            ( "post"
            , match Hashtbl.find_opt store.posts target_id with
              | Some (p : post) -> Some (Agent_id.to_string p.author)
              | None -> None )
          | Board_vote_key.Comment ->
            ( "comment"
            , match Hashtbl.find_opt store.comments target_id with
              | Some (c : comment) -> Some (Agent_id.to_string c.author)
              | None -> None )
        in
        match recipient_opt with
        | None -> None
        | Some recipient when String.equal recipient voter ->
            (* Content score still records the vote, but karma is
               peer recognition; self-upvotes do not mint reputation. *)
            None
        | Some recipient ->
            Some { recipient; voter; target_kind = kind; target_id; delta; ts }

(** Rebuild the karma ledger from the in-memory vote log and
    post/comment author tables.

    Contract:
    - Only [Up] votes generate karma events (scoring rule via
      {!karma_score_for_direction}).
    - Events are sorted ascending by [ts] (oldest first) so callers
      can replay them in order.
    - Author lookup is done against the live in-memory store; entries
      whose post/comment has been deleted are silently dropped (the
      vote remains in the log but the content is gone).
    - The function holds the store lock for the duration of the read
      so the snapshot is consistent. *)
let build_karma_ledger store =
  with_lock store (fun () ->
    Hashtbl.fold
      (fun key (direction, ts) acc ->
         match karma_event_of_vote store key (direction, ts) with
         | None -> acc
         | Some event -> event :: acc)
      store.vote_log [])
  |> List.sort (fun a b -> Float.compare a.ts b.ts)

(** Aggregate karma totals from a ledger.

    Returns [(recipient, total_karma)] pairs sorted descending by
    total so the highest-karma agents appear first.  Suitable for
    populating the karma leaderboard without re-reading the store. *)
let totals_of_karma_ledger events =
  let tbl = Hashtbl.create 64 in
  List.iter (fun (e : karma_event) ->
    let prev = Hashtbl.find_opt tbl e.recipient |> Option.value ~default:0 in
    Hashtbl.replace tbl e.recipient (prev + e.delta)
  ) events;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (_, a) (_, b) -> Int.compare b a)

(** JSON serialiser for a single karma event.

    Wire format (stable):
    {v
      { "recipient": "<agent>",
        "voter":     "<agent>",
        "target_kind": "post" | "comment",
        "target_id": "<id>",
        "delta": 1,
        "ts": 1234567890.0,
        "ts_iso": "YYYY-MM-DDTHH:MM:SSZ" }
    v} *)
let karma_event_to_yojson (e : karma_event) : Yojson.Safe.t =
  let ts_iso = Masc_domain.iso8601_of_unix_seconds e.ts in
  `Assoc [
    ("recipient",   `String e.recipient);
    ("voter",       `String e.voter);
    ("target_kind", `String e.target_kind);
    ("target_id",   `String e.target_id);
    ("delta",       `Int    e.delta);
    ("ts",          `Float  e.ts);
    ("ts_iso",      `String ts_iso);
  ]

(** Get karma for all agents (cached).

    Cache check / rebuild / write are all performed inside one
    [with_lock] block — same pattern as [Board_core.list_posts] for
    [sorted_posts_cache].  Previously the read at [store.karma_cache]
    and the write to it lived outside [with_lock] while
    [Board_core.invalidate_*_caches] (callers always hold the lock)
    cleared the field under lock — so two fibers could both observe
    [None] and both rebuild, and an invalidation occurring between an
    unlocked read of a stale [Some _] and a downstream consumer was
    silently lost.  Hashtbl iteration / fold / List.sort are pure CPU
    with no fiber yields, so holding the Eio mutex during the rebuild
    is safe. *)
let get_all_karma store =
  with_lock store (fun () ->
    match store.karma_cache with
    | Some cached -> cached
    | None ->
        let tbl = Hashtbl.create 64 in
        Hashtbl.iter
          (fun key vote ->
             match karma_event_of_vote store key vote with
             | None -> ()
             | Some (e : karma_event) ->
                 let prev =
                   Hashtbl.find_opt tbl e.recipient
                   |> Option.value ~default:0
                 in
                 Hashtbl.replace tbl e.recipient (prev + e.delta))
          store.vote_log;
        let result =
          Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
          |> List.sort (fun (_, a) (_, b) -> Int.compare b a)
        in
        store.karma_cache <- Some result;
        result)

(** Calculate karma (total peer upvotes) for an agent *)
let get_agent_karma store ~agent_name =
  get_all_karma store
  |> List.assoc_opt agent_name
  |> Option.value ~default:0

(** Available flairs *)
let available_flairs = [
  ("insight", "💡", "Insight");
  ("question", "❓", "Question");
  ("discussion", "💬", "Discussion");
  ("announcement", "📢", "Announcement");
  ("bug", "🐛", "Bug Report");
  ("idea", "💭", "Idea");
  ("meta", "🔧", "Meta");
]

(* Flair tag pattern — pure literal, hoist out of per-post extraction. *)
let flair_tag_re = Re.Pcre.re {|\[flair:([a-z]+)\]|} |> Re.compile

(** Extract flair from content (format: [flair:name] at start) *)
let extract_flair content =
  match Re.exec_opt flair_tag_re content with
  | Some g ->
    let flair_name = Re.Group.get g 1 in
    (match List.find_opt (fun (name, _, _) -> String.equal name flair_name) available_flairs with
    | Some f -> Some f
    | None -> None)
  | None -> None

(** Get flair info as JSON *)
let flair_to_yojson (name, emoji, label) =
  `Assoc [("name", `String name); ("emoji", `String emoji); ("label", `String label)]

(** Enhanced post_to_yojson with karma *)
let post_to_yojson_with_karma (p : post) ~author_karma : Yojson.Safe.t =
  let flair = extract_flair p.body in
  let flair_json = match flair with Some f -> flair_to_yojson f | None -> `Null in
  `Assoc ([
    ("id", `String (Post_id.to_string p.id));
    ("author", `String (Agent_id.to_string p.author));
    ("author_karma", `Int author_karma);
    ("title", `String p.title);
    ("body", `String p.body);
    ("post_kind", `String (post_kind_to_string p.post_kind));
    ("flair", flair_json);
    ("visibility", `String (visibility_to_string p.visibility));
    ("created_at", `Float p.created_at);
    ("updated_at", `Float p.updated_at);
    ("expires_at", `Float p.expires_at);
    ("votes_up", `Int p.votes_up);
    ("votes_down", `Int p.votes_down);
    ("score", `Int (p.votes_up - p.votes_down));
    ("reply_count", `Int p.reply_count);
    ("pinned", `Bool p.pinned);
  ] @ (match p.hearth with Some h -> [("hearth", `String h)] | None -> [])
    @ (match p.thread_id with Some t -> [("thread_id", `String t)] | None -> [])
    (* RFC-0233 §7: the dashboard board serializer ([board_post_dashboard_json])
       funnels every board list/detail route through this function, so emitting
       [origin] here exposes the originating-turn provenance on every
       dashboard-facing post in one place (no per-route N-of-M). Same encoder as
       [post_to_yojson] so the wire shape is identical. *)
    @ (match p.origin with Some o -> [("origin", post_origin_to_yojson o)] | None -> [])
    @ (match post_classification_reason p with
       | Some reason -> [("classification_reason", `String reason)]
       | None -> [])
    @ (match p.meta_json with Some meta -> [("meta", meta)] | None -> []))
