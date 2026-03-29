(** Board_pg - PostgreSQL backend for MASC Board

    Uses Caqti for database access, sharing the pool from Backend.PostgresNative.
    Auto-creates schema on initialization.

    All read queries filter expired posts/comments via SQL WHERE clause.
    Sort orders (hot/trending/recent/updated/discussed) are handled in SQL.

    @since 0.6.0
*)

open Board

open Result_syntax

type t = {
  pool: (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t;
}

(** Get pool for Board_listener pub/sub bridge *)
let get_pool t = t.pool

(** Convert Caqti errors to board_error *)
let caqti_err e = Io_error (Caqti_error.show e)

(** {1 Schema DDL} *)

open Pg_infix

let create_posts_table_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS masc_board_posts (\
     id TEXT PRIMARY KEY, \
     author TEXT NOT NULL, \
     content TEXT NOT NULL, \
     title TEXT, \
     body TEXT, \
     visibility TEXT NOT NULL DEFAULT 'internal', \
     created_at DOUBLE PRECISION NOT NULL, \
     updated_at DOUBLE PRECISION NOT NULL, \
     expires_at DOUBLE PRECISION NOT NULL DEFAULT 0.0, \
     votes_up INT NOT NULL DEFAULT 0, \
     votes_down INT NOT NULL DEFAULT 0, \
     reply_count INT NOT NULL DEFAULT 0, \
     hearth TEXT, \
     thread_id TEXT, \
     post_kind TEXT, \
     meta_json TEXT \
   )"

let alter_posts_add_title_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "ALTER TABLE masc_board_posts ADD COLUMN IF NOT EXISTS title TEXT"

let alter_posts_add_body_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "ALTER TABLE masc_board_posts ADD COLUMN IF NOT EXISTS body TEXT"

let alter_posts_add_post_kind_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "ALTER TABLE masc_board_posts ADD COLUMN IF NOT EXISTS post_kind TEXT"

let alter_posts_add_meta_json_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "ALTER TABLE masc_board_posts ADD COLUMN IF NOT EXISTS meta_json TEXT"

let create_comments_table_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS masc_board_comments (\
     id TEXT PRIMARY KEY, \
     post_id TEXT NOT NULL REFERENCES masc_board_posts(id) ON DELETE CASCADE, \
     parent_id TEXT REFERENCES masc_board_comments(id) ON DELETE SET NULL, \
     author TEXT NOT NULL, \
     content TEXT NOT NULL, \
     created_at DOUBLE PRECISION NOT NULL, \
     expires_at DOUBLE PRECISION NOT NULL DEFAULT 0.0, \
     votes_up INT NOT NULL DEFAULT 0, \
     votes_down INT NOT NULL DEFAULT 0 \
   )"

let create_votes_table_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS masc_board_votes (\
     target_type TEXT NOT NULL CHECK (target_type IN ('post', 'comment')), \
     target_id TEXT NOT NULL, \
     voter TEXT NOT NULL, \
     direction TEXT NOT NULL CHECK (direction IN ('up', 'down')), \
     created_at DOUBLE PRECISION NOT NULL, \
     UNIQUE (target_type, target_id, voter) \
   )"

(* Indexes *)
let create_idx_posts_score_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_board_posts_score \
   ON masc_board_posts ((votes_up - votes_down) DESC, created_at DESC)"

let create_idx_posts_created_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_board_posts_created \
   ON masc_board_posts (created_at DESC)"

let create_idx_posts_updated_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_board_posts_updated \
   ON masc_board_posts (updated_at DESC)"

let create_idx_posts_reply_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_board_posts_reply \
   ON masc_board_posts (reply_count DESC)"

let create_idx_posts_hearth_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_board_posts_hearth \
   ON masc_board_posts (hearth)"

let create_idx_posts_expires_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_board_posts_expires \
   ON masc_board_posts (expires_at)"

let create_idx_comments_post_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_board_comments_post \
   ON masc_board_comments (post_id, created_at)"

(** {1 Initialization} *)

let create pool =
  let init_result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* () = C.exec create_posts_table_q () in
    let* () = C.exec alter_posts_add_title_q () in
    let* () = C.exec alter_posts_add_body_q () in
    let* () = C.exec alter_posts_add_post_kind_q () in
    let* () = C.exec alter_posts_add_meta_json_q () in
    let* () = C.exec create_comments_table_q () in
    let* () = C.exec create_votes_table_q () in
    let* () = C.exec create_idx_posts_score_q () in
    let* () = C.exec create_idx_posts_created_q () in
    let* () = C.exec create_idx_posts_updated_q () in
    let* () = C.exec create_idx_posts_reply_q () in
    let* () = C.exec create_idx_posts_hearth_q () in
    let* () = C.exec create_idx_posts_expires_q () in
    let* () = C.exec create_idx_comments_post_q () in
    Ok ()
  ) pool in
  match init_result with
  | Error err ->
      Log.BoardPg.error "Schema init failed: %s" (Caqti_error.show err);
      Error (Io_error (Caqti_error.show err))
  | Ok () ->
      Log.BoardPg.info "Schema initialized.";
      Ok { pool }

(** {1 Row Types} *)

(* TTL filter clause — uses DB server time *)

include Board_pg_queries

let board_channel = "masc_board"

(** pg_notify sends real-time notification to all LISTEN clients
    Payload limited to 8000 bytes by PostgreSQL — truncate if needed.
    NOTE: pg_notify() returns void but SELECT always produces one row.
    Using ->! unit (expect one row, discard void value) avoids Caqti error. *)
let notify_q =
  (Caqti_type.(t2 string string) ->! Caqti_type.unit)
  "SELECT pg_notify($1, $2)"

(** Max payload size (safety margin below PostgreSQL 8000 limit) *)
let max_notify_payload = 7900

(** Event types for Board notifications *)
type board_event =
  | Post_created of { post_id: string; author: string; hearth: string option }
  | Post_voted of { post_id: string; voter: string; direction: string; new_score: int }
  | Comment_added of { post_id: string; comment_id: string; author: string }
  | Comment_voted of { comment_id: string; voter: string; direction: string }

(** Serialize event to JSON payload *)
let event_to_json = function
  | Post_created { post_id; author; hearth } ->
      let base = [("type", `String "post_created"); ("post_id", `String post_id); ("author", `String author)] in
      let with_hearth = match hearth with Some h -> ("hearth", `String h) :: base | None -> base in
      Yojson.Safe.to_string (`Assoc with_hearth)
  | Post_voted { post_id; voter; direction; new_score } ->
      Yojson.Safe.to_string (`Assoc [
        ("type", `String "post_voted"); ("post_id", `String post_id);
        ("voter", `String voter); ("direction", `String direction); ("new_score", `Int new_score)
      ])
  | Comment_added { post_id; comment_id; author } ->
      Yojson.Safe.to_string (`Assoc [
        ("type", `String "comment_added"); ("post_id", `String post_id);
        ("comment_id", `String comment_id); ("author", `String author)
      ])
  | Comment_voted { comment_id; voter; direction } ->
      Yojson.Safe.to_string (`Assoc [
        ("type", `String "comment_voted"); ("comment_id", `String comment_id);
        ("voter", `String voter); ("direction", `String direction)
      ])

(** Send notification on Board change (fire-and-forget, errors logged) *)
let notify_event t event =
  let payload = event_to_json event in
  (* Truncate if too large *)
  let payload = if String.length payload > max_notify_payload
    then String.sub payload 0 max_notify_payload else payload in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find notify_q (board_channel, payload)
  ) t.pool with
  | Ok () -> ()
  | Error err ->
      Log.BoardPg.error "notify_event error: %s" (Caqti_error.show err)

(** {1 Operations} *)

let create_post t ~author ~content ?title ?body ~post_kind ?meta_json
    ?(visibility=Internal) ?(ttl_hours=Limits.default_ttl_hours) ?hearth ?thread_id () =
  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->
  let ttl = if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours in
  let hearth = Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth in
  let now = Time_compat.now () in
  let expires_at = if ttl = 0 then 0.0 else now +. (float_of_int ttl *. 3600.0) in
  let title, body, normalized_kind, normalized_meta =
    normalize_post_payload ~content ?title ?body ~post_kind ?meta_json ()
  in
  if String.length body > Limits.max_content_length then
    Error (Validation_error (Printf.sprintf "Content too long: %d > %d"
      (String.length body) Limits.max_content_length))
  else if String.length body = 0 then
    Error (Validation_error "Content cannot be empty")
  else
  let post = {
    id = Post_id.generate ();
    author = author_id;
    title;
    body;
    content = body;
    post_kind = normalized_kind;
    meta_json = normalized_meta;
    visibility;
    created_at = now;
    updated_at = now;
    expires_at;
    votes_up = 0;
    votes_down = 0;
    reply_count = 0;
    hearth;
    thread_id;
  } in
  let meta_raw =
    match post.meta_json with
    | Some json -> Some (Yojson.Safe.to_string json)
    | None -> None
  in
  let vis_str = visibility_to_string post.visibility in
  let row = (
    (Post_id.to_string post.id, Agent_id.to_string post.author, post.content, Some post.title),
    (Some post.body, vis_str, post.created_at, post.updated_at),
    (post.expires_at, post.votes_up, post.votes_down, post.reply_count),
    (post.hearth, post.thread_id, Some (post_kind_to_string post.post_kind), meta_raw)
  ) in
  (* Capacity check + insert in single connection to avoid TOCTOU *)
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* count = C.find post_count_q () in
    if count >= Limits.max_posts then
      Ok (Error (Capacity_exceeded { current = count; max = Limits.max_posts }))
    else
      let* () = C.exec insert_post_q row in
      Ok (Ok post)
  ) t.pool in
  match result with
  | Error err -> Error (caqti_err err)
  | Ok (Error e) -> Error e
  | Ok (Ok post) ->
      notify_event t (Post_created {
        post_id = Post_id.to_string post.id;
        author = Agent_id.to_string post.author;
        hearth = post.hearth
      });
      Ok post

let get_post t ~post_id =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.find_opt get_post_q (Post_id.to_string pid)
    ) t.pool with
    | Error err -> Error (caqti_err err)
    | Ok None -> Error (Post_not_found post_id)
    | Ok (Some row) ->
        match post_of_row row with
        | Some p -> Ok p
        | None -> Error (Io_error "Failed to parse post row from DB")

type sort_order = Hot | Trending | Recent | Updated | Discussed

let list_posts t ?(visibility_filter=None) ?hearth ?(sort_by=Hot) ?(limit=50) () =
  let vis_str = Option.map visibility_to_string visibility_filter in
  let hearth_norm = Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth in
  let lim = max 1 (min limit 5200) in
  let q = match sort_by with
    | Hot -> list_hot_q
    | Recent -> list_recent_q
    | Updated -> list_updated_q
    | Trending -> list_trending_q
    | Discussed -> list_discussed_q
  in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list q (vis_str, hearth_norm, lim)
  ) t.pool with
  | Ok rows -> List.filter_map post_of_row rows
  | Error err ->
      Log.BoardPg.error "list_posts error: %s" (Caqti_error.show err);
      []

(** {1 Comment Operations} *)

let add_comment t ~post_id ~author ~content ?parent_id ?(ttl_hours=Limits.default_ttl_hours) () =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->
  let parent_result = match parent_id with
    | None -> Ok None
    | Some p -> match Comment_id.of_string p with
        | Ok cid -> Ok (Some cid)
        | Error e -> Error e
  in
  match parent_result with
  | Error e -> Error e
  | Ok parent_cid ->
  if String.length content > Limits.max_content_length then
    Error (Validation_error "Content too long")
  else if String.length content = 0 then
    Error (Validation_error "Content cannot be empty")
  else
  (* Verify post exists *)
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find_opt get_post_q (Post_id.to_string pid)
  ) t.pool with
  | Error err -> Error (caqti_err err)
  | Ok None -> Error (Post_not_found post_id)
  | Ok (Some _) ->
  let now = Time_compat.now () in
  let ttl = if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours in
  let comment = {
    id = Comment_id.generate ();
    post_id = pid;
    parent_id = parent_cid;
    author = author_id;
    content;
    created_at = now;
    expires_at = if ttl = 0 then 0.0 else now +. (float_of_int ttl *. 3600.0);
    votes_up = 0;
    votes_down = 0;
  } in
  let parent_str = Option.map Comment_id.to_string parent_cid in
  let row = (
    (Comment_id.to_string comment.id, Post_id.to_string pid, parent_str),
    (Agent_id.to_string author_id, content, comment.created_at),
    (comment.expires_at, 0, 0)
  ) in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* () = C.exec insert_comment_q row in
    let* () = C.exec inc_reply_count_q (Post_id.to_string pid) in
    Ok ()
  ) t.pool with
  | Error err -> Error (caqti_err err)
  | Ok () ->
      notify_event t (Comment_added {
        post_id = Post_id.to_string pid;
        comment_id = Comment_id.to_string comment.id;
        author = Agent_id.to_string author_id
      });
      Ok comment

let get_comments t ~post_id =
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.collect_list get_comments_q (Post_id.to_string pid)
    ) t.pool with
    | Error err -> Error (caqti_err err)
    | Ok rows -> Ok (List.filter_map comment_of_row rows)

let list_comments t ?(limit=1000) () =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list list_comments_q limit
  ) t.pool with
  | Ok rows -> List.filter_map comment_of_row rows
  | Error err ->
      Log.BoardPg.error "list_comments error: %s" (Caqti_error.show err);
      []

(** {1 Vote Operations} *)

let vote_post t ~voter ~post_id ~direction =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok _ ->
  match Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
  let pid_str = Post_id.to_string pid in
  let dir_str = vote_direction_to_string direction in
  (* All vote operations in a single transaction for atomicity.
     Without this, concurrent votes can both read "no existing vote"
     then both INSERT + increment, inflating the counter. *)
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.with_transaction (fun () ->
      (* Verify post exists *)
      let* post_opt = C.find_opt get_post_q pid_str in
      match post_opt with
      | None -> Ok (Error (Post_not_found post_id))
      | Some post_row ->
      (* Check existing vote *)
      let* existing = C.find_opt get_vote_q ("post", pid_str, voter) in
      match existing with
      | Some d when d = dir_str ->
          Ok (Error (Already_voted (Printf.sprintf "%s already voted %s on %s"
            voter dir_str post_id)))
      | Some _ ->
          (* Flip vote: upsert + counter update atomically *)
          let now = Time_compat.now () in
          let* () = C.exec upsert_vote_q ("post", pid_str, voter, (dir_str, now)) in
          let* () = C.exec (if dir_str = "up" then flip_to_up_post_q else flip_to_down_post_q) pid_str in
          let* score = C.find get_post_score_q pid_str in
          Ok (Ok (score, Some post_row))
      | None ->
          (* New vote: insert + counter update *)
          let now = Time_compat.now () in
          let* () = C.exec upsert_vote_q ("post", pid_str, voter, (dir_str, now)) in
          let* () = C.exec (if dir_str = "up" then inc_up_post_q else inc_down_post_q) pid_str in
          let* score = C.find get_post_score_q pid_str in
          Ok (Ok (score, Some post_row))
    )
  ) t.pool in
  match result with
  | Error err -> Error (caqti_err err)
  | Ok (Error e) -> Error e
  | Ok (Ok (score, post_row_opt)) ->
      (* Record Thompson Sampling outside Pool.use *)
      (match post_row_opt with
       | Some row ->
           (match post_of_row row with
            | Some p ->
                let author_name = Agent_id.to_string p.author in
                let vote_dir = match direction with Up -> `Up | Down -> `Down in
                Thompson_sampling.record_vote ~agent_name:author_name ~direction:vote_dir
            | None -> ())
       | None -> ());
      (* Notify vote event *)
      notify_event t (Post_voted {
        post_id;
        voter;
        direction = vote_direction_to_string direction;
        new_score = score
      });
      Ok score

let vote_comment t ~voter ~comment_id ~direction =
  match Agent_id.of_string voter with
  | Error e -> Error e
  | Ok _ ->
  match Comment_id.of_string comment_id with
  | Error e -> Error e
  | Ok cid ->
  let cid_str = Comment_id.to_string cid in
  let dir_str = vote_direction_to_string direction in
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.with_transaction (fun () ->
      (* Get comment author (also verifies existence) *)
      let* author_opt = C.find_opt comment_author_q cid_str in
      match author_opt with
      | None ->
          Ok (Error (Comment_not_found comment_id))
      | Some author_name ->
      (* Check existing vote *)
      let* existing = C.find_opt get_vote_q ("comment", cid_str, voter) in
      match existing with
      | Some d when d = dir_str ->
          Ok (Error (Already_voted (Printf.sprintf "%s already voted %s on comment %s"
            voter dir_str comment_id)))
      | Some _ ->
          (* Flip vote *)
          let now = Time_compat.now () in
          let* () = C.exec upsert_vote_q ("comment", cid_str, voter, (dir_str, now)) in
          let* () = C.exec (if dir_str = "up" then flip_to_up_comment_q else flip_to_down_comment_q) cid_str in
          let* score = C.find get_comment_score_q cid_str in
          Ok (Ok (score, author_name))
      | None ->
          (* New vote *)
          let now = Time_compat.now () in
          let* () = C.exec upsert_vote_q ("comment", cid_str, voter, (dir_str, now)) in
          let* () = C.exec (if dir_str = "up" then inc_up_comment_q else inc_down_comment_q) cid_str in
          let* score = C.find get_comment_score_q cid_str in
          Ok (Ok (score, author_name))
    )
  ) t.pool in
  match result with
  | Error err -> Error (caqti_err err)
  | Ok (Error e) -> Error e
  | Ok (Ok (score, author_name)) ->
      (* Record Thompson Sampling feedback *)
      let vote_dir = match direction with Up -> `Up | Down -> `Down in
      Thompson_sampling.record_vote ~agent_name:author_name ~direction:vote_dir;
      (* Notify vote event *)
      notify_event t (Comment_voted {
        comment_id;
        voter;
        direction = vote_direction_to_string direction
      });
      Ok score

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

let reclassify_posts t ?(limit = 5200) ?(dry_run = true) () =
  let scan_limit = max 0 (min limit 5200) in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* total = C.find post_count_q () in
    let* rows =
      if scan_limit = 0 then
        Ok []
      else
        C.collect_list list_recent_q (None, None, scan_limit)
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
      C.exec set_thread_id_q (thread_id, Post_id.to_string pid)
    ) t.pool with
    | Error err -> Error (caqti_err err)
    | Ok () -> Ok ()

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

(** {1 Karma Calculation} *)

let karma_by_author_q =
  (Caqti_type.unit ->* Caqti_type.(t2 string int))
  "SELECT author, COALESCE(SUM(votes_up), 0)::int AS karma \
   FROM ( \
     SELECT author, votes_up FROM masc_board_posts \
     WHERE (expires_at = 0 OR expires_at > extract(epoch from now())) \
     UNION ALL \
     SELECT author, votes_up FROM masc_board_comments \
     WHERE (expires_at = 0 OR expires_at > extract(epoch from now())) \
   ) AS combined \
   GROUP BY author \
   ORDER BY karma DESC"

let get_all_karma t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list karma_by_author_q ()
  ) t.pool with
  | Ok pairs -> pairs
  | Error err ->
      Log.BoardPg.error "get_all_karma error: %s" (Caqti_error.show err);
      []

let get_agent_karma t ~agent_name =
  let all_karma = get_all_karma t in
  match List.find_opt (fun (name, _) -> name = agent_name) all_karma with
  | Some (_, karma) -> karma
  | None -> 0

(** {1 TTL Sweep} *)

let sweep t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* posts_removed = C.find sweep_posts_q Limits.sweeper_batch_size in
    let* comments_removed = C.find sweep_comments_q Limits.sweeper_batch_size in
    Ok (posts_removed, comments_removed)
  ) t.pool with
  | Ok (p, c) -> (p, c)
  | Error err ->
      Log.BoardPg.error "sweep error: %s" (Caqti_error.show err);
      (0, 0)

(** {1 JSONL → PG Migration} *)

(** Upsert query for migration (skips existing rows) *)
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

  (* Migrate posts *)
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

  (* Migrate comments — posts must exist first *)
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

  (* Migrate votes *)
  Hashtbl.iter (fun key direction ->
    (* vote key format: "post:pid:voter" or "comment:cid:voter" *)
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
    | _ -> ()  (* Skip malformed keys *)
  ) store.vote_log;

  {
    posts_migrated = !posts_ok;
    comments_migrated = !comments_ok;
    votes_migrated = !votes_ok;
    posts_skipped = !posts_skip;
    comments_skipped = !comments_skip;
  }
