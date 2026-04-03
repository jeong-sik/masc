(** Board_pg_admin — Stats, search, karma, reclassification, sweep, and migration.

    Administrative and maintenance operations on the Board PostgreSQL backend.

    @since God file decomposition — extracted from board_pg.ml *)

open Board
open Pg_infix
open Board_pg_queries

open Result_syntax

(** {1 Stats} *)

let stats t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find stats_q ()
  ) t.pool with
  | Ok (post_count, comment_count, expired) ->
      `Assoc [
        ("post_count", `Int post_count);
        ("comment_count", `Int comment_count);
        ("expired_pending", `Int expired);
        ("backend", `String "postgresql");
      ]
  | Error err ->
      Log.BoardPg.error "stats error: %s" (Caqti_error.show err);
      `Assoc [("error", `String "Database operation failed")]

(** {1 Reclassification} *)

let reclassify_posts t ?(limit = 5200) ?(dry_run = true) () =
  let scan_limit = max 0 (min limit 5200) in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* total = C.find post_count_q () in
    let* rows =
      if scan_limit = 0 then
        Ok []
      else
        C.collect_list list_recent_q (None, None, None, scan_limit)
    in
    let posts = List.filter_map post_of_row rows in
    let changed = ref 0 in
    let unchanged = ref 0 in
    let apply_failures = ref 0 in
    let changed_post_ids = ref [] in
    let record_changed_id id =
      if List.length !changed_post_ids < 20 then
        changed_post_ids := id :: !changed_post_ids
    in
    List.iter (fun (post : post) ->
      let canonical_kind =
        legacy_migrate_post_kind
          ~author:(Agent_id.to_string post.author)
          ~meta_json:post.meta_json
          ~visibility:post.visibility
          ~expires_at:post.expires_at
          ~hearth:post.hearth
      in
      if canonical_kind = post.post_kind then
        incr unchanged
      else begin
        incr changed;
        let post_id = Post_id.to_string post.id in
        record_changed_id post_id;
        if not dry_run then
          match C.exec update_post_kind_q (post_id, post_kind_to_string canonical_kind) with
          | Ok () -> ()
          | Error err ->
              incr apply_failures;
              Log.BoardPg.error "reclassify post_kind failed for %s: %s"
                post_id (Caqti_error.show err)
      end) posts;
    Ok
      {
        backend = "postgresql";
        dry_run;
        scanned = List.length posts;
        changed = !changed;
        unchanged = !unchanged;
        skipped = max 0 (total - List.length posts);
        apply_failures = !apply_failures;
        changed_post_ids = List.rev !changed_post_ids;
      }
  ) t.pool with
  | Ok report -> report
  | Error err ->
      Log.BoardPg.error "reclassify_posts error: %s" (Caqti_error.show err);
      {
        backend = "postgresql";
        dry_run;
        scanned = 0;
        changed = 0;
        unchanged = 0;
        skipped = 0;
        apply_failures = 1;
        changed_post_ids = [];
      }

(** {1 Search} *)

let search t ~query ~limit =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list search_q (query, min limit 100)
  ) t.pool with
  | Ok rows -> List.filter_map post_of_row rows
  | Error err ->
      Log.BoardPg.error "search error: %s" (Caqti_error.show err);
      []

(** {1 Hearths} *)

let list_hearths t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list hearths_q ()
  ) t.pool with
  | Ok pairs -> pairs
  | Error err ->
      Log.BoardPg.error "list_hearths error: %s" (Caqti_error.show err);
      []

(** {1 Thread ID} *)

let set_thread_id t ~post_id ~thread_id =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.exec set_thread_id_q (Post_id.to_string pid, thread_id)
    ) t.pool with
    | Ok () -> Ok ()
    | Error err -> Error (caqti_err err)

(** {1 Delete} *)

let delete_post t ~post_id =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
      let pid_str = Post_id.to_string pid in
      match
        Caqti_eio.Pool.use
          (fun conn ->
            let module C = (val conn : Caqti_eio.CONNECTION) in
            let* post_opt = C.find_opt get_post_q pid_str in
            match post_opt with
            | None -> Ok (Error (Post_not_found post_id))
            | Some _ ->
                let* () = C.exec delete_comment_votes_for_post_q pid_str in
                let* () = C.exec delete_post_votes_q pid_str in
                let* () = C.exec delete_post_q pid_str in
                Ok (Ok ()))
          t.pool
      with
      | Error err -> Error (caqti_err err)
      | Ok (Error e) -> Error e
      | Ok (Ok ()) -> Ok ()

(** {1 Karma} *)

let karma_by_author_q =
  (Caqti_type.unit ->* Caqti_type.(t2 string int))
  {|SELECT author, \
      SUM(votes_up) - SUM(votes_down) AS karma \
    FROM masc_board_posts \
    GROUP BY author \
    ORDER BY karma DESC|}

let get_all_karma t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list karma_by_author_q ()
  ) t.pool with
  | Ok rows -> rows
  | Error err ->
      Log.BoardPg.error "get_all_karma error: %s" (Caqti_error.show err);
      []

let get_agent_karma t ~agent_name =
  get_all_karma t
  |> List.find_opt (fun (name, _) -> String.equal name agent_name)
  |> Option.map snd |> Option.value ~default:0

(** {1 TTL Sweep} *)

let sweep t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* posts_removed = C.find sweep_posts_q Limits.sweeper_batch_size in
    let* comments_removed = C.find sweep_comments_q Limits.sweeper_batch_size in
    let* cap_evicted =
      if Limits.author_post_cap > 0 then
        C.find sweep_author_cap_q Limits.author_post_cap
      else Ok 0
    in
    let total_posts = posts_removed + cap_evicted in
    Ok (total_posts, comments_removed)
  ) t.pool with
  | Ok (p, c) -> (p, c)
  | Error err ->
      Log.BoardPg.error "sweep error: %s" (Caqti_error.show err);
      (0, 0)

(** {1 JSONL -> PG Migration} *)

let upsert_post_q =
  (Caqti_type.(t4
    (t3 string string string)
    (t3 string float float)
    (t3 float int int)
    (t3 int (option string) (option string)))
  ->. Caqti_type.unit)
  "INSERT INTO masc_board_posts \
     (id, author, content, visibility, created_at, updated_at, \
      expires_at, votes_up, votes_down, reply_count, hearth, thread_id) \
   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) \
   ON CONFLICT (id) DO NOTHING"

let upsert_comment_q =
  (Caqti_type.(t3
    (t3 string string (option string))
    (t3 string string float)
    (t3 float int int))
  ->. Caqti_type.unit)
  "INSERT INTO masc_board_comments \
     (id, post_id, parent_id, author, content, created_at, \
      expires_at, votes_up, votes_down) \
   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) \
   ON CONFLICT (id) DO NOTHING"

type migrate_result = {
  posts_migrated: int;
  comments_migrated: int;
  votes_migrated: int;
  posts_skipped: int;
  comments_skipped: int;
}

(** Migrate data from a JSONL-backed Board.store into PostgreSQL.
    Uses ON CONFLICT DO NOTHING to safely re-run (idempotent). *)
let migrate_from_store t (store : Board.store) =
  let posts_ok = ref 0 in
  let posts_skip = ref 0 in
  let comments_ok = ref 0 in
  let comments_skip = ref 0 in
  let votes_ok = ref 0 in

  Hashtbl.iter (fun _ (p : post) ->
    let vis_str = visibility_to_string p.visibility in
    let row = (
      (Post_id.to_string p.id, Agent_id.to_string p.author, p.content),
      (vis_str, p.created_at, p.updated_at),
      (p.expires_at, p.votes_up, p.votes_down),
      (p.reply_count, p.hearth, p.thread_id)
    ) in
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.exec upsert_post_q row
    ) t.pool with
    | Ok () -> incr posts_ok
    | Error err ->
        incr posts_skip;
        Log.BoardPg.error "Post %s failed: %s"
          (Post_id.to_string p.id) (Caqti_error.show err)
  ) store.posts;

  Hashtbl.iter (fun _ (c : comment) ->
    let parent_str = Option.map Comment_id.to_string c.parent_id in
    let row = (
      (Comment_id.to_string c.id, Post_id.to_string c.post_id, parent_str),
      (Agent_id.to_string c.author, c.content, c.created_at),
      (c.expires_at, c.votes_up, c.votes_down)
    ) in
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.exec upsert_comment_q row
    ) t.pool with
    | Ok () -> incr comments_ok
    | Error err ->
        incr comments_skip;
        Log.BoardPg.error "Comment %s failed: %s"
          (Comment_id.to_string c.id) (Caqti_error.show err)
  ) store.comments;

  Hashtbl.iter (fun key direction ->
    match String.split_on_char ':' key with
    | target_type :: rest when List.length rest >= 2 ->
        let voter = match List.rev rest with last :: _ -> last | [] -> "" in
        let target_id = String.concat ":" (List.filteri (fun i _ ->
          i < List.length rest - 1) rest) in
        let dir_str = vote_direction_to_string direction in
        let now = Time_compat.now () in
        (match Caqti_eio.Pool.use (fun conn ->
          let module C = (val conn : Caqti_eio.CONNECTION) in
          C.exec upsert_vote_q (target_type, target_id, voter, (dir_str, now))
        ) t.pool with
        | Ok () -> incr votes_ok
        | Error err -> Log.BoardPg.info "vote migration: %s" (Caqti_error.show err))
    | _ -> ()
  ) store.vote_log;

  {
    posts_migrated = !posts_ok;
    comments_migrated = !comments_ok;
    votes_migrated = !votes_ok;
    posts_skipped = !posts_skip;
    comments_skipped = !comments_skip;
  }
