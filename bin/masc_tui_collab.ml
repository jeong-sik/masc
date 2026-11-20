module Fetched = Masc_tui_fetched

type form = Browsing | Name of string | Hours of string * string | Confirm_revoke of string | Confirm_resolution of string
type write_access = Writable | Pending of string | Uncertain of { request_id : string; notice : string } | Read_only of string
type read_failure = Read_failed of string | Read_kept_back of string
type read = Read of unit ref
type mutation = Mutation of unit ref
type t = {
  owner : unit ref;
  read : read option;
  inventory : (Masc.Tui_decode.play_invites, read_failure) Fetched.observation;
  selected : string option;
  form : form;
  pending : mutation option;
  message : string option;
  write_access : write_access;
}
type action = Stay | Close | Watch of Masc.Machine_lane.t | Game_menu | Refresh
  | Issue of mutation * string * int | Revoke of mutation * string | Open_link of string | Resolve_unknown of string

let create () = { owner = ref (); read = None; inventory = Fetched.Loading; selected = None;
  form = Browsing; pending = None; message = None; write_access = Writable }
let owner t = t.owner
let write_access t access =
  let form = match t.form, access with
    | (Name _ | Hours _ | Confirm_revoke _), (Pending _ | Uncertain _ | Read_only _)
    | Confirm_resolution _, (Writable | Pending _ | Read_only _) -> Browsing
    | Confirm_resolution request_id, Uncertain current when request_id <> current.request_id -> Browsing
    | (Browsing as form), _
    | ((Name _ | Hours _ | Confirm_revoke _) as form), Writable
    | (Confirm_resolution _ as form), Uncertain _ -> form in
  {t with write_access = access; form}
let loading t =
  let read = Read (ref ()) in
  {t with read = Some read}, read
let listed t read result =
  match t.read with
  | None -> t
  | Some current when current != read -> t
  | Some _ ->
      let t = {t with read = None} in
      (match result with
       | Error error ->
           let inventory = match Fetched.value t.inventory with
             | Some listed -> Fetched.Stale (listed, Read_failed error)
             | None -> Fetched.Failed (Read_failed error) in
           {t with inventory}
       | Ok listed ->
           let rows = listed.Masc.Tui_decode.pis_rows in
           let selected = match t.selected with
             | Some name when List.exists (fun row -> String.equal row.Masc.Tui_decode.pi_name name) rows -> Some name
             | Some _ | None -> Option.map (fun row -> row.Masc.Tui_decode.pi_name) (List.nth_opt rows 0) in
           {t with inventory = Fetched.Ready listed; selected})
let kept_back t read notice =
  match t.read with
  | None -> t
  | Some current when current != read -> t
  | Some _ -> {t with read = None; inventory = Fetched.Failed (Read_kept_back notice)}
let notice t message = {t with message = Some message}
let busy t =
  let mutation = Mutation (ref ()) in
  {t with pending = Some mutation; form = Browsing; message = Some "Waiting for the server"}, mutation
let settled t mutation = match t.pending with
  | Some pending when pending == mutation -> {t with pending = None}
  | Some _ | None -> t
let text_input_active t = match t.form with
  | Name _ | Hours _ -> true
  | Browsing | Confirm_revoke _ | Confirm_resolution _ -> false
let progress_status t =
  if Option.is_some t.pending then `Pending_write
  else match t.write_access with
    | Pending detail -> `Write_access_pending detail
    | Writable | Uncertain _ | Read_only _ ->
        (match t.read, t.inventory with
         | Some _, _ | None, Fetched.Loading -> `Loading
         | None, (Fetched.Absent | Fetched.Ready _ | Fetched.Stale _ | Fetched.Failed _) -> `Idle)
let paste t text = match t.form with
  | Name value -> {t with form = Name (value ^ text)}
  | Hours (name, value) -> {t with form = Hours (name, value ^ text)}
  | Browsing | Confirm_revoke _ | Confirm_resolution _ -> t
let rows t = match Fetched.value t.inventory with
  | Some listed -> listed.Masc.Tui_decode.pis_rows
  | None -> []
let selected t = match t.read, t.inventory with
  | None, Fetched.Ready listed ->
      List.find_opt (fun row -> Some row.Masc.Tui_decode.pi_name = t.selected) listed.pis_rows
  | Some _, _ | None, (Fetched.Absent | Fetched.Loading | Fetched.Stale _ | Fetched.Failed _) -> None
let position t =
  match rows t with
  | [] -> None
  | rows ->
      Some
        (Masc_tui_value.Position.row
           ~selected:(List.find_index (fun row -> Some row.Masc.Tui_decode.pi_name = t.selected) rows)
           ~total:(List.length rows))
let move t delta =
  let rows = rows t in
  let index = List.find_index (fun row -> Some row.Masc.Tui_decode.pi_name = t.selected) rows in
  let index = match index with None -> 0 | Some index -> max 0 (min (List.length rows - 1) (index + delta)) in
  {t with selected = Option.map (fun row -> row.Masc.Tui_decode.pi_name) (List.nth_opt rows index)}

(* Invite names and integer lifetimes are ASCII protocol fields. *)
let edit value key = match key with
  | "\127" | "\b" | "backspace" -> String.sub value 0 (max 0 (String.length value - 1))
  | "\021" -> ""
  | key when String.length key = 1 && Char.code key.[0] >= 32 && Char.code key.[0] < 127 -> value ^ key
  | _ -> value

let key t key =
  match t.form, key with
  | (Name _ | Hours _ | Confirm_revoke _ | Confirm_resolution _), ("esc" | "cancel") -> {t with form = Browsing; message = None}, Stay
  | Confirm_resolution request_id, ("\r" | "\n" | "enter") -> {t with form = Browsing}, Resolve_unknown request_id
  | Confirm_resolution _, _ -> t, Stay
  | Name name, ("\r" | "\n" | "enter") ->
      (match Masc.Play_invite.Name.of_string name with
       | Error reason -> {t with message = Some reason}, Stay
       | Ok name -> {t with form = Hours (Masc.Play_invite.Name.to_string name, "24"); message = None}, Stay)
  | Hours (name, value), ("\r" | "\n" | "enter") ->
      (match int_of_string_opt value with
       | Some hours when hours >= Masc_domain.min_token_expiry_hours && hours <= Masc_domain.max_token_expiry_hours ->
           let t, mutation = busy t in t, Issue (mutation, name, hours)
       | Some _ | None -> {t with message = Some (Printf.sprintf "Hours must be between %d and %d"
           Masc_domain.min_token_expiry_hours Masc_domain.max_token_expiry_hours)}, Stay)
  | Confirm_revoke name, ("\r" | "\n" | "enter") ->
      let t, mutation = busy t in t, Revoke (mutation, name)
  | Name name, key -> {t with form = Name (edit name key)}, Stay
  | Hours (name, value), key -> {t with form = Hours (name, edit value key)}, Stay
  | Confirm_revoke _, _ -> t, Stay
  | Browsing, ("esc" | "q") -> t, Close
  | Browsing, "m" -> t, Watch Masc.Machine_lane.Msx
  | Browsing, "d" -> t, Watch Masc.Machine_lane.Dos
  | Browsing, "g" -> t, Game_menu
  | Browsing, "r" -> t, Refresh
  | Browsing, "u" ->
      (match t.write_access with
       | Uncertain {request_id; _} -> {t with form = Confirm_resolution request_id; message = None}, Stay
       | Writable | Pending _ | Read_only _ -> t, Stay)
  | Browsing, ("j" | "down") -> move t 1, Stay
  | Browsing, ("k" | "up") -> move t (-1), Stay
  | Browsing, ("n" | "x") when t.write_access <> Writable ->
      let message = match t.write_access with
        | Pending text | Read_only text | Uncertain {notice=text; _} -> text
        | Writable -> "" in
      {t with message = Some message}, Stay
  | Browsing, "n" when Option.is_none t.pending -> {t with form = Name ""; message = None}, Stay
  | Browsing, "x" when Option.is_none t.pending ->
      (match selected t with
       | None -> t, Stay
       | Some row -> {t with form = Confirm_revoke row.pi_name; message = None}, Stay)
  | Browsing, ("\r" | "\n" | "enter") ->
      (match selected t with None -> t, Stay | Some row -> t, Open_link row.pi_name)
  | Browsing, _ -> t, Stay

let hints ?(ko = false) t = match t.form with
  | Browsing ->
      (if ko then "m:MSX  d:DOS  g:게임  j/k:선택  r:새로고침  Esc:뒤로"
       else "m:MSX  d:DOS  g:games  j/k:choose  r:refresh  Esc:back")
      ^ (if Option.is_some (selected t) then (if ko then "  Enter:링크" else "  Enter:link") else "")
      ^ (match t.write_access with Writable when Option.is_none t.pending ->
           (if ko then "  n:초대" else "  n:invite")
           ^ (if Option.is_some (selected t) then (if ko then "  x:취소" else "  x:revoke") else "")
         | Uncertain _ -> if ko then "  u:미확인 해결" else "  u:resolve unknown"
         | Pending _ | Read_only _ | Writable -> "")
  | Name _ | Hours _ ->
      if ko then "Enter:다음  Ctrl-U:비우기  Backspace:지우기  Esc:취소"
      else "Enter:continue  Ctrl-U:clear  Backspace:delete  Esc:cancel"
  | Confirm_revoke _ ->
      if ko then "Enter:이 초대 취소  Esc:취소"
      else "Enter:revoke this invite  Esc:cancel"
  | Confirm_resolution _ ->
      if ko then "Enter:서버 요청 종료 확인  Esc:차단 유지"
      else "Enter:I verified the server request finished  Esc:keep blocked"

let controller_note ?(ko = false) controller name = match controller with
  | Masc.Tui_decode.Play_controller_held holder when String.equal holder name ->
      if ko then " · 조작 중" else " · controlling"
  | Masc.Tui_decode.Play_controller_held _ | Masc.Tui_decode.Play_controller_free
  | Masc.Tui_decode.Play_machine_absent | Masc.Tui_decode.Play_controller_unobserved _ -> ""

let controller_summary ?(ko = false) = function
  | Masc.Tui_decode.Play_controller_held holder ->
      [(if ko then "DOS 조작자: " else "DOS controller: ")
       ^ Masc.Tui_terminal_text.sanitize_terminal_text holder]
  | Masc.Tui_decode.Play_controller_free -> []
  | Masc.Tui_decode.Play_machine_absent ->
      [if ko then "로드된 DOS 머신이 없습니다." else "No DOS machine is loaded."]
  | Masc.Tui_decode.Play_controller_unobserved reason ->
      [(if ko then "DOS 조작자를 읽지 못함: " else "DOS controller could not be read: ")
       ^ Masc.Tui_terminal_text.sanitize_terminal_text reason]

(* Prose wraps at the overlay's width instead of being cut at the frame's edge:
   the end of a refusal, an error or a confirmation is the part that says what
   to do. The text is sanitized first so the rows are as wide as the rows drawn. *)
let wrap ~width text =
  match Masc_tui_message_layout.wrap_words ~max_cells:width
          (Masc.Tui_terminal_text.sanitize_terminal_text text) with
  | [] -> [""]
  | rows -> rows

(* The three machine keys share one row while it fits and take a row each when
   it does not. *)
let machine_keys ~ko ~width =
  let keys =
    if ko then ["m  MSX 보기"; "d  DOS 보기"; "g  MSX 게임 고르기"]
    else ["m  Watch MSX"; "d  Watch DOS"; "g  Choose an MSX game"]
  in
  let row = String.concat "     " keys in
  if Masc_tui_message_layout.display_width row <= width then [row] else keys

(* One invite as the rows it takes at [width]: the selection mark leads the
   first row and a longer row hangs under the name. *)
let invite_rows ~ko ~width ~last_read t controller (row : Masc.Tui_decode.play_invite_row) =
  let lead = "  " in
  let is_selected = Some row.pi_name = t.selected in
  let mark = if is_selected then "› " else lead in
  wrap ~width:(max 1 (width - String.length lead))
    ((if last_read then (if ko then "마지막 조회 · " else "Last read · ") else "")
     ^ row.pi_name ^ controller_note ~ko controller row.pi_name
     ^ (if row.pi_expired then (if ko then " · 만료됨" else " · expired") else "")
     ^ " · " ^ (match row.pi_expires_at with
                | Some date -> date
                | None ->
                    (* No expiry on the credential means it never expires
                       (RFC tui-one-screen-grammar 6.4). *)
                    (if ko then "만료 " else "expires ") ^ Masc_tui_theme.Glyph.no_value))
  |> List.mapi (fun index text -> is_selected, (if index = 0 then mark else lead) ^ text)

(* The invites that fit [available] rows: the selected one always, the ones
   above it first, the ones below with the rows that are left. *)
let visible_invites ~available ~selected invites =
  let rec fit room taken = function
    | rows :: rest when List.length rows <= room -> fit (room - List.length rows) (rows :: taken) rest
    | _ -> taken, room in
  let above = List.filteri (fun index _ -> index < selected) invites in
  let below = List.filteri (fun index _ -> index > selected) invites in
  let current = Option.value (List.nth_opt invites selected) ~default:[] in
  let above, room = fit (available - List.length current) [] (List.rev above) in
  let below, _ = fit room [] below in
  List.concat (above @ [current] @ List.rev below)

let lines_with_selection ?(ko = false) ~height ~width t =
  let say korean english = if ko then korean else english in
  let plain rows = List.map (fun row -> false, row) rows in
  let wrap_each = List.concat_map (wrap ~width) in
  let last_read = match t.read, t.inventory with
    | Some _, (Fetched.Ready _ | Fetched.Stale _) | None, Fetched.Stale _ -> true
    | Some _, (Fetched.Absent | Fetched.Loading | Fetched.Failed _)
    | None, (Fetched.Absent | Fetched.Loading | Fetched.Ready _ | Fetched.Failed _) -> false in
  let keys = machine_keys ~ko ~width in
  let heading =
    wrap ~width (say "공유 머신 · 관전 중에는 게임 입력을 보내지 않습니다"
                   "Shared machines · observation does not send game input")
    @ keys @ [""]
    @ wrap ~width (say "DOS 플레이 링크 · 공유 게임에 참가자를 초대합니다"
                     "DOS play links · invite a player to the shared game")
  in
  let form = wrap_each (match t.form with
    | Name value ->
        [ say "참가자 이름: " "Player name: " ^ value ^ "▌"
        ; say "영문 소문자와 숫자만 사용하며 문자로 시작합니다."
            "Lowercase letters and digits; start with a letter." ]
    | Hours (name, value) ->
        [ say "참가자: " "Player: " ^ name
        ; say "만료 시간(시간): " "Expires in hours: " ^ value ^ "▌" ]
    | Confirm_revoke name ->
        [ if ko then name ^ " 초대를 취소할까요? 링크가 중지되고 조작 권한이 해제됩니다."
          else "Revoke " ^ name ^ "? Their link stops working and their controller is released." ]
    | Confirm_resolution request_id ->
        [ say "미확인 초대 변경을 해결할까요?" "Resolve the unknown invite change?"
        ; say "요청: " "Request: " ^ Masc.Tui_terminal_text.sanitize_terminal_text request_id
        ; say "원래 요청이 더 이상 완료될 수 없는지 확인하세요 (로그/서버 중지)."
            "Verify the original request cannot still complete (logs/server stop)."
        ; say "그다음 최종 초대 목록을 확인하세요. 새로고침만으로는 완료 증명이 되지 않습니다."
            "Then inspect final invites. A refresh alone is not completion proof."
        ; say "Enter: 확인했습니다. Esc: 변경 차단 유지."
            "Enter: I verified this. Esc: keep changes blocked." ]
    | Browsing -> []) in
  let access = match t.write_access with Writable -> []
    | Pending text | Read_only text | Uncertain {notice=text; _} -> [text] in
  let message = wrap_each (access @ (match t.message with None -> [] | Some text -> [text])) in
  let footer = wrap ~width
    (say "여기서 발급한 링크는 이 TUI 세션에 유지됩니다." "Links issued here remain in this TUI session."
     ^ if Option.is_some (selected t) then
         say " Enter: 보관된 QR/링크 열기." " Enter opens the retained QR/link."
       else "") in
  let status =
    (match t.read, t.inventory with
     | Some _, _ | None, (Fetched.Absent | Fetched.Loading) -> [say "초대 목록 읽는 중" "Reading invites"]
     | None, (Fetched.Ready _ | Fetched.Stale _ | Fetched.Failed _) -> [])
    @ (match t.inventory with
       | Fetched.Stale (_, Read_failed error) | Fetched.Failed (Read_failed error) ->
           [ say "초대 목록을 읽지 못했습니다: " "Could not read invites: " ^ error
           ; say "r: 다시 읽기 · 머신 관전은 계속 사용할 수 있습니다."
               "r retries the read; machine observation remains available." ]
       | Fetched.Stale (_, Read_kept_back notice) | Fetched.Failed (Read_kept_back notice) ->
           [ notice
           ; say "r: 다시 읽기 · 머신 관전은 계속 사용할 수 있습니다."
               "r retries the read; machine observation remains available." ]
       | Fetched.Absent | Fetched.Loading | Fetched.Ready _ -> [])
    @ (match t.read, t.inventory with
       | Some _, (Fetched.Ready _ | Fetched.Stale _) | None, Fetched.Stale _ ->
           [ say "마지막으로 읽은 초대와 조작자 정보를 표시 중입니다. 선택한 초대 열기/취소는 새로고침 성공 후 진행됩니다."
               "Showing the last read invites and controller. Opening or revoking a selected invite waits for a successful refresh." ]
       | Some _, (Fetched.Absent | Fetched.Loading | Fetched.Failed _)
       | None, (Fetched.Absent | Fetched.Loading | Fetched.Ready _ | Fetched.Failed _) -> []) in
  (* [fixed] is the body outside the invite list, [invites] the rows of each
     invite and [selected] the invite the list keeps in view. *)
  let fixed, invites, selected = match Fetched.value t.inventory with
    | None -> [], [], 0
    | Some {Masc.Tui_decode.pis_rows = []; pis_controller} ->
        wrap_each (controller_summary ~ko pis_controller
          @ [if t.write_access = Writable then
               say "초대가 없습니다. n을 눌러 플레이 링크를 만드세요." "No invites. Press n to create a play link."
             else say "초대가 없습니다." "No invites."]), [], 0
    | Some {Masc.Tui_decode.pis_rows = rows; pis_controller} ->
        let selected = match List.find_index (fun row -> Some row.Masc.Tui_decode.pi_name = t.selected) rows with
          | Some index -> index | None -> 0 in
        wrap_each (controller_summary ~ko pis_controller), List.map (invite_rows ~ko ~width ~last_read t pis_controller) rows, selected in
  let details = wrap_each status @ fixed in
  let fixed = details in
  let kept = List.length form + List.length message + List.length fixed in
  let everything = List.length heading + kept + List.length (List.concat invites) + 1 + List.length footer in
  if everything <= height then
    plain heading @ plain form @ plain message @ plain fixed @ List.concat invites @ plain ("" :: footer)
  else begin
    (* A short window gives up its static text first. The heading is whole while
       it fits in what the form, the messages, the fixed text and the selected
       invite leave, less the frame's note row; else the keys alone; else
       nothing. The closing sentence is not counted: it stays last, the frame
       cuts it first and says how many rows it cut, in a row of its own that is
       kept free here. A heading that gave way is not reported when what is
       left fits without a cut. The invites take the rows that are left. *)
    let current = List.length (Option.value (List.nth_opt invites selected) ~default:[]) in
    let message, trailing_message = match t.form with
      | Browsing when last_read -> [], message
      | Browsing | Name _ | Hours _ | Confirm_revoke _ | Confirm_resolution _ -> message, [] in
    let fixed, details =
      if last_read then
        let summary = wrap ~width (match t.read with
          | Some _ -> say "새로고침 중 · 마지막 조회" "Refreshing · last read"
          | None -> say "새로고침 실패 · 마지막 조회" "Refresh failed · last read") in
        let room = height - List.length form - List.length message - current - 1 in
        (if List.length summary <= room then summary else []), details
      else fixed, [] in
    let kept = List.length form + List.length message + List.length fixed in
    let room = height - kept - current - 1 in
    let heading = Option.value (List.find_opt (fun rows -> List.length rows <= room) [heading; keys]) ~default:[] in
    let available = max 1 (height - List.length heading - kept - 1) in
    plain heading @ plain form @ plain message @ plain fixed @ visible_invites ~available ~selected invites
    @ plain trailing_message @ plain details @ plain ("" :: footer)
  end

let lines ?(ko = false) ~height ~width t =
  List.map snd (lines_with_selection ~ko ~height ~width t)
