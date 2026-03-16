(** Board Listener - Bridges pg_notify to SSE for real-time updates
    Phase C: Local↔Remote PG Pub/Sub

    Architecture:
    1. Board writes → pg_notify('masc_board', json) + INSERT masc_pubsub
    2. This listener polls masc_pubsub table (Caqti can't LISTEN)
    3. Events forwarded to Sse.broadcast for all connected clients

    Hybrid approach:
    - pg_notify: Real-time push to external LISTEN clients (< 1ms)
    - Table polling: Reliable delivery (messages persist until consumed)
*)

open Caqti_request.Infix

(** Board listener channel (matches board_pg.ml) *)
let channel = "masc_board"

(** Polling interval in seconds *)
let poll_interval_s = 0.5

(** Max events per poll batch *)
let max_batch_size = 10

(** Listener state *)
type t = {
  pool: (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t;
  mutable running: bool;
  mutable last_seen_id: int;
}

(** Query to fetch and delete pending messages atomically *)
let fetch_messages_q =
  (Caqti_type.(t2 string int) ->* Caqti_type.(t2 int string))
  "DELETE FROM masc_pubsub \
   WHERE id IN ( \
     SELECT id FROM masc_pubsub \
     WHERE channel = $1 \
     ORDER BY id \
     LIMIT $2 \
     FOR UPDATE SKIP LOCKED \
   ) RETURNING id, message"

(** Create a new listener *)
let create pool =
  { pool; running = false; last_seen_id = 0 }

(** Parse board event JSON and create SSE-friendly format *)
let event_to_sse_json message_str =
  try
    let json = Yojson.Safe.from_string message_str in
    (* Wrap in board_event envelope *)
    Some (`Assoc [
      ("jsonrpc", `String "2.0");
      ("method", `String "notifications/board");
      ("params", json)
    ])
  with Yojson.Json_error _ ->
    Log.BoardListener.error "Failed to parse event: %s" message_str;
    None

(** Poll for new messages and broadcast via SSE *)
let poll_and_broadcast t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list fetch_messages_q (channel, max_batch_size)
  ) t.pool with
  | Ok messages ->
      List.iter (fun (id, message) ->
        if id > t.last_seen_id then begin
          t.last_seen_id <- id;
          match event_to_sse_json message with
          | Some json ->
              Sse.broadcast json;
              Log.BoardListener.info "Broadcast event id=%d" id
          | None -> ()
        end
      ) messages;
      List.length messages
  | Error err ->
      Log.BoardListener.error "Poll error: %s" (Caqti_error.show err);
      0

(** Start the listener loop (call from Eio fiber) *)
let start t =
  t.running <- true;
  Log.BoardListener.info "Started (poll_interval=%.1fs, channel=%s)"
    poll_interval_s channel;
  while t.running do
    let count = poll_and_broadcast t in
    if count > 0 then
      Log.BoardListener.info "Processed %d events" count;
    (* Sleep between polls *)
    Eio_unix.sleep poll_interval_s
  done;
  Log.BoardListener.info "Stopped"

(** Stop the listener *)
let stop t =
  Log.BoardListener.info "Stopping...";
  t.running <- false

(** Check if listener is running *)
let is_running t = t.running

(** Get stats *)
let stats t =
  `Assoc [
    ("running", `Bool t.running);
    ("last_seen_id", `Int t.last_seen_id);
    ("channel", `String channel);
    ("poll_interval_s", `Float poll_interval_s);
  ]
