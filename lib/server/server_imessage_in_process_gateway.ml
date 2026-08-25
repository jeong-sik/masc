(* Server_imessage_in_process_gateway — replaces sidecars/imessage-bot/.

   Shaped after the Slack gateway, minus everything Slack needs and iMessage
   does not: no socket, no handshake, no reconnect, no bot identity, no
   credential. The transport is a local SQLite file and a child process, so
   the only carried state is one integer — the last delivered ROWID. *)

module State = Channel_gate_imessage_state
module Db = Imessage_chat_db

let default_poll_interval_sec = 2.
let min_poll_interval_sec = 0.5

(* Bounded above as well: a cadence measured in hours is a configuration
   mistake that would look like a dead connector. *)
let max_poll_interval_sec = 300.

let resolved_poll_interval_sec () =
  match Env_config_imessage.poll_interval_sec_opt () with
  | None -> Ok default_poll_interval_sec
  | Some raw ->
    (match float_of_string_opt (String.trim raw) with
     | None ->
       Error
         (Printf.sprintf
            "MASC_IMESSAGE_POLL_INTERVAL_SEC is not a number: %S" raw)
     | Some seconds
       when seconds < min_poll_interval_sec || seconds > max_poll_interval_sec ->
       Error
         (Printf.sprintf
            "MASC_IMESSAGE_POLL_INTERVAL_SEC must be between %g and %g seconds, \
             got %g"
            min_poll_interval_sec max_poll_interval_sec seconds)
     | Some seconds -> Ok seconds)
;;

(* ---- Durable cursor ---- *)

let default_cursor_path = ".gate/runtime/imessage/cursor.json"

let cursor_path () =
  match Env_config_imessage.cursor_path_opt () with
  | Some path -> Env_config_core.resolve_against_base_path path
  | None -> Env_config_core.resolve_against_base_path default_cursor_path
;;

let cursor_to_json rowid =
  Yojson.Safe.to_string (`Assoc [ "last_rowid", `Int rowid ])
;;

(* A cursor file that cannot be read is an error rather than a restart from
   zero: zero would redeliver every message Messages.app has ever stored. *)
let cursor_of_json content =
  match Yojson.Safe.from_string content with
  | exception Yojson.Json_error detail ->
    Error ("cursor file is not JSON: " ^ detail)
  | `Assoc fields ->
    (match List.assoc_opt "last_rowid" fields with
     | Some (`Int rowid) when rowid >= 0 -> Ok rowid
     | Some (`Int rowid) ->
       Error (Printf.sprintf "cursor last_rowid must not be negative: %d" rowid)
     | Some _ -> Error "cursor field last_rowid must be an integer"
     | None -> Error "cursor file has no last_rowid field")
  | _ -> Error "cursor file must be a JSON object"
;;

let read_cursor () =
  let path = cursor_path () in
  match Fs_compat.load_file_opt path with
  | None -> Ok 0
  | Some content -> cursor_of_json content
;;

let write_cursor rowid =
  let path = cursor_path () in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path (cursor_to_json rowid)
;;

(* ---- Inbound projection ---- *)

let conversation_id ~chat_identifier =
  Printf.sprintf "imessage:chat:%s" chat_identifier
;;

(* An iMessage conversation is bound to exactly one keeper, so a message
   arriving on a bound conversation is addressed to that keeper by
   construction. There is no @mention to detect and no ambient tier: an
   unbound conversation is not this connector's traffic at all. *)
let inbound_message_of_row ~keeper_name (row : Db.inbound_row) :
  Channel_gate.inbound_message =
  { channel = State.channel
  ; channel_user_id = row.sender
  ; (* Messages.app gives a handle, not a display name; the handle is the
       identity and doubles as the label. [display_name] on the row is the
       group chat's name, not the author's. *)
    channel_user_name = row.sender
  ; (* iMessage has no workspace. The empty string is the gate's stringly
       absence; the typed [delivery.workspace_id] carries [None]. *)
    channel_workspace_id = ""
  ; keeper_name
  ; content = row.text
  ; idempotency_key = Printf.sprintf "imessage-msg-%d" row.rowid
  ; metadata =
      [ "conversation_id", conversation_id ~chat_identifier:row.chat_identifier
      ; "external_message_id", string_of_int row.rowid
      ; "imessage.chat_identifier", row.chat_identifier
      ; "imessage.rowid", string_of_int row.rowid
      ; "mentions_bound_keeper", "true"
      ]
      @
      if String.equal row.display_name "" then []
      else [ "imessage.chat_display_name", row.display_name ]
  }
;;

let delivery_of_row ~(row : Db.inbound_row) :
  (Gate_keeper_backend.connector_delivery, string) result =
  let chat_guid =
    if String.equal (String.trim row.chat_guid) "" then None
    else Some row.chat_guid
  in
  Result.map
    (fun continuation_channel ->
       { Gate_keeper_backend.continuation_channel
       ; surface =
           Surface_ref.Gate
             { label = State.channel
             ; address =
                 [ "connector", State.channel
                 ; ( "conversation_id"
                   , conversation_id ~chat_identifier:row.chat_identifier )
                 ; "external_message_id", string_of_int row.rowid
                 ]
             }
       ; conversation_id =
           Some (conversation_id ~chat_identifier:row.chat_identifier)
       ; external_message_id = Some (string_of_int row.rowid)
       ; workspace_id = None
       })
    (Keeper_continuation_channel.imessage ~chat_identifier:row.chat_identifier
       ~chat_guid ~user_id:row.sender)
;;

(* ---- Cursor decision ---- *)

type disposition =
  | Consume
  | Retry of string

(* The at-least-once boundary, stated once.

   A validation failure is permanent — the same row will fail the same way
   forever — so leaving the cursor on it would wedge the conversation behind
   one bad message. A dispatch or internal failure is the accept not having
   happened, so the row is still owed and the cursor stays. RFC-0384 names
   this choice for Telegram's offset and it is the same choice here. *)
let disposition_of_outcome = function
  | Ok (_ : Channel_gate.outbound_message) -> Consume
  | Error (Channel_gate.Validation error) ->
    Log.Server.warn
      "imessage: dropping a message the gate rejected as invalid (%s)"
      (Channel_gate.validation_error_to_string error);
    Consume
  | Error Channel_gate.Dispatch_unavailable ->
    Retry "keeper dispatch unavailable"
  | Error (Channel_gate.Keeper_error detail) -> Retry ("keeper error: " ^ detail)
  | Error (Channel_gate.Internal detail) -> Retry ("internal error: " ^ detail)
;;

module For_testing = struct
  let cursor_to_json = cursor_to_json
  let cursor_of_json = cursor_of_json
  let conversation_id = conversation_id
  let inbound_message_of_row = inbound_message_of_row
  let disposition_of_outcome = disposition_of_outcome
end

(* ---- Poll loop ---- *)

let handle_row ~dispatch_for_delivery ~(row : Db.inbound_row) =
  match State.resolve_keeper_for_channel_result ~channel_id:row.chat_identifier with
  | Error error ->
    (* The binding store could not be read, so whether this row belongs to a
       keeper is unknown. Unknown is not "unbound"; the row is still owed. *)
    Retry
      ("binding store unreadable: "
       ^ Channel_gate_binding_store.binding_store_error_to_string error)
  | Ok None ->
    (* Messages.app carries the operator's whole personal correspondence. A
       conversation nobody bound is not this connector's traffic, and passing
       it to a keeper would forward private mail. *)
    Consume
  | Ok (Some resolution) ->
    (match delivery_of_row ~row with
     | Error detail -> Retry ("delivery coordinates rejected: " ^ detail)
     | Ok delivery ->
       let message =
         inbound_message_of_row ~keeper_name:resolution.State.keeper_name row
       in
       disposition_of_outcome
         (Channel_gate.handle_inbound
            ~dispatch:(dispatch_for_delivery delivery) message))
;;

(* Rows arrive in ROWID order and are delivered in it, so the first row that
   cannot be accepted stops the batch: skipping past it would reorder the
   conversation and advancing over it would lose the message. *)
let rec process_rows ~dispatch_for_delivery ~cursor = function
  | [] -> cursor, None
  | (row : Db.inbound_row) :: rest ->
    (match handle_row ~dispatch_for_delivery ~row with
     | Retry reason -> cursor, Some reason
     | Consume ->
       (match write_cursor row.rowid with
        | Error detail ->
          (* The turn was accepted but the cursor did not move. Stopping here
             means the next poll redelivers it, which the gate's idempotency
             key collapses. Continuing would risk losing every later row on a
             restart. *)
          cursor, Some ("cursor write failed: " ^ detail)
        | Ok () ->
          process_rows ~dispatch_for_delivery ~cursor:row.rowid rest))
;;

let refresh_self_chat_guid ~db_path =
  match Env_config_imessage.self_chat_guid_opt () with
  | Some guid -> State.record_self_chat_guid guid
  | None ->
    (match Db.resolve_self_chat_guid ~db_path with
     | Ok (Some guid) -> State.record_self_chat_guid guid
     | Ok None | Error _ -> ())
;;

let start ~sw ~env ~state =
  let db_path = Db.default_db_path () in
  match Db.check_access ~db_path with
  | Error denial ->
    let detail = Db.error_to_string denial in
    State.record_startup_error detail;
    Log.Server.warn "imessage: in-process gateway not started (%s)" detail
  | Ok () ->
    (match State.configured_reply_mode (), resolved_poll_interval_sec () with
     | Error detail, _ | _, Error detail ->
       State.record_startup_error detail;
       Log.Server.error
         "imessage: configuration rejected; gateway not started (%s)" detail
     | Ok reply_mode, Ok poll_interval ->
       State.clear_startup_error ();
       let clock = Eio.Stdenv.clock env in
       refresh_self_chat_guid ~db_path;
       (match read_cursor () with
        | Error detail ->
          State.record_startup_error ("cursor unreadable: " ^ detail);
          Log.Server.error
            "imessage: cursor unreadable; gateway not started (%s)" detail
        | Ok initial_cursor ->
          let dispatch_for_delivery delivery =
            Gate_keeper_backend.accept_connector ~delivery ~clock
              ~config:(Mcp_server.workspace_config state)
          in
          Log.Server.info
            "imessage: starting in-process gateway (reply_mode=%s interval=%gs \
             cursor=%d)"
            (State.reply_mode_to_string reply_mode)
            poll_interval initial_cursor;
          Eio.Fiber.fork ~sw (fun () ->
            let rec loop cursor =
              Eio.Time.sleep clock poll_interval;
              (* Self-chat mode needs a target; the conversation may not exist
                 when the server boots, so keep looking rather than deciding
                 once at startup that replies are impossible forever. *)
              refresh_self_chat_guid ~db_path;
              match Db.read_new ~db_path ~after_rowid:cursor with
              | Error read_error ->
                State.record_poll_error (Db.error_to_string read_error);
                loop cursor
              | Ok rows ->
                let cursor, stopped =
                  process_rows ~dispatch_for_delivery ~cursor rows
                in
                (match stopped with
                 | None -> State.record_poll_ok ~cursor_rowid:cursor
                 | Some reason ->
                   State.record_poll_error reason;
                   Log.Server.warn
                     "imessage: batch stopped at cursor %d (%s)" cursor reason);
                loop cursor
            in
            try loop initial_cursor with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              let detail = Printexc.to_string exn in
              State.record_poll_error ("gateway crashed: " ^ detail);
              Log.Server.error "imessage: in-process gateway crashed: %s" detail)))
;;
