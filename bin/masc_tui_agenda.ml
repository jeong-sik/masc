type standing =
  | Coming
  | Settled
  | Unrecognised of string

(* The wire strings are [Schedule_domain.schedule_status_to_string]'s. Two of
   them are still ahead of the operator; the rest have already happened. A
   string outside the set is kept as itself rather than folded into [Settled]:
   "we do not know what this is" and "this is over" are different answers, and
   only one of them should silence a row for good. *)
let standing_of_wire = function
  | "scheduled" | "due" -> Coming
  | ("running" | "succeeded" | "failed" | "cancelled" | "expired") -> Settled
  | other -> Unrecognised other
;;

type scheduled =
  { at_iso : string
  ; standing : standing
  ; who : string
  ; what : string
  ; recurrence : string
  }

type awaiting =
  { asked_by : string
  ; tool_call_id : string
  ; question : string
  ; asked_at : float
  ; timeout_sec : float
  }

(* A Task with an unavailable Keeper route, an unreadable Keeper record or a
   completion awaiting a verdict. This does not establish that its owner has
   stopped or that a question was asked. *)
type stalled = Masc.Operator_task_attention.item

(* A Goal whose stored phase awaits operator confirmation. *)
type goal_to_confirm =
  { goal_id : string
  ; title : string
  ; since_iso : string
  }

(* An ask a Keeper put to the operator and nobody has answered. One row per
   ask, however many questions it holds: the operator answers an ask as one
   draft and one submit, so the ask is what is waiting. *)
type open_question =
  { ask : Masc.Tui_decode_asks.ask_key
  ; asked_by : string
  ; first_question : string option
  ; asked_at : float
  }

type 'row reading =
  | Not_read
  | Read_failed of string
  | Read of 'row list

type schedule_freshness = Last_read | Refresh_needed

type t =
  { coming : scheduled reading  (** earliest first *)
  ; scheduled_freshness : schedule_freshness
  ; blocked : awaiting reading
  ; asking : open_question reading  (** in the order the server sent them *)
  ; confirming : goal_to_confirm reading
  ; stuck : stalled reading  (** oldest claim/start first *)
  }

let rows_of = function
  | Read rows -> rows
  | Not_read | Read_failed _ -> []

let is_coming row = match row.standing with
  | Coming -> true
  | Settled | Unrecognised _ -> false
;;

(* RFC 3339 in UTC with a fixed shape, which the projection writes and the
   decoder passes through, so bytes order the same way instants do. Sorting
   here rather than trusting the payload: the projection orders active rows
   ahead of settled ones and then by due time, and a strip that depends on
   somebody else's sort is a strip that changes when their sort does. *)
let by_time left right = String.compare left.at_iso right.at_iso

let project ~scheduled ~scheduled_freshness ~awaiting ~asking ~confirming ~stalled =
  { coming =
      (match scheduled with
       | Read rows -> Read (rows |> List.filter is_coming |> List.sort by_time)
       | (Not_read | Read_failed _) as unread -> unread)
  ; scheduled_freshness
  ; blocked = awaiting
  ; asking
  ; confirming
  ; stuck = stalled
  }
;;

let next t = match rows_of t.coming with row :: _ -> Some row | [] -> None

(* A held call, a question, and a Goal awaiting confirmation need an operator
   response. An unavailable Task route is an observation, not a request.
   The badge names requests one by one
   ([waiting_label]); this total is what it falls back to when there is no room
   to name them. *)
let waiting t =
  List.length (rows_of t.blocked)
  + List.length (rows_of t.asking)
  + List.length (rows_of t.confirming)

(* Only a wake takes the row above the composer: what waits on the operator is
   on the surface strip at the top of every frame. One predicate, two readers:
   the row the frame draws and the row the keypress bound subtracts are the
   same row or neither exists. A section that was never read has no row to
   name, so the row stays down for it the same way; the overlay is where the
   difference is said. *)
let rows_taken t =
  match t.coming, t.scheduled_freshness with
  | Read _, Refresh_needed -> 1
  | (Not_read | Read_failed _ | Read _), (Last_read | Refresh_needed) ->
      if rows_of t.coming = [] then 0 else 1

(* The strip has one line to spend, so the clock stops at the minute, in the
   notation every screen draws a moment in (RFC tui-one-screen-grammar §6.1):
   [11:45] today, [08-27 11:45] this year. A wake the codec cannot read keeps
   its own text: a row that says nothing readable is still a row that says
   something is scheduled. *)
let hour_and_minute ~now ~localtime row =
  match Time_codec.parse_rfc3339_opt row.at_iso with
  | None -> Masc.Tui_terminal_text.short_timestamp_for_terminal ~localtime row.at_iso
  | Some at ->
    Masc_tui_value.Instant.detail_text ~localtime Masc_tui_value.Instant.To_minute
      ~now at
;;

let next_glyph = "\xe2\x96\xb8"

let clock_half ~now ~localtime ~cells row =
  let head = Printf.sprintf "%s %s  " next_glyph (hour_and_minute ~now ~localtime row) in
  let said =
    match String.trim row.what, String.trim row.who with
    | "", "" -> ""
    | "", who -> who
    | what, "" -> what
    | what, who -> Printf.sprintf "%s \xc2\xb7 %s" what who
  in
  let room = cells - Masc_tui_message_layout.display_width head in
  if room <= 0 then "" else head ^ Masc_tui_message_layout.fit_middle room said
;;

(* One phrase per request kind, questions first. *)
let waiting_phrases ~ko t =
  [ List.length (rows_of t.asking), "질문", "question", "questions"
  ; List.length (rows_of t.blocked), "보류된 호출", "held call", "held calls"
  ; List.length (rows_of t.confirming), "완료 확인 목표", "goal to confirm", "goals to confirm"
  ]
  |> List.filter_map (fun (count, korean, one, many) ->
    if count <= 0 then None
    else Some (if ko then Printf.sprintf "%s %d건" korean count
      else Printf.sprintf "%d %s" count (if count = 1 then one else many)))
;;

(* What waits on the operator, by kind, for the surface strip at the top of
   every frame. The key leads the badge. The panel behind [;] is the only
   screen that lists this work, and the footer that names [;] is among the
   first things a narrow terminal gives up, so the badge carries its own door.

   Three spellings, longest first, and the first that fits [cells] is drawn:
   the sentence, the kinds alone, the total alone. The total is the last
   resort and is returned even when it does not fit, because a badge that
   vanishes is worse than one the ring has to make room for. *)
let waiting_label ~ko ~cells t =
  match waiting_phrases ~ko t with
  | [] -> ""
  | phrases ->
    let listed = String.concat " \xc2\xb7 " phrases in
    let spellings =
      [ (if ko then "; 확인 필요: " else "; Awaiting you: ") ^ listed
      ; "; " ^ listed
      ]
    in
    let total = Printf.sprintf (if ko then "; 확인 필요 %d건" else "; %d waiting") (waiting t) in
    let fits text = Masc_tui_message_layout.display_width text <= cells in
    (match List.find_opt fits spellings with
     | Some text -> text
     | None -> total)
;;

(* The row above the composer: the next wake, or nothing. *)
let strip ~ko ~now ~localtime ~cols t =
  match t.coming, t.scheduled_freshness with
  | Read _, Refresh_needed ->
      Some (Masc_tui_message_layout.fit_middle cols
        (if ko then "일정 정보가 오래됐을 수 있음" else "Schedule may be out of date"))
  | (Not_read | Read_failed _ | Read _), (Last_read | Refresh_needed) ->
      (match next t with
       | None -> None
       | Some row -> Some (clock_half ~now ~localtime ~cells:cols row))
;;

type tone =
  | Heading
  | Wake
  | Question
  | Quiet
  | Failed

(* Where a row leads. Most lead nowhere -- headings, the blank spacers, the
   note an empty section draws -- and a row that leads nowhere is a row the
   cursor does not stop on.

   The panel used to lead nowhere at all: it counted the work waiting on the
   operator and then had no way to reach any of it, which is a count rather
   than an answer. *)
type destination =
  | Nowhere
  | Keeper_holding of { keeper : string; tool_call_id : string }
      (** The exact held call; one Keeper can have several awaiting answers. *)
  | Ask_to_answer of Masc.Tui_decode_asks.ask_key  (** the ask, answered on Approvals *)
  | Goal_to_confirm of string  (** the Goal, confirmed on its own detail *)
  | Stuck_task of string  (** the task, read on its own detail *)

type line =
  { tone : tone
  ; text : string
  ; goes_to : destination
  }

(* Cells the left column keeps before the right one is dropped: a clock that
   has spilled onto a second day ("08:00 08/27") and enough of a name to tell
   two keepers apart. *)
let minimum_left_cells = 24

(* Two cells of indent under a heading, and the right-hand column laid against
   the far edge. One helper so the wake rows and the question rows land on the
   same two columns; laying each out where it is written is how two lists on
   one panel end up half a cell apart.

   What the row is for is on the left. The right is context, and it is dropped
   whole rather than cut when it will not fit: half a cron expression reads as
   a schedule that is not the one running. *)
let two_column ~cols left right =
  let width = Masc_tui_message_layout.display_width in
  let indent = "  " in
  let body = max 0 (cols - width indent) in
  let right = if width right + minimum_left_cells > body then "" else right in
  let separator = if right = "" then 0 else 2 in
  let room = max 0 (body - width right - separator) in
  let left = Masc_tui_message_layout.fit_middle room left in
  let gap = max 0 (body - width left - width right) in
  indent ^ left ^ String.make gap ' ' ^ right
;;

let said ~ko (row : scheduled) =
  match String.trim row.what, String.trim row.who with
  | "", "" -> if ko then "(제목 없음)" else "(untitled)"
  | "", who -> who
  | what, "" -> what
  | what, who -> Printf.sprintf "%s \xc2\xb7 %s" what who
;;

(* How long the operator has not answered. Coarse on purpose: the row exists
   because the wait is long, and minutes past the first day are noise. *)
let waited_since ~ko ~now since =
  let seconds = now -. since in
  if Float.compare seconds 0.0 <= 0
  then (if ko then "방금" else "just now")
  else (
    let whole = int_of_float seconds in
    if whole >= 86_400
    then Printf.sprintf (if ko then "%dd 동안 대기" else "%dd waiting") (whole / 86_400)
    else if whole >= 3_600
    then Printf.sprintf (if ko then "%dh 동안 대기" else "%dh waiting") (whole / 3_600)
    else Printf.sprintf (if ko then "%dm 동안 대기" else "%dm waiting") (whole / 60))
;;

(* When the task was claimed, started or submitted, in the zone the panel was
   handed, in the notation of the wake rows above it (RFC
   tui-one-screen-grammar §6.1). The backlog's RFC 3339 text is for copying,
   not for the row. A time that does not read is a value not reported
   (§6.4). *)
let since_text ~ko ~now ~localtime since_iso =
  match Time_codec.parse_rfc3339_opt since_iso with
  | None -> "?"
  | Some since ->
    let at =
      Masc_tui_value.Instant.detail_text ~localtime Masc_tui_value.Instant.To_minute
        ~now since
    in
    if ko then at ^ " 부터" else "since " ^ at
;;

(* A Goal's update time is not the time it began awaiting confirmation. *)
let updated ~ko ~now since_iso =
  match Time_codec.parse_rfc3339_opt since_iso with
  | None -> ""
  | Some since ->
    let seconds = now -. since in
    if Float.compare seconds 0.0 <= 0
    then (if ko then "방금 갱신" else "updated just now")
    else (
      let whole = int_of_float seconds in
      if whole >= 86_400
      then Printf.sprintf (if ko then "갱신 %dd 전" else "updated %dd ago") (whole / 86_400)
      else if whole >= 3_600
      then Printf.sprintf (if ko then "갱신 %dh 전" else "updated %dh ago") (whole / 3_600)
      else Printf.sprintf (if ko then "갱신 %dm 전" else "updated %dm ago") (whole / 60))
;;

let overlay ~ko ~now ~localtime ~cols t =
  let say korean english = if ko then korean else english in
  let quiet text = { tone = Quiet; text = "  " ^ text; goes_to = Nowhere } in
  (* Why it failed, not only that it did. The reason is beside the flag in the
     state -- "schedule load failed: HTTP 503" -- and this panel dropped it,
     leaving two words that name neither the source nor the fault. Fitted like
     any other row here, so a long transport error cannot push the frame. *)
  let failure ~cols reason =
    (* No "load failed:" in front: the loader's own message already opens with
       the read that failed ("schedule load failed: HTTP 503"), and a prefix
       made the row stutter the way the Gate row did before #35436. *)
    (* Row-budget queries also project the agenda. Only the overlay displays
       read failures, so sanitize here, before measuring or clipping text. *)
    let reason = Masc.Tui_terminal_text.sanitize_terminal_text reason in
    { tone = Failed; text = two_column ~cols reason ""; goes_to = Nowhere }
  in
  (* An empty section is an answer only once its list was read. Before that,
     or when the read failed, each section's empty note was said about a list
     no one had seen. *)
  let wakes =
    match t.coming with
    | Not_read -> [ quiet (say "미조회" "not loaded yet") ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] when t.scheduled_freshness = Refresh_needed ->
      [ quiet (if ko then "일정 정보가 오래됐을 수 있음" else "Schedule may be out of date") ]
    | Read [] -> [ quiet (say "예정된 일정 없음" "nothing is scheduled") ]
    | Read rows ->
      (if t.scheduled_freshness = Refresh_needed then
         [ quiet (if ko then "일정 정보가 오래됐을 수 있음" else "Schedule may be out of date") ]
       else []) @ List.map
        (fun row ->
           { tone = Wake
           ; goes_to = Nowhere
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf
                    "%-6s  %s"
                    (hour_and_minute ~now ~localtime row)
                    (said ~ko row))
                 row.recurrence
           })
        rows
  in
  let questions =
    match t.blocked with
    | Not_read -> [ quiet (say "미조회" "not loaded yet") ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] -> [ quiet (say "보류된 호출 없음" "no keeper is holding a call") ]
    | Read rows ->
      List.map
        (fun (held : awaiting) ->
           { tone = Question
           ; goes_to = Keeper_holding { keeper = held.asked_by; tool_call_id = held.tool_call_id }
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf (if ko then "%s \xc2\xb7 %s 호출 보류 중" else "%s is holding %s")
                    held.asked_by held.question)
                 (waited_since ~ko ~now held.asked_at)
           })
        rows
  in
  let asked =
    match t.asking with
    | Not_read -> [ quiet (say "미조회" "not loaded yet") ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] -> [ quiet (say "답을 기다리는 질문 없음" "no keeper has asked a question") ]
    | Read rows ->
      List.map
        (fun (row : open_question) ->
           (* The asker wrote both, so both are made safe to draw before the
              row is measured; a question's line breaks are content and are
              kept as marks rather than dropped. *)
           let keeper = Masc.Tui_terminal_text.sanitize_terminal_text row.asked_by in
           { tone = Question
           ; goes_to = Ask_to_answer row.ask
           ; text =
               two_column
                 ~cols
                 (match row.first_question with
                  | Some question ->
                    Printf.sprintf (if ko then "%s 의 질문: %s" else "%s asks: %s") keeper
                      (Masc.Tui_terminal_text.preview_line question)
                  | None -> Printf.sprintf (if ko then "%s 의 질문" else "%s asked a question") keeper)
                 (waited_since ~ko ~now row.asked_at)
           })
        rows
  in
  let stuck =
    match t.stuck with
    | Not_read -> [ quiet (say "미조회" "not loaded yet") ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] -> [ quiet (say "운영자 목록에 작업 없음" "no task is on the operator list") ]
    (* Every row, oldest first. The panel scrolls, and a row the cursor
       cannot reach is work the operator cannot open. *)
    | Read rows ->
      List.map
        (fun (row : stalled) ->
           { tone = Quiet
           ; goes_to = Stuck_task (Masc.Operator_task_attention.task_id row)
           ; text = two_column ~cols
               (Masc.Tui_terminal_text.preview_line
                  (Masc.Operator_task_attention.summary ~ko row))
               (since_text ~ko ~now ~localtime
                  (Masc.Operator_task_attention.waiting_since row))
           })
        rows
  in
  let goals =
    match t.confirming with
    | Not_read -> [ quiet (say "미조회" "not loaded yet") ]
    | Read_failed reason -> [ failure ~cols reason ]
    (* Short enough for the narrowest panel, like the other notes: a quiet
       row is not fitted. *)
    | Read [] -> [ quiet (say "확인 대기 목표 없음" "no goal awaits confirmation") ]
    | Read rows ->
      List.map
        (fun (row : goal_to_confirm) ->
           { tone = Question
           ; goes_to = Goal_to_confirm row.goal_id
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf
                    (if ko then "%s \xc2\xb7 확인 대기" else "%s \xe2\x80\x94 awaiting confirmation")
                    row.title)
                 (updated ~ko ~now row.since_iso)
           })
        rows
  in
  let heading text = { tone = Heading; text; goes_to = Nowhere } in
  let blank = { tone = Quiet; text = ""; goes_to = Nowhere } in
  (heading (say "다가오는 일정" "Coming up") :: wakes)
  (* The operator task list remains inspectable but is not a request. *)
  @ [ blank; heading (say "보류된 호출" "Holding a call") ]
  @ questions
  @ [ blank; heading (say "답할 질문" "Answer a question") ]
  @ asked
  @ [ blank; heading (say "완료 확인 목표" "Confirm a goal") ]
  @ goals
  @ [ blank; heading (say "운영자 목록의 작업" "Tasks on the operator list") ]
  @ stuck
;;

(** Indexes of the rows Enter can act on, in display order. The cursor moves
    over these, not over prose -- the same shape the answering overlay walks
    its own lines with, so two panels that both step a subset of their rows
    step it the same way. *)
let target_indexes lines =
  let rec loop index acc = function
    | [] -> List.rev acc
    | line :: rest ->
      loop
        (index + 1)
        (match line.goes_to with
         | Nowhere -> acc
         | Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _
         | Stuck_task _ -> index :: acc)
        rest
  in
  loop 0 [] lines
;;

(* Two destinations are the same target when they name the same held call,
   Goal or task, or the same ask by [Masc.Tui_decode_asks.equal_ask_key]: an
   installation's title is the package's and does not name the ask. *)
let equal_destination left right =
  match left, right with
  | Nowhere, Nowhere -> true
  | Keeper_holding left, Keeper_holding right ->
      String.equal left.keeper right.keeper && String.equal left.tool_call_id right.tool_call_id
  | Ask_to_answer left, Ask_to_answer right -> Masc.Tui_decode_asks.equal_ask_key left right
  | Goal_to_confirm left, Goal_to_confirm right | Stuck_task left, Stuck_task right ->
      String.equal left right
  | (Nowhere | Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _ | Stuck_task _), _ -> false
;;

let selected_index lines ~selected =
  match selected with
  | Nowhere -> None
  | Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _ | Stuck_task _ ->
      List.find_index (fun line -> equal_destination line.goes_to selected) lines
;;

let selected_line lines ~selected =
  Option.bind (selected_index lines ~selected) (List.nth_opt lines)
;;

type step = Next | Previous

let step lines ~selected direction =
  let targets =
    List.filter_map (fun line ->
      match line.goes_to with
      | Nowhere -> None
      | (Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _ | Stuck_task _)
        as target -> Some target)
      lines
  in
  match targets with
  | [] -> Nowhere
  | first :: _ ->
      (match List.find_index (equal_destination selected) targets with
       | None -> first
       | Some index ->
           let next = match direction with
             | Next -> min (List.length targets - 1) (index + 1)
             | Previous -> max 0 (index - 1)
           in
           List.nth targets next)
;;
