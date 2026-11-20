open Masc.Tui_decode_memory_facts
open Masc_tui_types
open Masc.Tui_decode
open Masc.Tui_decode_memory_health
open Masc_tui_ansi

module Render_schedule = Masc_tui_render_schedule
module Message_layout = Masc_tui_message_layout
module Terminal_text = Masc_tui_ansi.Terminal_text
module Theme = Masc_tui_ansi.Theme
module Rows = Masc_tui_rows
module Memory_category = Masc.Keeper_memory_os_types
module Memory_usage = Masc_tui_memory_usage
module Chart = Masc_tui_chart
module Doc = Masc_tui_doc
module Memory_tree = Masc_tui_memory_tree

let librarian_failure_words ~ko kind =
  let text korean english = if ko then korean else english in
  match kind with
  | Masc.Tui_decode_memory_health.Failure_prompt_render -> text "프롬프트 구성 실패" "prompt could not be built"
  | Masc.Tui_decode_memory_health.Failure_execution_clock_unavailable -> text "실행 시계 없음" "no clock to run on"
  | Masc.Tui_decode_memory_health.Failure_exact_setup -> text "모델 호출 준비 실패" "model call could not be set up"
  | Masc.Tui_decode_memory_health.Failure_exact_execution -> text "모델 호출 실패" "model call failed"
  | Masc.Tui_decode_memory_health.Failure_domain_output_invalid -> text "모델 응답 사용 불가" "model answer was not usable"
  | Masc.Tui_decode_memory_health.Failure_absorb_judgment -> text "복사 검증 실패 · 저장 없음" "copy check failed; nothing saved"
  | Masc.Tui_decode_memory_health.Failure_memory_snapshot_write -> text "기억 저장 실패" "Memory could not be saved"
  | Masc.Tui_decode_memory_health.Failure_runtime_context_unavailable -> text "런타임 문맥 없음" "no runtime context"
  | Masc.Tui_decode_memory_health.Failure_lane_cancelled -> text "저장 전 취소" "cancelled before saving"
  | Masc.Tui_decode_memory_health.Failure_unhandled_exception -> text "예상하지 못한 실패" "unexpected crash"

(* How the facts title reads its own keeper. "*" is how the fleet view is asked
   for, not how it should be read, so the title reads it as a phrase. The title
   is drawn at every terminal size; a body row is not. *)
let facts_keeper_label ~ko = function
  | Some "*" -> if ko then "전체 키퍼" else "all keepers"
  | Some name -> name
  | None -> ""

(* What the title carries while the read is in flight and once it has landed.
   Typed so the two spellings cannot drift into each other's shape. The unread
   word arrives rendered: whether a read is still in
   flight or came back failed is the caller's reading, and
   [Masc_tui_types.here_missing_reading] is the one place that words it. *)
type facts_reading =
  | Facts_unread of { reading : string }
  | Facts_loaded of
      { total : int
      ; filter_label : string
      ; query_label : string
      }

(* What the facts title reads beside its path. Here beside the row under it
   so the two cannot disagree about which fact each one carries: the title
   says the total and the filters, the row says the breakdown and the sort.
   The title is the narrow line, so a fact spelled here and there goes off the
   right edge. *)
let facts_title_reading ~ko = function
  | Facts_unread { reading } -> reading
  | Facts_loaded { total; filter_label; query_label } ->
    Printf.sprintf "%s \xc2\xb7 %s%s"
      (if ko then Printf.sprintf "목록 %d개" total else Masc_tui_message_layout.count_noun total "listed row") filter_label
      query_label

(* The row under the facts title. The title says the total and the filter; this
   says how that total breaks down and which sort produced the order, so each
   fact is written in one place. The split runs in this direction because the
   title is the line with no room to spare: beside the Activity pane at the
   width it opens from, the title keeps only the pane's surface floor, less
   the frame, for the screen name, the keeper, the total, both filters and
   the badge.

   [grand_total] is not passed in because it is not drawn here. *)
let facts_stats_row ~ko ~ordinary ~source ~dropped ~sort_label =
  Printf.sprintf (if ko then "  %s목록: 일반 %d · 원본 %d · 무효화 %d%s · %s정렬 [s]:%s %s"
    else "  %sListed: %d ordinary · %d source · %d dropped%s · %sSort [s]:%s %s")
    (Theme.recede ()) ordinary source dropped Ansi.reset
    (Theme.recede ()) Ansi.reset sort_label

let memory_category_filter_text ~ko = function
  | Category_all -> if ko then "전체" else "All"
  | Category_ordinary category -> fst (Memory_tree.category_badge ~ko category)
  | Category_source -> if ko then "원본" else "source"
  | Category_dropped -> if ko then "무효화" else "dropped"

let memory_sort_text ~ko sort =
  if not ko then memory_sort_order_label sort
  else match sort with
    | Sort_recency -> "최근 관측순"
    | Sort_last_retrieved -> "최근 조회순"
    | Sort_retrieved_count -> "조회 많은 순"
    | Sort_category -> "분류순"
    | Sort_claim -> "내용순"

let memory_counts_complete state =
  match memory_facts_view state with
  | Masc_tui_fetched.Ready (_, unread)
  | Stale ((_, unread), _) -> Option.is_none unread
  | Absent | Loading | Failed _ -> false

let category_count state snapshot category =
  let scope = match category with
    | Category_all -> All_facts
    | Category_ordinary category -> Ordinary_facts (Some category)
    | Category_source -> Source_facts
    | Category_dropped -> Dropped_facts in
  memory_fact_count ~complete:(memory_counts_complete state) snapshot scope

let memory_facts_scope_lines ?(full = false) ~cols (state : state) =
  let text ko en = ui_text state ~ko ~en in
  let kept_back refusal =
    Terminal_text.single_line
      (workspace_refusal_text ~ko:(state.ui_language = Lang_ko)
         ~request:Kept_request.Memory_facts_read refusal) in
  let lines = (match memory_facts_reading state with
    | Masc_tui_fetched.Stale ((_, unread), failure) ->
        (match failure with
         | Request_failed detail ->
             [text "이전 관측 · 갱신 실패: " "Previous observation; refresh failed: " ^ Terminal_text.single_line detail]
         | Request_withdrawn refusal -> [kept_back refusal])
        @ (match unread with None -> [] | Some detail ->
            [text "일부 관측: " "Partial observation: " ^ Terminal_text.single_line detail])
    | Ready (_, Some detail) ->
        [text "일부 관측: " "Partial observation: " ^ Terminal_text.single_line detail]
    | Failed (Request_failed detail) -> [text "조회 실패: " "Read failed: " ^ Terminal_text.single_line detail]
    | Failed (Request_withdrawn refusal) -> [kept_back refusal]
    | Absent | Loading | Ready (_, None) -> [])
    @ (match memory_facts_snapshot state with
       | None -> []
       | Some snapshot ->
           (match snapshot.mfs_ordinary with
            | Memory_store_read_error detail -> [text "일반 저장소 조회 실패: " "Ordinary store unreadable: " ^ Terminal_text.single_line detail]
            | Memory_store_absent | Memory_store_present _ -> [])
           @ (match snapshot.mfs_source with
              | Memory_store_read_error detail -> [text "원본 저장소 조회 실패: " "Source store unreadable: " ^ Terminal_text.single_line detail]
              | Memory_store_absent | Memory_store_present _ -> [])
           @ (match snapshot.mfs_events_read_error with
              | None -> []
              | Some detail -> [text "조회·수정 기록 조회 실패: " "Retrieval/change history unreadable: " ^ Terminal_text.single_line detail])) in
  let width = max 1 (framed_inner_width cols - 2) in
  List.concat_map (fun line ->
    (if full then Message_layout.wrap_words ~max_cells:width line
     else [Message_layout.truncate_middle width line])
    |> List.map (fun row -> "  " ^ row)) lines

let memory_fact_age_label ts =
  Masc_tui_value.Ongoing.Narrow.since ~now:(Unix.gettimeofday ()) ts

let memory_date ts =
  Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now:(Unix.gettimeofday ()) ts

let memory_updated_text = function
  | None -> Masc_tui_theme.Glyph.no_value
  | Some ts -> memory_date ts

(* The health endpoint renders stored knowledge as text, excluding snapshot
   bookkeeping. Its token size is an estimate, never a provider input count. *)
let storage_size bytes =
  if bytes >= 1024 * 1024 then Printf.sprintf "%.1f MiB" (float bytes /. 1048576.)
  else if bytes >= 1024 then Printf.sprintf "%.1f KiB" (float bytes /. 1024.)
  else Printf.sprintf "%d B" bytes
;;
let stored_size unit bytes =
  match unit with
  | Memory_usage.Tokens ->
      Masc_tui_token_scale.format_estimate Masc_tui_token_scale.fleet bytes
  | Memory_usage.Bytes -> storage_size bytes

let stored_amount unit bytes =
  stored_size unit bytes
  ^ (match unit with Memory_usage.Tokens -> " tok" | Memory_usage.Bytes -> "")

(* One break, and no more. The block sits under the list and is paid for out
   of the same frame, so a reading never takes more than two rows. At a
   terminal wide enough to draw the roster, the Librarian row and an alert
   each need one break; a narrower one folds the middle (see [clause_rows]). *)
let maximum_rows_for_a_reading = 2

(* A row of the keeper block, given as its clauses rather than as the joined
   string: [pack_clauses] keeps a clause whose own text holds the mark whole,
   which it cannot do for a row that has already been joined. The block was
   drawn one row per reading and cut at the frame: the Librarian row lost
   "failed N since server start", the tail #36497 records as reading like a
   running total, and a server alert lost the half that says what to do about
   it.

   An alert is one sentence and arrives as one clause; [pack_clauses] wraps a
   clause too wide for a row rather than cutting it. Continuation rows carry
   the same two-space indent as the first.

   A reading that packs into more rows than the block pays for keeps its
   first row and its last, with the cut mark between them, the way a roster
   name folds its middle (#38469). The first row says which reading it is;
   the last holds the clause that changes what the others mean. Joined back
   into one row instead, the frame cut that tail again -- at 80 columns, the
   commonest terminal, the Librarian row still ended "failed N". The fold
   draws exactly two rows, so it holds for any [maximum_rows_for_a_reading]
   of two or more. *)
let clause_rows ?(full = false) ~cols clauses =
  let indent = "  " in
  let fold = Message_layout.cut_mark ^ " " in
  let lead_cells =
    max (Message_layout.display_width indent) (Message_layout.display_width fold)
  in
  let rows =
    Message_layout.pack_clauses
      ~max_cells:(max 1 (framed_inner_width cols - lead_cells))
      clauses
  in
  match rows with
  | first :: rest when not full && List.length rows > maximum_rows_for_a_reading ->
    let last = List.fold_left (fun _ row -> row) first rest in
    [ indent ^ first; fold ^ last ]
  | rows -> List.map (fun row -> indent ^ row) rows

let memory_input_lines ~ko ~cols ~unit reading =
  let text korean english = if ko then korean else english in
  let wrap clauses =
    Message_layout.pack_clauses ~max_cells:(max 1 (framed_inner_width cols - 2)) clauses
    |> List.map (fun row -> "  " ^ row)
  in
  let label, format = match unit with
    | Memory_usage.Tokens -> text "입력 토큰" "Input tok", (fun value -> Message_layout.compact_count (int_of_float (Float.round value)))
    | Memory_usage.Bytes -> text "요청 KiB" "Request KiB", (fun value -> Printf.sprintf "%.1f" (value /. 1024.))
  in
  let values (snapshot : Memory_usage.t) =
    let measured = match unit with
      | Memory_usage.Tokens -> snapshot.tokens
      | Memory_usage.Bytes -> snapshot.bytes in
    (* A figure the snapshot did not carry draws the not-reported mark (RFC
       tui-one-screen-grammar 6.4), as the record count beside it says how
       many turns were measured. *)
    let not_reported = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported in
    let avg, maximum, minimum, samples = match measured.distribution with
      | None -> not_reported, not_reported, not_reported, 0
      | Some d -> format d.mean, format (float d.maximum), format (float d.minimum), d.samples in
    let last = match measured.last with None -> not_reported | Some n -> format (float n) in
    wrap [label; text "평균 " "avg " ^ avg; text "최대 " "max " ^ maximum; text "최소 " "min " ^ minimum; text "최근 " "last " ^ last]
    @ wrap
        [ Printf.sprintf (if ko then "최근 기록 턴 %d개" else "Recent %d recorded turns") snapshot.records
        ; Printf.sprintf (if ko then "%d/%d 측정" else "%d/%d recorded") samples snapshot.records
        ; (match unit with Memory_usage.Tokens -> text "런타임 입력 추정치 포함 가능" "input may include runtime estimates" | Memory_usage.Bytes -> text "직렬화된 본문" "serialized body")
        ]
  in
  match reading with
  | Masc_tui_fetched.Absent -> wrap [label ^ ": " ^ text "관측 없음" "no observation"]
  | Loading ->
      let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
      wrap [label ^ ": " ^ under_way ^ " " ^ text "조회 중" "loading"]
  | Failed failure ->
      wrap [label ^ ": " ^ Terminal_text.single_line
              (request_failure_text ~ko ~request:Kept_request.Memory_input_read failure)]
  | Ready snapshot -> values snapshot
  | Stale (snapshot, failure) ->
      wrap [label ^ ": " ^ text "이전 관측 · " "stale · " ^ Terminal_text.single_line
              (request_failure_text ~ko ~request:Kept_request.Memory_input_read failure)]
      @ values snapshot

(* #39831: the Librarian clauses the block under the selected keeper draws
   before the operator asks for detail. A clause is an action: a lag or a
   failure count above zero. A lag that could not be read is an action too,
   never a zero. Zeros wait behind [d]. *)
type memory_row_kind =
  | Row_lag of int option
  | Row_librarian_failures of int

type memory_row_visibility =
  | Shown_by_default
  | Detail_only

let memory_row_visibility = function
  | Row_lag None -> Shown_by_default
  | Row_lag (Some behind) -> if behind > 0 then Shown_by_default else Detail_only
  | Row_librarian_failures failed -> if failed > 0 then Shown_by_default else Detail_only

let shown_by_default kind =
  match memory_row_visibility kind with
  | Shown_by_default -> true
  | Detail_only -> false

type memory_context_projection =
  { rows : string list
  ; primary_rows : int
  ; stalled_row : (int * string) option
  }

let memory_operator_state (state : state) keeper =
  memory_state_text ~ko:(state.ui_language = Lang_ko) keeper

let memory_librarian_stalled_lines ~ko (librarian : memory_librarian_health) =
  let text korean english = if ko then korean else english in
  match librarian.mlh_stalled with
  | Some (Masc.Tui_decode_memory_health.Stalled_gap { mls_gap_start_atom; mls_gap_end_atom }) ->
    let atoms =
      if mls_gap_end_atom - mls_gap_start_atom = 1 then
        Printf.sprintf (if ko then "아톰 %d" else "atom %d is") mls_gap_start_atom
      else
        Printf.sprintf (if ko then "아톰 %d-%d" else "atoms %d-%d are")
          mls_gap_start_atom (mls_gap_end_atom - 1)
    in
    [ Printf.sprintf
        (if ko then "  Librarian 처리 지연 · %s 누락 (요청과 기억 모두에 없음)"
         else "  Librarian stalled · %s in neither the request nor memory")
        atoms ]
  | Some (Masc.Tui_decode_memory_health.Stalled_unmeasured { mls_cause; mls_detail }) ->
    let cause =
      match mls_cause with
      | Masc.Tui_decode_memory_health.Stall_meta_unreadable -> text "키퍼 메타 읽기 실패" "keeper meta unreadable"
      | Masc.Tui_decode_memory_health.Stall_turn_records_unreadable -> text "턴 기록 읽기 실패" "turn records unreadable"
      | Masc.Tui_decode_memory_health.Stall_turn_boundary_refused -> text "턴 경계 읽기 실패" "turn boundaries unreadable"
      | Masc.Tui_decode_memory_health.Stall_snapshot_unreadable -> text "연속성 스냅샷 읽기 실패" "continuity snapshot unreadable"
      | Masc.Tui_decode_memory_health.Stall_read_position_unreadable -> text "읽은 위치 읽기 실패" "read position unreadable"
    in
    [ Printf.sprintf (if ko then "  Librarian 처리 지연 · 미측정, %s · %s" else "  Librarian stalled · not measured, %s · %s") cause
        (Terminal_text.preview_line mls_detail) ]
  | None -> []

let memory_context_lines ?(full = false) ~ko ~cols ~detail ~unit ~input (k : Masc.Tui_decode_memory_health.memory_keeper_health) =
  let text korean english = if ko then korean else english in
  let input_rows = memory_input_lines ~ko ~cols ~unit input in
  let stored_rows =
    match k.mkh_read_error, k.mkh_source_read_error with
    | None, None ->
      clause_rows ~full ~cols
        [ text "저장 " "Stored " ^ stored_amount unit (k.mkh_snapshot_bytes + k.mkh_source_snapshot_bytes)
        ; (match unit with Memory_usage.Tokens -> text "저장 지식 추정량" "estimated knowledge size" | Memory_usage.Bytes -> text "저장된 지식" "rendered knowledge") ]
    | Some _, _ | _, Some _ -> clause_rows ~full ~cols [text "저장량 읽기 실패" "Stored: unreadable"]
  in
  let current_line =
    Printf.sprintf (if ko then "  %s · %s · 저장 r%d · 저장량 %s · 갱신 %s" else "  %s · %s · snapshot r%d · stored %s · updated %s")
      k.mkh_keeper_id (memory_state_text ~ko k) k.mkh_revision
      (stored_amount unit k.mkh_snapshot_bytes)
      (memory_updated_text k.mkh_updated_at)
  in
  let facts_line =
    Printf.sprintf
      (if ko then "  사실 %d개 (관측 %d / 파생 %d) · 최근 변경 %s / %s / 근거 무효화 %d" else "  facts %d (observed %d / derived %d) · last change %s / %s / support-invalidated %d")
      k.mkh_facts k.mkh_observed_facts k.mkh_derived_facts
      (Masc_tui_value.Count.increase k.mkh_added)
      (Masc_tui_value.Count.decrease k.mkh_removed) k.mkh_support_invalidations
  in
  (* The facts line above already counts the facts, so the ages follow
     without a count of their own. *)
  let ladder_rows =
    clause_rows ~full ~cols
      (Masc_tui_keeper_age_ladder.ages_clauses ~ko k.mkh_age_bins)
  in
  (* RFC librarian-lifecycle §4.9: how far behind, when that was counted,
     and what the journal last said. A count the durable drain could not take prints
     as "unread ?" rather than as zero. *)
  let librarian = k.mkh_librarian in
  let unread_lag = Masc_tui_keeper_memory_reading.unread_lag librarian in
  let unread =
    match unread_lag with
    | Some behind -> Printf.sprintf (if ko then "미읽은 턴 %d개" else "unread %d") behind
    | None -> text "미읽은 턴 ?" "unread ?"
  in
  (* The two rounds fall behind separately, so the continuity lag prints
     beside the drain's count rather than folded into it. "?" is its own
     reading: no snapshot, an unreadable one, or one from another trace. *)
  let continuity =
    match librarian.mlh_continuity_unread_atoms with
    | Some atoms -> Printf.sprintf (if ko then "연속성 지연 %d개" else "continuity behind %d") atoms
    | None -> text "연속성 지연 ?" "continuity behind ?"
  in
  let memory_saved = text "기억 저장 " "Memory saved " ^ memory_updated_text librarian.mlh_last_success_at in
  let last_failure =
    text "최근 실패 " "last failure "
    ^ (match librarian.mlh_last_failure_kind with
       | Some kind -> librarian_failure_words ~ko kind
       | None -> Masc_tui_theme.Glyph.no_value)
  in
  let failed = Printf.sprintf (if ko then "서버 시작 후 실패 %d회" else "failed %d since server start") k.mkh_librarian_failures in
  let librarian_clauses =
    [ "Librarian"
    ; (match librarian.mlh_state with
       | Some state -> memory_pass_text ~ko state
       | None -> text "미측정" "not measured")
    ; unread
    ; continuity
    ; text "관측 " "measured " ^ memory_updated_text librarian.mlh_measured_at
    ; memory_saved
    ; last_failure
    ; failed
    ]
  in
  (* RFC librarian-lifecycle §4.10: the atoms requests skip while the
     Librarian stands behind the start the provider last accepted. An alarm,
     not a state anything waits on. On its own row, under the Librarian line,
     so the frame cutting a long Librarian line never cuts its atom numbers.
     A file the gap is read from that did not read gets the same row, naming
     which file: it is neither "no gap" nor a gap. *)
  let librarian_stalled_lines = memory_librarian_stalled_lines ~ko librarian in
  let librarian_cause_lines =
    (* The cause is drawn on its own row because it is the part of the
       Librarian row an operator acts on. *)
    match Option.bind k.mkh_librarian.mlh_state Masc.Tui_decode_memory_health.memory_librarian_pass_end_cause with
    | Some cause -> [ text "  Librarian 사유 · " "  Librarian cause · " ^ Terminal_text.preview_line cause ]
    | None -> []
  in
  let context_lines =
    let cycle = k.mkh_context_cycle in
    let frontier value =
      Printf.sprintf (if ko then "아톰 %d / 경계 %d · trace %s" else "atom %d / boundary %d · trace %s")
        value.mcf_end_atom value.mcf_boundary_line (Terminal_text.single_line value.mcf_trace_id)
    in
    let saved =
      let cut = match cycle.mcc_saved with
        | Some value -> frontier value
        | None ->
            if cycle.mcc_saved_unreadable then text "읽기 실패" "unreadable"
            else text "없음" "absent" in
      (* Where the Librarian has read to belongs beside the cut, not on a line
         of its own: a request starts at the cut and carries the atoms up to
         the position, so the two apart is what the turn pays (#37793). *)
      let read = match cycle.mcc_read_position, cycle.mcc_saved with
        | None, _ ->
          if cycle.mcc_read_position_unreadable
          then text " · 읽은 위치 읽기 실패" " · read position unreadable"
          else text " · 아직 읽은 기록 없음" " · nothing read yet"
        | Some position, Some value when position > value.mcf_end_atom ->
          if ko then
            Printf.sprintf " · 아톰 %d까지 읽음 (경계 이후 %d개)" position
              (position - value.mcf_end_atom)
          else
            Printf.sprintf " · read to atom %d, %s past the cut" position
              (Masc_tui_message_layout.count_noun
                 (position - value.mcf_end_atom) "atom")
        | Some position, Some _ | Some position, None ->
          Printf.sprintf (if ko then " · 아톰 %d까지 읽음" else " · read to atom %d") position in
      let rewriting = match cycle.mcc_rewriting_through with
        | None -> ""
        | Some through ->
          Printf.sprintf
            (if ko then " · 아톰 0부터 재작성 중 (아톰 %d까지 미사용)"
             else " · rewriting from atom 0, unused until atom %d") through in
      cut ^ read ^ rewriting in
    let none_since_start = text "서버 시작 이후 기록 없음" "none since server start" in
    let prepared, input = match cycle.mcc_prepared with
      (* The server keeps the latest prepared request and synthesis in
         memory only (Keeper_continuity_observation), so None is a read
         that found none since this server started, not a value it failed
         to read: the reason in words, and no context used (RFC
         tui-one-screen-grammar 6.4). *)
      | None -> none_since_start, Masc_tui_theme.Glyph.no_value
      | Some value ->
        let input = match value.mcp_input with
          | Masc.Tui_decode_memory_health.Context_summarized value -> text "요약 " "summary " ^ frontier value
          | Masc.Tui_decode_memory_health.Context_absorbed value ->
            Printf.sprintf (if ko then "아톰 %d까지 흡수 · trace %s · 요약 없음" else "absorbed to atom %d · trace %s · no summary")
              value.mcpo_end_atom (Terminal_text.single_line value.mcpo_trace_id)
          | Masc.Tui_decode_memory_health.Context_without_snapshot -> text "스냅샷 없음: 이번 턴만" "no snapshot: this turn only"
          | Masc.Tui_decode_memory_health.Context_not_applied -> text "저장된 컨텍스트 미적용" "saved context not applied" in
        (* The size as a size. The row drew the digit count -- one live block
           read "446558 request bytes" -- while every other size on this TUI
           goes through the shared ladder and reads "436.1 KB". The heading a
           line above already says what was prepared, so the figure needs no
           noun of its own. *)
        Printf.sprintf "%s · %s · %s"
          (memory_updated_text (Some value.mcp_prepared_at))
          (Masc_tui_context_inspector.format_bytes value.mcp_request_bytes)
          (Terminal_text.single_line value.mcp_runtime_id), input in
    let synthesis = match cycle.mcc_synthesis with
      | None -> none_since_start
      | Some value ->
        let module O = Masc.Keeper_continuity_observation in
        let state = match value.state with
          | O.No_source -> text "새 완료 소스 없음(범위 추정 안 함)" "no new completed source (coverage not inferred)"
          | O.Checking -> text "확인 중" (O.synthesis_state_to_string O.Checking)
          | O.Running -> text "실행 중" (O.synthesis_state_to_string O.Running)
          | O.Committed -> text "반영 완료" (O.synthesis_state_to_string O.Committed)
          | O.Disabled -> text "비활성" (O.synthesis_state_to_string O.Disabled)
          | O.Source_unavailable -> text "소스 조회 불가" (O.synthesis_state_to_string O.Source_unavailable)
          | O.Input_unavailable -> text "입력 조회 불가" (O.synthesis_state_to_string O.Input_unavailable)
          | O.Not_committed -> text "미반영" (O.synthesis_state_to_string O.Not_committed)
          | O.Capacity_refused -> text "용량 초과 거절" (O.synthesis_state_to_string O.Capacity_refused)
          | O.Cancelled -> text "취소됨" (O.synthesis_state_to_string O.Cancelled) in
        let range = match value.range with
          | None -> text " · 아톰 범위 조회 불가" " · atom range unavailable"
          | Some range ->
              Printf.sprintf
                (if ko then " · 최근 선택 아톰 [%d,%d) / 관측 완료 %d"
                 else " · last selected atoms [%d,%d) / observed completed %d")
                range.start_atom range.end_atom range.completed_end_atom in
        state ^ range ^ " · " ^ memory_updated_text (Some value.observed_at) in
    let unread label = function
      | Error () -> ["  " ^ label ^ text " · 조회 불가" " · unavailable"]
      | Ok records ->
        let count = List.length records in
        let heading =
          if ko then Printf.sprintf "  %s · 기록된 미읽음 메시지 %d건" label count
          else if count = 1 then Printf.sprintf "  %s · 1 recorded unread message" label
          else Printf.sprintf "  %s · %d recorded unread messages" label count
        in
        heading ::
        List.map (fun record ->
          "    " ^ Terminal_text.single_line (Yojson.Safe.to_string
            (Masc.Keeper_librarian_unread.to_json record))) records in
    unread (text "스냅샷 미읽음 근거" "Snapshot unread evidence") cycle.mcc_unread_snapshot @
    unread (text "기억 누적 미읽음 근거" "Memory cumulative unread evidence") cycle.mcc_unread_memory @
    [text "  컨텍스트 합성 · " "  Context synthesis · " ^ synthesis;
     text "  저장된 컨텍스트 · " "  Context saved · " ^ saved;
     text "  준비된 요청(제공자 성공 아님) · " "  Request prepared (not provider success) · " ^ prepared;
     text "  사용된 컨텍스트 · " "  Context used · " ^ input]
  in
  let source_line =
    Printf.sprintf
      (if ko then "  원본 저장 r%d · 사실 %d개 · 무효화 %d건 · 저장량 %s · %s" else "  source-bound snapshot r%d · facts %d · invalidations %d · stored %s · %s")
      k.mkh_source_revision k.mkh_source_facts k.mkh_source_invalidations
      (stored_amount unit k.mkh_source_snapshot_bytes)
      (if k.mkh_source_snapshot_present then text "저장됨" "present" else text "스냅샷 없음" "absent")
  in
  let vision_line =
    let reasons =
      match k.mkh_vision_ingest_error_reasons with
      | [] -> text "없음" "none"
      | reasons ->
        String.concat ", "
          (List.map
             (fun (reason, count) -> reason ^ " " ^ Masc_tui_value.Count.times count)
             reasons)
    in
    Printf.sprintf (if ko then "  이미지 수집 오류 %d건 · 사유 %s" else "  vision ingest errors %d · reasons %s")
      k.mkh_vision_ingest_errors reasons
  in
  let alert_lines =
    List.map
      (fun (a : Masc.Tui_decode_memory_health.memory_alert) ->
        Printf.sprintf "[%s] %s · %s"
          ((if Masc.Tui_decode_memory_health.memory_alert_is_history a.ma_code
            then text "이력 " "history " else "")
           ^ (match Masc.Tui_decode_memory_health.memory_alert_severity a.ma_code with
              | `Warn -> text "경고" "warn"
              | `Error -> text "오류" "error"))
          a.ma_label
          (Terminal_text.single_line a.ma_message))
      k.mkh_alerts
  in
  let read_error_lines =
    List.filter_map Fun.id
      [ Option.map
          (fun message ->
            text "  일반 기억 조회 실패: " "  ordinary read error: " ^ Terminal_text.single_line message)
          k.mkh_read_error
      ; Option.map
          (fun message ->
            text "  원본 기억 조회 실패: " "  source-bound read error: " ^ Terminal_text.single_line message)
          k.mkh_source_read_error
      ]
  in
  (* Only the rows whose tail changes what the row claims are broken. The
     Librarian row ends in "failed N since server start", and a cut leaves
     "failed N", which reads as a running total (#36497); an alert is one
     sentence from the server and a cut takes the half that says what to do.
     The readings around them end in a timestamp or a byte count, where a cut
     costs a value rather than the meaning of the ones before it, and
     breaking every row would double the block at the widths a terminal is
     likely to have. *)
  let alert_rows =
    List.concat_map (fun sentence -> clause_rows ~full ~cols [ sentence ]) alert_lines
  in
  let rows =
    if detail
    then
      [ current_line ]
      @ input_rows
      @ [ facts_line ]
      @ ladder_rows
      @ [ source_line;
          text "  불러온 기억: 키퍼 대화의 /context에서 확인"
            "  Recall block detail: open Keeper chat /context." ]
      @ clause_rows ~full ~cols librarian_clauses
      @ librarian_stalled_lines
      @ librarian_cause_lines @ context_lines
      @ (vision_line :: read_error_lines)
      @ alert_rows
    else begin
      (* One status row: the keeper, its state word, and when memory was last
         saved -- the Librarian's success time, not the snapshot file's, which
         changes without a save succeeding. The action rows follow only when
         [memory_row_visibility] lets them through. *)
      let status_row =
        Printf.sprintf (if ko then "  %s · 기억 %s · %s" else "  %s · memory %s · %s")
          k.mkh_keeper_id (memory_state_label_for ~ko (memory_state k)) memory_saved
      in
      let when_shown kind clauses = if shown_by_default kind then clauses else [] in
      let librarian_action_rows =
        match
          when_shown (Row_lag unread_lag) [ unread ]
          @ when_shown (Row_lag librarian.mlh_continuity_unread_atoms) [ continuity ]
          @ when_shown (Row_librarian_failures k.mkh_librarian_failures)
              [ last_failure; failed ]
        with
        | [] -> []
        | clauses -> clause_rows ~full ~cols ("Librarian" :: clauses)
      in
      [ status_row ]
      @ stored_rows
      @ input_rows
      @ librarian_action_rows
      @ librarian_stalled_lines
      @ librarian_cause_lines
      @ read_error_lines
      @ alert_rows
    end
  in
  { rows
  ; primary_rows = 1 + List.length input_rows + (if detail then 0 else List.length stored_rows)
  ; stalled_row =
      (match librarian_stalled_lines with
       | row :: _ ->
         Option.map (fun index -> index, row) (List.find_index (String.equal row) rows)
       | [] -> None)
  }

type memory_state = Masc_tui_types.memory_state =
  | Memory_ordinary | Memory_warning | Memory_degraded | Memory_no_current
  | Memory_source_only | Memory_starving | Memory_read_error

(* The glyph and the word for it are one module, so the column below and the
   [?] sheet cannot spell the same state two ways. *)
let memory_state_cell = Masc_tui_memory_mark.glyph

let memory_deviation_style (k : Masc.Tui_decode_memory_health.memory_keeper_health) =
  let server_error =
    List.exists
      (fun alert ->
        if Masc.Tui_decode_memory_health.memory_alert_is_history alert.ma_code then false
        else match Masc.Tui_decode_memory_health.memory_alert_severity alert.ma_code with
        | `Error -> true
        | `Warn -> false)
      k.mkh_alerts
  in
  if server_error then Some (Theme.bad ())
  else
    (* The colour of the mark the state wears (RFC tui-one-screen-grammar
       7.2): a failed read wears the failure mark, so it takes the failure
       colour with starving. It took the caution colour. *)
    match memory_state k with
    | Memory_starving | Memory_read_error -> Some (Theme.bad ())
    | Memory_no_current
    | Memory_source_only
    | Memory_degraded
    | Memory_warning ->
        Some (Theme.warn ())
    | Memory_ordinary -> None

let memory_row_line ?(selected = false) ~ko ~unit columns (k : Masc.Tui_decode_memory_health.memory_keeper_health) =
  let no_value = Masc_tui_theme.Glyph.no_value in
  let ordinary_reading value = if k.mkh_snapshot_present then value () else no_value in
  let source =
    if Option.is_some k.mkh_source_read_error then
      Theme.bad () ^ (if ko then "읽기 오류" else "read error") ^ Ansi.reset
    else if k.mkh_source_snapshot_present then
      Printf.sprintf "r%d i%d %s" k.mkh_source_revision
        k.mkh_source_invalidations
        (stored_size unit k.mkh_source_snapshot_bytes)
    else no_value
  in
  let delta =
    match k.mkh_added, k.mkh_removed with
    | 0, 0 -> ""
    | added, 0 -> Masc_tui_value.Count.increase added
    | 0, removed -> Masc_tui_value.Count.decrease removed
    | added, removed ->
      Masc_tui_value.Count.increase added ^ " " ^ Masc_tui_value.Count.decrease removed
  in
  let deviation = Option.value (memory_deviation_style k) ~default:"" in
  let state_style = deviation in
  let size_style = if k.mkh_snapshot_present then "" else deviation in
  let delta_style = if k.mkh_removed > 0 then Theme.warn () else "" in
  (if selected then "\xe2\x80\xba " else "  ")
  ^ Render_schedule.memory_row ~state_style ~size_style ~delta_style columns
      { Render_schedule.mrow_state = memory_state_cell (memory_state k)
      ; mrow_name = k.mkh_keeper_id
      ; mrow_updated = memory_updated_text k.mkh_updated_at
      ; mrow_facts = ordinary_reading (fun () -> string_of_int k.mkh_facts)
      ; mrow_size =
          ordinary_reading (fun () -> stored_size unit k.mkh_snapshot_bytes)
      ; mrow_source = source
      ; mrow_delta = delta
      }

(* What a row wears in its first cell. The category is the librarian
   label the producer writes ([Keeper_memory_os_types.category]); the other two are this
   pane's own words for rows that are not ordinary facts, and the call sites
   know which they are drawing, so they say so rather than handing over a
   string to be recognised. *)
type memory_row_badge =
  | Badge_category of Memory_category.category
  | Badge_source
  | Badge_dropped

let memory_fact_row_line ~ko ?(is_fleet = false) ?(sort = Sort_recency) ~cols (row : memory_fact_row) =
  let inner_width = max 1 (framed_inner_width cols) in
  let usage, at = match row, sort with
    | Memory_row_fact fact, (Sort_retrieved_count | Sort_last_retrieved) ->
      (match fact.mf_events.mfe_retrieval with
       | Retrieved {count; last_at; distinct_days = _} ->
           (Theme.info () ^ Printf.sprintf "%d× " count ^ Ansi.reset, last_at)
       | Never_retrieved ->
           (Theme.recede () ^ (if ko then "미조회 " else "unretrieved ") ^ Ansi.reset, fact.mf_last_seen))
    | Memory_row_fact fact, (Sort_recency | Sort_category | Sort_claim) -> ("", fact.mf_last_seen)
    | Memory_row_source_fact fact, (Sort_recency | Sort_retrieved_count | Sort_last_retrieved | Sort_category | Sort_claim) -> ("", fact.msf_first_seen)
    | Memory_row_invalidation fact, (Sort_recency | Sort_retrieved_count | Sort_last_retrieved | Sort_category | Sort_claim) -> ("", fact.mi_invalidated_at) in
  let keeper, badge, claim, path = match row with
    | Memory_row_fact fact ->
        fact.mf_keeper, Badge_category fact.mf_category, fact.mf_claim, None
    | Memory_row_source_fact fact ->
        fact.msf_keeper, Badge_source, fact.msf_claim, Some fact.msf_path
    | Memory_row_invalidation row ->
        row.mi_keeper, Badge_dropped, row.mi_reason, Some row.mi_source_path in
  let badge_label, badge_style =
    match badge with
    | Badge_category category -> Memory_tree.category_badge ~ko category
    | Badge_source -> Memory_tree.filter_badge ~ko Category_source
    | Badge_dropped -> Memory_tree.filter_badge ~ko Category_dropped
  in
  let keeper_owner = if is_fleet then
      Message_layout.truncate_middle (min 8 (max 1 (inner_width / 6)))
        (Terminal_text.single_line keeper) ^ " "
    else "" in
  let badge_pad_w = if inner_width >= 40 then 8 else max 4 (inner_width / 6) in
  let badge_text = Message_layout.fit_width badge_label badge_pad_w in
  let colored_badge = badge_style ^ badge_text ^ Ansi.reset ^ " " in
  let owner_plain =
    if keeper_owner = "" then "" else Theme.recede () ^ keeper_owner ^ Ansi.reset
  in
  let prefix_cells =
    2 + Message_layout.display_width keeper_owner
    + Message_layout.display_width usage + badge_pad_w + 1
  in
  let room = max 0 (inner_width - prefix_cells) in
  let age = memory_fact_age_label at in
  let path = Option.map (fun path -> Message_layout.truncate_middle 16
      (Terminal_text.single_line path)) path in
  let metadata = String.concat " · " (Option.to_list path @ [age]) in
  let tail = " · " ^ metadata in
  (* Content owns the row. A path and clock fit only in the spare third;
     the complete source and all timestamps remain in the fact reading. *)
  let tail = if Message_layout.display_width tail <= room / 3 then tail else "" in
  let claim = Message_layout.truncate_middle
      (max 0 (room - Message_layout.display_width tail)) (Terminal_text.single_line claim) in
  Message_layout.truncate_end inner_width
    ("  " ^ owner_plain ^ usage ^ colored_badge ^ claim ^ Theme.recede () ^ tail ^ Ansi.reset)

(* A claim is prose a Keeper wrote, often paragraphs and a numbered list. The
   list rows fold it to one line because a row has one line to give it; the
   detail pane has the height, so it keeps the claim's own breaks. Each line is
   escaped on its own -- escaping the whole claim turns every newline into a
   printed \x0A (#37017) -- and wrapped at spaces, so a word is not cut in two
   at the pane's edge. A blank line stays a blank row: it is a paragraph break,
   not an absence. *)
let detail_claim_lines ?state ~inner_width claim =
  let wrap () =
    let lines =
      let margin = String.make (min 2 (max 0 (inner_width - 1))) ' ' in
      let guide =
        if inner_width >= 6 then
          Theme.panel_border Masc_tui_theme.Panel_memory ^ Masc_tui_theme.Box.v ^ Ansi.reset ^ " "
        else ""
      in
      let guide_w = if inner_width >= 6 then 2 else 0 in
      let text_w = max 1 (inner_width - String.length margin - guide_w) in
      Message_layout.wrap_body
        ~max_cells:text_w
        ~sanitize:Terminal_text.single_line claim
      |> List.map (fun line ->
           if String.equal line "" then margin ^ (if guide_w > 0 then Theme.panel_border Masc_tui_theme.Panel_memory ^ Masc_tui_theme.Box.v ^ Ansi.reset else "")
           else margin ^ guide ^ line)
    in
    let count = List.length lines in
    Option.iter
      (fun (state : state) ->
        state.memory_fact_claim_wrap <- Some (claim, inner_width, lines, count))
      state;
    lines, count
  in
  match state with
  | Some state ->
      (match state.memory_fact_claim_wrap with
       | Some (source, width, lines, count)
         when source == claim && width = inner_width -> lines, count
       | Some _ | None -> wrap ())
  | None -> wrap ()

type fact_detail_parts = {
  heading : string;
  heading_plain : string;
  claim_lines : string list;
  claim_line_count : int;
  other_lines : string list;
}

let fact_detail_parts_for_width ?state ~ko ~width (row : memory_fact_row) =
  let width = max 1 width in
  let text korean english = if ko then korean else english in
  let kv_rows = Doc.kv_rows ~width ~indent:2 ~max_label_cells:12 in
  let mem_accent () = Theme.series_tint Masc_tui_theme.Memory 0.8 in
  match row with
  | Memory_row_fact fact ->
      let claim_lines, claim_line_count =
        detail_claim_lines ?state ~inner_width:width fact.mf_claim
      in
      let history =
        (* The retrieval count, its day count and its last clock are one
           reading: the server derives all three from the same list of
           retrieval times, and the decoder keeps them as one value. A fact
           nobody has read draws the single phrase "Never retrieved".

           [Retracted] and [Revised from] keep their zeros. Both are measured
           counts the server always sends, and hiding a measured zero makes it
           read as "not measured" -- the shape RFC-0462 closed. *)
        let read =
          match fact.mf_events.mfe_retrieval with
          | Never_retrieved -> text "조회된 적 없음" "Never retrieved"
          | Retrieved { count; distinct_days; last_at } ->
              Printf.sprintf (if ko then "조회 %d회 · %s · 최근 %s" else "Retrieved %d on %s · last %s") count
                (if ko then Printf.sprintf "%d일에 걸쳐" distinct_days else Message_layout.count_noun distinct_days "day")
                (memory_fact_age_label last_at)
        in
        Printf.sprintf (if ko then "%s · 철회 %d회 · 이전 사실 %d개" else "%s · Retracted %d · Revised from %d") read
          fact.mf_events.mfe_retracted_count
          (List.length fact.mf_events.mfe_revised_from)
      in
      let cat_label, cat_tone = Memory_tree.category_badge ~ko fact.mf_category in
      let heading_plain = text "기억한 사실" "Fact Detail" in
      { heading =
          Printf.sprintf "  %s%s%s%s" Ansi.bold (mem_accent ()) heading_plain Ansi.reset
      ; heading_plain
      ; claim_lines
      ; claim_line_count
      ; other_lines =
        kv_rows
          [ Doc.kv ~tone:Ansi.bold (text "키퍼" "Keeper") (Terminal_text.single_line fact.mf_keeper)
          ; Doc.kv ~tone:cat_tone (text "분류" "Category") cat_label
          ; Doc.kv (text "기록 출처" "Origin") (Terminal_text.single_line fact.mf_origin)
          ; Doc.kv (text "관측 시점" "Timeline")
              (Printf.sprintf (if ko then "처음 %s · 마지막 %s" else "First: %s · Last: %s")
                 (memory_fact_age_label fact.mf_first_seen)
                 (memory_fact_age_label fact.mf_last_seen))
          ; Doc.kv (text "조회·수정" "History") history
          ; Doc.kv ~tone:(Theme.recede ()) (text "기억 ID" "Memory ID")
              (Terminal_text.single_line fact.mf_memory_id)
          ]
      }
  | Memory_row_source_fact fact ->
      let claim_lines, claim_line_count =
        detail_claim_lines ?state ~inner_width:width fact.msf_claim
      in
      let heading_plain = text "원본에 묶인 사실" "Source-Bound Fact Detail" in
      { heading =
          Printf.sprintf "  %s%s%s%s" Ansi.bold
            (mem_accent ()) heading_plain Ansi.reset
      ; heading_plain
      ; claim_lines
      ; claim_line_count
      ; other_lines =
        kv_rows
          [ Doc.kv ~tone:Ansi.bold (text "키퍼" "Keeper") (Terminal_text.single_line fact.msf_keeper)
          ; Doc.kv (text "원본 경로" "Bound Path") (Terminal_text.single_line fact.msf_path)
          ; Doc.kv ~tone:(Theme.recede ()) (text "파일 SHA" "File SHA")
              (Printf.sprintf (if ko then "%s · 처음 관측: %s" else "%s · First Seen: %s")
                 (Terminal_text.single_line fact.msf_sha256)
                 (memory_fact_age_label fact.msf_first_seen))
          ]
      }
  | Memory_row_invalidation row ->
      let claim_lines, claim_line_count =
        detail_claim_lines ?state ~inner_width:width row.mi_reason in
      let heading_plain = text "무효화된 사실" "Dropped / Invalidated Fact" in
      { heading =
          Printf.sprintf "  %s%s%s%s" Ansi.bold
            (Theme.bad ()) heading_plain Ansi.reset
      ; heading_plain
      ; claim_lines
      ; claim_line_count
      ; other_lines =
        kv_rows
          [ Doc.kv ~tone:Ansi.bold (text "키퍼" "Keeper") (Terminal_text.single_line row.mi_keeper)
          ; Doc.kv (text "원본 경로" "Source Path") (Terminal_text.single_line row.mi_source_path)
          ; Doc.kv ~tone:(Theme.warn ()) (text "무효화 시점" "Dropped At")
              (memory_fact_age_label row.mi_invalidated_at ^ text " 전" " ago")
          ]
      }

let memory_fact_detail_parts ?state ~ko ~cols (row : memory_fact_row) =
  fact_detail_parts_for_width ?state ~ko ~width:(framed_inner_width cols) row

let fact_detail_line_count parts =
  1 + parts.claim_line_count + List.length parts.other_lines

let first_lines count lines =
  let rec collect remaining kept = function
    | _ when remaining <= 0 -> List.rev kept
    | [] -> List.rev kept
    | line :: rest -> collect (remaining - 1) (line :: kept) rest
  in
  collect count [] lines

let fact_detail_prefix parts count =
  if count <= 0 then []
  else
    let claim_kept = min parts.claim_line_count (count - 1) in
    parts.heading
    :: (first_lines claim_kept parts.claim_lines
       @ first_lines (count - 1 - claim_kept) parts.other_lines)

let memory_fact_detail_lines ~ko ~cols row =
  let parts = memory_fact_detail_parts ~ko ~cols row in
  fact_detail_prefix parts (fact_detail_line_count parts)

(* The world line: what the workspace curator's ledger and briefing say. The
   words come from {!Masc_tui_memory_world}, which the key sheet reads too. A
   world not read yet, or whose read failed, draws the unknown mark and no
   count. [labelled] is the fleet header's own wrapper, so the row folds under
   its label at the frame's width as the others do; [room] is the width it
   packs with, which the failure cause is cut to so it adds no row. *)
let memory_world_rows ~ko ~labelled ~room (state : state) =
  labelled
    (Masc_tui_memory_world.label ~ko)
    (Masc_tui_memory_world.clauses ~ko ~room
       (Masc_tui_memory_world.reading state.memory_world))

(* The fleet header above the sort row: the Total, Ordinary, Source and
   Librarian readings, each wrapped to the frame. Its row count depends on the
   width, so the list's height is worked out from these same rows
   ([memory_overview_scrolled]) rather than from a fixed count of header lines. *)
let memory_fleet_header_rows ~cols (state : state) : string list =
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  (* A failed first read has no counts. The error row below owns the cause;
     keep these two labelled values unavailable without repeating its verdict.
     An unread first visit still says what it is waiting for. *)
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
  let missing_reading waiting =
    if Option.is_some state.memory_health_error
    then Masc_tui_theme.Glyph.no_value
    else if state.memory_health_inflight then
      under_way ^ " " ^ waiting
    else waiting
  in
  (* Every reading in this header is a labelled row that asks the frame for its
     width. The row that carried the Ordinary and Librarian readings together
     needed 176 cells with every count a single digit, while the frame gives 96
     at the 100 columns the PTY harness opens and 136 at 140 -- so it was cut
     mid-word at every width a terminal is likely to have, and the tail it lost
     was the one saying the failure count restarts with the server. A cut count
     reads as a running total. A count is not a thing to spell halfway.

     The shape is the one this file already uses for the History field: wrap at
     the width the label leaves, continuation rows hanging under the label so a
     row starting with a number still has its subject above it. The break is a
     clause mark rather than any space, because "0 failures since server start"
     and "0 failures" are different claims (#36497). *)
  let prefix_of label = "  " ^ label ^ " " in
  let room_after label =
    max 1 (framed_inner_width cols - Message_layout.display_width (prefix_of label))
  in
  let labelled label clauses =
    let prefix = prefix_of label in
    let prefix_cells = Message_layout.display_width prefix in
    let styled_prefix = "  " ^ Theme.recede () ^ label ^ Ansi.reset ^ " " in
    Message_layout.pack_clauses ~max_cells:(room_after label) clauses
    |> List.mapi (fun index line ->
           (if index = 0 then styled_prefix else String.make prefix_cells ' ') ^ line)
  in
  let total =
    match state.memory_health with
    | None ->
        [ "  " ^ Theme.recede () ^ text "전체:" "Total:" ^ Ansi.reset ^ " "
          ^ missing_reading (text "메모리 관측 대기" "waiting for memory snapshots") ]
    | Some snapshot ->
       labelled (text "전체" "Total")
         ([ (if ko then Printf.sprintf "기억 %d개" (snapshot.mhs_total_facts + snapshot.mhs_total_source_facts)
             else Masc_tui_message_layout.count_noun
               (snapshot.mhs_total_facts + snapshot.mhs_total_source_facts) "fact")
          ; Printf.sprintf (if ko then "일반 %d + 원본 %d" else "%d ordinary + %d source")
              snapshot.mhs_total_facts snapshot.mhs_total_source_facts
          ; Printf.sprintf (if ko then "저장 %s" else "stored %s")
              (stored_amount state.memory_unit
                 (snapshot.mhs_total_snapshot_bytes + snapshot.mhs_total_source_snapshot_bytes))
          ; Masc_tui_value.Count.reading ~ko Masc_tui_value.Count.Keeper
              (List.length snapshot.mhs_keepers)
          ; (match state.memory_unit with
             | Memory_usage.Tokens -> text "저장 추정량, 턴 입력 아님" "stored estimate, not turn input"
             | Memory_usage.Bytes -> text "저장된 지식, 턴 입력 아님" "stored knowledge, not turn input")
          ]
          @ (if state.memory_health_inflight && Option.is_none state.memory_health_error then
               [ under_way ^ " " ^ text "새로고침 중" "refreshing" ]
             else []))
  in
  (* The ordinary facts counted by time since first seen, summed over the
     Keepers whose row carries the server's ladder (RFC-0515 §2.4.5). A Keeper
     without one, and a row this build refused, are counted at the end of the
     row, so a partial sum does not read as the whole. *)
  let age_ladder_rows (snapshot : memory_health_snapshot) =
    labelled (text "일반:" "Ordinary:")
      (Masc_tui_keeper_age_ladder.fleet_clauses ~ko
         (Masc_tui_keeper_age_ladder.fleet_of
            ~refused_rows:(List.length snapshot.mhs_refused_keepers)
            snapshot.mhs_keepers))
  in
  let readings =
    match state.memory_health with
    | None ->
        [ "  " ^ Theme.recede () ^ "Librarian:" ^ Ansi.reset ^ " "
          ^ missing_reading (text "상태 관측 대기" "waiting for health data") ]
    | Some snapshot ->
       (* Every count spells its own noun: each of these reads 1 on an
          ordinary day, and the line said "1 keepers", "1 atoms",
          "1 failures". The unread turns keep "?" when nothing measured
          them, which is not a count and cannot take a noun from one. *)
       labelled (text "일반:" "Ordinary:")
         [ Printf.sprintf (if ko then "관측 %d / 파생 %d" else "%d observed / %d derived")
             snapshot.mhs_total_observed_facts snapshot.mhs_total_derived_facts
         ; (let inv_text =
              if ko then Printf.sprintf "근거 무효화 %d건" snapshot.mhs_total_support_invalidations
              else Masc_tui_message_layout.count_noun
                snapshot.mhs_total_support_invalidations "support invalidation"
            in
            if snapshot.mhs_total_support_invalidations > 0 then
              Theme.warn () ^ inv_text ^ Ansi.reset
            else inv_text)
         ]
       @ (if snapshot.mhs_total_read_errors = 0 then [] else
            labelled (text "일반:" "Ordinary:")
              [ Theme.bad ()
                ^ Printf.sprintf (if ko then "읽기 실패 키퍼 %d명" else "read errors in %d keepers")
                    snapshot.mhs_total_read_errors
                ^ Ansi.reset ])
       @ age_ladder_rows snapshot
       (* The source-bound snapshot is stored and invalidated apart from the
          ordinary facts above, and each Keeper's roster row and detail already
          print their own count (#38446). The count here is the standing set of
          source invalidations; the Ordinary count is the invalidations of the
          latest write only, so the two are not one total split in two. A
          Keeper whose source snapshot could not be read contributes 0 to the
          count, so the row also says how many Keepers that is, as the roster
          does with "read error". *)
       @ labelled (text "원본:" "Source:")
         ([ (let inv_text =
               if ko then Printf.sprintf "무효화 %d건" snapshot.mhs_total_source_invalidations
               else Masc_tui_message_layout.count_noun
                 snapshot.mhs_total_source_invalidations "invalidation"
             in
             if snapshot.mhs_total_source_invalidations > 0 then
               Theme.warn () ^ inv_text ^ Ansi.reset
             else inv_text)
          ]
          @ (if snapshot.mhs_total_source_read_errors > 0
             then
               [ Theme.bad ()
                 ^ (if ko then Printf.sprintf "원본 읽기 실패 키퍼 %d명" snapshot.mhs_total_source_read_errors
                    else Masc_tui_message_layout.count_noun
                      snapshot.mhs_total_source_read_errors "keeper" ^ " with a source read error")
                 ^ Ansi.reset
               ]
             else []))
       @ labelled "Librarian:"
         [ (if ko then
              match snapshot.mhs_total_librarian_unread_turns with
              | None -> "미읽은 턴 ?"
              | Some turns -> Printf.sprintf "미읽은 턴 %d개" turns
            else
              (match snapshot.mhs_total_librarian_unread_turns with
               | None -> "? turns"
               | Some turns -> Masc_tui_message_layout.count_noun turns "turn") ^ " unread")
         ; (if ko then Printf.sprintf "연속성 지연 아톰 %d개 (미측정 키퍼 %d명)"
              snapshot.mhs_total_librarian_continuity_unread_atoms
              snapshot.mhs_total_librarian_continuity_unmeasured
            else Printf.sprintf "%s behind in continuity (%s not measured)"
              (Masc_tui_message_layout.count_noun snapshot.mhs_total_librarian_continuity_unread_atoms "atom")
              (Masc_tui_message_layout.count_noun snapshot.mhs_total_librarian_continuity_unmeasured "keeper"))
         ; (let fail_text =
              if ko then Printf.sprintf "서버 시작 후 실패 %d건" snapshot.mhs_total_librarian_failures
              else Masc_tui_message_layout.count_noun snapshot.mhs_total_librarian_failures "failure"
                ^ " since server start"
            in
            if snapshot.mhs_total_librarian_failures > 0 then
              Theme.warn () ^ fail_text ^ Ansi.reset
            else fail_text)
         ]
       @ (if snapshot.mhs_warn_alerts + snapshot.mhs_error_alerts = 0
              && snapshot.mhs_total_vision_ingest_errors = 0 then []
          else
            let alert_text =
              Printf.sprintf (if ko then "보고된 경고 %d / 오류 %d (이력 포함 가능)" else "reported warnings %d / errors %d (may include history)")
                snapshot.mhs_warn_alerts snapshot.mhs_error_alerts
            in
            let alert_clause =
              if snapshot.mhs_error_alerts > 0 then Theme.bad () ^ alert_text ^ Ansi.reset
              else if snapshot.mhs_warn_alerts > 0 then Theme.warn () ^ alert_text ^ Ansi.reset
              else alert_text
            in
            labelled (text "알림:" "Alerts:")
              [ alert_clause
              ; (let vis_text =
                   Printf.sprintf (if ko then "보고된 이미지 수집 오류 %d건" else "reported image ingestion errors %d")
                     snapshot.mhs_total_vision_ingest_errors
                 in
                 if snapshot.mhs_total_vision_ingest_errors > 0 then
                   Theme.warn () ^ vis_text ^ Ansi.reset
                 else vis_text)
              ])
  in
  total
  @ readings
  @ memory_world_rows ~ko ~labelled
      ~room:(room_after (Masc_tui_memory_world.label ~ko))
      state


(* Both counts are the length of what this module draws: the fleet header
   above the list, and the selected keeper's block below it. Neither is a
   count of readings -- a reading breaks into as many rows as the frame
   gives it. *)
(* The header and selected Keeper's detail share one finite body with the
   roster. If their wrapped rows do not fit, show both ends when there is room
   and say how many rows are hidden. A one-row slot shows only that omission,
   rather than pretending that a clipped alert is complete. *)
let fold_memory_rows ~ko ~subject ~max_rows rows =
  let count = List.length rows in
  if count <= max_rows then rows
  else if max_rows <= 0 then []
  else
    let leading = (max_rows - 1) / 2 in
    let trailing = max_rows - 1 - leading in
    let hidden = count - leading - trailing in
    let note =
      if ko then Printf.sprintf "  … %s %d행 생략됨 · 창을 늘려 주세요" subject hidden
      else Printf.sprintf "  … %d %s rows hidden; enlarge terminal" hidden subject
    in
    List.filteri (fun index _ -> index < leading) rows
    @ [ note ]
    @ List.filteri (fun index _ -> index >= count - trailing) rows

(* Keep the requested storage/input prefix and the actionable stalled row
   when detail exceeds the frame. Spend remaining room on the tail, with an
   explicit omission count between the readings. *)
let fold_memory_context_rows ~ko ~max_rows context =
  let rows = context.rows in
  let count = List.length rows in
  if count <= max_rows then rows
  else if max_rows <= 0 then []
  else
    let stalled = match context.stalled_row with
      | Some (index, row) when index >= context.primary_rows && max_rows > 1 -> Some (index, row)
      | Some _ | None -> None in
    let stalled_count = if Option.is_some stalled then 1 else 0 in
    let leading = min context.primary_rows (max_rows - 1 - stalled_count) in
    let remaining = max_rows - 1 - leading - stalled_count in
    let tail =
      List.mapi (fun index row -> index, row) rows
      |> List.filter (fun (index, _) ->
          index >= leading && match stalled with Some (kept, _) -> index <> kept | None -> true)
      |> List.rev |> List.take remaining |> List.rev |> List.map snd in
    let hidden = count - leading - stalled_count - List.length tail in
    List.take leading rows
    @ [Printf.sprintf
         (if ko then "  … 상세 %d행 숨김 · v:전체" else "  … %d Keeper detail rows hidden · v:full reading")
         hidden]
    @ (match stalled with Some (_, row) -> [row] | None -> [])
    @ tail

let memory_refused_keeper_lines (state : state) =
  let ko = state.ui_language = Lang_ko in
  match state.memory_health with
  | Some { mhs_refused_keepers = []; _ } | None -> []
  | Some { mhs_refused_keepers = refused; _ } ->
    List.map
      (fun refusal ->
        Printf.sprintf (if ko then "  행 읽기 실패 · %s: %s" else "  row not read · %s: %s")
          (match refusal.mkr_keeper_id with
           | Some keeper_id -> Terminal_text.single_line keeper_id
           | None -> if ko then "키퍼 ID 보고 안 됨" else "keeper id not reported")
          (Terminal_text.single_line refusal.mkr_reason))
      refused

(* The world's denominator is the workspace ledger, never a Keeper's facts.
   Qualify retained values before counts, rather than appending a stale tail. *)
let memory_world_axis (state : state) ~room =
  let ko = state.ui_language = Lang_ko in
  let reading = Masc_tui_memory_world.reading state.memory_world in
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
  let provenance = match reading with
    | Masc_tui_memory_world.Not_read -> [ui_text state ~ko:"미조회" ~en:"not read"]
    | Masc_tui_memory_world.Reading ->
        [ui_text state ~ko:(under_way ^ " 조회 중") ~en:(under_way ^ " reading")]
    | Masc_tui_memory_world.Read_failed (Kept_back _) -> [ui_text state ~ko:"현재 값 미조회" ~en:"current value not read"]
    | Masc_tui_memory_world.Read_failed (Suspended | Request_failed _) -> [ui_text state ~ko:"조회 실패" ~en:"read failed"]
    | Masc_tui_memory_world.Loaded { refresh_failure = Some (Kept_back _); _ } ->
        [ui_text state ~ko:"마지막 관측" ~en:"last observation"]
    | Masc_tui_memory_world.Loaded { refresh_failure = Some (Suspended | Request_failed _); _ } ->
        [ui_text state ~ko:"마지막 관측 · 갱신 실패" ~en:"last observation; refresh failed"]
    | Masc_tui_memory_world.Loaded { refresh_failure = None; _ } -> []
  in
  ( ui_text state ~ko:"공유 기억" ~en:"Shared memory"
  , provenance @ Masc_tui_memory_world.clauses ~ko ~room reading )

let memory_axis_context (state : state) ~cols ~compact (keeper : memory_keeper_health) =
  let ko = state.ui_language = Lang_ko in
  let text ~ko ~en = ui_text state ~ko ~en in
  let width = max 1 (framed_inner_width cols - 2) in
  let age = match keeper.mkh_read_error, keeper.mkh_snapshot_present with
    | Some _, _ -> [text ~ko:"일반 사실 읽기 실패" ~en:"ordinary facts unreadable"]
    | None, false -> [text ~ko:"일반 기억 스냅샷 없음" ~en:"no ordinary memory snapshot"]
    | None, true -> Masc_tui_keeper_age_ladder.keeper_clauses ~ko keeper.mkh_age_bins
  in
  let saved = match keeper.mkh_read_error, keeper.mkh_snapshot_present with
    | Some _, _ -> [text ~ko:"저장 시각 읽기 실패" ~en:"save time unreadable"]
    | None, false -> [text ~ko:"일반 기억 스냅샷 없음" ~en:"no ordinary memory snapshot"]
    | None, true ->
        [memory_updated_text keeper.mkh_updated_at;
         text ~ko:"출처 재확인 시각과 별개" ~en:"not a source revalidation time"]
  in
  let source = match keeper.mkh_source_read_error, keeper.mkh_source_snapshot_present with
    | Some _, _ -> [text ~ko:"출처 기억 읽기 실패" ~en:"source memory unreadable"]
    | None, false -> [text ~ko:"출처 기억 스냅샷 없음" ~en:"no source memory snapshot"]
    | None, true ->
        [ Printf.sprintf (if ko then "출처 사실 %d개" else "%d source facts") keeper.mkh_source_facts
        ; Printf.sprintf (if ko then "출처 무효화 %d건" else "%d source invalidations") keeper.mkh_source_invalidations
        ]
  in
  let librarian = keeper.mkh_librarian in
  let unread = match Masc_tui_keeper_memory_reading.unread_lag librarian with
    | None -> text ~ko:"미읽은 턴 미측정" ~en:"unread turns unmeasured"
    | Some turns -> Printf.sprintf (if ko then "미읽은 턴 %d개" else "%d unread turns") turns
  in
  let continuity = match librarian.mlh_continuity_unread_atoms with
    | None -> text ~ko:"연속성 지연 미측정" ~en:"continuity lag unmeasured"
    | Some atoms -> Printf.sprintf (if ko then "연속성 지연 아톰 %d개" else "continuity behind %d atoms") atoms
  in
  let pass = match librarian.mlh_state with
    | None -> text ~ko:"처리 결과 보고 안 됨" ~en:"pass not reported"
    | Some ending -> text ~ko:"처리 " ~en:"pass " ^ memory_pass_text ~ko ending
  in
  let axes =
    [ text ~ko:"사실 나이 · 처음 관측" ~en:"Fact age · first seen", age
    ; text ~ko:"저장 갱신" ~en:"Snapshot saved", saved
    ; text ~ko:"출처 무효화" ~en:"Source invalidation", source
    ; text ~ko:"Librarian" ~en:"Librarian",
        [unread; continuity; pass;
         text ~ko:"현재 모델 실행 여부와 별개" ~en:"not current model execution"]
    ; memory_world_axis state ~room:width
    ]
  in
  let style_heading h = Ansi.bold ^ h ^ Ansi.reset in
  let card ~cells (heading, clauses) =
    style_heading heading :: Message_layout.pack_clauses ~max_cells:cells clauses
  in
  let axis_rows =
    if compact then
      List.map (fun (heading, clauses) ->
        "  " ^ Message_layout.join_fitting ~sep:" · " ~cells:width (style_heading heading :: clauses)) axes
    else if cols >= Masc_tui_roster_pane.threshold_cols then
      let gap = Theme.border_muted () ^ "  │  " ^ Ansi.reset in
      let cells = max 1 ((width - Message_layout.display_width gap) / 2) in
      let rec pairs = function
        | [] -> []
        | [axis] -> List.map (fun row -> "  " ^ row) (card ~cells axis)
        | left :: right :: rest ->
            let left = card ~cells left and right = card ~cells right in
            List.init (max (List.length left) (List.length right)) (fun index ->
              "  " ^ Message_layout.fit_width
                (Option.value (List.nth_opt left index) ~default:"") cells
              ^ gap ^ Option.value (List.nth_opt right index) ~default:"")
            @ (if rest = [] then [] else [""]) @ pairs rest
      in
      pairs axes
    else
      List.concat_map (fun (heading, clauses) ->
        Message_layout.pack_clauses ~max_cells:width (style_heading heading :: clauses)
        |> List.map (fun row -> "  " ^ row)) axes
  in
  let errors = List.filter_map Fun.id
      [ Option.map (fun reason -> Theme.bad () ^ text ~ko:"일반 기억: " ~en:"Ordinary memory: " ^ Terminal_text.single_line reason ^ Ansi.reset) keeper.mkh_read_error
      ; Option.map (fun reason -> Theme.bad () ^ text ~ko:"출처 기억: " ~en:"Source memory: " ^ Terminal_text.single_line reason ^ Ansi.reset) keeper.mkh_source_read_error
      ; Option.map (fun reason -> Theme.warn () ^ "Librarian: " ^ Terminal_text.single_line reason ^ Ansi.reset)
          (Option.bind librarian.mlh_state memory_librarian_pass_end_cause)
      ] in
  let stalled =
    List.map (fun row -> Theme.warn () ^ row ^ Ansi.reset)
      (memory_librarian_stalled_lines ~ko librarian)
  in
  let alerts = if keeper.mkh_alerts = [] then [] else
      [ Theme.warn ()
        ^ Printf.sprintf
            (if ko then "보고된 알림 %d건 (이력 포함) · v:근거" else "%d reported alerts (including history) · v:evidence")
            (List.length keeper.mkh_alerts)
        ^ Ansi.reset ] in
  let warnings = List.map (fun row -> "  " ^ row) errors @ stalled
      @ List.map (fun row -> "  " ^ row) alerts in
  let observed = match state.memory_health with
    | None -> ""
    | Some snapshot ->
        Theme.recede () ^ text ~ko:" · 관측 " ~en:" · observed "
        ^ memory_date snapshot.mhs_generated_at ^ Ansi.reset
  in
  let state_tone = Option.value (memory_deviation_style keeper) ~default:(Theme.ok ()) in
  let heading =
    "  " ^ Theme.recede () ^ text ~ko:"선택 · " ~en:"Selected · " ^ Ansi.reset
    ^ Ansi.bold ^ Terminal_text.single_line keeper.mkh_keeper_id ^ Ansi.reset
    ^ Theme.recede () ^ " · " ^ Ansi.reset
    ^ state_tone ^ memory_operator_state state keeper ^ Ansi.reset
    ^ observed
  in
  { rows = heading :: warnings @ axis_rows
  ; primary_rows = 1 + List.length warnings
  ; stalled_row = (match stalled with [] -> None | row :: _ -> Some (1 + List.length errors, row))
  }

(* The full fleet and selected Keeper readings remain reachable even when the
   small overview cannot fit them beside a useful list. This is a captured
   reading: selection and later refreshes do not change an open document. *)
let memory_health_reading ~cols (state : state) ~keeper ~original =
  let ko = state.ui_language = Lang_ko in
  let section heading lines : Masc_tui_detail_reading.section =
    { heading; body = String.concat "\n" lines }
  in
  let observed = match state.memory_health with
    | None -> []
    | Some snapshot ->
        [ (if ko then "관측 시각 · " else "Observed at · ")
          ^ memory_date snapshot.mhs_generated_at ]
  in
  let warnings =
    Option.to_list (Option.map (function
      | Request_failed detail ->
        (if ko then "조회 오류 · " else "Read error · ") ^ Terminal_text.single_line detail
      | Request_withdrawn refusal ->
        workspace_refusal_text ~ko ~request:Kept_request.Memory_health_read refusal)
      state.memory_health_error)
    @ memory_refused_keeper_lines state
  in
  let keeper_section = match keeper with
    | None -> []
    | Some keeper ->
        let input = Masc_tui_fetched.view_for ~equal:String.equal state.memory_input
            ~key:keeper.mkh_keeper_id in
        let context = memory_context_lines ~full:true ~ko ~cols ~detail:true ~unit:state.memory_unit ~input keeper in
        let axes = memory_axis_context state ~cols ~compact:false keeper in
        [ section (if ko then "선택한 기억의 관측" else "Selected memory observations")
            (List.map Masc_tui_theme.strip_sgr axes.rows)
        ; section
           ((if ko then "선택한 키퍼 · " else "Selected Keeper · ") ^ keeper.mkh_keeper_id)
           context.rows]
  in
  let target_notice = match original, keeper with
    | Some {Masc.Operator_action_reason.cause=Memory_attention {keeper;_};_}, None ->
        [section (if ko then "대상 기억 미조회" else "Target memory not read")
          [Terminal_text.single_line keeper;
           (if ko then "이 키퍼의 기억 상태는 이 조회에서 확인하지 못했습니다."
            else "This reading did not establish this Keeper's memory state.")]]
    | Some {cause=(Memory_attention _ | Shutdown_fenced_backlog _ | Other_reported);_}, Some _
    | Some {cause=(Shutdown_fenced_backlog _ | Other_reported);_}, None
    | None, (Some _ | None) -> [] in
  let fleet_alerts = match state.memory_health with
    | None -> []
    | Some snapshot ->
        List.concat_map (fun keeper ->
          List.map (fun alert ->
            let history = if Masc.Tui_decode_memory_health.memory_alert_is_history alert.ma_code
              then (if ko then "이력 " else "history ") else "" in
            let severity = match Masc.Tui_decode_memory_health.memory_alert_severity alert.ma_code with
              | `Warn -> if ko then "경고" else "warning"
              | `Error -> if ko then "오류" else "error" in
            Printf.sprintf "%s · %s%s · %s · %s"
              (Terminal_text.single_line keeper.mkh_keeper_id) history severity
              (Terminal_text.single_line alert.ma_label) (Terminal_text.single_line alert.ma_message))
            keeper.mkh_alerts) snapshot.mhs_keepers
  in
  let fleet = [section (if ko then "전체 기억" else "Fleet memory")
      (observed @ List.map Masc_tui_theme.strip_sgr (memory_fleet_header_rows ~cols state))] in
  let warnings = if warnings = [] then [] else
      [section (if ko then "조회 경고" else "Read warnings") warnings] in
  let alerts = if fleet_alerts = [] then [] else
      [section (if ko then "읽은 키퍼의 알림" else "Alerts from decoded Keepers") fleet_alerts] in
  let title = if ko then "기억 관측 상세" else "Memory observation details" in
  let title, sections = match original with
    | None -> title, fleet @ warnings @ alerts @ target_notice @ keeper_section
    | Some action ->
        let title = match action.Masc.Operator_action_reason.cause with
          | Memory_attention {keeper;_} -> Terminal_text.single_line keeper ^ " · " ^ title
          | Shutdown_fenced_backlog _ | Other_reported -> title in
        let original = [section (if ko then "원래 조치 관측 · 별도 출처" else "Original action · separate source")
            [Masc.Operator_action_reason.diagnostic action;
             Yojson.Safe.pretty_to_string (Masc.Operator_action_reason.to_json action)]] in
        title, target_notice @ keeper_section @ warnings @ original @ fleet @ alerts in
  Masc_tui_detail_reading.create ~ko ~title sections

let memory_overview_reading ~cols state =
  memory_health_reading ~cols state ~keeper:(selected_memory_keeper state) ~original:None

let memory_action_reading ~cols state ~(action : Masc.Operator_action_reason.t) =
  match action.cause with
  | Memory_attention {keeper;_} ->
      let selected = Option.bind state.memory_health (fun snapshot ->
        List.find_opt (fun row -> String.equal row.Masc.Tui_decode_memory_health.mkh_keeper_id keeper)
          snapshot.mhs_keepers) in
      Some (memory_health_reading ~cols state ~keeper:selected ~original:(Some action))
  | Shutdown_fenced_backlog _ | Other_reported -> None

(* A single row replaces an unfittable fleet header. It leads with any
   actionable read failures, then unmeasured coverage, and always names the
   complete reading rather than displaying a detached continuation line. *)
let memory_compact_fleet_row ~cols (state : state) =
  let ko = state.ui_language = Lang_ko in
  let hint = if ko then "  v:전체 · " else "  v:details · " in
  let detail, attention_present = match state.memory_health with
    | None -> (if ko then "기억 관측 없음" else "no memory observation"), false
    | Some snapshot ->
        let attention =
          (if snapshot.mhs_refused_keepers <> [] then
             [Printf.sprintf (if ko then "읽지 못한 키퍼 행 %d개" else "%d Keeper rows not read")
                (List.length snapshot.mhs_refused_keepers)] else [])
          @ (if snapshot.mhs_total_read_errors > 0 then
             [Printf.sprintf (if ko then "일반 읽기 실패 %d명" else "ordinary read errors: %d keepers") snapshot.mhs_total_read_errors] else [])
          @ (if snapshot.mhs_total_source_read_errors > 0 then
               [Printf.sprintf (if ko then "원본 읽기 실패 %d명" else "source read errors: %d keepers") snapshot.mhs_total_source_read_errors] else [])
          @ (if snapshot.mhs_total_librarian_failures > 0 then
               [Printf.sprintf (if ko then "서버 시작 후 Librarian 실패 %d건" else "Librarian failures since server start: %d") snapshot.mhs_total_librarian_failures] else [])
          @ (if snapshot.mhs_warn_alerts + snapshot.mhs_error_alerts > 0 then
               [Printf.sprintf (if ko then "보고된 알림 %d건 (이력 포함 가능)" else "%d reported alerts (may include history)")
                  (snapshot.mhs_warn_alerts + snapshot.mhs_error_alerts)] else [])
          @ (if snapshot.mhs_total_vision_ingest_errors > 0 then
               [Printf.sprintf (if ko then "이미지 수집 오류 %d건" else "%d image ingestion errors") snapshot.mhs_total_vision_ingest_errors] else [])
          @ (if snapshot.mhs_total_librarian_continuity_unmeasured > 0 then
               [Printf.sprintf (if ko then "연속성 미측정 %d명" else "continuity unmeasured: %d keepers") snapshot.mhs_total_librarian_continuity_unmeasured] else [])
          @ (if snapshot.mhs_total_librarian_continuity_unread_atoms > 0 then
               [Printf.sprintf (if ko then "연속성 지연 아톰 %d개" else "continuity behind: %d atoms") snapshot.mhs_total_librarian_continuity_unread_atoms] else [])
          @ (match snapshot.mhs_total_librarian_unread_turns with
             | None -> [if ko then "미읽은 턴 보고 안 됨" else "unread turns not reported"]
             | Some turns when turns > 0 -> [Printf.sprintf (if ko then "미읽은 턴 %d개" else "%d unread turns") turns]
             | Some _ -> [])
        in
        match attention with
        | [] -> Printf.sprintf (if ko then "전체 기억 %d개" else "%d total facts")
                  (snapshot.mhs_total_facts + snapshot.mhs_total_source_facts), false
        | [one] -> one, true
        | _ :: _ :: _ -> (if ko then "주의 있음" else "attention reported"), true
  in
  let full = hint ^ detail in
  if Message_layout.display_width full <= framed_inner_width cols then full
  else
    let fallback = hint ^ (if attention_present then (if ko then "주의 있음" else "attention")
                            else (if ko then "관측 상세" else "see reading")) in
    if Message_layout.display_width fallback <= framed_inner_width cols then fallback
    else if attention_present then "  !v" else "  v"

type memory_overview_projection =
  { header : string list
  ; refused : string list
  ; refused_divider : bool
  ; context : string list
  }

let refused_rows projection =
  List.length projection.refused + if projection.refused_divider then 1 else 0

(* How tall one Keeper's reading is, full and compact, and whether it keeps a
   stalled-gap row: all the detail under the list needs from the Keepers that
   are not selected, to be as tall as the tallest of them (RFC
   tui-one-screen-grammar §8). *)
type memory_reading_measure = { full_rows : int; compact_rows : int; stalled : bool }

(* Measuring wraps every loaded Keeper's reading, and the overview is built
   several times a frame (its layout, its body, the position count). The
   measures are kept for the readings they were taken from: the same health
   snapshot and World reading, the same Keepers in the same order, at the
   same width and in the same reading. A value that changes is a new value,
   so any change measures again. The input reading is part of it only under
   [v]: the axis reading does not draw it, and the input is read again for
   every Keeper j or k selects, so keeping it there measured every Keeper on
   every move. *)
let memory_reading_measures :
    ((memory_health_snapshot option * Masc_tui_memory_world.t
      * (string, Masc_tui_memory_usage.t, request_failure) Masc_tui_fetched.source option
      * memory_keeper_health list * int * bool * bool * Masc_tui_memory_usage.display_unit)
     * memory_reading_measure list) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let measured_readings (state : state) ~cols ~readings keepers =
  let input = if state.memory_overview_detail then Some state.memory_input else None in
  let key =
    ( state.memory_health, state.memory_world, input, keepers, cols
    , state.ui_language = Lang_ko, state.memory_overview_detail, state.memory_unit )
  in
  let same (health, world, input, seen, seen_cols, seen_ko, seen_detail, seen_unit)
      (health', world', input', keepers', cols', ko', detail', unit') =
    health == health' && world == world' && Option.equal ( == ) input input'
    && List.equal ( == ) seen keepers' && seen_cols = cols' && Bool.equal seen_ko ko'
    && Bool.equal seen_detail detail' && seen_unit = unit'
  in
  match Domain.DLS.get memory_reading_measures with
  | Some (seen, measures) when same seen key -> measures
  | Some _ | None ->
      let measures =
        List.map
          (fun keeper ->
            let full, compact = readings keeper in
            { full_rows = List.length full.rows
            ; compact_rows = List.length compact.rows
            ; stalled = Option.is_some full.stalled_row })
          keepers
      in
      Domain.DLS.set memory_reading_measures (Some (key, measures));
      measures

let memory_overview_rows ~cols ~budget (state : state) =
  let keepers = visible_memory_keepers state in
  let ko = state.ui_language = Lang_ko in
  (* A Keeper's reading and the compact one that stands in for it on a short
     frame. [v] keeps the full input and coverage, so it has no compact one. *)
  let readings keeper =
    if state.memory_overview_detail then
      let full =
        memory_context_lines ~ko ~cols ~detail:state.memory_overview_detail
          ~unit:state.memory_unit
          ~input:(Masc_tui_fetched.view_for ~equal:String.equal state.memory_input
                    ~key:keeper.mkh_keeper_id)
          keeper
      in
      full, full
    else
      memory_axis_context state ~cols ~compact:false keeper,
      memory_axis_context state ~cols ~compact:true keeper
  in
  (* Every loaded Keeper's is measured, because the detail under the list is
     as tall as the tallest of them (RFC tui-one-screen-grammar §8). Sized by
     the selected Keeper alone, it moved the list's last row and the divider
     under it on every j and k (QA N02). Only the selected one is drawn. *)
  let measures = measured_readings state ~cols ~readings keepers in
  let no_reading = { rows = []; primary_rows = 0; stalled_row = None } in
  let context, compact_context =
    Option.fold ~none:(no_reading, no_reading) ~some:readings
      (List.nth_opt keepers (max 0 (min state.memory_health_cursor (List.length keepers - 1))))
  in
  let all_refused = memory_refused_keeper_lines state in
  let base = memory_overview_scrolled ~header_rows:0 ~refused_rows:0 ~context_rows:0 state in
  (* The context divider needs a row only when the detail itself is shown. *)
  let fixed_rows = base.sc_chrome - Masc_tui_frame.chrome_rows in
  (* Keep the selected Keeper and neighbouring rows together where they fit.
     Where the list stands is on the title row, so no row is kept for it. *)
  let count = List.length keepers in
  let list_rows = if count = 0 then 1 else min 3 count in
  (* Reserve a visible count when decoding rejected rows. The rejection
     block spends any additional room after the summary and before detail. *)
  let refused_min = if all_refused = [] then 0 else 1 in
  (* A compact reading keeps its state, an omission marker and an actionable
     stalled-gap row. The rows kept for the detail are the most any loaded
     Keeper's would keep, so the header and the rejected rows above the list
     do not change with the selection either. *)
  let reserve measure =
    if measure.full_rows = 0 then 0
    else if state.memory_overview_detail then 3 + (if measure.stalled then 1 else 0)
    else measure.compact_rows + 1
  in
  let context_reserve =
    List.fold_left (fun most measure -> max most (reserve measure)) 0 measures
  in
  let header_budget = max 0 (budget - fixed_rows - list_rows - refused_min - context_reserve) in
  (* On a very short frame the full list and selected detail must yield before
     a fleet warning does. Leave one row for the selected Keeper or empty
     state and one for a rejected-row notice when present. *)
  let compact_header_room = max 0 (budget - fixed_rows - 1 - refused_min) in
  let full_header =
    if state.memory_overview_detail then memory_fleet_header_rows ~cols state
    else
      [ Memory_tree.memory_mode_strip ~ko ~cols ~active:`Storage () ]
      @ Memory_tree.world_hierarchy_card ~ko
          ~width:(framed_inner_width cols)
          ~world:(Masc_tui_memory_world.reading state.memory_world)
          ~health:state.memory_health
          ~unit:state.memory_unit
      @ (match keepers with
         | _ :: _ -> []
         | [] ->
             let heading, clauses = memory_world_axis state ~room:(max 1 (framed_inner_width cols - 2)) in
             clause_rows ~cols (heading :: clauses))
  in
  let header =
    if List.length full_header <= header_budget then full_header
    else if compact_header_room > 0 then [memory_compact_fleet_row ~cols state]
    else []
  in
  let refused_available =
    let desired = max 0 (budget - fixed_rows - list_rows - List.length header - context_reserve) in
    if all_refused <> [] && budget - fixed_rows - List.length header >= 2
    then max 1 desired else desired
  in
  let refused =
    fold_memory_rows ~ko ~subject:(if ko then "거절된 키퍼" else "rejected Keeper")
      ~max_rows:(if refused_available > 1 then refused_available - 1 else refused_available)
      all_refused
  in
  let refused_divider = refused <> [] && refused_available > 1 in
  let refused_spent = List.length refused + if refused_divider then 1 else 0 in
  let context =
    let available =
      budget - fixed_rows - list_rows - List.length header - refused_spent
    in
    if context.rows = [] || available <= 1 then []
    else
      let room = available - 1 in
      let fold (context, compact) =
        fold_memory_context_rows ~ko ~max_rows:room
          (if List.length context.rows <= room then context else compact)
      in
      (* The rows [fold] leaves a reading: it keeps a reading that fits and
         folds a longer one, or its compact one, into the room. *)
      let folded measure =
        if measure.full_rows <= room then measure.full_rows else min measure.compact_rows room
      in
      let tallest = List.fold_left (fun tallest measure -> max tallest (folded measure)) 0 measures in
      (* Each reading is folded into the room before it is measured, so
         none is cut here: [fit_tallest] only pads the selected one to the
         tallest. The room is the cap as well: a reading too tall for it is
         already drawn in its compact form, so the default cap would only cut
         a reading that fits. *)
      Masc_tui_detail_height.fit_tallest ~cap:room ~budget:room ~tallest
        ~too_tall:(Masc_tui_detail_height.Cut_with
                     (if ko then "  … v:전체" else "  … v:full reading"))
        ~blank:"" (fold (context, compact_context))
  in
  { header; refused; refused_divider; context }

let memory_overview_scrolled ~cols ~budget (state : state) =
  let projection = memory_overview_rows ~cols ~budget state in
  memory_overview_scrolled
    ~header_rows:(List.length projection.header)
    ~refused_rows:(refused_rows projection)
    ~context_rows:(List.length projection.context) state

(* A row the operator picks a keeper from: the mark, the name, proportional
   memory bar, counts, stored size and state word. Selected rows still strip
   SGR down the line while preserving clean columns. *)
let memory_selector_line ?(selected = false) ?(max_facts = 0) ~cols (state : state) keeper =
  let ko = state.ui_language = Lang_ko in
  let width = max 1 (framed_inner_width cols - 2) in
  let mark_style, word_style =
    match memory_deviation_style keeper with
    | Some style -> style, style
    | None -> Theme.ok (), ""
  in
  let mark = mark_style ^ memory_state_cell (memory_state keeper) ^ Ansi.reset in
  let lead = if selected then "\xe2\x80\xba " else "  " in
  let state_word = memory_operator_state state keeper in
  if width >= 58 && max_facts > 0 then
    let name_cells = min 22 (max 14 (width / 3)) in
    let bar_cells = 10 in
    let facts_s =
      if keeper.mkh_snapshot_present then
        Printf.sprintf (if ko then "%5d건" else "%5d") keeper.mkh_facts
      else Message_layout.pad_left Masc_tui_theme.Glyph.no_value (if ko then 7 else 5)
    in
    let size_s =
      let raw =
        if keeper.mkh_snapshot_present then
          stored_size state.memory_unit keeper.mkh_snapshot_bytes
        else Masc_tui_theme.Glyph.no_value
      in
      Message_layout.pad_left raw 7
    in
    let bar =
      Chart.dot_meter_bar ~width:bar_cells ~value:keeper.mkh_facts ~max_value:max_facts
        ~scale:(Chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Memory })
        ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
    in
    let used =
      2 + 2 + name_cells + 2 + bar_cells + 2
      + Message_layout.display_width facts_s + 2 + 7 + 2
    in
    let status_cells = max 1 (width - used) in
    let word = Message_layout.fit_width state_word status_cells in
    lead ^ mark ^ " "
    ^ Message_layout.fit_middle name_cells (Terminal_text.single_line keeper.mkh_keeper_id)
    ^ "  " ^ bar ^ "  " ^ facts_s ^ "  "
    ^ Theme.recede () ^ size_s ^ Ansi.reset
    ^ "  "
    ^ (if word_style = "" then word else word_style ^ word ^ Ansi.reset)
  else
    let name_cells = max 1 (width / 2) in
    let status_cells = max 1 (width - name_cells - 3) in
    let word = Message_layout.fit_width state_word status_cells in
    lead ^ mark ^ " "
    ^ Message_layout.fit_middle name_cells (Terminal_text.single_line keeper.mkh_keeper_id)
    ^ " " ^ (if word_style = "" then word else word_style ^ word ^ Ansi.reset)

let render_memory_body ~cols ~budget (state : state)
    ~(report_drawn_list : paged_list -> height:int -> unit)
    ~(hand_position : Masc_tui_value.Position.t -> unit)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~(push_selected : string -> unit)
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let query = memory_overview_query state in
  let keepers = visible_memory_keepers state in
  let shown = List.length keepers in
  let max_facts =
    List.fold_left
      (fun acc (k : memory_keeper_health) ->
        if k.mkh_snapshot_present then max acc k.mkh_facts else acc)
      0 keepers
  in
  let inner_w = max 1 (framed_inner_width cols - 2) in
  let columns =
    Render_schedule.allocate_memory_columns ~inner_width:inner_w
  in
  let ko = state.ui_language = Lang_ko in
  let sort_label =
    if not ko then memory_overview_sort_label state.memory_overview_sort
    else match state.memory_overview_sort with
      | Mem_overview_facts -> "기억 많은 순"
      | Mem_overview_size -> "저장량 많은 순"
      | Mem_overview_delta -> "최근 변경 순"
      | Mem_overview_state -> "주의 우선"
      | Mem_overview_name -> "이름순"
      | Mem_overview_updated -> "최근 갱신순"
  in
  (* The sort it is in, and the filter key the footer gives up first. The row
     also named [a / A] in bold, a key with no value beside it that the footer
     carries at every width, so it said the footer's word again louder. *)
  let info_bar =
    Printf.sprintf (if ko then "  %s정렬 [s]:%s %s  %s·%s  %s[u]:%s %s  %s[/]:%s 필터"
      else "  %sSort [s]:%s %s  %s·%s  %s[u]:%s %s  %s[/]:%s Filter")
      (Theme.recede ()) Ansi.reset sort_label
      (Theme.recede ()) Ansi.reset
      (Theme.recede ()) Ansi.reset
      (if ko then (match state.memory_unit with Memory_usage.Tokens -> "토큰" | Memory_usage.Bytes -> "KiB")
       else Memory_usage.unit_label state.memory_unit)
      (Theme.recede ()) Ansi.reset
  in
  let projection = memory_overview_rows ~cols ~budget state in
  List.iter push projection.header;
  push info_bar;
  let search_bar =
    (* The one value the list was filtered by. [visible_memory_keepers] narrows
       on [memory_overview_query], which is the text being typed while a search
       is open and the applied one otherwise; the bar decided whether to draw
       from that and then quoted [search_last] instead. Typing the first filter
       drew the count for what was typed beside an empty pair of quotes, so the
       line named a filter that matched everything and a number that did not.

       And the noun follows the count: filtering by a Keeper's name usually
       leaves exactly one, which read "1 matching keepers". The stats line four
       rows up already counts through the helper that declines the plural. *)
    if query <> "" then
      if ko then
        Printf.sprintf "  %s필터 [/]:%s \"%s\" (키퍼 %d명)  %sEsc:해제%s"
          Ansi.bold Ansi.reset (Terminal_text.single_line query) shown (Theme.recede ()) Ansi.reset
      else
        Printf.sprintf "  %sFilter [/]:%s \"%s\" (%s)  %sEsc:clear%s"
          Ansi.bold Ansi.reset (Terminal_text.single_line query)
          (Masc_tui_message_layout.count_noun shown "matching keeper")
          (Theme.recede ()) Ansi.reset
    else ""
  in
  if search_bar <> "" then push search_bar;
  push_divider ();
  push_styled ~style:(Theme.recede ())
    (if state.memory_overview_detail then "  " ^ Render_schedule.memory_header_row ~ko columns
     else if inner_w >= 58 && max_facts > 0 then
       let name_cells = min 22 (max 14 (inner_w / 3)) in
       let facts_h =
         Message_layout.pad_left (if ko then "기억" else "FACTS") (if ko then 7 else 5)
       in
       let size_h = Message_layout.pad_left (if ko then "저장" else "SIZE") 7 in
       "    " ^ Message_layout.fit_width (if ko then "키퍼" else "KEEPER") name_cells
       ^ "  " ^ Message_layout.fit_width (if ko then "점유" else "USAGE") 10
       ^ "  " ^ facts_h ^ "  " ^ size_h ^ "  " ^ (if ko then "상태" else "STATE")
     else ui_text state
       ~ko:"  키퍼 · 상태"
       ~en:"  Keeper · state");
  push_divider ();
  (match memory_health_error_text state with
   | None -> ()
   | Some detail ->
       push_styled ~style:(Theme.bad ())
         ("  " ^ Terminal_text.single_line detail);
       push_divider ());
  (* The rejected rows use the same bounded projection as scroll layout. An
     omitted block retains its count, and never pushes the roster offscreen. *)
  List.iter (push_styled ~style:(Theme.bad ())) projection.refused;
  if projection.refused_divider then push_divider ();
  let cursor =
    if shown = 0 then 0 else max 0 (min state.memory_health_cursor (shown - 1))
  in
  let layout = Masc_tui_types.memory_overview_scrolled
      ~header_rows:(List.length projection.header)
      ~refused_rows:(refused_rows projection)
      ~context_rows:(List.length projection.context) state in
  let rows = budget + Masc_tui_frame.chrome_rows in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
  in
  let scroll =
    Masc_tui_scroll.normalize ~count:shown ~height:content_height
      state.memory_health_scroll
    |> Masc_tui_scroll.ensure_visible ~cursor ~height:content_height
  in
  if shown = 0 then
    (* A failed read and an unread one say what every page says. Memory had its
       own words for both, and "server error" named a connection nobody made. *)
    (match
       empty_page_of ~snapshot:state.memory_health ~error:state.memory_health_error
     with
     | Page_failed -> push_styled ~style:(Theme.recede ()) (page_failed_note ~ko)
     | Page_unread when state.memory_health_inflight ->
         let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
         push_styled ~style:(Theme.info ())
           (if ko then "  " ^ under_way ^ " 기억 조회 중"
            else "  " ^ under_way ^ " reading memory")
     | Page_unread ->
         push_styled ~style:(Theme.recede ())
           (if ko then "  (기억 미조회)" else page_unread_note_while ~ko:false ~reading:false)
     | Page_empty when query <> "" ->
         push_styled ~style:(Theme.recede ())
           (Printf.sprintf (if ko then "  (\"%s\"에 맞는 키퍼 없음 · Esc:필터 해제)"
              else "  (no keepers matching \"%s\" · Esc clears filter)")
              (Terminal_text.single_line query))
     | Page_empty ->
         push_styled ~style:(Theme.recede ())
           (if ko then "  (기억 설정이나 스냅샷이 있는 키퍼 없음)"
            else "  (no keepers with a memory config or snapshot)"))
  else begin
    let keepers_window =
      Rows.of_list ~first:scroll ~height:content_height keepers
    in
    report_drawn_list Memory_keepers ~height:content_height;
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at keepers_window idx with
      | None -> push_empty ()
      | Some k ->
          let is_selected = idx = cursor in
          let line =
            if state.memory_overview_detail then
              memory_row_line ~selected:is_selected ~ko ~unit:state.memory_unit columns k
            else memory_selector_line ~selected:is_selected ~max_facts ~cols state k in
          if is_selected then
            push_selected (Masc_tui_theme.strip_sgr line)
          else push line
    done;
    hand_position (Masc_tui_value.Position.row ~selected:(Some cursor) ~total:shown)
  end;
  (match projection.context with
   | [] -> ()
   | lines ->
       push_divider ();
       List.iter push lines)

(* How many fact rows the list keeps before the detail below it takes any.
   Enough to read the cursor against its neighbours -- one row above, one
   below, and the room a filter leaves when it lands the cursor near an
   edge. Under this the browser stops being one. *)
let memory_fact_list_floor_rows = 5

(* The tallest detail among the loaded facts, in lines. Counting it wraps
   every fact's claim, so it is kept for the rows it was counted from: the
   rows are the projection [memory_fact_rows] keeps until the snapshot, the
   filter or the sort changes, and a frame that draws the same rows reads
   the count back. *)
let memory_fact_tallest_detail :
    (memory_fact_row list * int * bool * int) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let tallest_fact_detail_lines ~ko ~cols rows =
  match Domain.DLS.get memory_fact_tallest_detail with
  | Some (seen, seen_cols, seen_ko, tallest)
    when seen == rows && seen_cols = cols && Bool.equal seen_ko ko -> tallest
  | Some _ | None ->
      let tallest =
        List.fold_left
          (fun tallest row ->
            Int.max tallest (fact_detail_line_count (memory_fact_detail_parts ~ko ~cols row)))
          0 rows
      in
      Domain.DLS.set memory_fact_tallest_detail (Some (rows, cols, ko, tallest));
      tallest

let memory_facts_layout ~cols ~budget ~cursor (state : state) rows =
  let total = List.length rows in
  let cursor = max 0 (min cursor (total - 1)) in
  let ko = state.ui_language = Lang_ko in
  let width = max 1 (framed_inner_width cols) in
  let selected_row = List.nth_opt rows cursor in
  let scope_rows = List.length (memory_facts_scope_lines ~cols state) in
  (* Stats, optional categories/search, two dividers and the column header.
     These are the rows rendered above the list below; detail owns its own
     divider when not drawn as a bordered bottom sheet. The search row is
     counted from [memory_search_query], the same value the renderer draws it from. *)
  let chrome_rows =
    4
    + (if Option.is_some (memory_facts_snapshot state) then 1 else 0)
    + (if String.trim (memory_search_query state) <> "" then 1 else 0)
    + scope_rows
    + (if scope_rows > 0 then 1 else 0)
  in
  let room_below_chrome = max 1 (budget - chrome_rows) in
  let detail_budget =
    max 0 (room_below_chrome - memory_fact_list_floor_rows - 1)
  in
  let tallest = if total = 0 then 0 else tallest_fact_detail_lines ~ko ~cols rows in
  let preview_eyebrow = if ko then "선택한 사실" else "Selected Fact" in
  let preview_footer_hints =
    [ { Masc_tui_card.key = "Enter"; label = (if ko then "전체" else "full") }
    ; { key = "d"; label = (if ko then "트리" else "tree") }
    ; { key = "c/C"; label = (if ko then "분류" else "cat") }
    ]
  in
  let preview_chrome =
    Doc.docked_preview_chrome ~eyebrow:preview_eyebrow
      ~footer_hints:preview_footer_hints ()
  in
  (* Reserve [tallest + preview_chrome] (clamped to [preview_chrome + 4 .. preview_chrome + 10],
     i.e. 7..13 with header + footer hints) so the final metadata row stays visible
     whenever [detail_budget >= tallest + preview_chrome]. *)
  let sheet_height =
    if total = 0 || detail_budget < 5 || tallest <= 0 || width < Masc_tui_card.min_width
    then 0
    else
      min detail_budget
        (min (preview_chrome + 10)
           (max (preview_chrome + 4) (tallest + preview_chrome)))
  in
  let detail_lines, detail_is_sheet =
    match selected_row with
    | Some row when sheet_height >= 5 ->
        let preview_indent = 1 in
        let preview_cells = max 1 (width - preview_indent) in
        let sheet_parts =
          fact_detail_parts_for_width ~state ~ko ~width:preview_cells row
        in
        let total_body =
          sheet_parts.claim_line_count + 1 + List.length sheet_parts.other_lines
        in
        let sheet =
          Doc.docked_preview ~width ~height:sheet_height ~indent:preview_indent
            ~eyebrow:preview_eyebrow
            ~title:(Masc_tui_theme.strip_sgr sheet_parts.heading_plain)
            ~meta:(Printf.sprintf (if ko then "%d줄" else "%d lines") total_body)
            ~footer_hints:preview_footer_hints
            (sheet_parts.claim_lines @ [ "" ] @ sheet_parts.other_lines)
        in
        sheet, true
    | Some row when detail_budget > 0 ->
        let parts = fact_detail_parts_for_width ?state:None ~ko ~width row in
        let total_detail_lines = fact_detail_line_count parts in
        let height = min detail_budget (max tallest total_detail_lines) in
        let overflow =
          "      "
          ^ Masc_tui_value.Count.more ~ko (total_detail_lines - (height - 1))
          ^ (if ko then " · Enter:전체 사실" else " · Enter for the whole fact")
        in
        let lines =
          Masc_tui_detail_height.fit_tallest ~budget:detail_budget ~tallest
            ~too_tall:(Masc_tui_detail_height.Cut_with overflow) ~blank:""
            (fact_detail_prefix parts total_detail_lines)
        in
        lines, false
    | None | Some _ -> [], false
  in
  let detail_rows =
    if detail_is_sheet then List.length detail_lines
    else match detail_lines with [] -> 0 | lines -> 1 + List.length lines
  in
  let height = max 1 (room_below_chrome - detail_rows) in
  let scroll =
    Masc_tui_scroll.normalize ~count:total ~height state.memory_facts_scroll
    |> Masc_tui_scroll.ensure_visible ~cursor ~height
  in
  (detail_lines, detail_is_sheet, height, scroll)

let memory_facts_pane_cols state cols =
  if state.memory_facts_categories_open && cols >= Masc_tui_roster_pane.threshold_cols then
    cols - Masc_tui_roster_pane.pane_cols - Message_layout.display_width " │ "
  else cols

let memory_facts_content_height ~cols ~budget ~cursor state =
  let _, _, height, _ =
    memory_facts_layout ~cols:(memory_facts_pane_cols state cols) ~budget ~cursor state (memory_fact_rows state)
  in
  height

let render_memory_facts_body_single ?(show_category_strip = true) ~cols ~budget (state : state)
    ~(report_drawn_list : paged_list -> height:int -> unit)
    ~(hand_position : Masc_tui_value.Position.t -> unit)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~(push_selected : string -> unit)
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let is_fleet = memory_facts_is_fleet state in
  let rows = memory_fact_rows state in
  let total = List.length rows in
  let cursor = max 0 (min state.memory_facts_cursor (total - 1)) in
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  let sort_label = memory_sort_text ~ko state.memory_facts_sort in
  (* The parts of the total the title draws, counted from the rows this screen
     is about to list, so the title's total and this breakdown count the same
     set. Counting the store instead gives a filtered title saying "2 facts"
     above a breakdown that sums to 285. The store's own totals are the category
     pills' job, and the All pill carries the grand total. *)
  let ordinary_count, source_count, dropped_count =
    List.fold_left
      (fun (ordinary, source, dropped) row ->
        match row with
        | Memory_row_fact _ -> (ordinary + 1, source, dropped)
        | Memory_row_source_fact _ -> (ordinary, source + 1, dropped)
        | Memory_row_invalidation _ -> (ordinary, source, dropped + 1))
      (0, 0, 0) rows
  in
  (* The row says what the listing below it says: a failed read drew
     "(loading facts…)" here over a body reading "(load failed; …)", because
     this row looked only at whether facts were held. *)
  let stats_line, pills_line =
    match memory_facts_view state with
    | Masc_tui_fetched.Loading ->
        let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
        (Theme.info () ^ "  " ^ under_way ^ " " ^ text "사실 조회 중" "loading facts" ^ Ansi.reset, "")
    | Masc_tui_fetched.Absent -> ("  " ^ here_missing_reading state ~error:None, "")
    | Masc_tui_fetched.Failed failure ->
        ("  " ^ here_missing_reading state ~error:(Some failure), "")
    | Masc_tui_fetched.Ready (snapshot, _) | Masc_tui_fetched.Stale ((snapshot, _), _) ->
        let stats =
          facts_stats_row ~ko ~ordinary:ordinary_count ~source:source_count
            ~dropped:dropped_count ~sort_label in
        let all_categories = if show_category_strip then memory_fact_categories state else [] in
        let count_of category = match category_count state snapshot category with
          | None -> "?" | Some count -> string_of_int count in
        let keys = text "  c/C:분류  " "  c/C:category  " in
        let after =
          if cols < Masc_tui_roster_pane.threshold_cols then ""
          else if state.memory_facts_categories_open then text "  d:분류 접기" "  d:hide categories"
          else text "  d:분류 펼치기" "  d:show categories"
        in
        let pills =
          if not show_category_strip then
            let active_mode =
              match state.memory_facts_sort with
              | Sort_retrieved_count -> `Retrieved
              | Sort_recency | Sort_last_retrieved | Sort_category | Sort_claim -> `Recent
            in
            Memory_tree.memory_mode_strip ~ko ~cols ~active:active_mode ()
          else Theme.recede () ^ keys ^ Ansi.reset
          ^ tab_strip
              ~width:(tab_strip_width ~cols ~before:keys ~after)
              ~press:(fun filt text ->
                Masc_tui_press.(pressable (Press_memory_category filt) text))
              (List.map
                 (fun filt ->
                   ( Printf.sprintf "%s %s" (fst (Memory_tree.filter_badge ~ko filt))
                       (count_of filt)
                   , state.memory_facts_category = filt
                   , filt ))
                 (Category_all :: all_categories))
          ^ Theme.recede () ^ after ^ Ansi.reset
        in
        (stats, pills)
  in
  push stats_line;
  if pills_line <> "" then push pills_line;
  let search_banner =
    (* [memory_search_query], the value [memory_fact_rows] filtered by, for
       all three of the decision, the quotation and the count. It used to
       decide and quote from [search_last] while the rows were already
       narrowed by the text being typed, so a second filter typed over an
       applied one drew the old word above rows the new one had left. *)
    let filter = memory_search_query state in
    if String.trim filter <> "" then
      Printf.sprintf (if ko then "  %s필터 [/]:%s \"%s\" (%s)  %sEsc:해제%s" else "  %sFilter [/]:%s \"%s\" (%s)  %sEsc:clear%s")
        Ansi.bold Ansi.reset (Terminal_text.single_line filter)
        (if ko then Printf.sprintf "일치 %d개" total else Masc_tui_message_layout.count_noun total "matching fact")
        (Theme.recede ()) Ansi.reset
    else ""
  in
  if search_banner <> "" then push search_banner;
  push_divider ();
  let scope = memory_facts_scope_lines ~cols state in
  if scope <> [] then begin
    List.iter (push_styled ~style:(Theme.bad ())) scope;
    push_divider ()
  end;
  let col_header = if is_fleet then text "  키퍼 · 분류 · 내용" "  Keeper · category · content"
    else text "  분류 · 내용" "  Category · content"
  in
  push_styled ~style:(Theme.recede ()) col_header;
  push_divider ();
  let detail_lines, detail_is_sheet, content_height, scroll =
    memory_facts_layout ~cols ~budget ~cursor state rows
  in
  if total = 0 then
    (match
       empty_page_of ~snapshot:(memory_facts_snapshot state) ~error:(memory_facts_failure state),
       state.memory_facts_category
     with
     | (Page_failed, Category_all) | (Page_failed, Category_ordinary _)
     | (Page_failed, Category_source) | (Page_failed, Category_dropped) ->
         push_styled ~style:(Theme.recede ()) (page_failed_note ~ko)
     | (Page_unread, Category_all) | (Page_unread, Category_ordinary _)
     | (Page_unread, Category_source) | (Page_unread, Category_dropped)
       when view_is_loading (memory_facts_view state) ->
         let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
         push_styled ~style:(Theme.info ())
           (text ("  " ^ under_way ^ " 사실 조회 중") ("  " ^ under_way ^ " loading facts"))
     | (Page_unread, Category_all) | (Page_unread, Category_ordinary _)
     | (Page_unread, Category_source) | (Page_unread, Category_dropped) ->
         push_styled ~style:(Theme.recede ())
           (text "  (미조회)" (page_unread_note_while ~ko:false ~reading:false))
     | Page_empty, Category_all ->
         (* [total] counts rows filtered by [memory_search_query], so the
            note reads the same value; the store is not empty just because
            a filter being typed matched nothing. *)
         let filter = memory_search_query state in
         push_styled ~style:(Theme.recede ())
           (if String.trim filter <> "" then
              Printf.sprintf (if ko then "  (\"%s\"에 맞는 사실 없음 · Esc:필터 해제)" else "  (no facts matching \"%s\" · Esc clears filter)")
                (Terminal_text.single_line filter)
            else if Option.bind (memory_facts_snapshot state) (fun snapshot ->
              memory_fact_count ~complete:(memory_counts_complete state) snapshot All_facts) = None then
              text "  (읽힌 사실 없음 · 일부 관측)" "  (no facts read; partial reading)"
            else if is_fleet then text "  (읽힌 키퍼에 사실 없음)" "  (no facts across the observed keepers)"
            else text "  (두 저장소에 사실 없음)" "  (no facts in either store)")
     | Page_empty, filt ->
         push_styled ~style:(Theme.recede ())
           (Printf.sprintf (if ko then "  (분류 %s에 읽힌 사실 없음 · c/C:변경)" else "  (no facts read in category %s · c/C cycles)")
              (memory_category_filter_text ~ko filt)))
  else begin
    let rows_window = Rows.of_list ~first:scroll ~height:content_height rows in
    report_drawn_list Memory_fact_rows ~height:content_height;
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at rows_window idx with
      | None -> push_empty ()
      | Some row ->
          let line = memory_fact_row_line ~ko ~is_fleet ~sort:state.memory_facts_sort ~cols row in
          if idx = cursor then
            let plain = Masc_tui_theme.strip_sgr line in
            let marked =
              if String.length plain >= 2 && plain.[0] = ' ' && plain.[1] = ' ' then
                "\xe2\x80\xba " ^ String.sub plain 2 (String.length plain - 2)
              else "\xe2\x80\xba " ^ plain
            in
            push_selected marked
          else push line
    done;
    hand_position (Masc_tui_value.Position.row ~selected:(Some cursor) ~total)
  end;
  (match detail_lines with
   | [] -> ()
   | lines ->
       if not detail_is_sheet then push_divider ();
       List.iter push lines)

let render_memory_facts_body ~cols ~budget (state : state)
    ~report_drawn_list ~hand_position ~push ~push_styled ~push_selected ~push_divider ~push_empty =
  if not state.memory_facts_categories_open || cols < Masc_tui_roster_pane.threshold_cols then
    render_memory_facts_body_single ~cols ~budget state
      ~report_drawn_list ~hand_position ~push ~push_styled ~push_selected ~push_divider ~push_empty
  else begin
    let width = Masc_tui_roster_pane.pane_cols in
    let fact_cols = memory_facts_pane_cols state cols in
    let fact_inner_cols = framed_inner_width fact_cols in
    let facts : (bool * string) list ref = ref [] in
    let handed : (int * Masc_tui_value.Position.t) option ref = ref None in
    let collect row = facts := row :: !facts in
    render_memory_facts_body_single ~show_category_strip:false ~cols:fact_cols ~budget state
      ~report_drawn_list
      ~hand_position:(fun pos -> handed := Some (List.length !facts, pos))
      ~push:(fun text -> collect (false, text))
      ~push_styled:(fun ~style text ->
        let styled = if style = "" then text else style ^ text ^ Ansi.reset in
        collect (true, styled))
      ~push_selected:(fun text ->
        let fitted = fit_width text fact_inner_cols in
        let painted =
          match Theme.sidebar_selection_background () with
          | Some bg when not (String.equal bg "") ->
              Masc_tui_theme.paint_row_background ~bg fitted
          | Some _ | None -> Theme.selection_style () ^ fitted ^ Ansi.reset
        in
        collect (false, painted))
      ~push_divider:(fun () ->
        collect (true, Theme.border_muted () ^ draw_hline fact_inner_cols ^ Ansi.reset))
      ~push_empty:(fun () -> collect (false, ""));
    let ko = state.ui_language = Lang_ko in
    let count category = Option.bind (memory_facts_snapshot state)
        (fun snapshot -> category_count state snapshot category) in
    let categories = Category_all :: memory_fact_categories state in
    let entries = List.map (fun category -> category, count category) categories in
    let rail =
      Memory_tree.sidebar_tree_rows ~ko ~width ~height:budget
        ~world:(Masc_tui_memory_world.reading state.memory_world)
        ~selected:state.memory_facts_category ~entries
      |> List.map (function
           | None, line -> line
           | Some category, line ->
               Masc_tui_press.(pressable (Press_memory_category category) line))
    in
    let facts = List.rev !facts in
    let height = max (List.length facts) (min budget (List.length rail)) in
    (* Both panes through the list-window helper the scroll panes read: two
       arrays, one pass, each row reads its own cells -- no row of the loop
       walks either list to find itself. *)
    let rail_window = Rows.of_list ~first:0 ~height rail in
    let facts_window = Rows.of_list ~first:0 ~height facts in
    (match !handed with
     | Some (0, pos) -> hand_position pos
     | Some _ | None -> ());
    for index = 0 to height - 1 do
      let rail_cell = Option.value (Rows.at rail_window index) ~default:"" in
      let is_other, fact_cell =
        Option.value (Rows.at facts_window index) ~default:(true, "")
      in
      let merged =
        fit_width rail_cell width ^ Theme.border_muted () ^ " │ " ^ Ansi.reset
        ^ fit_width fact_cell fact_inner_cols
      in
      if is_other then push_styled ~style:"" merged else push merged;
      match !handed with
      | Some (at, pos) when index + 1 = at -> hand_position pos
      | Some _ | None -> ()
    done;
    (match !handed with
     | Some (at, pos) when at > height -> hand_position pos
     | Some _ | None -> ())
  end
