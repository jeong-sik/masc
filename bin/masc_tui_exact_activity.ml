type owner = { workspace : string * string; lane : Standalone_lane.t }
type document = Masc_tui_runtime_config_edit.document
type write = { source_text : string; expected_source_path : string; expected_source_revision : string }
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
let same_owner a b = a.workspace = b.workspace && Standalone_lane.equal a.lane b.lane
let owner (t : t) = t.owner
let request_owner (request : request) = request.owner
let busy t = match t.phase with Idle -> false | Reading _ | Writing _ -> true
let create owner = {owner;draft=None;current=None;phase=Idle;message=None;receipt=None}
let path lane = [Runtime_toml_namespace.(key Runtime);"exact_output_lanes";Standalone_lane.to_id lane]
let table lane = String.concat "." (List.map Toml_line_editor.render_key (path lane))

(* Only the selected table's editing contract is read here. The server's
   preview and CAS commit validate the complete resulting configuration. *)
let activity lane (document : document) =
  try
    let* toml = Otoml.Parser.from_string_result document.source_text in
    match Otoml.find_opt toml Fun.id (path lane) with
    | None -> Error "This lane has no declaration. Return to Lanes and press a to add a candidate."
    | Some value ->
      let enabled = match Otoml.find_opt value Otoml.get_boolean ["enabled"] with
        | None -> true | Some value -> value in
      let slots key = match Otoml.find_opt value (Otoml.get_array Otoml.get_string) [key] with
        | None -> [] | Some values -> values in
      Ok (enabled, slots "slots", slots "cli_slots")
  with
  | Otoml.Duplicate_key detail | Otoml.Type_error detail -> Error detail

let apply desired lane (document : document) =
  let* _, slots, cli_slots = activity lane document in
  let* () = match Standalone_lane.obligation lane, desired with
    | Required, false -> Error "This lane is Required and cannot be switched off."
    | Required, true | Optional, _ -> Ok () in
  let* () = if desired && slots = [] && cli_slots = []
    then Error "Add a candidate before enabling this lane." else Ok () in
  let lines, _ = Toml_line_editor.split_lines document.source_text in
  if not (List.exists2 (fun structural line -> structural && Toml_line_editor.is_table ~path:(table lane) line)
      (Toml_line_editor.structural_lines lines) lines) then
    Error "Inline or dotted lane declarations must be edited in the source editor."
  else Ok (Toml_line_editor.edit_table_bool document.source_text ~path:(table lane)
    ~key:"enabled" ~value:desired)

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
     | Ok (enabled, _, _) ->
       let retain = match t.draft with
         | None -> false
         | Some draft -> draft.base.path <> current.path ||
           (match activity t.owner.lane draft.base with
            | Error _ -> true
            | Ok (base_enabled, _, _) -> draft.desired <> base_enabled) in
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
    (match apply draft.desired t.owner.lane current, activity t.owner.lane current with
     | Error detail, _ | _, Error detail -> {t with message=Some detail}
     | Ok _, Ok (enabled, _, _) ->
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
     | Ok (enabled, _, _) -> {t with draft=Some {base=current;desired=enabled};message=Some "Draft discarded; no file was written.";receipt=None})
let start_save ~generation t =
  let* draft,current = ready t in
  (* A receipt describes the previous attempt. Kept beside this one, it would
     read as this save's result after a refusal or conflict. Only an admitted
     save returns this session, so a refused start keeps the receipt. *)
  let t = {t with receipt=None} in
  let* () = if draft.base.source_revision<>current.source_revision
    then Error "File changed. u reapplies only this activity to current settings; s then saves."
    else Ok () in
  let* was_enabled,_,_ = activity t.owner.lane draft.base in
  let* () = if was_enabled=draft.desired then Error "No activity change to save." else Ok () in
  let* source_text = apply draft.desired t.owner.lane draft.base in
  let write = {source_text;expected_source_path=draft.base.path;expected_source_revision=draft.base.source_revision} in
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
  let label = Standalone_lane.to_id t.owner.lane in
  let current = match t.current with
    | None -> ["Current file: unverified"]
    | Some document ->
      (match activity t.owner.lane document with
       | Error detail -> [detail]
       | Ok (enabled,slots,cli) -> [document.path;
           Printf.sprintf "Current file: %s · %d HTTP / %d CLI candidates" (flag enabled) (List.length slots) (List.length cli)]) in
  let draft = match t.draft with None -> [] | Some draft ->
    ["Activity draft: " ^ flag draft.desired;
     "Based on revision: " ^ draft.base.source_revision] in
  let conflict = match t.draft,t.current with
    | Some draft,Some current when draft.base.source_revision<>current.source_revision ->
      ["File changed. u reapplies only activity to current settings; x discards the draft."]
    | Some _,Some _ | None,_ | _,None -> [] in
  ["Exact activity · " ^ label;
   (match Standalone_lane.obligation t.owner.lane with Required -> "Required lane: off is unavailable."
    | Optional -> "Off stops new work; accepted work finishes and candidates stay configured.")]
  @ current @ draft @ conflict
  @ (match t.phase with Idle -> [] | Reading _ -> ["Reading current configuration…"] | Writing _ -> ["Saving activity…"])
  @ Option.to_list t.message
  @ (match t.receipt with None -> [] | Some receipt -> [Masc_tui_runtime_config_receipt.lane_summary receipt])
  @ ["Space change draft · s save · r read current · u reapply · x discard · Esc back";
     "The file setting and live application are separate; the write receipt reports application."]
