(** Board_pg - PostgreSQL backend for MASC Board

    Uses Caqti for database access, sharing the pool from Backend.PostgresNative.
    Auto-creates schema on initialization.

    All read queries filter expired posts/comments via SQL WHERE clause.
    Sort orders (hot/trending/recent/updated/discussed) are handled in SQL.

    @since 0.6.0
*)

open Board

open Result_syntax

include Board_pg_queries

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

include Board_pg_notify
include Board_pg_admin

(** {1 Operations} — posts, comments, voting (core CRUD) *)

let create_post t ~author ~content ?title ?body ~post_kind ?meta_json
    ?(visibility=Internal) ?(ttl_hours=Limits.default_ttl_hours) ?hearth ?thread_id () =
  match Agent_id.of_string author with
  | Error e -> Error e
  | Ok author_id ->
  let ttl =
    match post_kind with
    | Automation_post | System_post ->
        let forced = Limits.automation_ttl_hours in
        if ttl_hours = 0 then forced
        else min ttl_hours forced
    | Human_post ->
        if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours
  in
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

let list_posts t ?(visibility_filter=None) ?hearth ?author_filter ?(sort_by=Hot) ?(limit=50) () =
  let vis_str = Option.map visibility_to_string visibility_filter in
  let hearth_norm = Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth in
  let author_norm =
    match author_filter with
    | Some raw ->
        let trimmed = String.trim raw in
        if trimmed = "" then None else Some (String.lowercase_ascii trimmed)
    | None -> None
  in
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
    C.collect_list q (vis_str, hearth_norm, author_norm, lim)
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
  | Ok (Some row) ->
  (match post_of_row row with
   | None -> Error (Validation_error "Corrupt parent post")
   | Some parent_post ->
  let now = Time_compat.now () in
  let ttl =
    match parent_post.post_kind with
    | Automation_post | System_post ->
        let forced = Limits.automation_ttl_hours in
        if ttl_hours = 0 then forced
        else min ttl_hours forced
    | Human_post ->
        if ttl_hours = 0 then 0 else min ttl_hours Limits.max_ttl_hours
  in
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
  )

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

