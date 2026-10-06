type document = {
  file_name : string; source_path : string; source_text : string;
  source_revision : string; desired_revision : string option;
  valid : bool; messages : string list;
}
type failure_code = Invalid_request | Not_found | Revision_conflict | Invalid_declaration | Io_error
type failure = { code : failure_code; message : string; current : document option }
type write_state = Created | Saved | Unchanged
type durability = Durable | Unconfirmed of string
type receipt = { document : document; state : write_state; durability : durability }
type session = {
  file_name : string; base : document option; current : document option;
  text : string; message : string option;
}
type request = Read of string | Save of session
type response = Read_document of document | Written of receipt | Rejected of failure
let template = "enabled = true\nid = \"\"\nrun_id = \"\"\nmanifest_path = \"\"\n\n[binding]\nsources = []\n"
let ( let* ) = Result.bind
let field name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some value -> Ok value | None -> Error ("missing " ^ name))
  | _ -> Error "expected object"
let text = function `String value -> Ok value | _ -> Error "expected string"
let nonempty json = let* value = text json in if String.trim value = "" then Error "expected non-blank string" else Ok value
let boolean = function `Bool value -> Ok value | _ -> Error "expected boolean"
let nullable parse = function `Null -> Ok None | value -> Result.map Option.some (parse value)
let get parse name json = let* value = field name json in parse value
let rec texts = function
  | `List [] -> Ok []
  | `List (head :: tail) -> let* head = text head in let* tail = texts (`List tail) in Ok (head :: tail)
  | _ -> Error "expected string array"
let document json =
  let* file_name = get nonempty "file_name" json in
  let* source_path = get nonempty "source_path" json in
  let* source_text = get text "source_text" json in
  let* source_revision = get nonempty "source_revision" json in
  let* desired_revision = get (nullable nonempty) "desired_revision" json in
  let* validation = field "validation" json in
  let* valid = get boolean "valid" validation in
  let* messages = get texts "messages" validation in
  Ok {file_name;source_path;source_text;source_revision;desired_revision;valid;messages}
let receipt json =
  let* document = get document "document" json in
  let* write = field "write" json in
  let* state = get (function `String "created" -> Ok Created | `String "saved" -> Ok Saved
    | `String "unchanged" -> Ok Unchanged | _ -> Error "unknown declaration write state") "state" write in
  let* detail = get (nullable text) "detail" write in
  let* durability = get (function
    | `String "durable" when detail = None -> Ok Durable
    | `String "unconfirmed" -> (match detail with Some detail -> Ok (Unconfirmed detail) | None -> Error "missing durability detail")
    | _ -> Error "unknown declaration durability") "durability" write in
  let* application = get text "application" json in
  if application <> "pending_reconciliation" then Error "unknown declaration application state"
  else Ok {document;state;durability}
let failure json =
  let* code = get (function
    | `String "invalid_request" -> Ok Invalid_request | `String "not_found" -> Ok Not_found
    | `String "revision_conflict" -> Ok Revision_conflict | `String "invalid_declaration" -> Ok Invalid_declaration
    | `String "io_error" -> Ok Io_error | _ -> Error "unknown declaration error code") "code" json in
  let* message = get text "error" json in
  let* current = get (nullable document) "current" json in
  Ok {code;message;current}
let create file_name =
  if String.trim file_name = "" || file_name <> Filename.basename file_name
    || String.contains file_name '\\' || String.contains file_name '\000'
    || String.length file_name < String.length ".toml" || not (Filename.check_suffix file_name ".toml")
  then Error "Choose one direct-child .toml filename"
  else Ok {file_name;base=None;current=None;text=template;message=None}
let editable_source_path ~directory source_path =
  let file_name = Filename.basename source_path in
  source_path=Filename.concat directory file_name && Result.is_ok (create file_name)
let find_for_path ?create_directory ~path sessions =
  match List.find_opt (fun (session : session) ->
    session.file_name = Filename.basename path) sessions with
  | None -> Ok None
  | Some session ->
      let source = match session.base with
        | Some base -> Some base.source_path
        | None -> Option.map (fun (current : document) -> current.source_path) session.current in
      (match source with
       | Some source when source = path -> Ok (Some session)
       | Some source -> Error ("Draft retained for " ^ source
           ^ "; it cannot be opened as " ^ path)
       | None when Option.exists (fun directory ->
           path = Filename.concat directory session.file_name) create_directory -> Ok (Some session)
       | None -> Error ("Create-only draft " ^ session.file_name
           ^ " retained; it cannot be opened as " ^ path))
let from_document (document : document) =
  {file_name=document.file_name;base=Some document;current=Some document;text=document.source_text;message=None}
let write_json (session : session) =
  `Assoc (["file_name",`String session.file_name;"source_text",`String session.text] @
    match session.base with
    | None -> ["mode",`String "create"]
    | Some base -> ["mode",`String "save";"expected_source_revision",`String base.source_revision])
let matches request (document : document) = match request with
  | Read path -> document.source_path = path
  | Save session -> document.file_name = session.file_name
      && (match session.base with None -> true | Some base -> document.source_path = base.source_path)
let decode_response request ~status ~body =
  let* json = try Ok (Yojson.Safe.from_string body) with Yojson.Json_error detail -> Error detail in
  if status >= 200 && status < 300 then
    match request with
    | Read _ -> let* document = document json in
        if matches request document then Ok (Read_document document)
        else Error "The returned TOML does not match the requested path"
    | Save session -> let* receipt = receipt json in
        if matches request receipt.document && receipt.document.source_text = session.text
        then Ok (Written receipt)
        else Error "The receipt does not match the submitted TOML; read the current file before saving again"
  else
    let* failure = match failure json with
      | Ok failure -> Ok failure
      | Error _ -> Error (Printf.sprintf "HTTP %d: %s" status body) in
    match failure.current with
    | Some document when not (matches request document) -> Error "The conflict TOML does not match the requested file"
    | Some _ | None -> Ok (Rejected failure)
let write_summary receipt =
  (match receipt.state with Created -> "Created" | Saved -> "Saved" | Unchanged -> "Unchanged")
  ^ (match receipt.durability with Durable -> " · durable" | Unconfirmed detail -> " · durability unconfirmed: " ^ detail)
  ^ " · pending reconciliation (r inspects application)"
let after_response (session : session) = function
  | Read_document document -> {session with current=Some document;
      message=Some "Current file loaded; draft preserved. u uses this revision; U replaces the draft."}
  | Written receipt -> {session with base=Some receipt.document;current=Some receipt.document;
      message=Some (write_summary receipt)}
  | Rejected failure -> {session with current=failure.current;message=Some failure.message}
let use_current_revision session = match session.current with
  | None -> Error "Read the current file first (l)"
  | Some current -> Ok {session with base=Some current;message=Some "Current revision selected; draft preserved. s saves explicitly."}
let replace_with_current session = match session.current with
  | None -> Error "Read the current file first (l)"
  | Some current -> Ok {session with base=Some current;text=current.source_text;
      message=Some "Draft replaced with the current file; E edits TOML."}
let parse_source text =
  try match Otoml.Parser.from_string_result text with
    | Ok (Otoml.TomlTable fields) -> Ok fields
    | Ok _ -> Error "Declaration requires a TOML table"
    | Error detail -> Error detail
  with Otoml.Duplicate_key detail -> Error detail
let draft_enabled (session : session) =
  let* fields = parse_source session.text in
  match List.assoc_opt "enabled" fields with
  | None -> Ok true
  | Some (Otoml.TomlBoolean enabled) -> Ok enabled
  | Some _ -> Error "enabled requires a boolean; repair the draft with E"
let toggle_enabled (session : session) =
  let* enabled = draft_enabled session in
  let text = Toml_line_editor.edit_root_bool session.text ~key:"enabled" ~value:(not enabled) in
  let changed = {session with text} in
  let* observed = draft_enabled changed in
  if observed = enabled then Error "The draft enabled key did not change"
  else Ok {changed with message=Some
    ((if observed then "Enable" else "Disable")
     ^ " staged in draft; s saves. Actual worker state is read with r after saving.")}
let summary (session : session) =
  ["TOML draft " ^ session.file_name;
   (match draft_enabled session with
    | Ok true -> "Draft: enabled · saved configuration and worker state are separate"
    | Ok false -> "Draft: disabled · save requests worker cleanup and keeps this file"
    | Error detail -> "Draft activity unknown: " ^ detail);
   " Space:on/off draft  E:edit  s:save  l:read current  u:use current revision  U:replace draft  Esc:back (draft kept)";
   (match session.base with None -> "Create only; no existing file will be overwritten"
    | Some base -> "Base " ^ base.source_revision ^ " · " ^ base.source_path)]
  @ (match session.message with None -> [] | Some message -> [message])
  @ (match session.current with None -> [] | Some current ->
      ["Current " ^ current.source_revision ^ " · " ^ (if current.valid then "valid TOML declaration" else "invalid declaration")]
      @ current.messages
      @ ["Current file text (u keeps the draft; U replaces it)"]
      @ String.split_on_char '\n' current.source_text)
  @ ["Draft text"] @ String.split_on_char '\n' session.text
