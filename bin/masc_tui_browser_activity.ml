type owner = { workspace : string * string; lane : Browser_lane.Lane_name.t }
type document = Masc_tui_runtime_config_edit.document
type write = { source_text : string; expected_source_revision : string; expected_source_path : string }
type draft = { base : document; desired : bool }
type phase = Idle | Reading of int | Writing of int
type t = {
  owner : owner; draft : draft option; current : document option;
  phase : phase; message : string option; receipt : Masc_tui_runtime_config_receipt.t option;
}
type operation = Read | Save of write
type request = { owner : owner; generation : int; operation : operation }
type write_result =
  | Saved of Masc_tui_runtime_config_receipt.t
  | Conflict of document
  | Refused of string
  | Unconfirmed of string
let ( let* ) = Result.bind
let same_owner a b = a.workspace = b.workspace && a.lane = b.lane
let owner (t : t) = t.owner
let request_owner (request : request) = request.owner
let busy t = match t.phase with Idle -> false | Reading _ | Writing _ -> true
let create owner = {owner;draft=None;current=None;phase=Idle;message=None;receipt=None}
let browser_table = Runtime_toml_namespace.(key Browser)
let path lane = [browser_table;Browser_lane.Lane_name.to_wire lane]
let table lane = String.concat "." (List.map Toml_line_editor.render_key (path lane))

(* The same pure parser owns Browser settings here and on the server. The
   server's preview and CAS commit still validate the complete Runtime file. *)
let configuration (document : document) =
  try
    let* toml = Otoml.Parser.from_string_result document.source_text in
    let* config = Browser_configuration.parse toml in
    Ok (toml, config)
  with Otoml.Duplicate_key detail | Otoml.Type_error detail -> Error detail
let configured_activity lane (config : Browser_configuration.t) = match lane with
  | Browser_lane.Lane_name.Live -> config.live_enabled
  | Automation -> config.automation_enabled
  | Stagehand -> config.stagehand_enabled
let activity lane document =
  let* _, config = configuration document in
  Ok (configured_activity lane config)
let with_activity lane desired (config : Browser_configuration.t) = match lane with
  | Browser_lane.Lane_name.Live -> {config with live_enabled=desired}
  | Automation -> {config with automation_enabled=desired}
  | Stagehand -> {config with stagehand_enabled=desired}

(* The key path a key spells, read by the TOML grammar the way it reads a
   header: quoting, escapes and whitespace around dots are the parser's. *)
let key_path text = match Toml_line_editor.header_of_line ("[" ^ text ^ "]") with
  | Some (Toml_line_editor.Table path) -> Some path
  | Some (Toml_line_editor.Table_array _) | None -> None

(* A [key = value] line split around its key: where the key starts, its text,
   the path it spells and where it ends. The separator is the first '=' that
   closes a well-formed key, so an '=' inside a quoted key is not it. *)
let assignment line =
  let length = String.length line in
  let rec indent i =
    if i < length && (line.[i] = ' ' || line.[i] = '\t') then indent (i + 1) else i in
  let start = indent 0 in
  let rec separator from = match String.index_from_opt line from '=' with
    | None -> None
    | Some at ->
      let key = String.trim (String.sub line start (at - start)) in
      (match key_path key with
       | Some path when key <> "" -> Some (start, key, path, start + String.length key)
       | Some _ | None -> separator (at + 1)) in
  if start < length then separator start else None

(* [key] spells [prefix @ [name]]. Put [automation] before [name], keeping
   every segment as the operator spelled it. *)
let before_last_segment key path =
  match List.rev path with
  | [] -> None
  | [_] -> Some ("automation." ^ key)
  | name :: reversed_prefix ->
    let prefix = List.rev reversed_prefix in
    let rec split from =
      if from < 0 then None else
      match String.rindex_from_opt key from '.' with
      | None -> None
      | Some dot ->
        let head = String.sub key 0 dot in
        let tail = String.trim (String.sub key (dot + 1) (String.length key - dot - 1)) in
        if key_path (String.trim head) = Some prefix && key_path tail = Some [name]
        then Some (head ^ ".automation." ^ tail)
        else split (dot - 1) in
    split (String.length key - 1)

(* Flat Browser paths move under [automation] before its flag is written.
   They are found by the key path each assignment declares -- the table it
   sits in followed by its own dotted key -- so [geckodriver] under a
   [\[browser\]] header and a root [browser.geckodriver] are the same path,
   as they are to [Browser_configuration.parse]. *)
let qualify_automation_paths source =
  let lines, trailing_newline = Toml_line_editor.split_lines source in
  let qualify table line = match table, assignment line with
    | Some table, Some (start, key, path, key_end) ->
      (match table @ path with
       | [ browser; ("geckodriver" | "binary") ] when String.equal browser browser_table ->
         (match before_last_segment key path with
          | Some key ->
            String.sub line 0 start ^ key
            ^ String.sub line key_end (String.length line - key_end)
          | None -> line)
       | _ -> line)
    | None, _ | _, None -> line in
  (* [None] inside an array of tables: no Browser path lives there. *)
  let _, reversed = List.fold_left2 (fun (table, acc) line structural ->
    if not structural then table, line :: acc
    else match Toml_line_editor.header_of_line line with
      | Some (Toml_line_editor.Table path) -> Some path, line :: acc
      | Some (Toml_line_editor.Table_array _) -> None, line :: acc
      | None -> table, qualify table line :: acc)
    (Some [], []) lines (Toml_line_editor.structural_lines lines) in
  Toml_line_editor.join_lines (List.rev reversed) ~trailing_newline

let apply desired lane (document : document) =
  let* toml, config = configuration document in
  let* source_text = match lane, config.automation with
    | Browser_lane.Lane_name.Automation, Some _
      when Option.is_some (Otoml.find_opt toml Fun.id [browser_table;"geckodriver"]) ->
        (* Qualify the original assignments in place: value spelling, inline
           comments and adjacent operator notes remain attached to their keys.
           Dotted keys declare automation, so add its flag through the nested
           editor rather than redeclaring it with a new table header. *)
        Toml_line_editor.edit_nested_bool (qualify_automation_paths document.source_text)
          ~path:(path lane) ~key:"enabled" ~value:desired
        |> Result.map_error (fun _ ->
          "Browser paths could not be preserved; use the Runtime source editor.")
    | (Live | Automation | Stagehand), _ ->
        (match Otoml.find_opt toml Fun.id (path lane) with
         | Some (Otoml.TomlTable _) ->
             (* A previously qualified path remains a dotted table on later
                toggles; do not redeclare that table with a new header. *)
             Toml_line_editor.edit_nested_bool document.source_text
               ~path:(path lane) ~key:"enabled" ~value:desired
             |> Result.map_error (fun _ -> "Browser activity requires the Runtime source editor.")
         | Some _ | None ->
             Ok (Toml_line_editor.edit_table_bool document.source_text
               ~path:(table lane) ~key:"enabled" ~value:desired)) in
  match configuration {document with source_text} with
  | Error _ -> Error "Inline or dotted Browser settings require the Runtime source editor; no file was changed."
  | Ok (_, observed) ->
      if Browser_configuration.equal observed (with_activity lane desired config)
      then Ok source_text
      else Error "The edit did not preserve the Browser configuration; use the Runtime source editor."

let suspend t = {t with phase=Idle;current=None;message=Some
  (match t.phase with Writing _ -> "Save result unconfirmed after workspace change. Read current before retrying."
   | Idle | Reading _ -> "Workspace reading withdrawn; activity draft retained.")}
let matches (request : request) (t : t) = same_owner request.owner t.owner &&
  match request.operation, t.phase with
  | Read, Reading generation | Save _, Writing generation -> generation=request.generation
  | Read, (Idle | Writing _) | Save _, (Idle | Reading _) -> false
let start_read ~generation t =
  if busy t then None else
    Some ({t with phase=Reading generation;current=None;message=None},
      {owner=t.owner;generation;operation=Read})
let finish_read request result t =
  if not (matches request t) then t else
  let t = {t with phase=Idle;current=None} in
  match result with
  | Error detail -> {t with message=Some (detail ^ " · draft retained")}
  | Ok current ->
    (match activity t.owner.lane current with
     | Error detail -> {t with message=Some detail}
     | Ok enabled ->
       let retain = match t.draft with
         | None -> false
         | Some draft -> draft.base.path <> current.path ||
           (match activity t.owner.lane draft.base with
            | Error _ -> true
            | Ok base_enabled -> draft.desired <> base_enabled) in
       (* Saving requires a changed value. An unconfirmed write keeps that
          original base, so this read retains the intended change. A later
          explicit edit, reapply or discard can resolve the retained intent. *)
       let draft = if retain then t.draft else Some {base=current;desired=enabled} in
       {t with draft;current=Some current;message=None})
(* How the draft's base relates to the current file. A different path is
   another document even when its bytes and revision match, so u cannot carry
   the draft across; only x starts over on the new file. Every gate and
   message below reads this one classification. *)
type base_relation = Same_document | File_changed | Other_file
let base_relation (draft : draft) (current : document) =
  if draft.base.path <> current.path then Other_file
  else if draft.base.source_revision <> current.source_revision then File_changed
  else Same_document
let path_changed_guidance =
  "The configuration file path changed. x discards this draft to edit the new file; u cannot reapply across files."
let file_changed_guidance =
  "File changed. u reapplies only activity to current settings; x discards the draft."
let relation_guidance = function
  | Same_document -> None
  | File_changed -> Some file_changed_guidance
  | Other_file -> Some path_changed_guidance

let ready t =
  if busy t then Error "A request is pending." else
  match t.draft,t.current with
  | Some draft, Some current ->
    (match base_relation draft current with
     | Other_file -> Error path_changed_guidance
     | Same_document | File_changed -> Ok (draft,current))
  | None, _ | _, None -> Error "Read the current configuration before editing or saving."
let toggle t = match ready t with
  | Error detail -> {t with message=Some detail}
  | Ok (draft, _) ->
    (match apply (not draft.desired) t.owner.lane draft.base with
     | Error detail -> {t with message=Some detail}
     | Ok _ -> {t with draft=Some {draft with desired=not draft.desired};message=None;receipt=None})
let reapply t = match ready t with
  | Error detail -> {t with message=Some detail}
  | Ok (draft,current) ->
    (match apply draft.desired t.owner.lane current, activity t.owner.lane current with
     | Error detail, _ | _, Error detail -> {t with message=Some detail}
     | Ok _, Ok enabled ->
       (* Saving requires a changed value, so a file that already holds the
          desired activity leaves nothing for s to save. *)
       let message = if enabled=draft.desired
         then "Current settings already have this activity. Nothing to save."
         else "Activity reapplied to current settings. s saves explicitly." in
       {t with draft=Some {draft with base=current};message=Some message})
let discard t =
  if busy t then {t with message=Some "A request is pending."} else
  match t.current with
  | None -> {t with draft=None;message=Some "Draft discarded. r reads current settings."}
  | Some current ->
    (match activity t.owner.lane current with
     | Error detail -> {t with draft=None;message=Some detail}
     | Ok enabled -> {t with draft=Some {base=current;desired=enabled};message=Some "Draft discarded; no file was written.";receipt=None})
let start_save ~generation t =
  let* draft,current = ready t in
  let* () = match base_relation draft current with
    | File_changed -> Error "File changed. u reapplies only this activity to current settings; s then saves."
    | Same_document | Other_file -> Ok () in
  let* was_enabled = activity t.owner.lane draft.base in
  let* () = if was_enabled=draft.desired then Error "No activity change to save." else Ok () in
  let* source_text = apply draft.desired t.owner.lane draft.base in
  let write = {source_text;expected_source_revision=draft.base.source_revision;expected_source_path=draft.base.path} in
  (* A receipt describes the previous attempt. Kept beside this one, it would
     read as this save's result after a refusal or conflict. *)
  Ok ({t with phase=Writing generation;message=None;receipt=None},
      {owner=t.owner;generation;operation=Save write},write)
let finish_save request result t =
  if not (matches request t) then t else
  let t = {t with phase=Idle} in
  match request.operation,result with
  | Save write,Saved receipt ->
    let draft = match t.draft,receipt.Masc_tui_runtime_config_receipt.durability with
      | Some draft, Durable -> Some {draft with base={draft.base with source_text=write.source_text;source_revision=receipt.source_revision}}
      | (Some _ | None), Durability_unconfirmed | None, Durable -> t.draft in
    {t with draft;current=None;receipt=Some receipt;
      message=Some "Write receipt received. Read current settings before editing again."}
  | Save _,Conflict current ->
    let message = match t.draft with
      | Some draft when base_relation draft current = Other_file -> path_changed_guidance
      | Some _ | None -> "File changed; draft retained. u reapplies activity to the current file." in
    {t with current=Some current;message=Some message}
  | Save _,Refused detail -> {t with message=Some detail}
  | Save _,Unconfirmed detail -> {t with current=None;message=Some (detail ^ " · read current before retrying")}
  | Read,_ -> t
let lines (t : t) =
  let flag value = if value then "On" else "Off" in
  let label = Browser_lane.Lane_name.to_wire t.owner.lane in
  let current = match t.current with
    | None -> ["Current file: unverified"]
    | Some document ->
      (match activity t.owner.lane document with
       | Error detail -> [detail]
       | Ok enabled -> [document.path; "Current file: " ^ flag enabled]) in
  let draft = match t.draft with None -> [] | Some draft ->
    ["Activity draft: " ^ flag draft.desired;
     "Based on revision: " ^ draft.base.source_revision] in
  let conflict = match t.draft,t.current with
    | Some draft,Some current -> Option.to_list (relation_guidance (base_relation draft current))
    | None,_ | _,None -> [] in
  ["Browser activity · " ^ label;
   "Off stops new reads and actions; accepted work finishes. Configuration and sessions remain.";
   (match t.owner.lane with
    | Browser_lane.Lane_name.Live -> "Live is client-owned; server session status and close controls are unavailable."
    | Automation | Stagehand -> "Server session status and close remain available while off.")]
  @ current @ draft @ conflict
  @ (match t.phase with Idle -> [] | Reading _ -> ["Reading current configuration…"] | Writing _ -> ["Saving activity…"])
  @ Option.to_list t.message
  @ (match t.receipt with None -> [] | Some receipt -> [Masc_tui_runtime_config_receipt.lane_summary receipt])
  @ ["Space change draft · s save · r read current · u reapply · x discard · Esc back";
     "Activity follows saved settings. Executable, extension and profile paths require a server restart.";
     "On does not install an absent executor or open a browser session."]
