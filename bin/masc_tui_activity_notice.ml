type t =
  | Given of string
  | Read_failed of string
  | Save_unconfirmed of string
  | Saving_when_workspace_changed
  | Reading_withdrawn
  | Request_pending
  | Path_changed
  | Unread
  | Reapplied
  | Nothing_to_reapply
  | Draft_discarded_unread
  | Draft_discarded
  | File_changed_before_save
  | No_change
  | Receipt_received
  | Conflict_kept
  | Lane_undeclared
  | Lane_required
  | Lane_needs_candidate
  | Lane_declared_inline
  | Machine_declared_inline
  | Machine_edit_lost_configuration

let text ~ko notice =
  let t korean english = if ko then korean else english in
  match notice with
  | Given detail -> detail
  | Read_failed detail -> detail ^ t " · 초안 유지" " · draft retained"
  | Save_unconfirmed detail ->
    detail
    ^ t " · 다시 시도하기 전에 현재 설정을 읽으세요" " · read current before retrying"
  | Saving_when_workspace_changed ->
    t "워크스페이스가 바뀌어 저장 결과를 확인하지 못했습니다. 다시 시도하기 전에 현재 설정을 읽으세요."
      "Save result unconfirmed after workspace change. Read current before retrying."
  | Reading_withdrawn ->
    t "워크스페이스 읽기를 거뒀습니다. 활동 초안은 유지합니다."
      "Workspace reading withdrawn; activity draft retained."
  | Request_pending -> t "처리 중인 요청이 있습니다." "A request is pending."
  | Path_changed ->
    t "설정 파일 경로가 바뀌었습니다. 새 파일을 고치기 전에 이 초안을 버리세요."
      "The configuration file path changed. Discard this draft before editing the new file."
  | Unread ->
    t "고치거나 저장하기 전에 현재 설정을 읽으세요."
      "Read the current configuration before editing or saving."
  | Reapplied ->
    t "활동을 현재 설정에 다시 적용했습니다. s 를 눌러야 저장됩니다."
      "Activity reapplied to current settings. s saves explicitly."
  | Nothing_to_reapply ->
    t "현재 설정이 이미 이 활동입니다. 저장할 것이 없습니다."
      "Current settings already have this activity. Nothing to save."
  | Draft_discarded_unread ->
    t "초안을 버렸습니다. r 로 현재 설정을 읽으세요."
      "Draft discarded. r reads current settings."
  | Draft_discarded ->
    t "초안을 버렸습니다. 파일은 쓰지 않았습니다." "Draft discarded; no file was written."
  | File_changed_before_save ->
    t "파일이 바뀌었습니다. u 는 이 활동만 현재 설정에 다시 적용하고, 그 뒤 s 로 저장합니다."
      "File changed. u reapplies only this activity to current settings; s then saves."
  | No_change -> t "저장할 활동 변경이 없습니다." "No activity change to save."
  | Receipt_received ->
    t "쓰기 영수증을 받았습니다. 다시 고치기 전에 현재 설정을 읽으세요."
      "Write receipt received. Read current settings before editing again."
  | Conflict_kept ->
    t "파일이 바뀌었습니다. 초안은 유지합니다. u 는 활동을 현재 파일에 다시 적용합니다."
      "File changed; draft retained. u reapplies activity to the current file."
  | Lane_undeclared ->
    t "이 Lane 은 선언이 없습니다. 기능 목록으로 돌아가 a 로 후보를 추가하세요."
      "This lane has no declaration. Return to Lanes and press a to add a candidate."
  | Lane_required ->
    t "이 Lane 은 필수라서 끌 수 없습니다."
      "This lane is Required and cannot be switched off."
  | Lane_needs_candidate ->
    t "이 Lane 을 켜기 전에 후보를 추가하세요." "Add a candidate before enabling this lane."
  | Lane_declared_inline ->
    t "인라인이나 점 표기로 쓴 Lane 선언은 소스 편집기에서 고쳐야 합니다."
      "Inline or dotted lane declarations must be edited in the source editor."
  | Machine_declared_inline ->
    t "인라인이나 점 표기로 쓴 머신 설정은 런타임 소스 편집기에서 고쳐야 합니다. 파일은 바꾸지 않았습니다."
      "Inline or dotted machine settings require the Runtime source editor; no file was changed."
  | Machine_edit_lost_configuration ->
    t "이 편집은 머신 설정을 보존하지 못합니다. 런타임 소스 편집기를 쓰세요."
      "The edit did not preserve machine configuration; use the Runtime source editor."
