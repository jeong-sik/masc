(* Imessage_chat_db — the only place that opens Messages.app's chat.db.

   Two queries, both lifted verbatim from the sidecar this module replaces
   (sidecars/imessage-bot/src/imessage_bridge.py). They are copied rather than
   rewritten on purpose: the schema belongs to Apple, the sidecar's version was
   working against the real database, and a port is the wrong moment to also
   change what gets selected. *)

type error =
  | Db_missing of string
  | Access_denied of string
  | Query_failed of string

let error_to_string = function
  | Db_missing path -> Printf.sprintf "chat.db not found at %s" path
  | Access_denied path ->
    Printf.sprintf
      "chat.db at %s is not readable: grant Full Disk Access in System \
       Settings > Privacy & Security > Full Disk Access"
      path
  | Query_failed detail -> Printf.sprintf "chat.db read failed: %s" detail
;;

type inbound_row =
  { rowid : int
  ; text : string
  ; sent_at_unix : float
  ; service : string
  ; sender : string
  ; chat_guid : string
  ; chat_identifier : string
  ; display_name : string
  }

(* 2001-01-01T00:00:00Z in Unix seconds. Apple's Core Data epoch. *)
let apple_epoch_unix = 978_307_200.

let apple_ns_to_unix ns = apple_epoch_unix +. (Int64.to_float ns /. 1e9)

let redact_chat_guid raw =
  let value = String.trim raw in
  if String.equal value "" then ""
  else
    match List.rev (String.split_on_char ';' value) with
    | _addressable_tail :: rev_prefix when rev_prefix <> [] ->
      String.concat ";" (List.rev rev_prefix) ^ ";[redacted]"
    | _ -> "[redacted]"
;;

let default_db_path () = Env_config_imessage.chat_db_path ()

(* Excludes what this account sent, empty bodies, and SMS. The LIMIT bounds one
   poll; the cursor carries the rest to the next one. *)
let poll_sql =
  {sql|
SELECT DISTINCT
    m.ROWID,
    m.text,
    m.date,
    m.service,
    h.id AS handle_id,
    c.guid AS chat_guid,
    c.chat_identifier,
    c.display_name
FROM message m
LEFT JOIN handle h ON m.handle_id = h.ROWID
LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN chat c ON cmj.chat_id = c.ROWID
WHERE m.ROWID > ?
  AND m.is_from_me = 0
  AND m.text IS NOT NULL
  AND m.text != ''
  AND m.service = 'iMessage'
ORDER BY m.ROWID ASC
LIMIT 100
|sql}
;;

(* Messages stores the account's own addresses with an "E:"/"P:" kind prefix
   (email / phone). A note-to-self chat is one whose identifier equals one of
   those addresses with the prefix stripped. *)
let self_chat_sql =
  {sql|
WITH own_aliases AS (
    SELECT DISTINCT
        trim(
            CASE
                WHEN account_login LIKE 'E:%' OR account_login LIKE 'P:%'
                    THEN substr(account_login, 3)
                ELSE account_login
            END
        ) AS alias
    FROM chat
    WHERE service_name = 'iMessage'
      AND account_login IS NOT NULL
      AND trim(account_login) != ''
),
self_chats AS (
    SELECT
        c.guid AS chat_guid,
        max(coalesce(m.date, 0)) AS last_date,
        count(m.ROWID) AS msg_count
    FROM chat c
    JOIN own_aliases a ON c.chat_identifier = a.alias
    LEFT JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
    LEFT JOIN message m ON m.ROWID = cmj.message_id
    WHERE c.service_name = 'iMessage'
    GROUP BY c.ROWID
)
SELECT chat_guid
FROM self_chats
WHERE trim(chat_guid) != ''
ORDER BY last_date DESC, msg_count DESC
LIMIT 1
|sql}
;;

(* Full Disk Access shows up as EPERM from access(2), which is a typed answer.
   Reading it here rather than matching on SQLite's message keeps the denial
   distinguishable from every other way an open can fail. *)
let readable path =
  match Unix.access path [ Unix.R_OK ] with
  | () -> true
  | exception Unix.Unix_error _ -> false
;;

let check_access ~db_path =
  if not (Sys.file_exists db_path) then Error (Db_missing db_path)
  else if not (readable db_path) then Error (Access_denied db_path)
  else Ok ()
;;

let with_db ~db_path f =
  match check_access ~db_path with
  | Error denial -> Error denial
  | Ok () -> (
    match Sqlite3.db_open ~mode:`READONLY db_path with
    | exception Sqlite3.Error detail -> Error (Query_failed ("open: " ^ detail))
    | db ->
      let result =
        try f db with
        | Sqlite3.Error detail -> Error (Query_failed detail)
      in
      (* The statement is finalized inside [f]; if it were not, this returns
         false and the handle leaks rather than the error being hidden. *)
      if not (Sqlite3.db_close db) then
        Log.Gate.warn "imessage: chat.db handle still had live statements";
      (* See Keeper_chat_operation_store.close_db — sqlite3-ocaml releases the
         OCaml runtime during the close and nulls the handle only after it
         reacquires it, so the wrapper has to stay reachable past the call or
         another domain's GC finalizer can close the same pointer. *)
      ignore (Sys.opaque_identity db);
      result)
;;

let with_statement db sql f =
  match Sqlite3.prepare db sql with
  | exception Sqlite3.Error detail -> Error (Query_failed ("prepare: " ^ detail))
  | stmt ->
    let result =
      try f stmt with
      | Sqlite3.Error detail -> Error (Query_failed detail)
    in
    let finalized =
      match Sqlite3.finalize stmt with
      | rc -> Sqlite3.Rc.is_success rc
      | exception Sqlite3.Error _ -> false
    in
    (* See Keeper_chat_operation_store.finalize — sqlite3-ocaml clears the
       statement pointer only after it reacquires the OCaml runtime, so the
       wrapper has to stay reachable past finalize for the same reason. *)
    ignore (Sys.opaque_identity stmt);
    (match result with
     | Error _ as error -> error
     | Ok _ when not finalized -> Error (Query_failed "finalize statement")
     | Ok _ as ok -> ok)
;;

(* [Sqlite3.Rc.t] carries 31 constructors, so a three-arm pattern match needs a
   catch-all and trips this library's fragile-match ratchet. Comparing against
   the two codes that mean something here says the same thing without asking
   the compiler to police an external vocabulary we do not own. *)
let fold_rows stmt ~decode =
  let rec loop acc =
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.ROW then loop (decode stmt :: acc)
    else if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
    else Error (Query_failed ("step: " ^ Sqlite3.Rc.to_string rc))
  in
  loop []
;;

let decode_inbound stmt =
  { rowid = Sqlite3.column_int stmt 0
  ; text = Sqlite3.column_text stmt 1
  ; sent_at_unix = apple_ns_to_unix (Sqlite3.column_int64 stmt 2)
  ; service = Sqlite3.column_text stmt 3
  ; sender = Sqlite3.column_text stmt 4
  ; chat_guid = Sqlite3.column_text stmt 5
  ; chat_identifier = Sqlite3.column_text stmt 6
  ; display_name = Sqlite3.column_text stmt 7
  }
;;

let read_new ~db_path ~after_rowid =
  with_db ~db_path (fun db ->
    with_statement db poll_sql (fun stmt ->
      let rc = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int after_rowid)) in
      if not (Sqlite3.Rc.is_success rc) then
        Error (Query_failed ("bind cursor: " ^ Sqlite3.Rc.to_string rc))
      else fold_rows stmt ~decode:decode_inbound))
;;

let resolve_self_chat_guid ~db_path =
  with_db ~db_path (fun db ->
    with_statement db self_chat_sql (fun stmt ->
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.ROW then (
        let guid = String.trim (Sqlite3.column_text stmt 0) in
        Ok (if String.equal guid "" then None else Some guid))
      else if rc = Sqlite3.Rc.DONE then Ok None
      else Error (Query_failed ("step: " ^ Sqlite3.Rc.to_string rc))))
;;
