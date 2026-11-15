open Masc_tui_types
open Masc_tui_ansi
module Decode = Masc.Tui_decode
module Chart = Masc_tui_chart
module Layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Count = Masc_tui_value.Count
module Unknown = Masc_tui_value.Unknown

module Task_flow = Masc_tui_task_flow

type turn_counts = { running : int; idle : int; unavailable : int }
type metrics_kpis = {
  total_keepers : int;
  paused_keepers : int;
  turns : turn_counts option;
  tasks : Task_flow.counts option;
  gate_pending_count : int option;
  held_approvals_count : int option;
}

(* Two ways a source can have no reading, and the difference is who wrote the
   string. [Read_failed] carries the loader's own message, which names its
   subject and its verdict -- "memory health load failed: HTTP 503: ..." --
   and needs nothing in front of it. [Unavailable] carries the server's reason
   for a source it will not serve, which is a reason and nothing else, so the
   row says what state it is naming before it.

   One constructor held both, and the row put "unavailable: " in front of
   either. In front of a loader's message that was the subject and the verdict
   a second time, and it pushed the row past the pane: at a hundred and fifty
   columns beside the roster, three of the four Gate and Memory rows were cut
   before their reason ended. *)
type 'a observation =
  | Not_observed
  | Current of 'a
  | Read_failed of string
  | Unavailable of string
  | Stale of string

let observe_source ~observed ~error ?unavailable value =
  match error, unavailable, observed with
  | Some detail, _, true -> Stale detail
  | Some detail, _, false -> Read_failed detail
  | None, Some detail, _ -> Unavailable detail
  | None, None, true -> Current value
  | None, None, false -> Not_observed

let current_value = function
  | Current value -> Some value
  | Not_observed | Read_failed _ | Unavailable _ | Stale _ -> None

let gate_observation (state : state) =
  observe_source ~observed:state.gate_snapshot_observed ~error:state.gate_error
    ?unavailable:state.gate_queue_unavailable state.gate_pending

let held_observation (state : state) =
  observe_source ~observed:state.keeper_tool_approvals_observed
    ~error:state.keeper_tool_approvals_error state.keeper_tool_approvals

(* A count in a card, or the mark for why there is none (RFC
   tui-one-screen-grammar section 6.4). [Unavailable] is a source the server
   could not read from its own store, so it is no more read than a request
   that failed; a refresh that failed draws as failed too, not as the count
   an earlier read left behind. *)
let observation_count observation =
  match observation with
  | Current rows -> Count.grouped (List.length rows)
  | Not_observed -> Unknown.(glyph Unread)
  | Read_failed _ | Unavailable _ | Stale _ -> Unknown.(glyph Read_failed)

(* A section row's value. Without one, the row names the state of the
   reading in RFC-0519 section 2's words, then the reason the source gave;
   [current] says what a current reading reads as. A loader's message already
   names its subject and its verdict, so it stands alone. The card above the
   section draws the same observation as a mark ({!observation_count}). *)
let observation_detail_with ~ko ~current observation =
  match observation with
  | Current value -> current value
  | Not_observed -> field_unread ~ko
  | Read_failed detail -> Terminal_text.single_line detail
  | Unavailable detail -> field_failed ~ko ^ ": " ^ Terminal_text.single_line detail
  | Stale detail -> field_stale ~ko ^ " \xc2\xb7 " ^ Terminal_text.single_line detail

let observation_detail ~ko observation =
  observation_detail_with ~ko
    ~current:(fun rows -> Count.grouped (List.length rows))
    observation

let calculate_kpis (state : state) =
  let turns =
    match state.keeper_turns_observed_at, state.keeper_turns_error with
    | Some _, None ->
      Some (List.fold_left
        (fun count (row : Decode.keeper_turn_row) ->
          match row.ktr_state with
          | Decode.Keeper_turn_running _ -> { count with running = count.running + 1 }
          | Keeper_turn_idle -> { count with idle = count.idle + 1 }
          | Keeper_turn_unavailable _ -> { count with unavailable = count.unavailable + 1 })
        { running = 0; idle = 0; unavailable = 0 } state.keeper_turns)
    | None, _ | _, Some _ -> None
  in
  { total_keepers = List.length state.keepers;
    (* The number the row wants, counted straight off the field that holds
       it. The row used to draw "N configured · M unpaused" and leave the
       reader to subtract, and the subtraction is where the bug was: the
       count skipped a declared keeper as well as a paused one, so every
       declared keeper sat inside the difference a reader reads as paused.
       A word beside a number should name what that number counts. *)
    paused_keepers =
      List.length
        (List.filter (fun (keeper : keeper) -> keeper.k_paused) state.keepers);
    turns;
    tasks = Option.map (fun flow -> flow.Task_flow.current) state.task_flow;
    gate_pending_count = Option.map List.length (current_value (gate_observation state));
    held_approvals_count = Option.map List.length (current_value (held_observation state)) }

let format_words words =
  Masc_tui_context_inspector.format_bytes (max 0 words * 8)

let format_megawords words =
  let mw = Float.abs words /. 1_000_000.0 in
  if mw >= 1000.0 then Printf.sprintf "%.1f GW" (mw /. 1000.0)
  else if mw >= 1.0 then Printf.sprintf "%.1f MW" mw
  else Printf.sprintf "%.0f kW" (words /. 1000.0)

let repeat_glyph glyph count =
  if count <= 0 then "" else String.concat "" (List.init count (fun _ -> glyph))

(* The probe's state in words. A word from a server newer than this build is
   drawn as it came behind [?] (RFC tui-one-screen-grammar section 7.1). That
   word and a stopped probe's reason come off the wire, so both are escaped
   here, where the three rows that ask for them cannot each forget. *)
let scheduler_probe_word ~ko = function
  | Decode.Probe_reported Scheduler_lag.Not_started ->
      if ko then "시작 전" else "not started"
  | Decode.Probe_reported Scheduler_lag.Running -> if ko then "실행 중" else "running"
  | Decode.Probe_reported (Scheduler_lag.Stopped reason) ->
      (if ko then "멈춤: " else "stopped: ") ^ Terminal_text.single_line reason
  | Decode.Probe_reported Scheduler_lag.Cancelled -> if ko then "취소됨" else "cancelled"
  | Decode.Probe_unknown word -> "? " ^ Terminal_text.single_line word

let scheduler_probe_text ~ko = function
  | None -> Unknown.(glyph Unreported)
  | Some probe -> scheduler_probe_word ~ko probe

let pulse_line ~cols (state : state) kpis =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let inner_width = max 10 (framed_inner_width cols) in
  (* A count with no reading behind it draws the mark of why (RFC
     tui-one-screen-grammar section 6.4). *)
  let turns = match kpis.turns with
    | None ->
      say "턴 " "Turns "
      ^ Unknown.glyph
          (match state.keeper_turns_error with
           | Some _ -> Unknown.Read_failed
           | None -> Unknown.Unread)
    | Some count ->
      Printf.sprintf
        (if ko then "턴: 실행 중 %s · 대기 중 %s · 확인 불가 %s"
         else "Turns: %s running · %s idle · %s unavailable")
        (Count.grouped count.running) (Count.grouped count.idle)
        (Count.grouped count.unavailable)
  in
  let roster =
    match state.local_keepers, state.keepers_error with
    | Local_workspace_read, None ->
      Printf.sprintf (if ko then "키퍼 %s · 일시정지 %s" else "%s configured · %s paused")
        (Count.grouped kpis.total_keepers) (Count.grouped kpis.paused_keepers)
    | Local_workspace_unread, None -> say "키퍼 " "roster " ^ Unknown.(glyph Unread)
    | (Local_workspace_unread | Local_workspace_read | Local_workspace_failed _), Some _
    | Local_workspace_failed _, None ->
      say "키퍼 " "roster " ^ Unknown.(glyph Read_failed)
  in
  let text = Printf.sprintf "  %s%s%s  %s| %s%s"
      Ansi.bold turns Ansi.reset (Theme.recede ()) roster Ansi.reset in
  Layout.take_cells text inner_width ^ Ansi.reset

(* The three sections as a tab strip, drawn the way the surface strip above
   every screen is: a mark on the one being read, the names beside it. It was
   "Sections [1-3 / s]: [1 ● Engine & Scheduler] [2 ○ Work & Outcomes] ...",
   which spelled the keys the footer already draws (1-3:section, s:cycle),
   wrote each name a second time beside [metrics_section_label], and was cut
   before the third name at 150 columns beside the Activity pane. The order is
   the order 1, 2 and 3 select. *)
(* Why the server identity has no GC or scheduler block to draw: none has
   been read yet, the last read failed, or the one read did not carry it. *)
let identity_gap (state : state) =
  match state.server_identity, state.server_identity_error with
  | Some _, (None | Some _) -> Unknown.Unreported
  | None, Some _ -> Unknown.Read_failed
  | None, None -> Unknown.Unread

let section_pills_line ~ko ~cols ~(active : metrics_section) : string =
  let inner_width = max 10 (framed_inner_width cols) in
  let tab section = (metrics_section_label ~ko section, active = section, section) in
  let line =
    "  "
    ^ tab_strip
        ~width:(tab_strip_width ~cols ~before:"  " ~after:"")
        ~press:(fun section text ->
          Masc_tui_press.(pressable (Press_metrics_section section)) text)
        (List.map tab [ Section_fleet; Section_resources; Section_tools ])
  in
  if Layout.display_width line > inner_width then
    Layout.take_cells line inner_width ^ Ansi.reset
  else line

let render_kpi_cards ~cols (state : state) (kpis : metrics_kpis) : string list =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let inner_width = max 20 (framed_inner_width cols) in
  let card_w = max 18 ((inner_width - 10) / 4) in
  (* Reserve readable text cells inside the border and padding. Below this
     width use the compact summaries, not four boxes of clipped labels. *)
  let minimum_card_text_cells = 32 in
  let format_card title line1 line2 tone_style =
    let h_rule = repeat_glyph "\xe2\x94\x80" (max 0 (card_w - 2)) in
    let box_t = "\xe2\x94\x8c" ^ h_rule ^ "\xe2\x94\x90" in
    let box_b = "\xe2\x94\x94" ^ h_rule ^ "\xe2\x94\x98" in
    let pad_line s =
      let w = Layout.display_width s in
      if w >= card_w - 4 then Layout.take_cells s (card_w - 4)
      else s ^ String.make (card_w - 4 - w) ' '
    in
    let l_t = "\xe2\x94\x82 " ^ tone_style ^ pad_line title ^ Ansi.reset ^ " \xe2\x94\x82" in
    let l_1 = "\xe2\x94\x82 " ^ pad_line line1 ^ " \xe2\x94\x82" in
    let l_2 = "\xe2\x94\x82 " ^ pad_line line2 ^ " \xe2\x94\x82" in
    (box_t, l_t, l_1, l_2, box_b)
  in
  let gc_opt =
    match state.server_identity with
    | Some { sid_gc = Some gc; _ } -> Some gc
    | _ -> None
  in
  let sched_opt =
    match state.server_identity with
    | Some { sid_scheduler = Some s; _ } -> Some s
    | _ -> None
  in
  let identity_gap = identity_gap state in
  let domains = match sched_opt with
    | Some { ssch_pool_domains = Some count; _ } -> Count.grouped count
    | Some { ssch_pool_domains = None; _ } -> Unknown.(glyph Unreported)
    | None -> Unknown.glyph identity_gap
  in
  let c1_l1, c1_l2 = match gc_opt with
    | Some gc ->
      (Printf.sprintf (if ko then "힙 %s · 사용 중 %s" else "Heap %s · live %s")
         (format_words gc.sgc_heap_words) (format_words gc.sgc_live_words),
       Printf.sprintf (if ko then "워커 %s · 마이너 힙 %s" else "%s workers · minor %s")
         domains (format_words gc.sgc_minor_heap_size))
    | None -> say "힙 " "Heap " ^ Unknown.glyph identity_gap, say "워커 " "Workers " ^ domains
  in
  let c2_l1, c2_l2, c2_tone = match sched_opt with
    | Some s when s.ssch_samples <= 0 ->
      ( say "지연 표본 없음" "No latency samples",
        say "프로브: " "Probe: " ^ scheduler_probe_text ~ko s.ssch_probe,
        Theme.recede () )
    | Some s ->
      (Printf.sprintf (if ko then "p95 %.3fms · 최대 %.3fms" else "p95 %.3fms · max %.3fms")
         s.ssch_p95_ms s.ssch_max_ms,
       Printf.sprintf (if ko then "표본 %s · 정체 %s" else "%s samples · %s stalls")
         (Count.grouped s.ssch_samples) (Count.grouped s.ssch_stalls),
       if s.ssch_stalls > 0 then Theme.warn () else Theme.recede ())
    (* One condition -- no scheduler reading at all -- so both halves of the
       card draw the same mark. *)
    | None ->
      let mark = Unknown.glyph identity_gap in
      "p95 " ^ mark, say "표본 " "Samples " ^ mark, Theme.recede ()
  in
  let c3_l1, c3_l2 = match kpis.tasks with
    | Some count ->
      (Printf.sprintf (if ko then "열린 작업 %s · 검증 대기 %s" else "%s open · %s verifying")
         (Count.grouped (Task_flow.open_count count))
         (Count.grouped count.awaiting_verification),
       Printf.sprintf (if ko then "완료 %s · 취소 %s" else "%s done · %s cancelled")
         (Count.grouped count.completed) (Count.grouped count.cancelled))
    | None ->
      let mark =
        Unknown.glyph
          (match state.tasks_error with
           | Some _ -> Unknown.Read_failed
           | None -> Unknown.Unread)
      in
      say "열린 작업 " "Open " ^ mark, say "완료 " "Done " ^ mark
  in
  let c4_l1 = "Gate " ^ observation_count (gate_observation state) in
  let c4_l2 = say "보류된 호출 " "Tool holds " ^ observation_count (held_observation state) in
  let c4_tone = match kpis.gate_pending_count, kpis.held_approvals_count with
    | Some 0, Some 0 -> Theme.recede ()
    | _ -> Theme.warn () in

  let combine (t1, lt1, l11, l21, b1)
              (t2, lt2, l12, l22, b2)
              (t3, lt3, l13, l23, b3)
              (t4, lt4, l14, l24, b4) =
    [ "  " ^ t1 ^ "  " ^ t2 ^ "  " ^ t3 ^ "  " ^ t4
    ; "  " ^ lt1 ^ "  " ^ lt2 ^ "  " ^ lt3 ^ "  " ^ lt4
    ; "  " ^ l11 ^ "  " ^ l12 ^ "  " ^ l13 ^ "  " ^ l14
    ; "  " ^ l21 ^ "  " ^ l22 ^ "  " ^ l23 ^ "  " ^ l24
    ; "  " ^ b1 ^ "  " ^ b2 ^ "  " ^ b3 ^ "  " ^ b4
    ]
  in
  if card_w - 4 >= minimum_card_text_cells then
    combine
      (format_card (say "엔진" "ENGINE") c1_l1 c1_l2 (Theme.info ()))
      (format_card (say "스케줄러 지연" "SCHEDULER LAG") c2_l1 c2_l2 c2_tone)
      (format_card (say "작업 현황" "TASK SNAPSHOT") c3_l1 c3_l2 (Theme.info ()))
      (format_card (say "확인 필요" "ATTENTION") c4_l1 c4_l2 c4_tone)
  else
    [ Printf.sprintf "  %s[%s]%s %s · %s[%s]%s %s"
        (Theme.info ()) (say "엔진" "ENGINE") Ansi.reset c1_l1
        c2_tone (say "지연" "SCHED") Ansi.reset c2_l1
    ; Printf.sprintf "  %s[%s]%s %s"
        (Theme.info ()) (say "작업" "TASKS") Ansi.reset c3_l1
    ; Printf.sprintf "  %s[%s]%s %s · %s"
        c4_tone (say "확인" "HOLDS") Ansi.reset c4_l1 c4_l2
    ]
    |> List.map (fun line -> if Layout.display_width line > inner_width then Layout.take_cells line inner_width ^ Ansi.reset else line)

let render_section_fleet ?session_rows ~cols (state : state) =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let inner_width = max 20 (framed_inner_width cols) in
  let clip text = Layout.take_cells text inner_width ^ Ansi.reset in
  let title text = "  " ^ Ansi.bold ^ Theme.info () ^ text ^ Ansi.reset in
  let gc = Option.bind state.server_identity (fun identity -> identity.Decode.sid_gc) in
  let scheduler = Option.bind state.server_identity (fun identity -> identity.Decode.sid_scheduler) in
  (* Why a block the server identity holds has nothing in it. Not read yet is
     said in the word every surface uses for a reading not loaded; a failed
     read is the loader's own sentence, as the transport block draws it. *)
  let identity_gap =
    match state.server_identity, state.server_identity_error with
    | Some _, (None | Some _) -> say "서버가 보고하지 않음" "not reported by the server"
    | None, Some error -> Terminal_text.single_line error
    | None, None -> field_unread ~ko
  in
  let reported_count =
    Option.fold ~none:Unknown.(glyph Unreported) ~some:Count.grouped
  in
  let gc_lines = match gc with
    | None -> [ "    " ^ identity_gap ]
    | Some gc ->
      [ Printf.sprintf
          (if ko then "    힙 %s · 사용 중 %s · 마이너 힙 설정 %s"
           else "    Heap %s · live %s · configured minor heap %s")
          (format_words gc.sgc_heap_words) (format_words gc.sgc_live_words)
          (format_words gc.sgc_minor_heap_size)
      ; Printf.sprintf
          (if ko then "    수거: 마이너 %s · 메이저 %s · 강제 메이저 %s · 압축 %s"
           else "    Collections: minor %s · major %s · forced %s · compactions %s")
          (Count.grouped gc.sgc_minor_collections) (Count.grouped gc.sgc_major_collections)
          (Count.grouped gc.sgc_forced_major_collections) (Count.grouped gc.sgc_compactions)
      ; Printf.sprintf
          (if ko then "    할당 누계: 마이너 %s · 승격 %s · 메이저 %s"
           else "    Allocation totals: minor %s · promoted %s · major %s")
          (format_megawords gc.sgc_minor_words) (format_megawords gc.sgc_promoted_words)
          (format_megawords gc.sgc_major_words) ]
  in
  let scheduler_lines = match scheduler with
    | None -> [ "    " ^ identity_gap ]
    | Some sched when sched.ssch_samples <= 0 ->
      [ say "    서버 표본 구간에 지연 표본 없음" "    No latency samples in the producer window"
      ; Printf.sprintf
          (if ko then "    프로브 %s · 워커 도메인 %s" else "    Probe %s · worker domains %s")
          (scheduler_probe_text ~ko sched.ssch_probe)
          (reported_count sched.ssch_pool_domains) ]
    | Some sched ->
      [ Printf.sprintf "    p50 %.3fms · p95 %.3fms · p99 %.3fms"
          sched.ssch_p50_ms sched.ssch_p95_ms sched.ssch_p99_ms
      ; Printf.sprintf
          (if ko then "    최대 %.3fms · 평균 %.3fms · 표본 %s"
           else "    Maximum %.3fms · mean %.3fms · %s samples")
          sched.ssch_max_ms sched.ssch_mean_ms (Count.grouped sched.ssch_samples)
      ; Printf.sprintf
          (if ko then "    서버가 센 정체 %s · 프로브 %s · 워커 도메인 %s"
           else "    Producer-reported stalls %s · probe %s · worker domains %s")
          (Count.grouped sched.ssch_stalls)
          (scheduler_probe_text ~ko sched.ssch_probe)
          (reported_count sched.ssch_pool_domains)
      ; say "    스케줄러 지연은 런타임 응답 속도이며 작업 결과가 아닙니다."
          "    Scheduler delay measures runtime responsiveness, not task output." ]
  in
  let path_word = function
    | Masc.Transport_metrics.Grpc_subscribe -> say "gRPC 구독" "gRPC subscribe"
    | Websocket -> "WebSocket"
    | Sse -> "SSE"
    | Streamable_http -> "Streamable HTTP"
  in
  let pressure_word = function
    | Masc.Transport_metrics.Steady -> say "안정" "steady"
    | Watch -> say "주의" "watch"
    | High -> say "높음" "high"
  in
  (* A failed read is the loader's own sentence, which names its subject and
     its verdict, so it is not drawn as a read not made yet. *)
  let transport_lines = match state.transport, state.transport_error with
    | Some transport, _ ->
      [ Printf.sprintf
          (if ko then "    주 경로 %s · gRPC %s" else "    Primary path %s · gRPC %s")
          (path_word transport.th_primary_path)
          (Option.fold ~none:(say "꺼짐" "off") ~some:(Printf.sprintf ":%d")
             transport.th_grpc_port)
      ; Printf.sprintf
          (if ko then "    SSE 세션 %s · WebSocket 세션 %s · 버린 이벤트 %s"
           else "    SSE sessions %s · WebSocket sessions %s · dropped events %s")
          (Count.grouped transport.th_sse_sessions)
          (reported_count transport.th_websocket_sessions)
          (Count.grouped transport.th_events_dropped)
      ; say "    큐 압력: " "    Queue pressure: " ^ pressure_word transport.th_queue_pressure ]
    | None, Some error -> [ "    " ^ Terminal_text.single_line error ]
    | None, None -> [ "    " ^ field_unread ~ko ]
  in
  (* This TUI's own subscription to the runtime event feed. The count sits
     straight after the state word in both states, the way the Activity
     status row puts it, so a closed feed's number reads as the frames it
     carried. *)
  let feed_line =
    say "    런타임 이벤트 수신: " "    Runtime event feed: "
    ^
    match state.observer with
    | Observer_off -> say "꺼짐" "off"
    | Observer_opening -> say "연결 중" "opening"
    | Observer_live { events; _ } ->
        Printf.sprintf (if ko then "수신 중 %s" else "live %s") (Count.grouped events)
    | Observer_closed_after_live { events; reason; _ } ->
        Printf.sprintf (if ko then "닫힘 %s · %s" else "closed %s · %s")
          (Count.grouped events) (Terminal_text.single_line reason)
    | Observer_closed_before_answer { reason; _ } ->
        say "시작 실패 · " "failed to open · " ^ Terminal_text.single_line reason
  in
  (* This TUI's own log: what it did and what it was told, oldest first so the
     newest line is last. The log holds eleven lines ([add_event]); a run of
     the same line folds into one row with a ×N tail. First in the section,
     so the block starts on screen. [session_rows] is how many rows the frame
     can give it: past that the block keeps its newest rows and says how many
     earlier ones it left out, so the newest line is never below the fold. *)
  let session_lines =
    match state.events with
    | [] -> [ say "    (아직 이벤트 없음)" "    (no events yet)" ]
    | events ->
      let rows =
        Masc_tui_render_schedule.collapse_consecutive
          ~key:session_event_collapse_key events
        |> List.rev
        |> List.map (fun ((event : event), run) ->
               let mark =
                 match session_event_mark event with
                 | None -> ""
                 | Some glyph ->
                   Printf.sprintf "%s%s%s%s " Ansi.bold (Theme.bad ()) glyph
                     Ansi.reset
               in
               let tail =
                 if run > 1 then
                   Printf.sprintf " %s\xc3\x97%d%s" Ansi.dim run Ansi.reset
                 else ""
               in
               Printf.sprintf "    %s[%s]%s %s%s%s" Ansi.dim event.timestamp
                 Ansi.reset mark
                 (Terminal_text.single_line event.content)
                 tail)
      in
      let count = List.length rows in
      (match session_rows with
       | Some room when count > room && room >= 2 ->
         (* One row goes to the count of what was left out. *)
         let earlier = count - (room - 1) in
         (Printf.sprintf (if ko then "    %s이전 %s건%s" else "    %s%s earlier%s")
            Ansi.dim (Count.grouped earlier) Ansi.reset)
         :: List.filteri (fun index _ -> index >= earlier) rows
       | Some room when count > room ->
         (* No room for the count as well: the newest row alone. *)
         List.filteri (fun index _ -> index = count - 1) rows
       | Some _ | None -> rows)
  in
  List.map clip
    ([ title (say "TUI 세션" "TUI session") ] @ session_lines
     @ [ ""; title (say "엔진 메모리" "Engine memory") ] @ gc_lines
     @ [ ""; title (say "스케줄러 지연 (서버 표본 구간)" "Scheduler lag (producer sample window)") ]
     @ scheduler_lines
     @ [ ""; title (say "전송" "Transport delivery") ] @ transport_lines @ [ feed_line ])

(* The one ladder every other surface reads a span on. This pane had its own
   -- a single unit with a tenth after it -- so "how long since" read "7.6s"
   and "1.5d" here while the Board, Fusion, Keepers and the chat rows read
   "7s" and "1d12h" of the same question. The tenth was precision nobody acts
   on, and the single unit loses the second figure at every step above
   minutes. [Masc_tui_message_layout.span_text] says why it is shaped the way
   it is; the two callers before this one were joined for the same reason. *)
let age_text = Layout.span_text

let render_section_resources ~cols (state : state) =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip text = Layout.take_cells text inner_width ^ Ansi.reset in
  let title text = "  " ^ Ansi.bold ^ Theme.info () ^ text ^ Ansi.reset in
  let now = Unix.gettimeofday () in
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  (* The blocks after the first read the same snapshot. Without one they say
     why in a word; the first block carries the loader's sentence. *)
  let no_snapshot = "    " ^ field_missing_reading ~ko ~error:state.tasks_error in
  let task_lines = match state.task_flow with
    | None ->
      [ "    "
        ^ (match state.tasks_error with
           | None -> field_unread ~ko
           | Some error -> Terminal_text.single_line error) ]
    | Some flow ->
      let current = flow.Task_flow.current in
      let moment at =
        Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now at
      in
      (* A count of the tasks in a status, which the Tasks screen names. *)
      let in_status (tag : Masc_domain.Task_status_tag.t) count =
        Masc_tui_task_document.status_tag_label ~ko tag ^ " " ^ Count.grouped count
      in
      let row parts = "    " ^ String.concat " · " parts in
      [ row
          [ say "새 작업 " "New tasks " ^ Count.grouped flow.recent.created
          ; in_status Done flow.recent.completed
          ; in_status Cancelled flow.recent.cancelled ]
      ; Printf.sprintf (if ko then "    구간: %s ~ %s" else "    Window: %s to %s")
          (moment flow.window_started_at) (moment flow.observed_at)
      ; say "    지금 열린 작업 " "    Current open "
        ^ Count.grouped (Task_flow.open_count current) ^ ": "
        ^ String.concat " · "
            [ in_status Todo current.todo
            ; in_status Claimed current.claimed
            ; in_status In_progress current.in_progress
            ; in_status Awaiting_verification current.awaiting_verification ]
      ; row
          [ say "백로그 전체 " "Retained total " ^ Count.grouped (Task_flow.total_count current)
          ; in_status Done current.completed
          ; in_status Cancelled current.cancelled
          ; Printf.sprintf (if ko then "스냅샷 %s 전" else "snapshot %s ago")
              (age_text (now -. flow.observed_at)) ]
      ; say "    가장 오래된 열린 작업: " "    Oldest open task registration: "
        ^ Option.fold ~none:(say "등록 시각을 아는 작업 없음" "none with a known timestamp")
            ~some:(fun at ->
              Printf.sprintf (if ko then "스냅샷 %s 전 등록" else "%s before this snapshot")
                (age_text (flow.observed_at -. at)))
            flow.oldest_open_created_at
      ; say "    완료는 작업 결과이고, 도구 호출과 턴 종료는 활동입니다."
          "    Done is a task outcome; tool calls and turn endings are activity." ]
      @ (if flow.unparseable_timestamps = 0 then [] else
           [ Printf.sprintf
               (if ko then "    구간 집계에서 뺀 잘못된 시각 %s개"
                else "    %s invalid timestamps excluded from time-window counts")
               (Count.grouped flow.unparseable_timestamps) ])
      @ (match state.tasks_error with None -> [] | Some error ->
           [ say "    스냅샷 경고: " "    Snapshot warning: " ^ Terminal_text.single_line error ])
  in
  (* One row per assignee, longest queue first. The list is capped so the two
     blocks below it stay on screen; the tail is reported as a count rather
     than dropped silently. The columns are fitted by cells: Printf pads by
     bytes, so a Korean head or name pulled every column after it left. *)
  let assignee_rows_shown = 10 in
  let assignee_row name done_count open_count lead =
    let count text = " " ^ Layout.pad_left text 6 in
    "    " ^ Layout.fit_width name 26 ^ count done_count ^ count open_count ^ "  " ^ lead
  in
  let assignee_lines = match state.task_flow with
    | None -> [ no_snapshot ]
    | Some flow ->
      (match flow.Task_flow.by_assignee with
       | [] -> [ say "    담당자가 있는 작업이 없습니다." "    No retained task carries an assignee." ]
       | rows ->
         let head = List.filteri (fun index _ -> index < assignee_rows_shown) rows in
         let body =
           List.map
             (fun (row : Task_flow.assignee_flow) ->
               assignee_row row.af_assignee (Count.grouped row.af_done)
                 (Count.grouped row.af_open)
                 (match row.af_median_lead_hours with
                  | None -> Masc_tui_theme.Glyph.no_value
                  | Some hours -> age_text (hours *. 3600.)))
             head
         in
         let omitted = List.length rows - List.length head in
         [ say "    키퍼 이름과 에이전트 이름은 합치지 않고 따로 적습니다."
             "    A keeper name and an agent name stay separate rows; nothing is merged."
         ; assignee_row (say "담당자" "assignee") (say "완료" "done") (say "열림" "open")
             (say "소요 중앙값" "median lead") ]
         @ body
         @ (if omitted <= 0 then []
            else
              [ Printf.sprintf (if ko then "    외 %s명" else "    %s more")
                  (Count.grouped omitted) ]))
  in
  let day_label at =
    let tm = Unix.gmtime at in
    Printf.sprintf "%02d-%02d" (tm.Unix.tm_mon + 1) tm.tm_mday
  in
  let daily_title = match state.task_flow with
    | Some flow when flow.Task_flow.daily <> [] ->
      let first = List.hd flow.Task_flow.daily in
      let last = List.fold_left (fun _ day -> day) first flow.Task_flow.daily in
      Printf.sprintf
        (if ko then "일별 작업 흐름 · %s ~ %s UTC" else "Daily task flow · %s to %s UTC")
        (day_label first.Task_flow.d_start) (day_label last.Task_flow.d_start)
    | Some _ | None ->
      Printf.sprintf
        (if ko then "일별 작업 흐름 · UTC 기준 %d일간" else "Daily task flow · %d UTC days")
        Task_flow.daily_days
  in
  (* Days run across rather than down: the question is the shape of the trend,
     and one line per day pushes every other block off the section. A day's
     column is its widest figure and a space, so a day of a thousand tasks
     does not run into the next one, and does not widen the quiet days and
     push the latest off a narrow pane. *)
  let daily_lines = match state.task_flow with
    | None -> [ no_snapshot ]
    | Some flow ->
      let rows =
        [ say "날짜" "day", (fun (day : Task_flow.day) -> (Unix.gmtime day.d_start).Unix.tm_mday)
        ; say "새 작업" "created", (fun (day : Task_flow.day) -> day.d_created)
        ; say "완료" "completed", (fun (day : Task_flow.day) -> day.d_completed)
        ; say "취소" "cancelled", (fun (day : Task_flow.day) -> day.d_cancelled) ]
      in
      let columns =
        List.map
          (fun day ->
            ( day
            , List.fold_left
                (fun width (_, pick) -> max width (1 + String.length (Count.grouped (pick day))))
                3 rows ))
          flow.Task_flow.daily
      in
      List.map
        (fun (label, pick) ->
          "    " ^ Layout.fit_width label 10
          ^ String.concat ""
              (List.map
                 (fun (day, width) -> Layout.pad_left (Count.grouped (pick day)) width)
                 columns))
        rows
  in
  let turn_lines = match state.keeper_turns_observed_at, state.keeper_turns_error with
    | _, Some error ->
      [ "    " ^ Terminal_text.single_line error
      ; say "    이전 행은 지금 실행 중인 턴으로 세지 않습니다."
          "    Previous rows are not counted as current running turns." ]
    | None, None -> [ "    " ^ field_unread ~ko ]
    | Some observed_at, None ->
      let running = List.filter_map
          (fun (row : Decode.keeper_turn_row) -> match row.ktr_state with
            | Keeper_turn_running { lane; started_at_unix; _ } ->
              Some (row.ktr_keeper_name, lane, started_at_unix)
            | Keeper_turn_idle | Keeper_turn_unavailable _ -> None)
          state.keeper_turns in
      let idle, unavailable = List.fold_left
          (fun (idle, unavailable) (row : Decode.keeper_turn_row) -> match row.ktr_state with
            | Keeper_turn_idle -> idle + 1, unavailable
            | Keeper_turn_unavailable _ -> idle, unavailable + 1
            | Keeper_turn_running _ -> idle, unavailable)
          (0, 0) state.keeper_turns in
      [ Printf.sprintf
          (if ko then "    실행 중 %s · 대기 중 %s · 확인 불가 %s · %s 전 조회"
           else "    %s running · %s idle · %s unavailable · observed %s ago")
          (Count.grouped (List.length running)) (Count.grouped idle)
          (Count.grouped unavailable) (age_text (now -. observed_at))
      ; say "    턴 시간은 키퍼가 알린 시작 시각부터 잽니다."
          "    Turn age = since owner-reported start." ]
      @ List.map
          (fun (name, lane, started_at_unix) ->
              Printf.sprintf
                (if ko then "    %s  턴 %8s  레인 %s" else "    %s  turn %8s  lane %s")
                (Layout.fit_width name 18)
                (age_text (now -. started_at_unix))
                (Masc_tui_answering.lane_word ~ko lane))
          running
  in
  (* A failed read is the loader's own sentence, as the Keepers header draws
     it. It read the words this block says before the first read, so a fleet
     the TUI could not read looked like one it had not asked for yet
     (#38499). *)
  let readiness text = say "    실행 준비: " "    Execution readiness: " ^ text in
  let safety_lines = match fleet_stream_view state with
    | Masc_tui_fleet_stream.Cannot_read failure ->
      [ readiness (Masc_tui_fleet_line.failure_text ~ko failure) ]
    | Masc_tui_fleet_stream.Awaiting_first_reading -> [ readiness (field_unread ~ko) ]
    | Masc_tui_fleet_stream.Unreachable { since } ->
      [ readiness (Masc_tui_fleet_line.unreachable_text ~ko ~now ~since) ]
    | Masc_tui_fleet_stream.Unavailable { degradation; disconnected_since } ->
      [ readiness
          (Masc_tui_fleet_line.unavailable_text ~ko ~now ~degradation ~disconnected_since) ]
    | Masc_tui_fleet_stream.Reading { reading = { fleet = safety; _ }; trouble } ->
      Printf.sprintf
        (if ko then "    실행 가능 %s · 목표 %s · 부족 %s · 실패 %s · 일시정지 %s"
         else "    Executable %s · target %s · shortfall %s · failing %s · paused %s")
        (Count.grouped safety.fs_executable_count)
        (Count.grouped safety.fs_target_reaction_capacity)
        (Count.grouped safety.fs_reaction_capacity_shortfall)
        (Count.grouped safety.fs_failing_count) (Count.grouped safety.fs_paused_count)
      :: (trouble
          |> Option.map (fun trouble -> "    " ^ Masc_tui_fleet_line.trouble_text ~ko ~now trouble)
          |> Option.to_list)
  in
  List.map clip
    ([ title (say "작업 결과 · 스냅샷 전 24시간" "Retained task outcomes · 24-hour snapshot window") ]
     @ task_lines
     @ [ ""
       ; title
           (say "담당자별 작업 · 소요는 등록부터 완료까지"
              "Work per assignee · lead time is created to completed") ]
     @ assignee_lines
     @ [ ""; title daily_title ] @ daily_lines
     @ [ ""; title (say "현재 턴" "Current owner turns") ] @ turn_lines
     @ [ ""; title (say "실행 준비 (fleet 스트림)" "Execution readiness (fleet stream)") ]
     @ safety_lines)

let render_section_tools ~cols (state : state) : string list =
  (* Section 3: Memory & Gate Safety *)
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in
  let bar_w = min 60 (max 20 (inner_width - 8)) in

  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let title_mem =
    Printf.sprintf "  %s%s%s%s" Ansi.bold (Theme.info ())
      (say "Memory OS 사실 저장소" "Memory OS Knowledge Base & Fact Store") Ansi.reset
  in
  (* The same four states the Gate rows below draw. This read "not loaded --
     visit Memory surface to fetch" whatever had happened: arriving here
     already asks for memory health, the same request the Memory surface
     makes, so the advice sent the reader to repeat it, and a read that had
     failed read as one never made. *)
  let memory =
    observe_source ~observed:(Option.is_some state.memory_health)
      ~error:state.memory_health_error state.memory_health
  in
  let memory_status =
    say "    기억 상태: " "    Memory health: "
    ^ observation_detail_with ~ko ~current:(fun _ -> "") memory
  in
  let memory_rows =
    match state.memory_health with
    | None -> []
    | Some mhs ->
        let total_facts = mhs.mhs_total_facts in
        (* The ordinary snapshots' size, named as the Memory screen names it. *)
        let header =
          Printf.sprintf
            (if ko then "    일반 사실 %s · 출처 사실 %s · 일반 저장량 %s tok"
             else "    Ordinary facts %s · source facts %s · ordinary stored %s tok")
            (Count.grouped total_facts)
            (Count.grouped mhs.mhs_total_source_facts)
            (Masc_tui_token_scale.format_estimate Masc_tui_token_scale.fleet
               (List.fold_left (fun acc (k : Masc.Tui_decode_memory_health.memory_keeper_health) -> acc + k.mkh_snapshot_bytes) 0 mhs.mhs_keepers))
        in
        let rows =
          if mhs.mhs_keepers = [] then
            [ say "    (기억 구역이 있는 등록 키퍼 없음)"
                "    (no registered keepers with memory partitions)" ]
          else
            List.map
              (fun (k : Masc.Tui_decode_memory_health.memory_keeper_health) ->
                let pct = if total_facts = 0 then 0 else (k.mkh_facts * 100) / total_facts in
                let bar = Chart.gauge ~width:16 ~value:pct ~max_value:100 ~label:"" () in
                Printf.sprintf
                  (if ko then "    %s  사실 %s  %s  %s tok%s" else "    %s  %s facts  %s  %s tok%s")
                  (Layout.fit_width
                     (Terminal_text.single_line k.mkh_keeper_id)
                     16)
                  (Layout.pad_left (Count.grouped k.mkh_facts) 6)
                  bar
                  (Masc_tui_token_scale.format_estimate
                     Masc_tui_token_scale.fleet k.mkh_snapshot_bytes)
                  Ansi.reset)
              mhs.mhs_keepers
        in
        header :: rows
  in
  let mem_lines =
    match memory with
    | Current _ -> memory_rows
    | Stale _ -> memory_status :: memory_rows
    | Read_failed _ | Unavailable _ | Not_observed -> [ memory_status ]
  in

  let title_gate =
    Printf.sprintf "  %s%s%s%s" Ansi.bold (Theme.bad ())
      (say "Gate 승인과 보안 설정" "Gate Governance & Security Stance") Ansi.reset
  in
  let gate = gate_observation state in
  let held = held_observation state in
  let rules =
    observe_source ~observed:state.gate_snapshot_observed ~error:state.gate_error
      ?unavailable:state.gate_rules_unavailable state.gate_rules in
  let yolo =
    observe_source ~observed:state.keeper_tool_modes_observed
      ~error:state.keeper_tool_modes_error state.keeper_yolo_names in
  let module Tool_map = Map.Make (String) in
  let counts =
    let add_tool acc tool =
      let current = Option.value (Tool_map.find_opt tool acc) ~default:0 in
      Tool_map.add tool (current + 1) acc
    in
    let acc =
      match current_value gate with
      | None -> Tool_map.empty
      | Some gps ->
        List.fold_left
          (fun acc (gp : Decode.gate_pending) ->
            add_tool acc (Terminal_text.single_line gp.gp_display_tool))
          Tool_map.empty
          gps
    in
    match current_value held with
    | None -> acc
    | Some ktas ->
      List.fold_left
        (fun acc (kta : Decode.keeper_tool_approval) ->
          add_tool acc (Terminal_text.single_line kta.kta_tool))
        acc
        ktas
  in

  let gate_summary =
    [ say "    Gate 승인 대기: " "    Pending Gate Calls: " ^ observation_detail ~ko gate
    ; say "    보류된 호출: " "    Held Tool Approvals: " ^ observation_detail ~ko held
    ; say "    항상 허용 규칙: " "    Standing Rules: " ^ observation_detail ~ko rules
    ; say "    YOLO 키퍼: " "    YOLO Keepers: " ^ observation_detail ~ko yolo ]
  in
  let yolo_line =
    match yolo with
    | Current (_ :: _ as names) ->
      [ say "    YOLO 실행: " "    YOLO Execution: "
        ^ String.concat " \xc2\xb7 " (List.map Terminal_text.single_line names) ]
    | Current [] | Not_observed | Read_failed _ | Unavailable _ | Stale _ -> []
  in

  let tool_bars =
    if Tool_map.is_empty counts then
      (match gate, held with
       | Current [], Current [] ->
         [ say "    (Gate 승인 대기와 보류된 호출 없음)"
             "    (no active pending gate operations or held approval requests)" ]
       | (Current [], Current (_::_))
       | (Current [], (Not_observed | (Read_failed _ | (Unavailable _ | Stale _))))
       | (Current (_::_), _) | ((Not_observed | (Read_failed _ | (Unavailable _ | Stale _))), _) ->
         [ say "    도구별 대기 수를 다 읽지 못해 비었다고 보지 않습니다."
             "    Pending tool totals unavailable; no empty queue inferred" ])
    else
      let items =
        Tool_map.fold
          (fun name count acc ->
            { Chart.name; count; style = Masc_tui_theme.Warn } :: acc)
          counts []
        |> List.sort (fun (a : Chart.bar_item) (b : Chart.bar_item) ->
               let c = Int.compare b.count a.count in
               if c <> 0 then c else String.compare a.name b.name)
      in
      let scope = match gate, held with
        | Current _, Current _ -> []
        | (Current _, (Not_observed | (Read_failed _ | (Unavailable _ | Stale _))))
        | ((Not_observed | (Read_failed _ | (Unavailable _ | Stale _))), _) ->
          [ say "    도구 분포: 읽은 대기열만 (일부 관측)"
              "    Tool distribution: observed queues only (partial coverage)" ] in
      scope @ (Chart.distribution_bars ~width:bar_w items
        |> List.map (fun l -> "    " ^ l))
  in

  [ clip title_mem ]
  @ List.map clip mem_lines
  @ [ ""
    ; clip title_gate
    ]
  @ List.map clip (gate_summary @ yolo_line)
  @ [ "" ]
  @ List.map clip tool_bars

let rebase_scroll_for_cards ~scroll ~previous_cards ~current_cards =
  match previous_cards with
  | None -> scroll
  | Some previous_cards ->
      if scroll = 0 || scroll = clamped_scroll_end then scroll
      else Masc_tui_scroll.step_uncounted ~delta:(current_cards - previous_cards) scroll

let render_metrics_body ~cols ~budget ~suffix_lines (state : state)
    ~(report_scroll : int -> int -> int -> unit)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~push_selected:_
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let ko = state.ui_language = Lang_ko in
  let kpis = calculate_kpis state in
  let pulse = pulse_line ~cols state kpis in
  push pulse;
  let pills = section_pills_line ~ko ~cols ~active:state.metrics_section in
  push pills;
  push_divider ();
  let card_lines = render_kpi_cards ~cols state kpis in
  (* On a short, wide terminal the cards alone can consume the body. Keep
     them scrollable in that case so the section and status remain reachable. *)
  let pinned_cards, scroll_cards =
    if budget <= 4 + List.length card_lines then [], card_lines
    else card_lines, [] in
  List.iter push pinned_cards;
  if suffix_lines = [] then push_divider ()
  else push_styled ~style:(Theme.recede ()) (metrics_status_at_end ~ko);
  let fixed_rows = 1 + 1 + 1 + List.length pinned_cards + 1 in
  let room = max 0 (budget - fixed_rows) in
  let section_lines =
    match state.metrics_section with
    | Section_fleet ->
      (* The block's title takes one row and the scroll hint under the
         section may take another. Use the space before cards move into the
         scroll, so the card transition does not also expand the log. *)
      let room_with_pinned_cards = max 0 (budget - 4 - List.length card_lines) in
      render_section_fleet ~session_rows:(max 1 (room_with_pinned_cards - 2)) ~cols state
    | Section_resources -> render_section_resources ~cols state
    | Section_tools -> render_section_tools ~cols state
  in
  let section_lines = scroll_cards @ section_lines @ suffix_lines in
  let total_lines = List.length section_lines in
  let overflowing = total_lines > room in
  let hint_rows = if overflowing && room >= 2 then 1 else 0 in
  let available = max 0 (room - hint_rows) in
  let max_scroll = max 0 (total_lines - available) in
  let card_rows = List.length scroll_cards in
  let scroll =
    rebase_scroll_for_cards ~scroll:state.metrics_scroll
      ~previous_cards:state.metrics_scroll_card_rows ~current_cards:card_rows
    |> min max_scroll |> max 0 in
  (* The row this frame could actually start at, handed back so the next
     keypress steps from it rather than from wherever the last one left the
     stored value. *)
  report_scroll scroll available card_rows;
  let section_lines_window =
    Rows.of_list ~first:scroll ~height:available section_lines
  in
  for i = 0 to available - 1 do
    let idx = i + scroll in
    match Rows.at section_lines_window idx with
    | Some line -> push line
    | None -> push_empty ()
  done;
  if hint_rows > 0 then
    (* Where the window stands. The keys that move it are the footer's. *)
    match Masc_tui_scroll.position_row ~ko ~scroll ~height:available total_lines with
    | None -> push_empty ()
    | Some row ->
      let inner_width = max 20 (framed_inner_width cols) in
      let clipped =
        if Layout.display_width row > inner_width then Layout.take_cells row inner_width
        else row
      in
      push_styled ~style:(Theme.recede ()) clipped
