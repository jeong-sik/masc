let ( let* ) = Result.bind
type speaker = Keeper | Participant
type message = {
  id : int; at : float; who : string; speaker : speaker;
  machine : Machine_lane.t; text : string;
}
type member = { name : string; speaker : speaker; machine : Machine_lane.t; seen_at : float }
type snapshot = { messages : message list; members : member list; has_more : bool }
type error = Invalid_request of string | Conflict of string | Unavailable of string
type operation = Join | Read of int option | Say of { message_id : string; text : string } | Leave
type action = { client_id : string; machine : Machine_lane.t; operation : operation }
let history_page_size = 100
let presence_seconds = 60.
let error_message = function Invalid_request s | Conflict s | Unavailable s -> s
let speaker_name = function Keeper -> "keeper" | Participant -> "participant"
let machine_name = function Machine_lane.Msx -> "msx" | Dos -> "dos"
let machine_of_string = function
  | "msx" -> Ok Machine_lane.Msx | "dos" -> Ok Machine_lane.Dos
  | _ -> Error (Invalid_request "machine must be msx or dos")
let speaker_of_string = function
  | "keeper" -> Ok Keeper | "participant" -> Ok Participant
  | _ -> Error (Unavailable "invalid stored speaker")
let identifier field value =
  if String.length value < 1 || String.length value > 128
     || not (String.for_all (function 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' | '.' -> true | _ -> false) value)
  then Error (Invalid_request (field ^ " must be 1..128 ASCII letters, digits, dots, underscores or hyphens"))
  else Ok value

(* Unicode White_Space property. [String.trim] removes only ASCII spaces, so
   a no-break or ideographic space alone would otherwise count as text. *)
let is_white_space uchar = match Uchar.to_int uchar with
  | 0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x20 | 0x85 | 0xA0 | 0x1680
  | 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000 -> true
  | code -> code >= 0x2000 && code <= 0x200A

(* Callers check [String.is_valid_utf_8] first; an invalid byte still counts
   as content so the validity check reports it. *)
let has_non_space text =
  let rec scan index =
    index < String.length text
    && (let decoded = String.get_utf_8_uchar text index in
        (not (Uchar.utf_decode_is_valid decoded))
        || (not (is_white_space (Uchar.utf_decode_uchar decoded)))
        || scan (index + Uchar.utf_decode_length decoded)) in
  scan 0

let parse_action = function
  | `Assoc fields ->
    let get key = match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | Some _ | None -> Error (Invalid_request (key ^ " must be a string")) in
    let* name = get "action" in
    let allowed = match name with
      | "say" -> ["action"; "client_id"; "machine"; "message_id"; "text"]
      | "read" -> ["action"; "client_id"; "machine"; "before"]
      | "join" | "leave" -> ["action"; "client_id"; "machine"]
      | _ -> [] in
    if List.exists (fun (key, _) -> not (List.mem key allowed)) fields
       || List.length fields <> List.length (List.sort_uniq String.compare (List.map fst fields))
    then Error (Invalid_request "unknown or duplicate room field")
    else
      let* client_id = get "client_id" in
      let* client_id = identifier "client_id" client_id in
      let* machine = get "machine" in
      let* machine = machine_of_string machine in
      let* operation = match name with
        | "join" -> Ok Join
        | "leave" -> Ok Leave
        | "read" -> (match List.assoc_opt "before" fields with
            | None -> Ok (Read None)
            | Some (`Int n) when n > 0 -> Ok (Read (Some n))
            | Some _ -> Error (Invalid_request "before must be a positive message id"))
        | "say" ->
          let* message_id = get "message_id" in
          let* message_id = identifier "message_id" message_id in
          let* text = get "text" in
          if not (has_non_space text) || String.length text > 4096 || not (String.is_valid_utf_8 text)
          then Error (Invalid_request "text must be 1..4096 UTF-8 bytes and contain a non-space character")
          else Ok (Say {message_id; text})
        | _ -> Error (Invalid_request "action must be join, read, say or leave") in
      Ok { client_id; machine; operation }
  | _ -> Error (Invalid_request "room request must be an object")

let sql_error db rc = Unavailable ("game room storage: " ^ Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db)
let exec db sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc then Ok () else Error (sql_error db rc)
let with_stmt db sql values fn =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t)) (fun () ->
    let rec bind index = function
      | [] -> fn stmt
      | value :: rest ->
        let rc = Sqlite3.bind stmt index value in
        if Sqlite3.Rc.is_success rc then bind (index + 1) rest else Error (sql_error db rc) in
    bind 1 values)
let update db sql values = with_stmt db sql values (fun stmt ->
  match Sqlite3.step stmt with Sqlite3.Rc.DONE -> Ok () | rc -> Error (sql_error db rc))
let rows db sql values decode = with_stmt db sql values (fun stmt ->
  let rec loop acc = match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok (List.rev acc)
    | ROW -> let* row = decode stmt in loop (row :: acc)
    | rc -> Error (sql_error db rc) in
  loop [])
let schema = {|
CREATE TABLE IF NOT EXISTS messages (
 id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, who TEXT NOT NULL,
 speaker TEXT NOT NULL, machine TEXT NOT NULL, text TEXT NOT NULL,
 client_id TEXT NOT NULL, message_id TEXT NOT NULL,
 UNIQUE(who, client_id, message_id));
CREATE TABLE IF NOT EXISTS members (
 who TEXT NOT NULL, client_id TEXT NOT NULL, speaker TEXT NOT NULL,
 machine TEXT NOT NULL, seen_at REAL NOT NULL, PRIMARY KEY(who, client_id));
|}
let with_db ~base_path fn =
  let work () =
    try
      let directory = Filename.concat (Common.masc_dir_from_base_path ~base_path) "play" in
      Fs_compat.mkdir_p directory;
      let db = Sqlite3.db_open (Filename.concat directory "room.sqlite3") in
      Fun.protect ~finally:(fun () ->
        ignore (Sqlite3.db_close db : bool); ignore (Sys.opaque_identity db)) (fun () ->
        let* () = exec db "PRAGMA busy_timeout=5000" in
        let* () = exec db "PRAGMA journal_mode=WAL" in
        let* () = exec db "PRAGMA synchronous=FULL" in
        let* () = exec db schema in
        fn db)
    with
    | Sqlite3.Error message | Sys_error message -> Error (Unavailable message)
    | Unix.Unix_error (error, operation, _) -> Error (Unavailable (operation ^ ": " ^ Unix.error_message error))
  in
  match Fs_compat.execution_context () with
  | Non_eio -> work ()
  | Eio_fiber -> Eio_unix.run_in_systhread ~label:"public game room" work

let text value = Sqlite3.Data.TEXT value
let stored_machine stmt index =
  machine_of_string (Sqlite3.column_text stmt index)
  |> Result.map_error (fun error -> Unavailable (error_message error))
let snapshot db ~now ~before =
  let* messages = rows db
      "SELECT id,at,who,speaker,machine,text FROM messages WHERE (? IS NULL OR id < ?) ORDER BY id DESC LIMIT ?"
      [ (match before with None -> Sqlite3.Data.NULL | Some n -> INT (Int64.of_int n));
        (match before with None -> Sqlite3.Data.NULL | Some n -> INT (Int64.of_int n));
        INT (Int64.of_int (history_page_size + 1)) ]
      (fun stmt ->
        let* speaker = speaker_of_string (Sqlite3.column_text stmt 3) in
        let* machine = stored_machine stmt 4 in
        Ok { id = Sqlite3.column_int stmt 0; at = Sqlite3.column_double stmt 1;
             who = Sqlite3.column_text stmt 2; speaker; machine; text = Sqlite3.column_text stmt 5 }) in
  let* members = rows db
      "SELECT who,speaker,machine,MAX(seen_at) FROM members WHERE seen_at > ? GROUP BY who ORDER BY who"
      [FLOAT (now -. presence_seconds)] (fun stmt ->
        let* speaker = speaker_of_string (Sqlite3.column_text stmt 1) in
        let* machine = stored_machine stmt 2 in
        Ok {name = Sqlite3.column_text stmt 0; speaker; machine; seen_at = Sqlite3.column_double stmt 3}) in
  Ok { messages = List.rev (List.take history_page_size messages); members;
       has_more = List.length messages > history_page_size }

let transaction db fn =
  let* () = exec db "BEGIN IMMEDIATE" in
  match fn () with
  | Ok value -> let* () = exec db "COMMIT" in Ok value
  | Error error -> ignore (exec db "ROLLBACK"); Error error
  | exception ex -> ignore (exec db "ROLLBACK"); raise ex

let perform ~base_path ~who ~speaker ~now action = with_db ~base_path (fun db ->
  transaction db (fun () ->
    let* () = match action.operation with
      | Say {message_id; text = body} ->
        let* existing = rows db
            "SELECT machine,text FROM messages WHERE who=? AND client_id=? AND message_id=?"
            [text who; text action.client_id; text message_id]
            (fun stmt -> Ok (Sqlite3.column_text stmt 0, Sqlite3.column_text stmt 1)) in
        (match existing with
         | [] -> update db
             "INSERT INTO messages(at,who,speaker,machine,text,client_id,message_id) VALUES (?,?,?,?,?,?,?)"
             [FLOAT now; text who; text (speaker_name speaker); text (machine_name action.machine);
              text body; text action.client_id; text message_id]
         | [(machine, previous)] when machine = machine_name action.machine && previous = body -> Ok ()
         | _ -> Error (Conflict "message_id already names a different message; keep the original id only for an identical retry"))
      | Join | Read _ | Leave -> Ok () in
    let* () = match action.operation with
      | Leave -> update db "DELETE FROM members WHERE who=? AND client_id=?" [text who; text action.client_id]
      | Join | Read _ | Say _ -> update db
          "INSERT INTO members(who,client_id,speaker,machine,seen_at) VALUES (?,?,?,?,?) ON CONFLICT(who,client_id) DO UPDATE SET speaker=excluded.speaker,machine=excluded.machine,seen_at=excluded.seen_at"
          [text who; text action.client_id; text (speaker_name speaker); text (machine_name action.machine); FLOAT now] in
    let* () = update db "DELETE FROM members WHERE seen_at <= ?" [FLOAT (now -. presence_seconds)] in
    snapshot db ~now ~before:(match action.operation with Read before -> before | Join | Say _ | Leave -> None)))

let read ~base_path ~now ~before =
  match before with
  | Some n when n <= 0 -> Error (Invalid_request "before must be a positive message id")
  | None | Some _ -> with_db ~base_path (fun db -> snapshot db ~now ~before)

let snapshot_json ?viewer snapshot = `Assoc ((match viewer with
  | None -> [] | Some name -> ["viewer", `String name]) @ [
  "messages", `List (List.map (fun (m : message) -> `Assoc [
    "id", `Int m.id; "at", `Float m.at; "who", `String m.who;
    "speaker", `String (speaker_name m.speaker); "machine", `String (machine_name m.machine);
    "text", `String m.text]) snapshot.messages);
  "members", `List (List.map (fun (m : member) -> `Assoc [
    "name", `String m.name; "speaker", `String (speaker_name m.speaker);
    "machine", `String (machine_name m.machine); "seen_at", `Float m.seen_at]) snapshot.members);
  "has_more", `Bool snapshot.has_more;
  "presence_seconds", `Float presence_seconds;
])

let snapshot_of_json json =
  let field key = function
    | `Assoc fields -> (match List.assoc_opt key fields with
        | Some value -> Ok value | None -> Error ("missing room field " ^ key))
    | _ -> Error "room value must be an object" in
  let string = function `String s -> Ok s | _ -> Error "room string expected" in
  let number = function
    | `Float n when Float.is_finite n -> Ok n
    | `Int n -> Ok (float_of_int n)
    | _ -> Error "room timestamp expected" in
  let bool = function `Bool b -> Ok b | _ -> Error "room boolean expected" in
  let rec list decode = function
    | [] -> Ok []
    | row :: rest -> let* row = decode row in let* rest = list decode rest in Ok (row :: rest) in
  let array decode = function `List rows -> list decode rows | _ -> Error "room array expected" in
  let speaker json = let* value = field "speaker" json in let* value = string value in
    speaker_of_string value |> Result.map_error error_message in
  let machine json = let* value = field "machine" json in let* value = string value in
    machine_of_string value |> Result.map_error error_message in
  let message json =
    let* id = field "id" json in
    let* id = match id with `Int n when n > 0 -> Ok n | _ -> Error "room message id expected" in
    let* at = field "at" json in let* at = number at in
    let* who = field "who" json in let* who = string who in
    let* text = field "text" json in let* text = string text in
    let* speaker = speaker json in let* machine = machine json in
    Ok {id; at; who; text; speaker; machine} in
  let member json =
    let* name = field "name" json in let* name = string name in
    let* seen_at = field "seen_at" json in let* seen_at = number seen_at in
    let* speaker = speaker json in let* machine = machine json in
    Ok {name; seen_at; speaker; machine} in
  let* messages = field "messages" json in let* messages = array message messages in
  let* members = field "members" json in let* members = array member members in
  let* has_more = field "has_more" json in let* has_more = bool has_more in
  Ok {messages; members; has_more}

let view_of_json json =
  let* viewer = match json with
    | `Assoc fields -> (match List.assoc_opt "viewer" fields with
        | Some (`String viewer) when viewer <> "" -> Ok viewer
        | _ -> Error "authenticated room viewer is missing or malformed")
    | _ -> Error "room view must be an object" in
  let* snapshot = snapshot_of_json json in
  Ok (viewer, snapshot)
