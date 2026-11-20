module Room = Masc.Play_room
module Layout = Masc_tui_message_layout
type send = { id : string; machine : Masc.Machine_lane.t; text : string }
type operation = Read of int option | Say of send | Leave
type request = { ticket : unit ref; client : string; machine : Masc.Machine_lane.t; operation : operation }
type anchor = { message_id : int; line : int }
type position = Latest | Anchored of anchor
type viewport = { anchors : anchor list; last_top : int }
(* When the room is read next: at once, at an instant on the loop's clock,
   or not until something changes (an answered read has no periodic
   successor). *)
type next_read = Now | At of Masc_tui_wake.Mono.t | Until_changed
type t = {
  client : string; active : bool; joined : bool; focused : bool; draft : string;
  retry : send option; pending : request option; next_read : next_read;
  changed_since : bool;
  snapshot : Room.snapshot option; notice : string option;
  viewer : string option;
  before : int option; position : position; viewport : viewport option;
}
type intent = Repaint | Send
type origin = Viewer | Keeper | Peer
let create () = { client = Random_id.hex ~bytes:16; active = false; joined = false;
  focused = false; draft = ""; retry = None; pending = None; next_read = Now; changed_since = false;
  snapshot = None; notice = None; viewer = None; before = None; position = Latest; viewport = None }
let client_id t = t.client
let focused t = t.focused
let focus t focused = { t with focused }
let active t active = if t.active = active then t else {t with active; focused = false; next_read = Now}
let revalidate t =
  {t with next_read = Now; changed_since = t.changed_since || Option.is_some t.pending}
let suspend t =
  let joined = t.joined || match t.pending with
    | Some {operation=(Read _ | Say _); _} -> true
    | Some {operation=Leave; _} | None -> false in
  {t with pending = None; active = false; joined; changed_since = false;
  focused = false; snapshot = None; viewer = None; next_read = Now; before = None; position = Latest; viewport = None}
let is_read request = match request.operation with
  | Read _ -> true
  | Say _ | Leave -> false
let request_kind request = match request.operation with
  | Read _ -> `Read
  | Say _ -> `Say
  | Leave -> `Leave
(* Preserve the inactive Leave obligation even though Read itself does not
   create or renew membership. *)
let retire_read t = match t.pending with
  | Some {operation = Read _; _} -> {t with pending = None; next_read = Now; joined = true}
  | Some {operation = Say _ | Leave; _} | None -> t
let anchor_index anchors target =
  match List.find_index (fun a -> a.message_id = target.message_id) anchors with
  | Some first ->
      let count = List.length (List.filter (fun a -> a.message_id = target.message_id) anchors) in
      first + min target.line (count - 1)
  | None ->
      (match List.find_index (fun a -> a.message_id > target.message_id) anchors with
       | Some first -> first
       | None -> max 0 (List.length anchors - 1))
let top position viewport = match position with
  | Latest -> viewport.last_top
  | Anchored anchor -> min viewport.last_top (anchor_index viewport.anchors anchor)
let scroll t delta = match t.viewport with
  | None -> t
  | Some viewport ->
      let next = max 0 (min viewport.last_top (top t.position viewport + delta)) in
      let position = if next = viewport.last_top then Latest else
        match List.nth_opt viewport.anchors next with Some anchor -> Anchored anchor | None -> Latest in
      {t with position}
let paste ?(ko = true) t text =
  let text = Masc.Tui_terminal_text.sanitize_terminal_text text in
  if String.length t.draft + String.length text > 4096 then
    {t with notice = Some
       (if ko then "대화는 UTF-8 4096바이트까지 보낼 수 있어요."
        else "Chat messages are limited to 4096 UTF-8 bytes.")}
  else {t with draft = t.draft ^ text}
let key ?(ko = true) t = function
  | "\r" | "\n" | "enter" -> t, Send
  | "esc" | "\t" | "tab" -> {t with focused = false}, Repaint
  | "\127" | "\b" | "backspace" -> {t with draft = Layout.drop_last_utf8_scalar t.draft}, Repaint
  | "\021" -> {t with draft = ""}, Repaint
  | "pageup" | "pgup" -> scroll t (-5), Repaint
  | "pagedown" | "pgdn" -> scroll t 5, Repaint
  | "home" ->
    (match t.snapshot with
     | Some {messages = first :: _; has_more = true; _} when Option.is_none t.pending ->
         {t with before = Some first.id; next_read = Now; position = Latest; viewport = None}, Repaint
     | Some _ | None -> t, Repaint)
  | "end" -> {t with before = None; next_read = Now; position = Latest; viewport = None}, Repaint
  | text when String.length text > 0 && String.is_valid_utf_8 text
      && (String.length text = 1 || Char.code text.[0] >= 128)
      && not (String.exists (fun c -> Char.code c < 32 || Char.code c = 127) text) -> paste ~ko t text, Repaint
  | _ -> t, Repaint
let start t machine operation =
  let request = {ticket = ref (); client = t.client; machine; operation} in
  {t with pending = Some request}, Some request
(* While a read waits for its instant, the instant is noted for the main
   loop's wait. *)
let read_due t ~now = match t.next_read with
  | Now -> true
  | At at -> Masc_tui_wake.reached_mono Masc_tui_wake.Play_room_read ~now ~at
  | Until_changed -> false
let poll t ~now ~machine =
  if Option.is_some t.pending then t, None
  else if not t.active then
    if t.joined && read_due t ~now then start t machine Leave else t, None
  else if read_due t ~now then start t machine (Read t.before)
  else t, None
let send ?(ko = true) t ~machine =
  if not t.active || Option.is_some t.pending then
    {t with notice = Some
       (if ko then "읽거나 보내는 중이에요. 초안은 남겨 두었어요."
        else "Reading or sending in progress; your draft is kept.")}, None
  else if Option.is_none t.retry && String.trim t.draft = "" then t, None
  else
    let sending, draft, notice = match t.retry with
      | Some sending ->
          sending, t.draft,
          (if ko then "이전 전송을 확인하는 중이에요. 새 초안은 남겨 두어요."
           else "Confirming previous send; your new draft is kept.")
      | None ->
          {id = Random_id.hex ~bytes:16; machine; text = t.draft}, "",
          (if ko then "보내는 중" else "Sending") in
    start {t with draft; retry = Some sending; notice = Some notice} sending.machine (Say sending)
let request_json request =
  let machine = match request.machine with Masc.Machine_lane.Msx -> "msx" | Dos -> "dos" in
  let action, fields = match request.operation with
    | Leave -> "leave", []
    | Read before -> "read", (match before with None -> [] | Some id -> ["before", `Int id])
    | Say sending -> "say", ["message_id", `String sending.id; "text", `String sending.text] in
  `Assoc (["action", `String action; "client_id", `String request.client; "machine", `String machine] @ fields)
(* A read that failed, or one the caller's workspace guard stopped before it
   left, whose notice the caller has already worded. *)
type failure = Unanswered of string | Kept_back of string

(* The wait before a failed read, or an unconfirmed leave, is tried again. *)
let retry_s = 2.

let settle ?(ko = true) ?viewer t request ~now result = match t.pending with
  | None -> t
  | Some current when current.ticket != request.ticket -> t
  | Some _ ->
    let viewer = match result, viewer with
      | Ok _, Some _ -> viewer
      | (Ok _ | Error _), None | Error _, Some _ -> t.viewer in
    let retry = At (Masc_tui_wake.Mono.after now retry_s) in
    let next_read =
      if t.changed_since then Now
      else if not t.active then
        match request.operation with
        | Read _ | Say _ -> Now
        | Leave -> retry
      else
        match request.operation, result with
        | (Read _ | Say _), Ok _ -> Until_changed
        | (Read _ | Say _ | Leave), Error _ -> retry
        | Leave, Ok _ -> retry
    in
    let t = {t with pending = None; viewer; next_read; changed_since = false} in
    match request.operation, result with
    | Leave, Ok _ -> {t with joined = false}
    | Leave, Error (Unanswered detail) ->
        {t with notice = Some
           ((if ko then "공용 대화 나가기 확인 실패: " else "Failed to confirm leaving room chat: ")
            ^ detail)}
    | Leave, Error (Kept_back notice) -> {t with notice = Some notice}
    | (Read _ | Say _), Error (Unanswered detail) ->
        {t with joined = true; notice = Some
           (if ko then "공용 대화 확인 실패: " ^ detail ^ " · 초안을 유지합니다."
            else "Room chat check failed: " ^ detail ^ " · draft kept.")}
    | (Read _ | Say _), Error (Kept_back notice) -> {t with joined = true; notice = Some notice}
    | Read before, Ok snapshot ->
        {t with joined = true; snapshot = (if before = t.before then Some snapshot else t.snapshot);
          notice = (if Option.is_none t.retry then None else t.notice)}
    | Say _, Ok snapshot ->
        let notice = if String.trim t.draft <> "" then
            Some (if ko then "전송을 확인했어요. 새 초안은 Enter로 보낼 수 있어요."
                  else "Send confirmed. Press Enter to send your new draft.")
          else None in
        {t with joined = true; snapshot = Some snapshot; retry = None; notice;
          before = None;
          position = Latest; viewport = None}
let receive ?(ko = true) ?viewer t request ~now result =
  settle ~ko ?viewer t request ~now (Result.map_error (fun detail -> Unanswered detail) result)
let kept_back t request ~now notice = settle t request ~now (Error (Kept_back notice))
let clean = Masc.Tui_terminal_text.sanitize_terminal_text
let origin t (m : Room.message) =
  if t.viewer = Some m.who then Viewer
  else match m.speaker with Room.Keeper -> Keeper | Room.Participant -> Peer
let footer ?(ko = true) t = if not t.focused then "" else
  let send =
    match t.retry with
    | None -> if ko then "보내기" else "send"
    | Some _ -> if ko then "이전 전송 확인" else "confirm previous send"
  in
  if ko then
    " 대화 · Enter: " ^ send ^ "  Tab/Esc: 관전  PgUp/PgDn: 스크롤  Home/End: 이전/최근"
  else
    " Chat · Enter: " ^ send ^ "  Tab/Esc: watch  PgUp/PgDn: scroll  Home/End: top/latest"
let layout ?(ko = true) t ~width ~height =
  let say korean english = if ko then korean else english in
  if height <= 0 then {t with viewport = None}, []
  (* Below the compact room heading's width, there is no usable conversation
     viewport. Preserve drafts/history but do not expand every message into
     one-cell lines just to discard them again. *)
  else if width < Layout.display_width (say "공용 대화" "Room chat") then
    {t with viewport = None},
    List.init height (fun row -> Layout.fit_width (if row = 0 then say "공용 대화: 창을 넓혀 주세요." "Room chat: widen window." else "") width)
  else
  let members, messages, empty = match t.snapshot with
    | None ->
      say "참여자를 읽고 있어요." "Reading participants.", [], say "대화를 읽고 있어요." "Reading messages."
    | Some snapshot ->
      let members = (say "참여 중 · " "In room · ") ^ String.concat ", " (List.map (fun (m : Room.member) -> clean m.name) snapshot.members) in
      let messages =
        List.concat_map (fun (m : Room.message) ->
          let mark = match origin t m with Viewer -> "▶ " | Keeper -> "● " | Peer -> "◀ " in
          let machine = match m.machine with Masc.Machine_lane.Msx -> "MSX" | Dos -> "DOS" in
          let heading = mark ^ clean m.who ^ " · " ^ machine in
          heading :: (Layout.wrap_words ~max_cells:(max 1 (width - 1)) (clean m.text)
            |> List.map (fun line -> " " ^ line))
          |> List.mapi (fun line text -> {message_id = m.id; line}, text)) snapshot.messages in
      members, messages, say "아직 대화가 없어요." "No messages yet." in
  let heading =
    say "공용 게임 대화" "Shared game chat"
    ^ (if t.focused then say " · 입력" " · typing" else say " · Tab 입력 / F4 전환" " · Tab type / F4 toggle")
  in
  let notice = match t.notice with None -> [] | Some text -> [clean text] in
  let notice = match t.retry with
    | None -> notice
    | Some sending -> (say "› 전송 확인 중: " "› confirming send: " ^ clean sending.text) :: notice in
  let prefix = if height >= 5 then [heading; members] else [heading] in
  let available = max 0 (height - List.length prefix - List.length notice - 1) in
  let t, body = if available = 0 || messages = [] then
      {t with viewport = None}, List.take available [empty]
    else
      let viewport = {anchors = List.map fst messages;
        last_top = max 0 (List.length messages - available)} in
      let first = top t.position viewport in
      let position = match t.position, List.nth_opt viewport.anchors first with
        | Latest, _ -> Latest
        | Anchored _, Some anchor -> Anchored anchor
        | Anchored _, None -> Latest in
      {t with position; viewport = Some viewport},
      messages |> List.drop first |> List.take available |> List.map snd in
  let composer =
    if t.draft = "" then
      if t.focused then "› " else say "Tab: 함께 보는 사람에게 말하기" "Tab: talk to watchers"
    else "› " ^ Layout.input_viewport ~max_cells:(max 0 (width - 2)) (clean t.draft) in
  let rows = prefix @ body @ notice in
  let rows = List.take (max 0 (height - 1)) rows in
  let rows = rows @ List.init (max 0 (height - 1 - List.length rows)) (fun _ -> "") @ [composer] in
  t, List.map (fun line -> Layout.fit_width line width) rows
