module Room = Masc.Play_room
module Layout = Masc_tui_message_layout
type send = { id : string; machine : Masc.Machine_lane.t; text : string }
type operation = Read of int option | Say of send | Leave
type request = { ticket : unit ref; client : string; machine : Masc.Machine_lane.t; operation : operation }
type anchor = { message_id : int; line : int }
type position = Latest | Anchored of anchor
type viewport = { anchors : anchor list; last_top : int }
type t = {
  client : string; active : bool; joined : bool; focused : bool; draft : string;
  retry : send option; pending : request option; next_read : float;
  snapshot : Room.snapshot option; notice : string option;
  viewer : string option;
  before : int option; position : position; viewport : viewport option;
}
type intent = Repaint | Send
let create () = { client = Random_id.hex ~bytes:16; active = false; joined = false;
  focused = false; draft = ""; retry = None; pending = None; next_read = 0.;
  snapshot = None; notice = None; viewer = None; before = None; position = Latest; viewport = None }
let focused t = t.focused
let focus t focused = { t with focused }
let active t active = if t.active = active then t else {t with active; focused = false; next_read = 0.}
let suspend t =
  let joined = t.joined || match t.pending with
    | Some {operation=(Read _ | Say _); _} -> true
    | Some {operation=Leave; _} | None -> false in
  {t with pending = None; active = false; joined;
  focused = false; snapshot = None; viewer = None; next_read = 0.; before = None; position = Latest; viewport = None}
let is_read request = match request.operation with
  | Read _ -> true
  | Say _ | Leave -> false
(* A retired read may already have joined or renewed the server membership,
   so it keeps the presence that a later inactive poll must release. *)
let retire_read t = match t.pending with
  | Some {operation = Read _; _} -> {t with pending = None; next_read = 0.; joined = true}
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
let paste t text =
  let text = Masc.Tui_terminal_text.sanitize_terminal_text text in
  if String.length t.draft + String.length text > 4096 then
    {t with notice = Some "대화는 UTF-8 4096바이트까지 보낼 수 있어요."}
  else {t with draft = t.draft ^ text}
let key t = function
  | "\r" | "\n" | "enter" -> t, Send
  | "esc" | "\t" | "tab" -> {t with focused = false}, Repaint
  | "\127" | "\b" | "backspace" -> {t with draft = Layout.drop_last_utf8_scalar t.draft}, Repaint
  | "\021" -> {t with draft = ""}, Repaint
  | "pageup" | "pgup" -> scroll t (-5), Repaint
  | "pagedown" | "pgdn" -> scroll t 5, Repaint
  | "home" ->
    (match t.snapshot with
     | Some {messages = first :: _; has_more = true; _} when Option.is_none t.pending ->
         {t with before = Some first.id; next_read = 0.; position = Latest; viewport = None}, Repaint
     | Some _ | None -> t, Repaint)
  | "end" -> {t with before = None; next_read = 0.; position = Latest; viewport = None}, Repaint
  | text when String.length text > 0 && String.is_valid_utf_8 text
      && (String.length text = 1 || Char.code text.[0] >= 128)
      && not (String.exists (fun c -> Char.code c < 32 || Char.code c = 127) text) -> paste t text, Repaint
  | _ -> t, Repaint
let start t machine operation =
  let request = {ticket = ref (); client = t.client; machine; operation} in
  {t with pending = Some request}, Some request
let poll t ~now ~machine =
  if Option.is_some t.pending then t, None
  else if not t.active then
    if t.joined && now >= t.next_read then start t machine Leave else t, None
  else if now >= t.next_read then start t machine (Read t.before)
  else t, None
let send t ~machine =
  if not t.active || Option.is_some t.pending then
    {t with notice = Some "읽거나 보내는 중이에요. 초안은 남겨 두었어요."}, None
  else if Option.is_none t.retry && String.trim t.draft = "" then t, None
  else
    let sending, draft, notice = match t.retry with
      | Some sending -> sending, t.draft, "이전 전송을 확인하는 중이에요. 새 초안은 남겨 두어요."
      | None -> {id = Random_id.hex ~bytes:16; machine; text = t.draft}, "", "보내는 중…" in
    start {t with draft; retry = Some sending; notice = Some notice} sending.machine (Say sending)
let request_json request =
  let machine = match request.machine with Masc.Machine_lane.Msx -> "msx" | Dos -> "dos" in
  let action, fields = match request.operation with
    | Leave -> "leave", []
    | Read before -> "read", (match before with None -> [] | Some id -> ["before", `Int id])
    | Say sending -> "say", ["message_id", `String sending.id; "text", `String sending.text] in
  `Assoc (["action", `String action; "client_id", `String request.client; "machine", `String machine] @ fields)
let receive ?viewer t request ~now result = match t.pending with
  | None -> t
  | Some current when current.ticket != request.ticket -> t
  | Some _ ->
    let viewer = match result, viewer with
      | Ok _, Some _ -> viewer
      | (Ok _ | Error _), None | Error _, Some _ -> t.viewer in
    let next_read = match request.operation with
      | (Read _ | Say _) when not t.active -> now
      | Read _ | Say _ | Leave -> now +. 2. in
    let t = {t with pending = None; viewer; next_read} in
    match request.operation, result with
    | Leave, Ok _ -> {t with joined = false}
    | Leave, Error detail ->
        {t with notice = Some ("공용 대화 나가기 확인 실패: " ^ detail)}
    | (Read _ | Say _), Error detail ->
        {t with joined = true; notice = Some ("공용 대화 확인 실패: " ^ detail ^ " · 초안을 유지합니다.")}
    | Read before, Ok snapshot ->
        {t with joined = true; snapshot = (if before = t.before then Some snapshot else t.snapshot);
          notice = (if Option.is_none t.retry then None else t.notice)}
    | Say _, Ok snapshot ->
        let notice = if String.trim t.draft <> "" then
            Some "전송을 확인했어요. 새 초안은 Enter로 보낼 수 있어요." else None in
        {t with joined = true; snapshot = Some snapshot; retry = None; notice;
          before = None;
          position = Latest; viewport = None}
let clean = Masc.Tui_terminal_text.sanitize_terminal_text
let footer t = if not t.focused then "" else
  let send = match t.retry with None -> "보내기" | Some _ -> "이전 전송 확인" in
  " 대화 · Enter: " ^ send ^ "  Tab/Esc: 관전  PgUp/PgDn: 스크롤  Home/End: 이전/최근"
let layout t ~width ~height =
  if height <= 0 then {t with viewport = None}, []
  (* Below the compact room heading's width, there is no usable conversation
     viewport. Preserve drafts/history but do not expand every message into
     one-cell lines just to discard them again. *)
  else if width < Layout.display_width "공용 대화" then
    {t with viewport = None},
    List.init height (fun row -> Layout.fit_width (if row = 0 then "공용 대화: 창을 넓혀 주세요." else "") width)
  else
  let members, messages, empty = match t.snapshot with
    | None -> "참여자를 읽고 있어요.", [], "대화를 읽고 있어요."
    | Some snapshot ->
      let members = "참여 중 · " ^ String.concat ", " (List.map (fun (m : Room.member) -> clean m.name) snapshot.members) in
      let messages =
        List.concat_map (fun (m : Room.message) ->
          let mark = if t.viewer = Some m.who then "▶ " else
            match m.speaker with Room.Keeper -> "● " | Participant -> "◀ " in
          let machine = match m.machine with Masc.Machine_lane.Msx -> "MSX" | Dos -> "DOS" in
          let heading = mark ^ clean m.who ^ " · " ^ machine in
          heading :: (Layout.wrap_words ~max_cells:(max 1 (width - 1)) (clean m.text)
            |> List.map (fun line -> " " ^ line))
          |> List.mapi (fun line text -> {message_id = m.id; line}, text)) snapshot.messages in
      members, messages, "아직 대화가 없어요." in
  let heading = "공용 게임 대화" ^ (if t.focused then " · 입력" else " · Tab 입력 / F4 전환") in
  let notice = match t.notice with None -> [] | Some text -> [clean text] in
  let notice = match t.retry with
    | None -> notice
    | Some sending -> ("› 전송 확인 중: " ^ clean sending.text) :: notice in
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
  let composer = if t.draft = "" then (if t.focused then "› " else "Tab: 함께 보는 사람에게 말하기")
    else "› " ^ Layout.input_viewport ~max_cells:(max 0 (width - 2)) (clean t.draft) in
  let rows = prefix @ body @ notice in
  let rows = List.take (max 0 (height - 1)) rows in
  let rows = rows @ List.init (max 0 (height - 1 - List.length rows)) (fun _ -> "") @ [composer] in
  t, List.map (fun line -> Layout.fit_width line width) rows
