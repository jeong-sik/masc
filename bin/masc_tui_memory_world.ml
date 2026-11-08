module Wire = Masc.Tui_decode_workspace_memory

type inventory = Wire.inventory

type request = unit Masc_tui_fetched.request

(* [not_before] is the monotonic time before which no read starts. An answer,
   good or failed, sets it, so a down server is asked as rarely as a healthy
   one. A read that was retired without an answer sets nothing, which is why
   reading again once the workspace is confirmed does not wait. *)
type t =
  { fetched : (unit, inventory) Masc_tui_fetched.t
  ; not_before : float option
  }

let initial = { fetched = Masc_tui_fetched.initial; not_before = None }

(* [refresh] and not [start]: over a failure only [refresh] keeps the failure in
   view while the retry runs, so a server that stays down does not flip the
   line between "read failed" and "not read" every interval. It supersedes a
   read in flight, which is why that case is turned away first. *)
let start ~now t =
  let waiting =
    match t.not_before with
    | Some not_before -> now < not_before
    | None -> false
  in
  if waiting || Masc_tui_fetched.in_flight t.fetched
  then None
  else (
    match Masc_tui_fetched.refresh ~equal:Unit.equal t.fetched ~key:() with
    | Masc_tui_fetched.Already_loading -> None
    | Masc_tui_fetched.Started (fetched, request) -> Some ({ t with fetched }, request))

let complete ~next_read_at t request result =
  if Masc_tui_fetched.is_current ~equal:Unit.equal t.fetched request
  then
    { fetched = Masc_tui_fetched.complete ~equal:Unit.equal t.fetched request result
    ; not_before = Some next_read_at
    }
  else t

let suspend t = { t with fetched = Masc_tui_fetched.suspend t.fetched }

(* [Masc_tui_fetched.clear] keeps the generation counter, so a reply to a read
   made before this cannot pass for the next one. *)
let clear t = { fetched = Masc_tui_fetched.clear t.fetched; not_before = None }

type reading =
  | Not_read
  | Reading
  | Loaded of { world : inventory; refresh_failed : bool }
  | Read_failed

let reading t =
  match Masc_tui_fetched.view_for ~equal:Unit.equal t.fetched ~key:() with
  | Masc_tui_fetched.Absent -> Not_read
  | Masc_tui_fetched.Loading -> Reading
  | Masc_tui_fetched.Ready world -> Loaded { world; refresh_failed = false }
  | Masc_tui_fetched.Stale (world, _) -> Loaded { world; refresh_failed = true }
  | Masc_tui_fetched.Failed _ -> Read_failed

(* The words the line and the sheet share are spelled here once, so the screen
   and the sheet cannot name a state two ways. The briefing statuses are the
   server's words and stay as they are in Korean: translating [stale] would put
   a second meaning on a word RFC-0418 keeps for what the server wrote. *)
let unknown = "?"
let claim_noun = "claim"
let conflict_noun = "conflict"
let briefing_word = "briefing"
let building_word = "building"
let read_failed_word ~ko = if ko then "읽기 실패" else "read failed"
let no_ledger_word ~ko = if ko then "장부 없음" else "no ledger"
let label ~ko = if ko then "월드:" else "World:"

let briefing_status_word = function
  | Wire.Pending -> "pending"
  | Wire.Current -> "current"
  | Wire.Stale -> "stale"
  | Wire.Unavailable -> "unavailable"

let briefing_clause ~ko status =
  (if ko then "브리핑 " else briefing_word ^ " ") ^ briefing_status_word status

(* The word is the server's field name. The pass it names is on disk; the
   server does not say that a model is running now, and the legend row for the
   word says so. *)
let building_clause ~ko (pass : Wire.building_pass) =
  if ko
  then Printf.sprintf "%s, %d개 중 %d개 남음" building_word pass.Wire.target pass.Wire.remaining
  else Printf.sprintf "%s, %d of %d left" building_word pass.Wire.remaining pass.Wire.target

let count_clause ~ko ~korean_noun ~noun count =
  if ko
  then Printf.sprintf "%s %d건" korean_noun count
  else Masc_tui_message_layout.count_noun count noun

let value_clauses ~ko = function
  | Wire.Missing _ -> [ no_ledger_word ~ko ]
  | Wire.Available available ->
    let briefing = available.Wire.briefing in
    [ count_clause ~ko ~korean_noun:"공유 주장" ~noun:claim_noun available.Wire.claim_count
    ; count_clause ~ko ~korean_noun:"충돌" ~noun:conflict_noun available.Wire.conflict_count
    ; briefing_clause ~ko briefing.Wire.status
    ]
    @ (match briefing.Wire.building with
       | None -> []
       | Some pass -> [ building_clause ~ko pass ])

let clauses ~ko = function
  | Not_read | Reading -> [ unknown ]
  | Read_failed -> [ unknown; read_failed_word ~ko ]
  | Loaded { world; refresh_failed } ->
    value_clauses ~ko world @ (if refresh_failed then [ read_failed_word ~ko ] else [])

(* What each word does not say, because the server does not say it either
   (RFC-0511 W3): the counts are the curator's records, [current] is a match
   with the present sources and not a check of the text, and an open pass is a
   file on disk and not a model running now. The key sheet keeps its key column
   16 cells wide, so a longer key here would push its row's text out of line. *)
let legend =
  [ ( unknown
    , "world line: not read yet or still being read; nothing is known, and it is not zero" )
  ; ( read_failed_word ~ko:false
    , "world line: the inventory could not be read just now, because the request failed or \
       reading is suspended until the workspace is confirmed; any count beside it is from \
       an earlier read" )
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
