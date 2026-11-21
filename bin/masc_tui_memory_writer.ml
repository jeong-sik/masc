module Writer = Masc.Tui_decode_memory_writer
module Level = Masc.Librarian_level
open Writer

let text ~ko korean english = if ko then korean else english
let grouped = Masc_tui_value.Count.grouped
let heading ~ko = text ~ko "기억 쓰는 쪽" "Memory writer"

let level_text ~ko : Level.level -> string = function
  | Level.Ok -> text ~ko "정상" "ok"
  | Level.Warn -> text ~ko "경고" "warn"
  | Level.Error -> text ~ko "오류" "error"
;;

(* The refusal E4 reads, in the words its alarm row and its last-read row
   share: the two rows of one detail say it in one order. *)
let every_slot_refused_the_one_item ~ko =
  text ~ko "항목 하나를 모든 slot 이 거절함" "every slot refused the one item"
;;

let alarm_text ~ko : Level.alarm -> string = function
  | Level.E1 -> text ~ko "E1 저장소가 멈춤" "E1 the store is stopped"
  | Level.E2 ->
    text
      ~ko
      "E2 선언한 slot 이 모두 맨 앞 항목을 크기로 거절함"
      "E2 every declared slot refused the head item for its size"
  | Level.E3 ->
    text
      ~ko
      "E3 안 읽은 것이 있고 마지막 읽기가 입력 결함이나 실패로 끝남"
      "E3 unread; the last read ended in an input fault or failure"
  | Level.E4 ->
    "E4 "
    ^ every_slot_refused_the_one_item ~ko
    ^ text ~ko ", 크기 사실 없는 거절 있음" ", one without a size fact"
  | Level.E5 ->
    text
      ~ko
      "E5 Memory 가 선언한 어느 slot 에도 들어가지 않음"
      "E5 Memory fits no declared slot"
  | Level.W1 -> text ~ko "W1 안 읽은 것을 아직 읽지 못함" "W1 unread is not read yet"
  | Level.W3 ->
    text
      ~ko
      "W3 마지막 읽기 반영이 Memory 없이 됨"
      "W3 the last committed read was without Memory"
;;

let asked_text ~ko = function
  | Asked_range -> text ~ko "범위 읽기" "a range"
  | Asked_item_alone -> text ~ko "항목 하나만 읽기" "one item alone"
  | Asked_room -> text ~ko "자리 내기" "room"
;;

let stop_text ~ko = function
  | Log_diverged ->
    text ~ko "반영 기록과 스냅샷이 어긋남" "the commit log and the snapshot disagree"
  | Memory_unreadable -> text ~ko "스냅샷을 읽지 못함" "the snapshot does not read"
  | Log_unreadable -> text ~ko "반영 기록을 읽지 못함" "the commit log does not read"
  | Store_unwritable -> text ~ko "저장소에 쓸 수 없음" "the store cannot be written"
  | Store_raised -> text ~ko "쓰는 쪽 코드가 예외로 멈춤" "the writer's code raised"
;;

let state_text ~ko = function
  | Booting -> text ~ko "시작 중" "starting"
  | Retired -> text ~ko "물러남" "retired"
  | Open { activity = Idle; _ } -> text ~ko "대기" "idle"
  | Open { activity = Asking asking; _ } ->
    text ~ko "묻는 중 · " "asking · " ^ asked_text ~ko asking.asked
  | Open { activity = Resting; _ } ->
    text ~ko "쉼 · 마지막 묻기가 반영 없이 끝남" "resting: the last ask ended without a commit"
  | Open { activity = Refused_at_bottom; _ } ->
    text ~ko "맨 앞 항목이 거절됨" "the head item is refused"
  | Stopped { stop; _ } -> text ~ko "멈춤 · " "stopped · " ^ stop_text ~ko stop
;;

let unread_text ~ko = function
  | Booting ->
    Some (text ~ko "안 읽은 것은 시작이 끝나야 앎" "unread is known once it has started")
  | Retired -> None
  | Open { unread = true; _ } -> Some (text ~ko "안 읽은 것 있음" "unread")
  | Open { unread = false; _ } -> Some (text ~ko "안 읽은 것 없음" "nothing unread")
  | Stopped _ ->
    Some (text ~ko "안 읽은 것은 멈춘 동안 셀 수 없음" "unread cannot be told while stopped")
;;

let slot_outcome_text ~ko = function
  | Input_too_large -> text ~ko "입력이 큼" "input too large"
  | Output_over_reserve -> text ~ko "출력이 몫을 넘음" "output over the reserve"
  | Window_reached -> text ~ko "창이 참" "window reached"
  | Refused -> text ~ko "크기 사실 없이 거절" "refused without a size fact"
  | Not_called -> text ~ko "부르지 않음" "not called"
  | Unavailable -> text ~ko "쓸 수 없음" "unavailable"
  | Busy -> text ~ko "바쁨" "busy"
  | Overdue -> text ~ko "기한을 넘김" "overdue"
  | Lost -> text ~ko "응답이 끊김" "lost"
  | Unusable -> text ~ko "답을 쓸 수 없음" "unusable answer"
;;

let input_fault_text ~ko = function
  | Line_unreadable { offset } ->
    Printf.sprintf
      (if ko
       then "턴 기록의 줄을 해석하지 못함 (offset %s)"
       else "a turn log line does not parse (offset %s)")
      (grouped offset)
  | Turn_log_replaced { expected; observed } ->
    Printf.sprintf
      (if ko
       then "턴 기록 파일이 바뀜 (읽던 파일 %s, 지금 파일 %s)"
       else "the turn log file was replaced (was %s, now %s)")
      expected
      (match observed with
       | Some observed -> observed
       | None -> text ~ko "id 없음" "no id")
  | Position_lost { offset; length } ->
    Printf.sprintf
      (if ko
       then "읽던 자리를 잃음 (offset %s, 파일 길이 %s)"
       else "the reading position is lost (offset %s, file length %s)")
      (grouped offset)
      (grouped length)
  | Content_unreadable { line } ->
    Printf.sprintf
      (if ko
       then "단위의 내용을 읽지 못함 (턴 기록 줄 %s)"
       else "a unit's content does not read (turn log line %s)")
      (grouped line)
;;

let ask_failure_text ~ko = function
  | Raised -> text ~ko "예외" "raised"
  | Flow_stopped -> text ~ko "흐름이 끊김" "flow stopped"
  | Read_failed -> text ~ko "읽기 실패" "read failed"
;;

let none_since_start ~ko = text ~ko "시작 뒤 끝난 것 없음" "none ended since the start"

(* An end is about the Memory and the lane value of its ask. Once either is
   another, the alarm that reads the end is off, and the end says which. *)
let memory_changed_since ~ko = text ~ko "그 뒤 Memory 가 바뀜" "Memory changed since"
let lane_changed_since ~ko = text ~ko "그 뒤 lane 값이 바뀜" "the lane value changed since"

(* The ending alone, for a clause beside the state. *)
let last_read_short ~ko = function
  | None -> none_since_start ~ko
  | Some Read_committed -> text ~ko "반영됨" "committed"
  | Some (Read_refused_not_all_sized _) -> every_slot_refused_the_one_item ~ko
  | Some (Read_lane _) -> text ~ko "답한 slot 없음" "no slot answered"
  | Some (Read_input_fault _) -> text ~ko "입력 결함" "input fault"
  | Some (Read_ask_failed _) -> text ~ko "묻기 실패" "ask failed"
;;

let last_read_clauses ~ko =
  let slot_clauses slots =
    List.map (fun (slot, outcome) -> slot ^ " " ^ slot_outcome_text ~ko outcome) slots
  in
  function
  | (None | Some Read_committed) as last -> [ last_read_short ~ko last ]
  | Some (Read_refused_not_all_sized { about_memory_now; about_lane_now; slots }) as last ->
    [ last_read_short ~ko last ]
    @ (if about_memory_now then [] else [ memory_changed_since ~ko ])
    @ (if about_lane_now then [] else [ lane_changed_since ~ko ])
    @ slot_clauses slots
  | Some (Read_lane { one_item; silent; about_memory_now; slots }) as last ->
    [ last_read_short ~ko last ]
    @ (if one_item then [ text ~ko "항목 하나를 물음" "asked one item" ] else [])
    @ (if silent then [ text ~ko "말 없는 slot 있음" "a slot was silent" ] else [])
    @ (if about_memory_now then [] else [ memory_changed_since ~ko ])
    @ slot_clauses slots
  | Some (Read_input_fault fault) as last ->
    [ last_read_short ~ko last; input_fault_text ~ko fault ]
  | Some (Read_ask_failed failure) as last ->
    [ last_read_short ~ko last; ask_failure_text ~ko failure ]
;;

let last_read_text ~ko last = String.concat " · " (last_read_clauses ~ko last)

let last_room_text ~ko = function
  | None -> none_since_start ~ko
  | Some Room_made -> text ~ko "자리를 냄" "made room"
  | Some Room_unchanged -> text ~ko "바뀐 것 없음" "nothing changed"
  | Some Room_stale ->
    text ~ko "묻는 사이 직접 쓰기가 있어 버림" "dropped: a direct write came while it was asked"
  | Some Room_not_judged -> text ~ko "판정하지 못함" "not judged"
  | Some (Room_fits_none { about_memory_now; about_lane_now }) ->
    text ~ko "어느 slot 에도 들어가지 않음" "fits no slot"
    ^ (if about_memory_now then "" else " · " ^ memory_changed_since ~ko)
    ^ if about_lane_now then "" else " · " ^ lane_changed_since ~ko
;;

let position_text ~ko = function
  | Before_first -> text ~ko "아직 읽은 것 없음" "nothing read yet"
  | Through { line; within_item = false } ->
    Printf.sprintf
      (if ko then "턴 기록 줄 %s 까지 읽음" else "read through turn log line %s")
      (grouped line)
  | Through { line; within_item = true } ->
    Printf.sprintf
      (if ko then "턴 기록 줄 %s 의 단위를 읽는 중" else "reading the unit at turn log line %s")
      (grouped line)
;;

let last_line_text ~ko = function
  | Line_started -> text ~ko "시작 줄" "start line"
  | Line_commit { seq } ->
    Printf.sprintf (if ko then "반영 #%s" else "commit #%s") (grouped seq)
;;

let snapshot_file_text ~ko = function
  | File { sha; bytes } ->
    Printf.sprintf "sha %s · %s B" (Masc_tui_value.Hash.short sha) (grouped bytes)
  | File_absent -> text ~ko "파일 없음" "no file"
  | File_not_a_snapshot -> text ~ko "스냅샷 파일이 아님" "not a snapshot file"
  | File_not_read -> text ~ko "파일을 읽지 못함" "the file was not read"
;;

let none_in_process_text ~ko = text ~ko "서버가 띄우지 않음" "not started by the server"

let no_writer_text ~ko =
  text ~ko "없음 · 등록되지 않은 Keeper" "none: the Keeper is not registered"
;;

let card_clauses ~ko = function
  | None_in_process -> [ none_in_process_text ~ko ]
  | No_writer -> [ no_writer_text ~ko ]
  | Writer { row; level = _; alarms = _ } ->
    [ state_text ~ko row ]
    @ Option.to_list (unread_text ~ko row)
    @
    (match row with
     | Open { kept; _ } | Stopped { kept; _ } ->
       [ text ~ko "마지막 읽기 " "last read " ^ last_read_short ~ko kept.last_read ]
     | Booting | Retired -> [])
;;

type tone =
  | Tone_warn
  | Tone_error

let tone_of_level : Level.level -> tone option = function
  | Level.Ok -> None
  | Level.Warn -> Some Tone_warn
  | Level.Error -> Some Tone_error
;;

let attention_rows ~ko = function
  | None_in_process -> [ Tone_warn, heading ~ko ^ " · " ^ none_in_process_text ~ko ]
  | No_writer -> []
  | Writer { alarms; level = _; row = _ } ->
    List.filter_map
      (fun alarm ->
         Option.map
           (fun tone -> tone, heading ~ko ^ " · " ^ alarm_text ~ko alarm)
           (tone_of_level (Level.level [ alarm ])))
      alarms
;;

let detail_rows ~ko ~moment = function
  | None_in_process -> [ [ heading ~ko; none_in_process_text ~ko ] ]
  | No_writer -> [ [ heading ~ko; no_writer_text ~ko ] ]
  | Writer { level; alarms; row } ->
    let named reading = heading ~ko ^ " " ^ reading in
    let no_lane (kept : kept) =
      if kept.lane then [] else [ text ~ko "lane 값 없음" "no lane value" ]
    in
    let state_row =
      [ heading ~ko; level_text ~ko level; state_text ~ko row ]
      @ Option.to_list (unread_text ~ko row)
      @
      (match row with
       | Open { kept; _ } | Stopped { kept; _ } -> no_lane kept
       | Booting | Retired -> [])
    in
    let alarm_rows =
      List.map (fun alarm -> [ named (text ~ko "경보" "alarm"); alarm_text ~ko alarm ]) alarms
    in
    let kept_rows (kept : kept) =
      [ named (text ~ko "마지막 읽기" "last read") :: last_read_clauses ~ko kept.last_read
      ; [ named (text ~ko "마지막 자리 내기" "last room ask"); last_room_text ~ko kept.last_room ]
      ]
    in
    let place_rows =
      match row with
      | Booting | Retired -> []
      | Open
          { activity
          ; kept
          ; last_line
          ; last_line_at
          ; turn_log
          ; covers_through
          ; snapshot
          ; facts
          ; unread = _
          } ->
        (match activity with
         | Asking { ask; since; asked } ->
           [ [ named (text ~ko "묻는 중" "asking")
             ; asked_text ~ko asked
             ; text ~ko "시작 " "since " ^ moment since
             ; Printf.sprintf (if ko then "묻기 #%s" else "ask #%s") (grouped ask)
             ]
           ]
         | Idle | Resting | Refused_at_bottom -> [])
        @ kept_rows kept
        @ [ [ named (text ~ko "읽은 자리" "reading stands")
            ; position_text ~ko covers_through
            ; last_line_text ~ko last_line ^ " " ^ moment last_line_at
            ; Printf.sprintf (if ko then "fact %s개" else "%s facts") (grouped facts)
            ; text ~ko "스냅샷 " "snapshot " ^ Masc_tui_value.Hash.short snapshot
            ; text ~ko "턴 기록 " "turn log " ^ turn_log
            ]
          ]
      | Stopped { snapshot_file; kept; stop = _ } ->
        [ [ named (text ~ko "스냅샷 파일" "snapshot file"); snapshot_file_text ~ko snapshot_file ] ]
        @ kept_rows kept
    in
    (state_row :: alarm_rows) @ place_rows
;;
