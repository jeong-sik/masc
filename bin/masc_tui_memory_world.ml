module Wire = Masc.Tui_decode_workspace_memory
module Owed = Masc_tui_owed_read

type inventory = Wire.inventory

type request = unit Masc_tui_fetched.request

(* Why the line has no fresh inventory. [Suspended] is the one cause this module
   makes itself: the workspace stopped being confirmed and the read in flight
   was retired. Every answer that failed reaches [complete] as the text the
   shared read path built (launcher precondition, transport, HTTP status,
   missing receipt, decode). Those layers hand the same string to every
   consumer, so the text is kept as received and is never read to tell one
   cause from another. *)
type failure =
  | Suspended
  | Request_failed of string
  | Kept_back of string

type t =
  { fetched : (unit, inventory, failure) Masc_tui_fetched.source
  ; owed : Owed.t
  }

let initial = { fetched = Masc_tui_fetched.initial; owed = Owed.changed Owed.settled }

let changed t = { t with owed = Owed.changed t.owed }

(* [refresh] and not [start]: over a failure only [refresh] keeps the failure in
   view while the retry runs, so a server that stays down does not flip the
   line between "read failed" and "not read" every interval. It supersedes a
   read in flight, which is why that case is turned away first. *)
let start ~now t =
  if not (Owed.due ~now t.owed) || Masc_tui_fetched.in_flight t.fetched
  then None
  else (
    match Masc_tui_fetched.refresh ~equal:Unit.equal t.fetched ~key:() with
    | Masc_tui_fetched.Already_loading -> None
    | Masc_tui_fetched.Started (fetched, request) ->
        Some ({ fetched; owed = Owed.started t.owed }, request))

let settle ~retry_s ~max_retry_s ~now t request result =
  if Masc_tui_fetched.is_current ~equal:Unit.equal t.fetched request
  then
    { fetched = Masc_tui_fetched.complete ~equal:Unit.equal t.fetched request result
    ; owed = (match result with
        | Ok _ -> Owed.succeeded t.owed
        | Error _ -> Owed.failed ~retry_s ~max_retry_s ~now t.owed)
    }
  else t

let complete ~retry_s ~max_retry_s ~now t request result =
  settle ~retry_s ~max_retry_s ~now t request
    (Result.map_error (fun text -> Request_failed text) result)

let withdraw ~retry_s ~max_retry_s ~now t request notice =
  settle ~retry_s ~max_retry_s ~now t request (Error (Kept_back notice))

(* A retry over a failure keeps that failure's cause when it is retired: the
   retry never answered, so it has nothing to add. A refresh over an inventory
   takes [Suspended] as the cause of its stale mark. *)
let suspend t =
  { fetched = Masc_tui_fetched.suspend_with ~reason:Suspended t.fetched
  ; owed = Owed.changed (Owed.abandoned t.owed)
  }

(* [Masc_tui_fetched.clear] keeps the generation counter, so a reply to a read
   made before this cannot pass for the next one. *)
let clear t =
  { fetched = Masc_tui_fetched.clear t.fetched; owed = Owed.changed Owed.settled }

type reading =
  | Not_read
  | Reading
  | Loaded of { world : inventory; refresh_failure : failure option }
  | Read_failed of failure

let reading t =
  match Masc_tui_fetched.view_for ~equal:Unit.equal t.fetched ~key:() with
  | Masc_tui_fetched.Absent -> Not_read
  | Masc_tui_fetched.Loading -> Reading
  | Masc_tui_fetched.Ready world -> Loaded { world; refresh_failure = None }
  | Masc_tui_fetched.Stale (world, failure) ->
    Loaded { world; refresh_failure = Some failure }
  | Masc_tui_fetched.Failed failure -> Read_failed failure

(* Translate only the server's typed briefing status. Fact age never selects
   these states: RFC-0418 keeps age separate from source invalidation. The
   reference sheet retains its English keys. *)
let unknown = "?"
let claim_noun = "claim"
let conflict_noun = "conflict"
let briefing_word = "briefing"
let building_word = "building"
let read_failed_word ~ko = if ko then "읽기 실패" else "read failed"
(* The Work screen words an unconfirmed workspace the same way. *)
let suspended_word ~ko =
  Masc_tui_words.workspace_name ~ko ^ " " ^ Masc_tui_words.field_unconfirmed ~ko
let no_ledger_word ~ko = if ko then "장부 없음" else "no ledger"
let label ~ko = if ko then "월드:" else "World:"

let briefing_status_word ~ko = function
  | Wire.Pending -> if ko then "미발행" else "pending"
  | Wire.Current -> if ko then "현재 근거와 일치" else "current"
  | Wire.Stale -> if ko then "갱신 필요" else "stale"
  | Wire.Unavailable -> if ko then "조회 불가" else "unavailable"

let briefing_clause ~ko status =
  (if ko then "브리핑 " else briefing_word ^ " ") ^ briefing_status_word ~ko status

(* The word is the server's field name. The pass it names is on disk; the
   server does not say that a model is running now, and the legend row for the
   word says so. *)
let building_clause ~ko (pass : Wire.building_pass) =
  if ko
  then
    Printf.sprintf "작성 중, %s개 중 %s개 남음"
      (Masc_tui_value.Count.grouped pass.Wire.target)
      (Masc_tui_value.Count.grouped pass.Wire.remaining)
  else
    Printf.sprintf "%s, %s of %s left" building_word
      (Masc_tui_value.Count.grouped pass.Wire.remaining)
      (Masc_tui_value.Count.grouped pass.Wire.target)

let value_clauses ~ko = function
  | Wire.Missing _ -> [ no_ledger_word ~ko ]
  | Wire.Available available ->
    let briefing = available.Wire.briefing in
    [ Masc_tui_value.Count.reading ~ko Masc_tui_value.Count.Claim available.Wire.claim_count
    ; Masc_tui_value.Count.reading ~ko Masc_tui_value.Count.Conflict available.Wire.conflict_count
    ; briefing_clause ~ko briefing.Wire.status
    ]
    @ (match briefing.Wire.building with
       | None -> []
       | Some pass -> [ building_clause ~ko pass ])

(* Below this many free cells a cut text is a few letters and the mark, which
   names nothing, so the row goes without it. Ten keeps a head such as
   "HTTP 503:" whole beside the mark. *)
let min_cause_cells = 10

let cut_to ~cells text =
  if Masc_tui_message_layout.fits_within_cells ~max_cells:cells text
  then text
  else (
    let head, _ =
      Masc_tui_message_layout.split_at_cells
        text
        (cells - Masc_tui_message_layout.cut_mark_cells)
    in
    String.trim head ^ Masc_tui_message_layout.cut_mark)

(* How a cause is drawn in the [cells] a row has left. The fixed word is drawn
   whole or not at all, since "workspace..." names nothing. The text of a failed
   answer is put on one printable line and cut, because it is the one part of
   the line whose length this module does not choose. *)
let cause_clause ~ko ~cells = function
  | Suspended ->
    let word = suspended_word ~ko in
    if Masc_tui_message_layout.fits_within_cells ~max_cells:cells word
    then Some word
    else None
  | Request_failed text | Kept_back text ->
    let text = String.trim (Masc.Tui_terminal_text.sanitize_terminal_text text) in
    if text = "" || cells < min_cause_cells then None else Some (cut_to ~cells text)

(* The cause goes after [fixed] on the row the packed clauses end on, in what
   that row has left, so it never adds a row. The Memory list works out its
   height from the header's rows, and a cause of any length must not move it. *)
let with_cause ~ko ~room failure fixed =
  let last_row_cells =
    List.fold_left
      (fun _ row -> Masc_tui_message_layout.display_width row)
      0
      (Masc_tui_message_layout.pack_clauses ~max_cells:room fixed)
  in
  let cells =
    room
    - last_row_cells
    - Masc_tui_message_layout.display_width Masc_tui_message_layout.clause_separator
  in
  match cause_clause ~ko ~cells failure with
  | Some clause -> fixed @ [ clause ]
  | None -> fixed

let clauses ~ko ~room = function
  | Not_read | Reading -> [ unknown ]
  | Read_failed (Kept_back _ as failure) -> with_cause ~ko ~room failure [ unknown ]
  | Read_failed ((Suspended | Request_failed _) as failure) ->
    with_cause ~ko ~room failure [ unknown; read_failed_word ~ko ]
  | Loaded { world; refresh_failure = None } -> value_clauses ~ko world
  | Loaded { world; refresh_failure = Some (Kept_back _ as failure) } ->
    with_cause ~ko ~room failure (value_clauses ~ko world)
  | Loaded { world; refresh_failure = Some ((Suspended | Request_failed _) as failure) } ->
    with_cause ~ko ~room failure (value_clauses ~ko world @ [ read_failed_word ~ko ])

(* What each word does not say, because the server does not say it either
   (RFC-0511 W3): the counts are the curator's records, [current] is a match
   with the present sources and not a check of the text, and an open pass is a
   file on disk and not a model running now. The key sheet keeps its key column
   16 cells wide, so a longer key here would push its row's text out of line. *)
let legend_for ~ko =
  if ko then
    [ ( unknown
      , "월드 줄: 아직 조회하지 않았거나 조회 중 · 아직 알 수 없음(0이 아님)" )
    ; ( read_failed_word ~ko:true
      , "월드 줄: 방금 현황을 읽지 못함 · 옆의 숫자는 이전 조회 값 · 뒤의 이유는 워크스페이스 미확인(조회 중단) 또는 수신 오류" )
    ; ( no_ledger_word ~ko:true
      , "월드 줄: 서버에 큐레이터 장부 파일이 없음(미조회가 아닌 확인된 상태)" )
    ; ( "주장/충돌"
      , "월드 줄: 큐레이터가 기록한 공유 주장과 충돌 수 · 키퍼 사실에 대한 판독이며 진위 검증은 아님" )
    ; ( "브리핑"
      , "월드 줄: 공유 브리핑 상태 · 현재 근거와 일치(현재 주장·프롬프트 계약과 맞음), 갱신 필요(이후 변경됨), 미발행, 조회 불가" )
    ; ( "작성 중"
      , "월드 줄: 디스크에 열려 있는 브리핑 패스(현재 모델 실행 중이라는 증거는 아님) · M개 중 N개 남음" )
    ]
  else
    [ ( unknown
      , "world line: not read yet or still being read; nothing is known, and it is not zero" )
    ; ( read_failed_word ~ko:false
      , "world line: the inventory could not be read just now; any count beside it is from \
         an earlier read. After it, why: workspace unconfirmed (reading is suspended), or \
         the failure as received, cut with … or left out when the row is short" )
    ; ( no_ledger_word ~ko:false
      , "world line: the server found no curator ledger file when it looked; that is a \
         value, not an unknown" )
    ; ( claim_noun ^ "s/" ^ conflict_noun ^ "s"
      , "world line: how many shared claims and conflicts the curator recorded; its reading \
         of the Keepers' facts, not a check that any is true" )
    ; ( briefing_word
      , "world line: the server's word for the shared briefing, shown as sent. current: it \
         matches the present claims and prompt contract (always so when there are none), \
         not that its text is right. stale: they changed since it was written. pending: none \
         is published. unavailable: it could not be read" )
    ; ( building_word
      , "world line: a briefing pass is open on disk, not proof that a model is running now; \
         N of M left counts entries still to summarize, and N equal to M starts from nothing" )
    ]
