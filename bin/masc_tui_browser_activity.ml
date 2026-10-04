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

let apply desired lane (document : document) =
  let* toml, config = configuration document in
  (* During the accepted transition, setting automation.enabled also moves
     root automation paths into its canonical table. Other Browser backends
     and unrelated Runtime settings stay in their original locations. *)
  let source = match lane, config.automation with
    | Browser_lane.Lane_name.Automation, Some {driver;binary}
      when Option.is_some (Otoml.find_opt toml Fun.id [browser_table;"geckodriver"]) ->
        let source = Toml_line_editor.edit_table_scalar document.source_text
          ~path:browser_table ~key:"geckodriver" ~value:None in
        let source = Toml_line_editor.edit_table_scalar source
          ~path:browser_table ~key:"binary" ~value:None in
        let source = Toml_line_editor.edit_table_scalar source
          ~path:(table lane) ~key:"geckodriver" ~value:(Some driver) in
        (match binary with None -> source | Some value ->
          Toml_line_editor.edit_table_scalar source ~path:(table lane) ~key:"binary" ~value:(Some value))
    | (Live | Automation | Stagehand), _ -> document.source_text in
  let source_text = Toml_line_editor.edit_table_bool source ~path:(table lane) ~key:"enabled" ~value:desired in
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
let ready t =
  if busy t then Error "A request is pending." else
  match t.draft,t.current with
  | Some draft, Some current when draft.base.path=current.path -> Ok (draft,current)
  | Some _, Some _ -> Error "The configuration file path changed. Discard this draft before editing the new file."
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
    (match apply draft.desired t.owner.lane current with
     | Error detail -> {t with message=Some detail}
     | Ok _ -> {t with draft=Some {draft with base=current};message=Some "Activity reapplied to current settings. s saves explicitly."})
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
  let* () = if draft.base.source_revision<>current.source_revision
    then Error "File changed. u reapplies only this activity to current settings; s then saves."
    else Ok () in
  let* was_enabled = activity t.owner.lane draft.base in
  let* () = if was_enabled=draft.desired then Error "No activity change to save." else Ok () in
  let* source_text = apply draft.desired t.owner.lane draft.base in
  let write = {source_text;expected_source_revision=draft.base.source_revision;expected_source_path=draft.base.path} in
  Ok ({t with phase=Writing generation;message=None},
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
  | Save _,Conflict current -> {t with current=Some current;message=Some "File changed; draft retained. u reapplies activity to the current file."}
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
    | Some draft,Some current when draft.base.source_revision<>current.source_revision ->
      ["File changed. u reapplies only activity to current settings; x discards the draft."]
    | Some _,Some _ | None,_ | _,None -> [] in
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
