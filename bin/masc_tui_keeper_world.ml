module World = Masc_tui_memory_world
module Wire = Masc.Tui_decode_workspace_memory
module Health = Masc.Tui_decode_memory_health
module Ladder = Masc_tui_keeper_age_ladder
module Model = Masc_tui_keeper_list_model
module Layout = Masc_tui_message_layout
module Terminal_text = Masc_tui_ansi.Terminal_text

type pulse = Ledger_and_briefing | Fact_ages of Masc.Keeper_memory_age_bins.t option
type row_cells = { pulse : pulse; now_cell : string; strip : string; due : string; right : string }

(* The status marks of RFC tui-one-screen-grammar 7.2 and the missing-value
   marks of 6.4. A briefing not yet published waits, a current one is
   settled, a stale one is the 오래됨 caution, and one the server could not
   give read failed. A world not read yet or being read is [◌] (6.4 names
   both), and one that failed to read [✕], rather than one [?] for all. *)
let marked mark word = mark ^ " " ^ word

let briefing_word ~ko = function
  | Wire.Pending ->
      marked (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Waiting)
        (if ko then "대기 중" else "pending")
  | Wire.Current ->
      marked (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Settled)
        (if ko then "최신" else "current")
  | Wire.Stale ->
      marked (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Caution)
        (if ko then "오래됨" else "stale")
  | Wire.Unavailable ->
      marked (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed)
        (if ko then "없음" else "unavailable")

let now_word ~ko = function
  | World.Not_read ->
      marked (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread)
        (if ko then "미조회" else "not read")
  | World.Reading ->
      marked (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread)
        (if ko then "읽는 중" else "reading")
  | World.Read_failed _ ->
      marked (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed)
        (if ko then "읽기 실패" else "read failed")
  | World.Loaded { world; refresh_failure } ->
      let word = match world with
        | Wire.Missing _ -> if ko then "— 원장 없음" else "— no ledger"
        | Wire.Available world -> briefing_word ~ko world.Wire.briefing.status in
      (* The reading shown is the last one; a refresh after it failed, so it
         may be old. *)
      word ^ (match refresh_failure with
        | None -> ""
        | Some _ -> " " ^ Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Caution)

let inventory_absence = function
  | Wire.Missing { ordinary_absence; _ } -> ordinary_absence
  | Wire.Available world -> world.Wire.ordinary_absence

let absence_number ~ko = function
  | World.Not_read | World.Reading | World.Read_failed _ -> "?"
  | World.Loaded { world; refresh_failure } ->
      let value = match inventory_absence world with
        | Wire.Absence_complete counts -> string_of_int counts.absent
        | Wire.Absence_partial { counts; _ } -> "≥" ^ string_of_int counts.absent
        | Wire.Absence_unavailable _ -> "?" in
      (match refresh_failure with None -> "" | Some _ -> if ko then "이전 " else "last ") ^ value

let fleet_ladder snapshot =
  Ladder.fleet_of ~refused_rows:(List.length snapshot.Health.mhs_refused_keepers)
    snapshot.Health.mhs_keepers

let age_bins = function
  | None -> None
  | Some snapshot ->
      (match fleet_ladder snapshot with
       | Ladder.Nobody_measured _ -> None
       | Ladder.Measured { unmeasured_keepers = 0; bins } -> Some bins
       | Ladder.Measured { unmeasured_keepers = _; bins = _ } -> None)

let row_cells ~ko ~health_error ~view snapshot world =
  let partial_reads = match snapshot with
    | None -> false
    | Some snapshot -> snapshot.Health.mhs_total_read_errors > 0
        || snapshot.mhs_total_source_read_errors > 0 in
  let age = match view with
    | Model.By_age -> true
    | Model.Plain | Model.By_state | Model.By_cause | Model.By_time
    | Model.By_memory | Model.By_runtime | Model.Day_wall -> false in
  { pulse = if age then Fact_ages (age_bins snapshot) else Ledger_and_briefing
  ; now_cell = (match health_error with
      | Some _ -> "mem! "
      | None -> if partial_reads then "mem! " else "") ^ now_word ~ko world
  ; strip = absence_number ~ko world ^ (if ko then " 누락" else " absent")
  ; due = if age then (match snapshot with
      | Some snapshot when not partial_reads -> let count = snapshot.Health.mhs_total_source_invalidations
          + snapshot.mhs_total_support_invalidations in
          if count = 0 then "" else "×" ^ Layout.compact_count count
      | Some _ | None -> "?") else "?"
  ; right = if age then (match snapshot with
      | Some snapshot when snapshot.Health.mhs_total_read_errors = 0 ->
          Layout.compact_count snapshot.mhs_total_facts
      | Some _ | None -> "?") else "?" }

let health_partial = function
  | None -> false
  | Some snapshot -> snapshot.Health.mhs_total_read_errors > 0
      || snapshot.mhs_total_source_read_errors > 0
      || snapshot.mhs_refused_keepers <> []

let memory_summary ~ko ~health_error snapshot =
  let say korean english = if ko then korean else english in
  let qualifiers = (match health_error with
    | Some _ -> [say "읽기 실패 · 이전 합계" "read failed; earlier totals"] | None -> [])
    @ (if health_partial snapshot then [say "일부 집계" "partial counts"] else []) in
  qualifiers @ (match snapshot with
    | None -> ["?"]
    | Some snapshot -> [Printf.sprintf (if ko then "일반 %s + 원본 %s" else "%s ordinary + %s source facts")
        (Layout.compact_count snapshot.Health.mhs_total_facts)
        (Layout.compact_count snapshot.Health.mhs_total_source_facts)])

let world_failed = function
  | World.Read_failed _ | World.Loaded { refresh_failure = Some _; _ } -> true
  | World.Not_read | World.Reading | World.Loaded { refresh_failure = None; _ } -> false

let inventory_summary ~ko world =
  let say korean english = if ko then korean else english in
  let qualifier = if world_failed world then [say "읽기 실패 · 이전 목록" "read failed; earlier inventory"] else [] in
  qualifier @ (match world with
    | World.Not_read | World.Reading -> [now_word ~ko world]
    | World.Read_failed _ ->
        [Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed]
    | World.Loaded { world = Wire.Missing _; _ } -> [say "원장 없음" "no ledger"]
    | World.Loaded { world = Wire.Available world; _ } ->
        [Printf.sprintf (if ko then "주장 %s / 충돌 %s" else "%s claims / %s conflicts")
          (Layout.compact_count world.Wire.claim_count) (Layout.compact_count world.conflict_count)])

let detail_lines ~ko ~health_error ~cells snapshot world =
  let say korean english = if ko then korean else english in
  let health = match health_error with None -> [] | Some error ->
    [say "기억 읽기 실패 · " "memory read failed · " ^ Terminal_text.single_line error] in
  let inventory = if world_failed world then
    [String.concat " · " (World.clauses ~ko ~room:cells world)] else [] in
  let memory = match snapshot with
    | None -> []
    | Some snapshot ->
        [Printf.sprintf
           (if ko then "Keeper %d행 / 거부 %d / 일반 오류 %d / 원본 오류 %d"
            else "Keeper rows %d / refused %d / ordinary read errors %d / source read errors %d")
          (List.length snapshot.Health.mhs_keepers) (List.length snapshot.mhs_refused_keepers)
          snapshot.mhs_total_read_errors snapshot.mhs_total_source_read_errors
        ; say "나이별 일반 사실 · " "ordinary facts by age · " ^ String.concat " · "
            (Ladder.fleet_clauses ~ko (fleet_ladder snapshot))] in
  let inventory_details = match world with
    | World.Not_read | World.Reading | World.Read_failed _
    | World.Loaded { world = Wire.Missing _; _ } -> []
    | World.Loaded { world = Wire.Available world; _ } ->
        [Printf.sprintf (if ko then "원장 · 제외 %d / 분류 %d" else "ledger · %d excluded / %d classified")
          world.Wire.excluded_count world.classified_count]
        @ (match world.briefing.building with None -> [] | Some pass ->
            [Printf.sprintf (if ko then "브리핑 생성 중 · %d/%d 남음" else "briefing building · %d of %d left")
               pass.Wire.remaining pass.target]) in
  let stores (counts : Wire.absence_counts) unavailable =
    Printf.sprintf
      (if ko then "일반 저장소 · 읽음 %d / 없음 %d / 읽기 불가 %d"
       else "ordinary stores · %d read / %d missing / %d unreadable")
      counts.available_stores counts.missing_stores unavailable in
  let absence_details = match world with
    | World.Not_read | World.Reading | World.Read_failed _ -> []
    | World.Loaded { world; refresh_failure = _ } ->
        (match inventory_absence world with
         | Wire.Absence_unavailable detail ->
             [say "일반 포함 여부 미조회 · " "ordinary membership unread · " ^ Terminal_text.single_line detail]
         | Wire.Absence_complete counts -> [stores counts 0]
         | Wire.Absence_partial { counts; unavailable_stores } -> [stores counts unavailable_stores]) in
  health @ inventory @ memory @ inventory_details @ absence_details
    @ [say "누락된 일반 사실 · " "absent ordinary facts · " ^ absence_number ~ko world
      ; say "▹ 다음 · 예정 시각 없음" "▹ Next · no time announced"]

let dock_lines ~ko ~health_error ~cells ~max_lines snapshot world =
  let say korean english = if ko then korean else english in
  let stage tag clauses = Layout.join_fitting ~sep:" · " ~cells (tag :: clauses) in
  let memory = memory_summary ~ko ~health_error snapshot in
  let ledger = inventory_summary ~ko world @ [say "일반 누락 " "ordinary absent " ^ absence_number ~ko world] in
  let briefing = now_word ~ko world in
  let core =
    [ stage (say "◂ Keeper" "◂ Keepers") memory
    ; stage (say "↓ 원장" "↓ Ledger") ledger
    ; stage (say "● 브리핑" "● Briefing") [briefing]
    ]
  in
  if max_lines <= 0 then []
  else if max_lines >= List.length core then
    let details = detail_lines ~ko ~health_error ~cells snapshot world
      |> List.concat_map (Layout.wrap_words ~max_cells:(max 1 cells)) in
    core @ List.take (max_lines - List.length core) details
  else
    let combined =
      say "Keeper " "Keepers " ^ String.concat ", " memory
      ^ say " → 원장 " " → Ledger "
      ^ String.concat ", " ledger ^ " → " ^ briefing in
    let wrapped = Layout.wrap_words ~max_cells:(max 1 cells) combined in
    if List.length wrapped <= max_lines then wrapped
    else [stage (match health_error with
        | Some _ -> say "기억 읽기 실패" "memory read failed"
        | None -> if world_failed world then say "세계 읽기 실패" "world read failed"
            else say "공유 세계" "world") [say "일부 보기" "partial view"]]
