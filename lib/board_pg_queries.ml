(** Board_pg query definitions — row types, SQL queries, column defs.

    Also hosts the shared [t] connection pool type used by all Board_pg
    sub-modules. *)

open Board
open Pg_infix

(* ================================================================ *)
(* Shared connection type                                            *)
(* ================================================================ *)

type t = {
  pool: (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t;
}

(** Get pool for PG queries *)
let get_pool t = t.pool

(** Convert Caqti errors to board_error *)
let caqti_err e = Io_error (Caqti_error.show e)

let ttl_where = "(expires_at = 0 OR expires_at > extract(epoch from now()))"
let comment_ttl_where = "(c.expires_at = 0 OR c.expires_at > extract(epoch from now()))"

(* Post row: 16 fields packed as t4(t4, t4, t4, t4) *)
let post_row_t = Caqti_type.(
  t4
    (t4 string string string (option string))         (* id, author, content, title *)
    (t4 (option string) string float float)           (* body, visibility, created_at, updated_at *)
    (t4 float int int int)                            (* expires_at, votes_up, votes_down, reply_count *)
    (t4 (option string) (option string) (option string) (option string))
                                                    (* hearth, thread_id, post_kind, meta_json *)
)

(* Comment row: 9 fields packed as t3(t3, t3, t3) *)
let comment_row_t = Caqti_type.(
  t3
    (t3 string string (option string))                (* id, post_id, parent_id *)
    (t3 string string float)                          (* author, content, created_at *)
    (t3 float int int)                                (* expires_at, votes_up, votes_down *)
)

(** {1 Row Conversion} *)

let post_of_row
    ((id, author, content, title_opt), (body_opt, vis_str, created_at, updated_at),
     (expires_at, votes_up, votes_down, reply_count),
     (hearth, thread_id, post_kind_raw, meta_raw)) =
  match Post_id.of_string id, Agent_id.of_string author, visibility_of_string vis_str with
  | Ok pid, Ok aid, Some vis ->
      let post_kind =
        match post_kind_raw with
        | Some raw -> post_kind_of_string raw
        | None -> None
      in
      let meta_json =
        match meta_raw with
        | Some raw -> (try Some (Yojson.Safe.from_string raw) with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.BoardPg.warn "meta_json parse failed: %s (raw=%s)" (Printexc.to_string exn) raw;
            None)
        | None -> None
      in
      let resolved_kind =
        match post_kind with
        | Some kind -> kind
        | None ->
            legacy_migrate_post_kind
              ~author
              ~meta_json
              ~visibility:vis
              ~expires_at
              ~hearth
      in
      let title, body, post_kind, meta_json =
        normalize_post_payload ~content ?title:title_opt ?body:body_opt
          ~post_kind:resolved_kind ?meta_json ()
      in
      Some {
        id = pid;
        author = aid;
        title;
        body;
        content = body;
        post_kind;
        meta_json;
        visibility = vis;
        created_at;
        updated_at;
        expires_at;
        votes_up;
        votes_down;
        reply_count;
        hearth;
        thread_id;
      }
  | _ -> None

let comment_of_row ((id, post_id, parent_id), (author, content, created_at),
                    (expires_at, votes_up, votes_down)) =
  match Comment_id.of_string id, Post_id.of_string post_id, Agent_id.of_string author with
  | Ok cid, Ok pid, Ok aid ->
      let parent = match parent_id with
        | Some s -> (match Comment_id.of_string s with Ok c -> Some c | _ -> None)
        | None -> None
      in
      Some { id = cid; post_id = pid; parent_id = parent; author = aid;
             content; created_at; expires_at; votes_up; votes_down }
  | _ -> None

(** {1 Post Queries} *)

let post_columns =
  "id, author, content, title, body, visibility, created_at, updated_at, \
   expires_at, votes_up, votes_down, reply_count, hearth, thread_id, \
   post_kind, meta_json"

let insert_post_q =
  (Caqti_type.(t4
    (t4 string string string (option string))
    (t4 (option string) string float float)
    (t4 float int int int)
    (t4 (option string) (option string) (option string) (option string)))
  ->. Caqti_type.unit)
  "INSERT INTO masc_board_posts \
     (id, author, content, title, body, visibility, created_at, updated_at, \
      expires_at, votes_up, votes_down, reply_count, hearth, thread_id, \
      post_kind, meta_json) \
   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)"

let get_post_q =
  (Caqti_type.string ->? post_row_t)
  (Printf.sprintf
    "SELECT %s FROM masc_board_posts WHERE id = $1 AND %s"
    post_columns ttl_where)

let post_count_q =
  (Caqti_type.unit ->! Caqti_type.int)
  (Printf.sprintf
    "SELECT COUNT(*)::int FROM masc_board_posts WHERE %s" ttl_where)

let update_post_kind_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "UPDATE masc_board_posts SET post_kind = $2 WHERE id = $1"

(* Sort-order specific list queries.
   $1=visibility (NULL=any), $2=hearth (NULL=any),
   $3=author filter (matches post author or visible comment author), $4=limit.
   NOTE: PostgreSQL cannot infer type from `$n IS NULL` alone, so explicit ::TEXT cast needed. *)
let mk_list_q order_clause =
  (Caqti_type.(t4 (option string) (option string) (option string) int) ->* post_row_t)
  (Printf.sprintf
    "SELECT %s FROM masc_board_posts \
     WHERE %s \
       AND ($1::TEXT IS NULL OR visibility = $1) \
       AND ($2::TEXT IS NULL OR hearth = $2) \
       AND ($3::TEXT IS NULL \
         OR position(lower($3) in lower(author)) > 0 \
         OR EXISTS ( \
           SELECT 1 FROM masc_board_comments c \
           WHERE c.post_id = masc_board_posts.id \
             AND %s \
             AND position(lower($3) in lower(c.author)) > 0)) \
     ORDER BY %s LIMIT $4"
    post_columns ttl_where comment_ttl_where order_clause)

let list_hot_q = mk_list_q "(votes_up - votes_down) DESC, created_at DESC"
let list_recent_q = mk_list_q "created_at DESC"
let list_updated_q = mk_list_q "updated_at DESC"
let list_discussed_q = mk_list_q "reply_count DESC, created_at DESC"

let list_updated_since_q =
  (Caqti_type.float ->* post_row_t)
  (Printf.sprintf
     "SELECT %s FROM masc_board_posts \
      WHERE %s AND updated_at >= $1 \
      ORDER BY updated_at ASC, id ASC"
     post_columns ttl_where)

(* Trending: engagement / sqrt(age_in_hours) *)
let list_trending_q = mk_list_q
  "((votes_up - votes_down + reply_count * 2)::float / \
    GREATEST(1.0, POWER(GREATEST(1.0, \
      (extract(epoch from now()) - created_at) / 3600.0), 0.5))) DESC"

(** {1 Comment Queries} *)

let comment_columns =
  "id, post_id, parent_id, author, content, created_at, \
   expires_at, votes_up, votes_down"

let insert_comment_q =
  (Caqti_type.(t3
    (t3 string string (option string))
    (t3 string string float)
    (t3 float int int))
  ->. Caqti_type.unit)
  "INSERT INTO masc_board_comments \
     (id, post_id, parent_id, author, content, created_at, \
      expires_at, votes_up, votes_down) \
   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)"

let get_comments_q =
  (Caqti_type.string ->* comment_row_t)
  (Printf.sprintf
    "SELECT %s FROM masc_board_comments \
     WHERE post_id = $1 AND %s ORDER BY created_at"
    comment_columns ttl_where)

let list_comments_q =
  (Caqti_type.int ->* comment_row_t)
  (Printf.sprintf
    "SELECT %s FROM masc_board_comments \
     WHERE %s ORDER BY created_at DESC LIMIT $1"
    comment_columns ttl_where)

let inc_reply_count_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_posts \
   SET reply_count = reply_count + 1, \
       updated_at = extract(epoch from now()) \
   WHERE id = $1"

(** {1 Vote Queries} *)

let get_vote_q =
  (Caqti_type.(t3 string string string) ->? Caqti_type.string)
  "SELECT direction FROM masc_board_votes \
   WHERE target_type = $1 AND target_id = $2 AND voter = $3"

let upsert_vote_q =
  (Caqti_type.(t4 string string string (t2 string float)) ->. Caqti_type.unit)
  "INSERT INTO masc_board_votes (target_type, target_id, voter, direction, created_at) \
   VALUES ($1, $2, $3, $4, $5) \
   ON CONFLICT (target_type, target_id, voter) \
   DO UPDATE SET direction = $4, created_at = $5"

(* Vote count update queries for posts *)
let flip_to_up_post_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_posts SET \
     votes_up = votes_up + 1, \
     votes_down = GREATEST(0, votes_down - 1), \
     updated_at = extract(epoch from now()) \
   WHERE id = $1"

let flip_to_down_post_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_posts SET \
     votes_down = votes_down + 1, \
     votes_up = GREATEST(0, votes_up - 1), \
     updated_at = extract(epoch from now()) \
   WHERE id = $1"

let inc_up_post_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_posts SET \
     votes_up = votes_up + 1, \
     updated_at = extract(epoch from now()) \
   WHERE id = $1"

let inc_down_post_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_posts SET \
     votes_down = votes_down + 1, \
     updated_at = extract(epoch from now()) \
   WHERE id = $1"

(* Vote count update queries for comments *)
let flip_to_up_comment_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_comments SET \
     votes_up = votes_up + 1, \
     votes_down = GREATEST(0, votes_down - 1) \
   WHERE id = $1"

let flip_to_down_comment_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_comments SET \
     votes_down = votes_down + 1, \
     votes_up = GREATEST(0, votes_up - 1) \
   WHERE id = $1"

let inc_up_comment_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_comments SET votes_up = votes_up + 1 WHERE id = $1"

let inc_down_comment_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "UPDATE masc_board_comments SET votes_down = votes_down + 1 WHERE id = $1"

let get_post_score_q =
  (Caqti_type.string ->! Caqti_type.int)
  "SELECT (votes_up - votes_down)::int FROM masc_board_posts WHERE id = $1"

let get_comment_score_q =
  (Caqti_type.string ->! Caqti_type.int)
  "SELECT (votes_up - votes_down)::int FROM masc_board_comments WHERE id = $1"

let comment_author_q =
  (Caqti_type.string ->? Caqti_type.string)
  "SELECT author FROM masc_board_comments WHERE id = $1"

(** {1 Stats / Search / Hearth Queries} *)

let stats_q =
  (Caqti_type.unit ->! Caqti_type.(t3 int int int))
  (Printf.sprintf
    "SELECT \
       (SELECT COUNT(*)::int FROM masc_board_posts WHERE %s), \
       (SELECT COUNT(*)::int FROM masc_board_comments WHERE %s), \
       (SELECT COUNT(*)::int FROM masc_board_posts \
        WHERE expires_at > 0 AND expires_at < extract(epoch from now()))"
    ttl_where ttl_where)

let search_q =
  (Caqti_type.(t2 string int) ->* post_row_t)
  (Printf.sprintf
    "SELECT %s FROM masc_board_posts \
     WHERE %s AND (title ILIKE '%%' || $1 || '%%' \
       OR content ILIKE '%%' || $1 || '%%' \
       OR author ILIKE '%%' || $1 || '%%' \
       OR hearth ILIKE '%%' || $1 || '%%') \
     ORDER BY (votes_up - votes_down) DESC, created_at DESC \
     LIMIT $2"
    post_columns ttl_where)

let hearths_q =
  (Caqti_type.unit ->* Caqti_type.(t2 string int))
  (Printf.sprintf
    "SELECT hearth, COUNT(*)::int FROM masc_board_posts \
     WHERE %s AND hearth IS NOT NULL \
     GROUP BY hearth ORDER BY COUNT(*) DESC"
    ttl_where)

(** {1 Thread / Misc Queries} *)

let set_thread_id_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "UPDATE masc_board_posts SET thread_id = $1 WHERE id = $2"

let delete_post_votes_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "DELETE FROM masc_board_votes WHERE target_type = 'post' AND target_id = $1"

let delete_comment_votes_for_post_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "DELETE FROM masc_board_votes \
   WHERE target_type = 'comment' \
     AND target_id IN (SELECT id FROM masc_board_comments WHERE post_id = $1)"

let delete_post_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "DELETE FROM masc_board_posts WHERE id = $1"

let sweep_posts_q =
  (Caqti_type.int ->! Caqti_type.int)
  "WITH deleted AS ( \
     DELETE FROM masc_board_posts \
     WHERE ctid IN ( \
       SELECT ctid FROM masc_board_posts \
       WHERE expires_at > 0 AND expires_at < extract(epoch from now()) \
       LIMIT $1 \
     ) RETURNING 1 \
   ) SELECT COUNT(*)::int FROM deleted"

(** Author cap enforcement: delete oldest posts from authors exceeding the cap.
    $1 = author_post_cap limit. *)
let sweep_author_cap_q =
  (Caqti_type.int ->! Caqti_type.int)
  "WITH ranked AS ( \
     SELECT id, author, \
       ROW_NUMBER() OVER (PARTITION BY author ORDER BY created_at ASC) as rn, \
       COUNT(*) OVER (PARTITION BY author) as total \
     FROM masc_board_posts \
   ), to_delete AS ( \
     DELETE FROM masc_board_posts \
     WHERE id IN ( \
       SELECT id FROM ranked WHERE total > $1 AND rn <= total - $1 \
     ) RETURNING 1 \
   ) SELECT COUNT(*)::int FROM to_delete"

let sweep_comments_q =
  (Caqti_type.int ->! Caqti_type.int)
  "WITH deleted AS ( \
     DELETE FROM masc_board_comments \
     WHERE ctid IN ( \
       SELECT ctid FROM masc_board_comments \
       WHERE expires_at > 0 AND expires_at < extract(epoch from now()) \
       LIMIT $1 \
     ) RETURNING 1 \
   ) SELECT COUNT(*)::int FROM deleted"

(** {1 Pub/Sub Notification} *)

(** PostgreSQL NOTIFY channel for Board events *)
