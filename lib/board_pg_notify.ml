(** Board_pg_notify — PostgreSQL LISTEN/NOTIFY event system for Board changes.

    Sends real-time notifications to all LISTEN clients on board mutations.

    @since God file decomposition — extracted from board_pg.ml *)

open Board_pg_queries
open Pg_infix

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
  let payload = if String.length payload > max_notify_payload
    then String.sub payload 0 max_notify_payload else payload in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find notify_q (board_channel, payload)
  ) t.pool with
  | Ok () -> ()
  | Error err ->
      Log.BoardPg.error "notify_event error: %s" (Caqti_error.show err)
