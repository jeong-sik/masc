module Notice = Masc_tui_activity_notice
type owner = { workspace : string * string; machine : Masc.Machine_lane.t }
type document = Masc_tui_runtime_config_edit.document
type reading = { document : (document, string) result; activity : (Machine_configuration.activity, string) result }
type write = { source_text : string; expected_source_revision : string; expected_source_path : string }
type draft = { base : document; desired : bool }
type phase = Idle | Reading of int | Writing of int
type t = {
  owner : owner; draft : draft option; current : document option;
  observed : (Machine_configuration.activity, string) result option;
  phase : phase; message : Notice.t option; receipt : Masc_tui_runtime_config_receipt.t option;
}
type operation = Read | Save of write
type request = { owner : owner; generation : int; operation : operation }
type write_result =
  | Saved of Masc_tui_runtime_config_receipt.t
  | Conflict of document
  | Refused of string
  | Unconfirmed of string
open Result.Syntax
module L = Masc_tui_page_line
let same_owner a b = a.workspace = b.workspace && a.machine = b.machine
let owner (t : t) = t.owner
let request_owner (request : request) = request.owner
let busy t = match t.phase with Idle -> false | Reading _ | Writing _ -> true
let create owner = {owner;draft=None;current=None;observed=None;phase=Idle;message=None;receipt=None}
let table machine = Runtime_toml_namespace.(key Machines) ^ "." ^ Masc.Machine_lane.to_wire machine
let configuration (document : document) =
  try
    let given result = Result.map_error (fun detail -> Notice.Given detail) result in
    let* toml = given (Otoml.Parser.from_string_result document.source_text) in
    given (Machine_configuration.parse toml)
  with Otoml.Duplicate_key detail | Otoml.Type_error detail -> Error (Notice.Given detail)
let configured_activity machine (config : Machine_configuration.t) = match machine with
  | Masc.Machine_lane.Msx -> config.msx_enabled
  | Dos -> config.dos_enabled
let activity machine document = Result.map (configured_activity machine) (configuration document)
let with_activity machine desired (config : Machine_configuration.t) = match machine with
  | Masc.Machine_lane.Msx -> {config with msx_enabled=desired}
  | Dos -> {config with dos_enabled=desired}
let apply desired machine (document : document) =
  let* config = configuration document in
  let source_text = Toml_line_editor.edit_table_bool document.source_text
    ~path:(table machine) ~key:"enabled" ~value:desired in
  match configuration {document with source_text} with
  | Error _ -> Error Notice.Machine_declared_inline
  | Ok observed ->
      if Machine_configuration.equal observed (with_activity machine desired config)
      then Ok source_text
      else Error Notice.Machine_edit_lost_configuration

let suspend_read t = match t.phase with
  | Reading _ -> {t with phase=Idle}
  | Idle | Writing _ -> t
let suspend t = {t with phase=Idle;current=None;observed=None;message=Some
  (match t.phase with Writing _ -> Notice.Saving_when_workspace_changed
   | Idle | Reading _ -> Notice.Reading_withdrawn)}
let matches (request : request) (t : t) = same_owner request.owner t.owner &&
  match request.operation, t.phase with
  | Read, Reading generation | Save _, Writing generation -> generation=request.generation
  | Read, (Idle | Writing _) | Save _, (Idle | Reading _) -> false
let start_read ~generation t =
  if busy t then None else
    Some ({t with phase=Reading generation;current=None;observed=None;message=None},
      {owner=t.owner;generation;operation=Read})
let finish_read request result t =
  if not (matches request t) then t else
  let t = {t with phase=Idle;current=None;observed=None} in
  match result with
  | Error detail -> {t with message=Some (Notice.Read_failed detail)}
  | Ok {document=Error detail;activity=observed} ->
      {t with observed=Some observed;message=Some (Notice.Read_failed detail)}
  | Ok {document=Ok current;activity=observed} ->
    (match activity t.owner.machine current with
     | Error detail -> {t with observed=Some observed;message=Some detail}
     | Ok enabled ->
       let retain = match t.draft with
         | None -> false
         | Some draft -> draft.base.path <> current.path ||
           (match activity t.owner.machine draft.base with
            | Error _ -> true
            | Ok base_enabled -> draft.desired <> base_enabled) in
       (* Saving requires a changed value. An unconfirmed write keeps that
          original base, so this read retains the intended change. A later
          explicit edit, reapply or discard can resolve the retained intent. *)
       let draft = if retain then t.draft else Some {base=current;desired=enabled} in
       {t with draft;current=Some current;observed=Some observed;message=None})
let ready t =
  if busy t then Error Notice.Request_pending else
  match t.draft,t.current with
  | Some draft, Some current when draft.base.path=current.path -> Ok (draft,current)
  | Some _, Some _ -> Error Notice.Path_changed
  | None, _ | _, None -> Error Notice.Unread
let toggle t = match ready t with
  | Error detail -> {t with message=Some detail}
  | Ok (draft, _) ->
    (match apply (not draft.desired) t.owner.machine draft.base with
     | Error detail -> {t with message=Some detail}
     | Ok _ -> {t with draft=Some {draft with desired=not draft.desired};message=None;receipt=None})
let reapply t = match ready t with
  | Error detail -> {t with message=Some detail}
  | Ok (draft,current) ->
    (match apply draft.desired t.owner.machine current with
     | Error detail -> {t with message=Some detail}
     | Ok _ -> {t with draft=Some {draft with base=current};message=Some Notice.Reapplied})
let discard t =
  if busy t then {t with message=Some Notice.Request_pending} else
  match t.current with
  | None -> {t with draft=None;message=Some Notice.Draft_discarded_unread}
  | Some current ->
    (match activity t.owner.machine current with
     | Error detail -> {t with draft=None;message=Some detail}
     | Ok enabled -> {t with draft=Some {base=current;desired=enabled};message=Some Notice.Draft_discarded;receipt=None})
let start_save ~generation t =
  let* draft,current = ready t in
  let* () = if draft.base.source_revision<>current.source_revision
    then Error Notice.File_changed_before_save
    else Ok () in
  let* was_enabled = activity t.owner.machine draft.base in
  let* () = if was_enabled=draft.desired then Error Notice.No_change else Ok () in
  let* source_text = apply draft.desired t.owner.machine draft.base in
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
      | (Some _ | None), Durability_unconfirmed _ | None, Durable -> t.draft in
    {t with draft;current=None;observed=None;receipt=Some receipt;
      message=Some Notice.Receipt_received}
  | Save _,Conflict current -> {t with current=Some current;observed=None;message=Some Notice.Conflict_kept}
  | Save _,Refused detail -> {t with message=Some (Notice.Given detail)}
  | Save _,Unconfirmed detail -> {t with current=None;observed=None;message=Some (Notice.Save_unconfirmed detail)}
  | Read,_ -> t
let lines ~ko (t : t) =
  let say korean english = if ko then korean else english in
  let flag value = if value then say "켜짐" "On" else say "꺼짐" "Off" in
  let label = match t.owner.machine with Masc.Machine_lane.Msx -> "MSX" | Dos -> "DOS" in
  let current_enabled, current = match t.current with
    | None -> None, [L.fact (say "현재 파일" "Current file") (say "미확인" "unverified")]
    | Some document ->
      (match activity t.owner.machine document with
       | Error notice -> None, [L.note ~tone:L.Failure (Notice.text ~ko notice)]
       | Ok enabled ->
         Some enabled,
         [L.fact (say "파일" "File") document.path;
          L.fact (say "현재 파일" "Current file") (flag enabled)]) in
  let draft = match t.draft with None -> [] | Some draft ->
    (* A draft that differs from the file's activity has not been saved. *)
    let unsaved = match current_enabled with
      | Some enabled -> not (Bool.equal enabled draft.desired)
      | None -> false in
    [(if unsaved then
        L.fact ~tone:L.Attention (say "활동 초안" "Activity draft")
          (flag draft.desired ^ say " · 저장 안 됨" " · not saved")
      else L.fact (say "활동 초안" "Activity draft") (flag draft.desired));
     L.fact ~tone:L.Quiet (say "기준 revision" "Based on revision") draft.base.source_revision] in
  let conflict = match t.draft,t.current with
    | Some draft,Some current when draft.base.source_revision<>current.source_revision ->
      [L.note ~tone:L.Attention
         (say "파일이 바뀌었습니다. u 는 활동만 현재 설정에 다시 적용하고, x 는 초안을 버립니다."
            "File changed. u reapplies only activity to current settings; x discards the draft.")]
    | Some _,Some _ | None,_ | _,None -> [] in
  let server = say "서버 활동" "Server activity" in
  [L.Title (say "머신 켜고 끄기 · " "Machine activity · " ^ label);
   L.note ~tone:L.Quiet
     (say "끄면 새 실행과 입력을 멈춥니다. 이미 받은 작업은 끝냅니다."
        "Off stops new execution and input; accepted work finishes.");
   L.note ~tone:L.Quiet
     (say "머신 상태와 체크포인트는 남습니다. 살펴보기, 저장, 정리는 계속 쓸 수 있습니다."
        "Machine state and checkpoints remain. Inspection, saving and cleanup stay available.")]
  @ (match t.observed with
    | None -> [L.fact server (say "읽지 않음" "not read")]
    | Some (Error detail) ->
      [L.note ~tone:L.Failure
         (say "서버 활동을 읽지 못함: " "Server activity read failed: " ^ detail)]
    | Some (Ok Machine_configuration.Enabled) ->
      [L.fact server (say "켜짐 (마지막 읽기)" "On (last read)")]
    | Some (Ok Disabled) -> [L.fact server (say "꺼짐 (마지막 읽기)" "Off (last read)")]
    | Some (Ok Unobserved) ->
      [L.fact server
         (say "설정을 읽을 수 없음 (마지막 읽기)" "configuration unavailable (last read)")])
  @ current @ draft @ conflict
  @ (match t.phase with
     | Idle -> []
     | Reading _ -> [L.note (say "현재 설정을 읽는 중…" "Reading current configuration…")]
     | Writing _ -> [L.note (say "활동 저장 중…" "Saving activity…")])
  @ Option.to_list (Option.map (fun notice -> L.note (Notice.text ~ko notice)) t.message)
  @ (match t.receipt with None -> [] | Some receipt -> [L.note (Masc_tui_runtime_config_receipt.lane_summary receipt)])
  @ [L.note ~tone:L.Quiet
       (say "파일과 서버 읽기는 따로 관측한 것입니다. r 로 둘 다 다시 읽습니다."
          "The file and server reading are separate observations; r reads both again.");
     L.note ~tone:L.Quiet
       (say "켜면 새 작업을 받습니다. 머신을 불러오거나 되살리지는 않습니다."
          "On allows new work. It does not load or restore a machine.")]
