(** Features, plugins and clients. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Hint_lines = Masc_tui_hint_lines
module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Page_line = Masc_tui_page_line
module Page_reading = Masc_tui_page_reading
module Keeper_chat = Masc_tui_keeper_chat_projection
module Render_schedule = Masc_tui_render_schedule

let format_context_tokens = Masc_tui_types.format_context_tokens

(* A refusal is bad news about the key pressed; a pending write is a warning
   about what the screen shows, as is a list that may be stale
   ([Masc_tui_types.runtime_lane_stale_lines], drawn in warn). *)
let runtime_lane_notice_tone = function
  | Masc_tui_types.Lane_write_refused _ -> Page_line.Failure
  | Masc_tui_types.Lane_write_pending -> Page_line.Attention
  | Masc_tui_types.Lane_write_committed receipt ->
    if Masc_tui_runtime_config_receipt.lane_needs_attention receipt then Page_line.Attention
    else Page_line.Info

let runtime_lane_notice_style notice =
  Page_reading.tone_style (runtime_lane_notice_tone notice)

(* What a list of candidates reads when it has none. *)
let no_candidates = "(없음)"

let standalone_lane_purpose (lane : Tui_decode.standalone_lane) =
  Option.value ~default:"No consumer purpose reported by this server."
    lane.sl_purpose

let standalone_lane_obligation (lane : Tui_decode.standalone_lane) =
  if lane.sl_required then "필수(Required)" else "선택(Optional)"

let standalone_lane_outcome_ko = function
  | "succeeded" | "ok" | "approved" | "reviewed" | "committed" -> "성공"
  | "failed" | "error" | "raised" -> "실패"
  | "cancelled" | "review_cancelled" -> "취소"
  | "rejected" -> "반려"
  | other -> Terminal_text.single_line other

let standalone_lane_last_run ~now (lane : Tui_decode.standalone_lane) =
  match lane.sl_last_outcome, lane.sl_last_terminal_at with
  | None, _ -> "실행 기록 없음"
  | Some outcome, None ->
    "마지막 실행 " ^ standalone_lane_outcome_ko outcome
  | Some outcome, Some at ->
    Printf.sprintf "마지막 실행 %s (%s 전)"
      (standalone_lane_outcome_ko outcome)
      (Masc_tui_answering.elapsed_text ~now at)

let standalone_lane_state_tone (lane : Tui_decode.standalone_lane) =
  match lane.sl_configuration_state, lane.sl_status with
  | Tui_decode.Lane_registry_unavailable, _
  | _, Tui_decode.Standalone_degraded -> Page_line.Failure
  | (Tui_decode.Lane_slotless | Tui_decode.Lane_unconfigured), _
  | _, Tui_decode.Standalone_unavailable -> Page_line.Attention
  | Tui_decode.Lane_off, _ | _, Tui_decode.Standalone_off -> Page_line.Quiet
  | Tui_decode.Lane_ready, Tui_decode.Standalone_running -> Page_line.Info
  | Tui_decode.Lane_ready,
    Tui_decode.(Standalone_idle | Standalone_no_retained_observation) ->
    Page_line.Plain

let standalone_lane_headline_state ~now (lane : Tui_decode.standalone_lane) =
  let last_run = standalone_lane_last_run ~now lane in
  match lane.sl_configuration_state, lane.sl_status with
  | Tui_decode.Lane_registry_unavailable, _ ->
    "오류 — 런타임 레지스트리를 읽을 수 없음"
  | Tui_decode.Lane_unconfigured, _ ->
    "미설정 — 지정된 모델 후보가 없음"
  | Tui_decode.Lane_slotless, _ ->
    "실행 불가 — 설정된 후보 중 사용 가능한 모델이 없음"
  | Tui_decode.Lane_off, _ | _, Tui_decode.Standalone_off ->
    if lane.sl_running_count > 0 then
      Printf.sprintf "꺼짐 (진행 중 %d건 마무리 중) · %s"
        lane.sl_running_count last_run
    else
      Printf.sprintf "꺼짐 (신규 실행 중지) · %s" last_run
  | Tui_decode.Lane_ready, Tui_decode.Standalone_degraded ->
    Printf.sprintf "주의 필요 — %s" last_run
  | Tui_decode.Lane_ready, Tui_decode.Standalone_running ->
    let started_note =
      match lane.sl_last_started_at with
      | Some started ->
        Printf.sprintf "%d건 진행 중 (최근 %s 전 시작)"
          lane.sl_running_count
          (Masc_tui_answering.elapsed_text ~now started)
      | None -> Printf.sprintf "%d건 진행 중" lane.sl_running_count
    in
    Printf.sprintf "실행 중 — %s · %s" started_note last_run
  | Tui_decode.Lane_ready, Tui_decode.Standalone_idle ->
    Printf.sprintf "모델 설정됨 · %s" last_run
  | Tui_decode.Lane_ready, Tui_decode.Standalone_no_retained_observation ->
    "모델 설정됨 · 보존된 실행 기록 없음"
  | Tui_decode.Lane_ready, Tui_decode.Standalone_unavailable ->
    Printf.sprintf "사용 불가 · %s" last_run

let standalone_lane_run_score_summary (lane : Tui_decode.standalone_lane) =
  let total = lane.sl_retained_run_count in
  if total > 0 then
    let rate =
      float_of_int lane.sl_succeeded_count /. float_of_int total *. 100.0
    in
    Printf.sprintf "%.1f%% 성공 (%d성공 / %d실패 / %d취소 · 총 %d건)"
      rate lane.sl_succeeded_count lane.sl_failed_count
      lane.sl_cancelled_count total
  else "집계된 실행 기록 없음"

let standalone_lane_latency_summary (lane : Tui_decode.standalone_lane) =
  match lane.sl_p50_elapsed_s with
  | Some s -> (
      match Message_layout.elapsed_text s with
      | Some text -> Some (Printf.sprintf "중앙값(p50) %s 소요" text)
      | None -> None)
  | None -> None

let standalone_lane_jev_summary (lane : Tui_decode.standalone_lane) =
  match lane.sl_jev with
  | None -> None
  | Some Tui_decode.Jev_off -> Some (Page_line.Quiet, "꺼짐 (OFF)")
  | Some Tui_decode.Jev_cli_only ->
    Some (Page_line.Quiet, "사용 불가 (Board 레인이 CLI 전용)")
  | Some Tui_decode.Jev_lane_unavailable ->
    Some (Page_line.Attention, "사용 불가 (Board 레인이 준비되지 않음)")
  | Some (Tui_decode.Jev_configured { destinations }) ->
    let named (destination : Tui_decode.standalone_lane_jev_destination) =
      Printf.sprintf "%s (%s)" destination.sljd_destination_uri destination.sljd_model
    in
    Some
      ( Page_line.Plain
      , "활성 · "
        ^ Terminal_text.single_line
            (String.concat ", " (List.map named destinations)) )

let hint key label = { Hint_lines.key; label }

let exact_lane_overview_actions state =
  [ hint "Enter" (ui_text state ~ko:"실행 기록" ~en:"runs")
  ; hint "Space" (ui_text state ~ko:"켜기/끄기" ~en:"on/off")
  ; hint "s / a" (ui_text state ~ko:"실행 후보 편집/추가" ~en:"edit/add candidates")
  ; hint "d" (ui_text state ~ko:"통계·후보·설정 근거" ~en:"statistics, candidates and evidence")
  ]

(* The first reading separates declarations, application and observed work.
   Candidate routes, percentages and latency remain in the full [d] reading. *)
let feature_summary_lines state ~width ~label ~purpose ~standing ~notices ~fields ~actions =
  let wrap style text =
    Masc_tui_text_block.rows ~max_cells:(max 1 width) text
    |> List.map (fun line -> style, line) in
  wrap Ansi.bold label
  @ wrap (Theme.recede ()) purpose
  @ wrap (Masc_tui_lane_standing.colour standing)
      (Masc_tui_lane_standing.word ~korean:(state.ui_language = Lang_ko) standing)
  @ List.concat_map (fun (style, line) -> wrap style line) notices
  @ List.concat_map (fun (style, line) -> wrap style line) fields
  @ List.map (fun line -> Theme.info (), line) (Hint_lines.wrap ~max_cells:(max 1 width) actions)

let standalone_lane_summary_lines state ~width ~standing
    (lane : Tui_decode.standalone_lane) =
  let text ko en = ui_text state ~ko ~en in
  let declared = match lane.sl_configuration_state with
    | Lane_ready | Lane_slotless -> text "켜짐" "On"
    | Lane_off -> text "꺼짐" "Off"
    | Lane_unconfigured -> text "실행 후보 미설정" "No candidates configured"
    | Lane_registry_unavailable -> text "레지스트리 미관측" "Registry not observed" in
  let current = if lane.sl_running_count = 0 then text "보고된 실행 없음" "No runs reported"
    else Printf.sprintf (if state.ui_language = Lang_ko then "%d건 실행 관측" else "%d runs observed") lane.sl_running_count in
  let notices = Option.to_list (Option.map (fun error -> Theme.bad (),
      text "실행 준비 오류 · " "Admission error · " ^ error) lane.sl_admission_error) in
  let fields =
    [ Ansi.reset, text "모델 설정 · " "Model configuration · " ^ declared
    ; Ansi.reset, text "현재 실행 · " "Current runs · " ^ current
    ]
    @ Option.to_list (Option.map (fun outcome -> Theme.recede (),
        text "마지막 종료 결과 · " "Last terminal outcome · " ^ Terminal_text.single_line outcome)
        lane.sl_last_outcome) in
  feature_summary_lines state ~width ~label:lane.sl_label
    ~purpose:(match lane.sl_purpose with
      | Some purpose -> purpose
      | None -> text "이 관측에는 기능 설명이 없습니다." "No purpose was reported in this observation.")
    ~standing ~notices ~fields
    ~actions:(exact_lane_overview_actions state)

let inventory_row_summary_lines state ~width ~standing ~selected_output
    (row : Masc.Tui_decode_lane_inventory.row) =
  let open Masc.Tui_decode_lane_inventory in
  let text ko en = ui_text state ~ko ~en in
  let field label value = Ansi.reset, label ^ " · " ^ value in
  let fields, notices, actions = match row.state with
    | Exact_state config ->
        let declared, applied, errors = match config with
          | Configured c ->
              text "켜짐" "On",
              Printf.sprintf (if state.ui_language = Lang_ko then "수락된 후보 %d개" else "%d candidates admitted")
                (List.length c.admitted_slots + List.length c.cli_slots),
              Option.to_list (Option.map (fun error -> Theme.bad (), error) c.admission_error)
          | Disabled _ -> text "꺼짐" "Off", text "새 실행 중지" "New runs disabled", []
          | Unconfigured detail -> text "미설정" "Not configured", detail, []
          | Registry_unavailable detail -> text "미관측" "Not observed", detail, [] in
        [field (text "모델 설정" "Model configuration") declared;
         field (text "실행 준비" "Admission") applied;
         field (text "실행 기록" "Run history") (text "미관측" "Not observed")],
        errors, exact_lane_overview_actions state
    | Browser_clients reading ->
        let connection, notices = match reading with
          | Browser_observed count -> Printf.sprintf
              (if state.ui_language = Lang_ko then "연결된 클라이언트 %d개" else "%d connected clients") count, []
          | Browser_addon_absent -> text "브라우저 플러그인 선언 없음" "No browser plugin declared", []
          | Browser_addon_off -> text "브라우저 플러그인 꺼짐" "Browser plugin off", []
          | Browser_addon_not_running -> text "켜짐 선언 · 워커 실행 미보고" "Declared on; no running worker reported", []
          | Browser_addon_unavailable detail -> text "조회 실패" "Read failed", [Theme.bad (), detail] in
        [field (text "연결" "Connection") connection;
         field (text "설정" "Configuration") (text "브라우저 플러그인에서 관리" "Managed by the browser plugin")], notices,
        [hint "Enter" (text "브라우저 열기" "open browser"); hint "d" (text "관측 근거" "evidence")]
    | Machine_state (activity, publication) ->
        let declared = match activity with
          | Machine_enabled -> text "켜짐" "On"
          | Machine_disabled -> text "꺼짐 · 머신 상태 보존" "Off; machine state retained"
          | Machine_unobserved -> text "미관측" "Not observed" in
        let publication = match publication with
          | No_screen -> text "게시된 화면 없음" "No screen published"
          | Stable -> text "보존된 화면 안정 상태" "Published screen stable"
          | Running -> text "실행 상태 보고" "Running state reported"
          | Publication_unavailable -> text "워커 관측 불가" "Worker observation unavailable" in
        [field (text "설정" "Configuration") declared;
         field (text "화면" "Screen") publication], [],
        [hint "Enter" (text "화면 열기" "open screen"); hint "Space" (text "켜기/끄기" "on/off"); hint "d" (text "관측 근거" "evidence")]
    | Package_state {declaration; instances} ->
        let declared, application, errors = match declaration with
          | None -> text "수동 연결 · 선언 파일 없음" "Manual attachment; no declaration file", text "선언 적용 대상 아님" "No declaration application", []
          | Some Absent -> text "선언 파일 없음" "Declaration absent", text "미관측" "Not observed", []
          | Some Unobserved -> text "디렉터리 읽기 미완료" "Directory not fully observed", text "미관측" "Not observed", []
          | Some (Invalid messages) -> text "선언 오류" "Invalid declaration", text "미확인" "Unconfirmed",
              List.map (fun message -> Theme.bad (), message) messages
          | Some (Valid value) ->
              let application, errors = match value.application with
                | Masc.Lane_addon_application.Applied _ -> text "워커 적용 보고" "Worker application reported", []
                | Starting_worker -> text "워커 시작 대기" "Worker startup pending", []
                | Cleaning_workers -> text "이전 워커 정리 중" "Previous workers being cleaned", []
                | Inactive -> text "워커 정리 확인" "Worker cleanup confirmed", []
                | Failed messages -> text "적용 실패" "Application failed", List.map (fun message -> Theme.bad (), message) messages
                | Unknown messages -> text "적용 미확인" "Application unconfirmed", List.map (fun message -> Theme.warn (), message) messages in
              (if value.enabled then text "켜짐" "On" else text "꺼짐" "Off"), application, errors in
        let live = List.filter (fun (item : instance) -> match item.presence with Live -> true | Retained -> false) instances in
        let phase_label = function
          | Attached -> text "연결" "attached"
          | Observing -> text "관측 중" "observing"
          | Failed _ -> text "실패" "failed"
          | Detaching -> text "정리 중" "cleanup pending"
          | Detached -> text "종료" "detached" in
        let current = match live with
          | [] -> text "현재 서버 워커 기록 없음" "No current-server worker record"
          | items ->
              Printf.sprintf (if state.ui_language = Lang_ko then "현재 서버 기록 %d개" else "%d current-server records") (List.length items)
              ^ " · " ^ String.concat ", " (List.map (fun (item : instance) -> phase_label item.phase) items) in
        let failures = List.filter_map (fun (item : instance) ->
          let prefix = match item.presence with Live -> text "현재 워커 실패 · " "Current worker failed · " | Retained -> text "보존 워커 실패 · " "Retained worker failed · " in
          match item.phase with
          | Failed detail -> Some (Theme.bad (), prefix ^ detail)
          | Detaching -> Some (Theme.info (), text "워커 정리 중" "Worker cleanup pending")
          | Attached | Observing | Detached -> None) instances in
        let output = match Masc_tui_lane_inventory.selected_exact_output ~selected:selected_output row with
          | None -> []
          | Some (_, output) -> [field (text "선택 출력" "Selected output") output.output] in
        let actions = match row.selection,
          Masc_tui_lane_inventory.selected_exact_output ~selected:selected_output row with
          | Declaration _, Some _ ->
              [hint "Enter" (text "적용 상태·조치" "application and actions");
               hint "e" (text "출력 설정 편집" "edit output settings");
               hint "[ / ]" (text "출력 선택" "select output"); hint "d" (text "전체 근거" "full evidence")]
          | Declaration _, None | Manual_instance _, _ ->
              [hint "Enter" (text "워커·적용 상태" "workers and application"); hint "d" (text "전체 근거" "full evidence")]
          | (Exact _ | Browser _ | Machine _), _ ->
              [hint "Enter" (text "열기" "open"); hint "d" (text "전체 근거" "full evidence")] in
        [field (text "설정" "Configuration") declared]
        @ (match declaration with None -> [] | Some _ -> [field (text "적용" "Application") application])
        @ [field (text "워커" "Workers") current]
        @ output, errors @ failures, actions
  in
  feature_summary_lines state ~width ~label:row.label ~purpose:row.purpose
    ~standing ~notices ~fields ~actions

let standalone_lane_without_slot_rows_ko (lane : Tui_decode.standalone_lane) =
  let without = lane.sl_runs_without_slot in
  let counted label count =
    if count <= 0 then [] else [ Printf.sprintf "• %s: %d건" label count ]
  in
  let gap =
    match standalone_lane_slot_history_gap lane with
    | 0 -> []
    | gap when gap > 0 -> [ Printf.sprintf "• 슬롯 집계 누락: %d건" gap ]
    | gap -> [ Printf.sprintf "• 슬롯 집계 초과: %d건" (-gap) ]
  in
  counted "Vendor System One (외부 직접 응답)" without.slws_vendor_system_one
  @ counted "서버 재시작으로 중단" without.slws_server_restarted
  @ counted "슬롯 미기록" without.slws_no_slot
  @ gap

(* A candidate list is a numbered list; none is the word for none, receded. *)
let candidate_items ?(tone = Page_line.Plain) label = function
  | [] -> Page_line.fact ~tone:Page_line.Quiet label no_candidates
  | values -> Page_line.items ~tone label values

let standalone_lane_detail_lines ~now ~width (lane : Tui_decode.standalone_lane) =
  let fact = Page_line.fact in
  let state_tone = standalone_lane_state_tone lane in
  let answer = Tui_decode.standalone_lane_answer lane in
  let slot_history =
    let slot_rows =
      List.map
        (fun (sc : Tui_decode.standalone_lane_slot_count) ->
           Printf.sprintf "• %s: %d회"
             (Terminal_text.single_line sc.slsc_slot_id) sc.slsc_count)
        lane.sl_selected_slots
    in
    match slot_rows @ standalone_lane_without_slot_rows_ko lane with
    | [] ->
      [ Page_line.note ~tone:Page_line.Quiet "(기록된 슬롯 응답 이력이 없습니다)" ]
    | rows -> List.map Page_line.note rows
  in
  let state =
    [ fact ~tone:state_tone "상태" (standalone_lane_headline_state ~now lane)
    ; fact "구분" (standalone_lane_obligation lane)
    ; fact ~tone:state_tone "설정"
        (Tui_decode.standalone_lane_configuration_phrase lane.sl_configuration_state)
    ; fact
        ~tone:(if lane.sl_failed_count > 0 then Page_line.Attention else Page_line.Plain)
        "보존된 실행" (standalone_lane_run_score_summary lane)
    ]
    @ (match standalone_lane_latency_summary lane with
       | None -> []
       | Some latency -> [ fact "속도" latency ])
    @ (match standalone_lane_jev_summary lane with
       | None -> []
       | Some (tone, text) -> [ fact ~tone "JEV" text ])
    @ (match lane.sl_admission_error with
       | None -> []
       | Some error ->
         [ fact ~tone:Page_line.Failure "등록 오류" (Terminal_text.single_line error) ])
  in
  let failover =
    [ fact ~tone:Page_line.Quiet "TOML 섹션"
        (Printf.sprintf "[runtime.exact_output_lanes.%s]"
           (Standalone_lane.to_id lane.sl_lane))
    ; candidate_items "1차 HTTP 후보 (순서대로 시도)" lane.sl_admitted_slots
    ; candidate_items "2차 CLI 후보 (HTTP 모두 실패 시)" lane.sl_cli_slots
    ; candidate_items ~tone:Page_line.Attention "탈락 후보"
        lane.sl_dropped_slots
    ]
  in
  Page_reading.rows
    ~max_cells:(max 1 (width - String.length Page_reading.detail_indent))
    [ Page_line.Title
        (Printf.sprintf "%s · %s" (Terminal_text.single_line lane.sl_label)
           (Terminal_text.single_line (standalone_lane_purpose lane)))
    ]
  @ [ Ansi.reset, "" ]
  @ detail_page ~width
      [ "1. 현재 관측 · 최근 실행", state
      ; "2. 설정된 실행 후보 · 설정 위치", failover
      ; "3. 모델별 누적 응답 횟수 (Slot Selection History)", slot_history
      ; ( "4. 레인 출력 의미 · 실행 증거 (Contract)"
        , [ fact "Output meaning" answer.sla_output_meaning
          ; fact ~tone:Page_line.Quiet "Evidence" answer.sla_evidence
          ] )
      ]

let inventory_row_detail_lines ~width ~selected_output
    (row : Masc.Tui_decode_lane_inventory.row) =
  let max_cells = max 1 (width - 2) in
  let output_lines =
    match Masc_tui_lane_inventory.exact_output_lines ~selected:selected_output row with
    | [] -> []
    | outputs ->
      detail_section_heading "2. 출력 스키마 바인딩 (Exact Output)"
      @ Page_reading.wrap_indented_lines ~max_cells Ansi.reset outputs
  in
  Page_reading.rows ~max_cells [ Page_line.Title (row.label ^ " · " ^ row.purpose) ]
  @ detail_section_heading "1. 설정 · 관측 상세 (Configuration · Observation)"
  @ Page_reading.rows ~max_cells (Masc_tui_lane_inventory.detail_lines row)
  @ output_lines

let rec take_rows remaining acc = function
  | _ when remaining <= 0 -> List.rev acc
  | [] -> List.rev acc
  | row :: rest -> take_rows (remaining - 1) (row :: acc) rest

(* Editing takes the pane while it is open. A long CLI tail otherwise sits
   below the lane matrix and can put the acting cursor outside the frame. *)
let render_exact_lane_provider_editor (state : state) editor =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let lane = Masc_tui_types.slot_editor_target_name editor.Masc_tui_types.se_target in
  let entries = Masc_tui_types.slot_editor_rows state in
  let count = List.length entries in
  let selected_index = Masc_tui_types.slot_editor_cursor_index state in
  (* j/k stop on slots, never on a group's title, so an empty group has no
     row to move into. Its title says where a slot comes from instead: [a]
     picks one, and the runtime's kind decides the group it joins. *)
  let group_rows kind title =
    let rows =
      entries
      |> List.mapi (fun index row -> index, row)
      |> List.filter (fun (_, row) -> row.Masc_tui_types.sr_kind = kind)
    in
    let heading =
      match rows with
      | [] -> Printf.sprintf "  %s (0) · a adds one" title
      | _ :: _ -> Printf.sprintf "  %s (%d)" title (List.length rows)
    in
    (None, heading)
    :: List.map (fun (index, row) -> Some index, row.Masc_tui_types.sr_slot) rows
  in
  let display_rows =
    group_rows Masc_tui_types.Catalog_slot "HTTP slots · tried first"
    @ group_rows Masc_tui_types.Official_client_slot
        "CLI slots · tried after every HTTP slot"
  in
  box_top buf cols;
  box_line buf cols
    (here_row ~cols state
       ~path:[ Terminal_text.single_line lane
             ; ui_text state ~ko:"모델 순서" ~en:"model order" ]
       ~readings:[] ~position:None);
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.info ())
    (Printf.sprintf "  %s · HTTP candidates first, then CLI candidates"
       (Terminal_text.single_line lane));
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
     box_lines_styled buf cols ~style:(Theme.warn ())
       (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail));
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
     box_lines_styled buf cols ~style:(runtime_lane_notice_style notice)
       (Keeper_chat.terminal_safe_text ~preserve_newlines:true
          (Masc_tui_types.runtime_lane_notice_text notice)));
  List.iter
    (fun line -> box_line_styled buf cols ~style:(Theme.warn ())
       ("  " ^ Keeper_chat.terminal_safe_text line))
    (Masc_tui_types.runtime_lane_stale_lines state);
  (match state.runtime_lane_write with
   | Masc_tui_types.Lane_write_posting ->
     box_line_styled buf cols ~style:(Theme.info ()) "  Saving candidate order..."
   | Masc_tui_types.Lane_write_rereading _ ->
     box_line_styled buf cols ~style:(Theme.info ()) "  Reading current candidate order..."
   | Masc_tui_types.Lane_write_idle -> ());
  (match Masc_tui_types.runtime_picker_projection
     ~page:(Masc_tui_types.runtime_exact_picker_page state ~terminal_rows ~cols) state with
   | Some picker ->
     let action = match picker.Masc_tui_types.rlp_pick with
       | Masc_tui_types.Pick_exact_lane_replacement _ -> "Replace selected candidate", "Enter replace"
       | Pick_media_failover | Pick_route_default | Pick_conversation_lane _ | Pick_exact_lane _
       | Pick_new_lane _ -> "Add fallback candidate", "Enter add" in
     box_line_styled buf cols ~style:(Theme.info ())
       ("  " ^ fst action);
     box_line_styled buf cols ~style:(Theme.recede ())
       ("  " ^ picker.Masc_tui_types.rlp_summary);
     if picker.Masc_tui_types.rlp_choices = [] then
       box_line_styled buf cols ~style:(Theme.recede ())
         (Masc_tui_types.runtime_picker_empty_note picker)
     else
       picker.Masc_tui_types.rlp_choices
       |> List.iteri (fun offset choice ->
            match choice with
            | Masc_tui_types.Lane_choice _ -> ()
            | Masc_tui_types.Runtime_choice runtime ->
            let destination =
              match picker.rlp_pick, runtime.ro_exact_slot_group with
              | Masc_tui_types.Pick_exact_lane_replacement _, Tui_decode.Exact_http_slots -> "HTTP replacement"
              | Masc_tui_types.Pick_exact_lane_replacement _, Tui_decode.Exact_cli_slots -> "CLI replacement"
              | (Pick_conversation_lane _, Tui_decode.Exact_http_slots)
              | (Pick_exact_lane _, Tui_decode.Exact_http_slots)
              | (Pick_new_lane _, Tui_decode.Exact_http_slots)
              | (Pick_media_failover, Tui_decode.Exact_http_slots)
              | (Pick_route_default, Tui_decode.Exact_http_slots) -> "HTTP tail"
              | (Pick_conversation_lane _, Tui_decode.Exact_cli_slots)
              | (Pick_exact_lane _, Tui_decode.Exact_cli_slots)
              | (Pick_new_lane _, Tui_decode.Exact_cli_slots)
              | (Pick_media_failover, Tui_decode.Exact_cli_slots)
              | (Pick_route_default, Tui_decode.Exact_cli_slots) -> "CLI tail"
              | (Pick_conversation_lane _, Tui_decode.Exact_output_unsupported)
              | (Pick_exact_lane _, Tui_decode.Exact_output_unsupported)
              | (Pick_exact_lane_replacement (_, _, _), Tui_decode.Exact_output_unsupported)
              | (Pick_new_lane _, Tui_decode.Exact_output_unsupported)
              | (Pick_media_failover, Tui_decode.Exact_output_unsupported)
              | (Pick_route_default, Tui_decode.Exact_output_unsupported) -> "no output schema"
            in
            let line bracket note =
              Printf.sprintf "  %s [%s] %s%s"
                (if picker.Masc_tui_types.rlp_selected_row = Some offset
                 then ">" else " ")
                bracket
                (Masc_tui_types.runtime_model_picker_title runtime)
                note
            in
            (match
              Masc_tui_types.runtime_pick_availability
                picker.Masc_tui_types.rlp_pick runtime
            with
            | Masc_tui_types.Pick_refused refusal ->
              (* The bracket carries the refusal: a note after the model
                 is the first thing the frame cuts. *)
              box_line_styled buf cols ~style:(Theme.recede ())
                (line (Masc_tui_types.runtime_pick_refusal_tag refusal) "")
            | Masc_tui_types.Pick_available ->
              (if picker.rlp_selected_row = Some offset
               then box_line_selected buf cols
               else box_line buf cols)
                (line destination
                   (if List.mem runtime.ro_id picker.rlp_already
                    then "  (already declared)" else "")));
            let prefix = "      Quota scope " in
            let suffix = " · " ^ format_context_tokens runtime.ro_effective_max_context ^ " context" in
            let scope_width =
              max 1 (framed_inner_width cols - Message_layout.display_width (prefix ^ suffix)) in
            box_line_styled buf cols ~style:(Theme.recede ())
              (prefix ^ Masc_tui_message_layout.truncate_middle scope_width
                 (Terminal_text.single_line (runtime_quota_scope_label runtime)) ^ suffix));
     (match picker.rlp_selected_row with
      | Some offset ->
        (match List.nth_opt picker.rlp_choices offset with
         | Some (Masc_tui_types.Runtime_choice runtime) ->
           box_line_styled buf cols ~style:(Theme.recede ())
             ("  " ^ Masc_tui_message_layout.truncate_middle (max 1 (framed_inner_width cols - 2))
                (Terminal_text.single_line ("Connection " ^ runtime.ro_provider_id ^ " · Selected " ^ runtime.ro_id)))
         | Some (Masc_tui_types.Lane_choice _) | None -> ())
      | None -> ());
     box_line_styled buf cols ~style:(Theme.info ())
       ("  " ^ Masc_tui_types.runtime_picker_keys (snd action) picker.rlp_filter)
   | None ->
     let catalog = match state.runtime_catalog_reading with
       | Runtime_catalog_read | Runtime_catalog_refreshing _ | Runtime_catalog_stale _ -> state.runtime_catalog
       | Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_failed _ -> [] in
     (match state.runtime_catalog_reading with
      | Runtime_catalog_read -> ()
      | Runtime_catalog_refreshing _ | Runtime_catalog_stale _ ->
          box_line_styled buf cols ~style:(Theme.warn ())
            ("  " ^ Terminal_text.single_line (Masc_tui_types.runtime_catalog_reading_suffix state.runtime_catalog_reading))
      | Runtime_catalog_unread ->
          box_line_styled buf cols ~style:(Theme.recede ()) "  runtime catalogue unread · showing slot IDs"
      | Runtime_catalog_loading ->
          box_line_styled buf cols ~style:(Theme.recede ()) "  runtime catalogue loading · showing slot IDs"
      | Runtime_catalog_failed detail ->
          box_line_styled buf cols ~style:(Theme.warn ())
            ("  runtime catalogue read failed: " ^ Terminal_text.single_line detail ^ " · showing slot IDs"));
     (* Reserve a key line and the frame bottom; at least the selected row
        stays visible on a short terminal. The ordinal places the moving
        window in the complete declaration. *)
     let visible =
       let reserved = if entries <> [] && Option.is_none selected_index then 8 else 7 in
       max 1 (min (List.length display_rows) (rows - count_frame_lines buf - reserved))
     in
     let selected_display_index =
       display_rows
       |> List.find_mapi (fun display_index (index, _) ->
            if index <> None && index = selected_index
            then Some display_index
            else None)
       |> Option.value ~default:0
     in
     let first =
       min (max 0 (List.length display_rows - visible))
         (max 0 (selected_display_index - (visible / 2)))
     in
     if entries = [] then
       box_line_styled buf cols ~style:(Theme.recede ())
         "  no provider slots declared; a adds one"
     else
       display_rows
       |> List.iteri (fun display_index (index, label) ->
            if display_index >= first && display_index < first + visible then (
              match index with
              | None -> box_line_styled buf cols ~style:(Theme.info ()) label
              | Some index ->
              let row = List.nth entries index in
              let kind =
                match row.Masc_tui_types.sr_kind with
                | Masc_tui_types.Catalog_slot -> "HTTP"
                | Masc_tui_types.Official_client_slot -> "CLI"
                | Masc_tui_types.Media_route_slot -> "ROUTE"
              in
              let line =
                Printf.sprintf "  %s %d/%d  [%s] %s%s"
                  (if Some index = selected_index then ">" else " ")
                  (index + 1) count kind
                  (match List.find_opt (fun (runtime : Tui_decode.runtime_option) ->
                     String.equal runtime.ro_id row.Masc_tui_types.sr_slot) catalog with
                   | Some runtime -> Masc_tui_types.runtime_model_picker_title runtime
                   | None -> Terminal_text.single_line row.Masc_tui_types.sr_slot)
                  (if row.Masc_tui_types.sr_admitted then ""
                   else "  (not admitted)")
              in
              if Some index = selected_index
              then box_line_selected buf cols line
              else box_line buf cols line));
     if entries <> [] && Option.is_none (selected_index) then
       box_line_styled buf cols ~style:(Theme.warn ())
         "  no slot selected; j/k selects a current slot";
     (match Masc_tui_types.slot_editor_cursor_row state with
      | None -> ()
      | Some row ->
        let selected_runtime = List.find_opt (fun (runtime : Tui_decode.runtime_option) ->
           String.equal runtime.ro_id row.Masc_tui_types.sr_slot) catalog in
        let identity = Terminal_text.single_line
          ((match selected_runtime with
            | Some runtime -> "Connection " ^ runtime.ro_provider_id ^ " · "
            | None -> "") ^ "Selected " ^ row.sr_slot) in
        (match selected_runtime with
         | Some runtime ->
           let prefix = "  Quota scope " in
           let suffix = " · " ^ format_context_tokens runtime.ro_effective_max_context ^ " context" in
           let scope_width =
             max 1 (framed_inner_width cols - Message_layout.display_width (prefix ^ suffix)) in
           box_line_styled buf cols ~style:(Theme.info ())
             (prefix ^ Masc_tui_message_layout.truncate_middle scope_width
                (Terminal_text.single_line (runtime_quota_scope_label runtime)) ^ suffix)
         | None -> box_line_styled buf cols ~style:(Theme.warn ()) "  Model details unavailable");
        box_line_styled buf cols ~style:(Theme.recede ())
          ("  " ^ Masc_tui_message_layout.truncate_middle (max 1 (framed_inner_width cols - 2)) identity));
     box_line_styled buf cols ~style:(Theme.recede ())
       "  arrows/j/k select · r replace model/effort · a add fallback · 1 first in group";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  J/K reorder · x remove · Enter/d settings · e TOML · Esc back";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  Changes save immediately; file and application results are shown separately");
  for _ = 1 to max 0 (rows - count_frame_lines buf - 2) do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

let render_lanes_overview (state : state) =
  match state.slot_editor with
  | Some ({ Masc_tui_types.se_target = Masc_tui_types.Exact_lane_slots _; _ } as editor) ->
    render_exact_lane_provider_editor state editor
  | None | Some { Masc_tui_types.se_target = Masc_tui_types.Media_failover_slots; _ } ->
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let inner = max 1 (framed_inner_width cols) in
  let buf = Buffer.create 4096 in
  let korean = state.ui_language = Lang_ko in
  let projection = Masc_tui_types.lanes_overview_projection state ~rows ~cols in
  let header =
    let readings = match state.lane_inventory with
      | None -> [String.trim (title_missing_reading ~error:state.standalone_lanes_error)]
      | Some _ -> [] in
    here_row ~cols state ~path:[] ~readings ~position:None
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  projection.lop_links
  |> List.iter (fun links ->
       let line = links |> List.map (fun (target, label) ->
         match target with
         | Some surface -> pressable (Press_surface surface) label
         | None -> label) |> String.concat " · " in
       box_line_styled buf cols ~style:(Theme.info ()) line);
  let observed_heading = match state.lane_inventory with
    | None -> ui_text state ~ko:"기능 상태 미관측 · r:조회" ~en:"Feature states not observed · r:read"
    | Some snapshot ->
        let observed = Unix.localtime snapshot.Masc.Tui_decode_lane_inventory.observed_at in
        let standings = Masc_tui_lane_standing.count_items ~korean
            (List.map (Masc_tui_lane_inventory.row_standing_in snapshot) snapshot.rows) in
        Message_layout.join_fitting ~sep:" · " ~cells:inner
          ((match state.standalone_lanes_error with
            | None -> ui_text state ~ko:"기능 목록 관측" ~en:"Feature inventory observed"
            | Some _ -> ui_text state ~ko:"보존한 기능 목록 관측" ~en:"Retained inventory observation")
           :: Printf.sprintf "%02d:%02d:%02d"
                observed.Unix.tm_hour observed.Unix.tm_min observed.Unix.tm_sec
           :: standings) in
  if projection.lop_observation then
    box_line_styled buf cols ~style:(Theme.recede ()) observed_heading;
  List.iter (fun notice -> box_line_styled buf cols ~style:(Theme.warn ()) ("  " ^ notice))
    projection.lop_notices;
  let inventory = lane_inventory_rows state in
  let entries = lane_inventory_entries state in
  let split = projection.lop_split in
  let list_width = projection.lop_list_width in
  let detail_width = projection.lop_detail_width in
  let panel_padding = if projection.lop_boxed then 4 else 0 in
  let list_cells = max 1 (list_width - panel_padding) in
  let layout = projection.lop_scroll in
  let height = projection.lop_list_height in
  let selected_position = lane_inventory_visual_cursor state in
  let scroll = Masc_tui_scroll.normalize ~count:layout.sc_count ~height state.lanes_scroll in
  let scroll = match selected_position with
    | None -> scroll
    | Some cursor ->
        Masc_tui_scroll.ensure_visible_with_lead ~cursor
          ~lead:(lane_inventory_lead state) ~height scroll in
  let standing row = match state.lane_inventory with
    | Some snapshot -> Masc_tui_lane_inventory.row_standing_in snapshot row
    | None -> Masc_tui_lane_inventory.row_standing row in
  let summary row = Masc_tui_lane_standing.word ~korean (standing row) in
  let status_width = List.fold_left (fun width row -> max width
      (Message_layout.display_width (summary row))) 0 inventory
    |> fun width -> min width (max 1 (list_cells / 3)) in
  let label_width = max 1 (list_cells - status_width - 4) in
  let window = Rows.of_list ~first:scroll ~height entries in
  let listing = List.init height (fun offset ->
    let index = scroll + offset in
    match Rows.at window index with
    | None when offset = 0 && Option.is_none state.lane_inventory ->
        Theme.recede () ^ ui_text state ~ko:"기능 목록 미관측 · r:조회" ~en:"Inventory not observed · r:read" ^ Ansi.reset
    | None -> ""
    | Some (Masc_tui_lane_inventory.Category_header category) ->
        Theme.info () ^ Masc_tui_lane_inventory.category_label category ^ Ansi.reset
    | Some (Masc_tui_lane_inventory.Lane_row row) ->
        let observed = standing row in
        let label =
          (if not projection.lop_observation && Option.is_some state.standalone_lanes_error
           then ui_text state ~ko:"보존 · " ~en:"Retained · " else "")
          ^ Terminal_text.single_line row.label ^ " · " ^ Terminal_text.single_line row.purpose in
        let plain = fit_width (Masc_tui_lane_standing.mark observed) 2
          ^ fit_width label label_width ^ "  " ^ fit_width (summary row) status_width in
        let marked text = pressable (Press_lane_row (Masc_tui_lane_inventory.identity row))
            (fit_width text list_cells) in
        if selected_position = Some index then Theme.selection ^ marked plain ^ Ansi.reset
        else
          let recede = if Masc_tui_lane_standing.recedes observed then Theme.recede () else "" in
          marked (Masc_tui_lane_standing.colour observed
            ^ fit_width (Masc_tui_lane_standing.mark observed) 2 ^ Ansi.reset
            ^ recede ^ fit_width label label_width ^ "  " ^ Ansi.reset
            ^ Masc_tui_lane_standing.colour observed ^ fit_width (summary row) status_width ^ Ansi.reset)) in
  let position = if projection.lop_position
    then Masc_tui_scroll.position_row ~scroll ~height (List.length entries) else None in
  let listing = listing @ Option.to_list position in
  let listing = if projection.lop_boxed then
      studio_panel ~width:list_width
        ~title:(ui_text state ~ko:"기능" ~en:"Features")
        ~lines:listing
    else listing in
  let detail_height = projection.lop_detail_height in
  let detail = match selected_inventory_lane state with
    | None -> [Theme.recede (), ui_text state ~ko:"목록에서 기능을 선택하세요." ~en:"Select a capability in the list."]
    | Some row ->
        (match selected_standalone_lane state with
         | Some lane -> standalone_lane_summary_lines state ~width:(max 1 (detail_width - panel_padding))
             ~standing:(standing row) lane
         | None -> inventory_row_summary_lines state ~width:(max 1 (detail_width - panel_padding))
             ~standing:(standing row)
             ~selected_output:(Masc_tui_types.lanes_exact_output_name state row) row) in
  let visible_detail =
    if List.length detail <= detail_height then detail else
      take_rows (max 0 (detail_height - 1)) [] detail
      @ (if detail_height > 0 then [Theme.info (), ui_text state ~ko:"… d: 전체 관측·설정 근거" ~en:"… d: full observation and configuration evidence"] else []) in
  let detail = List.map (fun (style, line) -> style ^ line ^ Ansi.reset) visible_detail in
  let detail = if projection.lop_boxed then
      studio_panel ~width:detail_width
        ~title:(ui_text state ~ko:"선택한 기능" ~en:"Selected feature")
        ~lines:detail
    else detail in
  if split then begin
    let pane_height = max (List.length listing) (List.length detail) in
    let left = Rows.of_list ~first:0 ~height:pane_height listing in
    let right = Rows.of_list ~first:0 ~height:pane_height detail in
    for i = 0 to pane_height - 1 do
      box_line buf cols (fit_width (Option.value (Rows.at left i) ~default:"") list_width
        ^ "  " ^ Option.value (Rows.at right i) ~default:"")
    done
  end else begin
    List.iter (box_line buf cols) listing;
    if detail_height > 0 then List.iter (box_line buf cols) detail
  end;
  (match projection.lop_tail with
   | Some lines -> List.iter (box_line_styled buf cols ~style:(Theme.warn ())) lines
   | None ->
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
       box_lines_styled buf cols ~style:(Theme.warn ())
         (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail));
  (* The lane editor's notice is the Runtime view's too: a standalone lane's
     slots are written from here, and a write started on either view can
     still be out when the other is opened. *)
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
       (* The refusal can be the server's own multi-line sentence, which wraps
          to more rows than the frame has left. Bound it to what remains after
          the picker and the footer, keeping the "lane write refused" head and
          the actionable tail. *)
       let picker_rows =
         match Masc_tui_types.runtime_picker_projection state with
         | None -> 0
         | Some picker -> 1 + max 1 (2 * List.length picker.rlp_choices)
       in
       let budget = max 1 (rows - count_frame_lines buf - picker_rows - 4) in
       box_lines_styled_bounded buf cols ~style:(runtime_lane_notice_style notice) ~budget
         (Keeper_chat.terminal_safe_text ~preserve_newlines:true
                   (Masc_tui_types.runtime_lane_notice_text notice)));
  List.iter
    (fun line ->
       box_line_styled buf cols ~style:(Theme.warn ())
         ("  " ^ Keeper_chat.terminal_safe_text line))
    (Masc_tui_types.runtime_lane_stale_lines state);
  (* The runtime-candidate picker the "a" key opens. Same projection the
     Runtime surface draws; the row order both render and the key handler
     read is the picker's own, so the cursor and the drawing cannot drift. *)
  (match Masc_tui_types.runtime_picker_projection state with
   | None -> ()
   | Some picker ->
       box_line_styled buf cols ~style:(Theme.info ())
         (Printf.sprintf
            "  adding a candidate to the candidate order of %s — %s — %s"
            (Terminal_text.single_line picker.Masc_tui_types.rlp_lane)
            picker.Masc_tui_types.rlp_summary
            (Masc_tui_types.runtime_picker_keys "Enter append"
               picker.Masc_tui_types.rlp_filter));
       if picker.Masc_tui_types.rlp_choices = [] then
         box_line_styled buf cols ~style:(Theme.recede ())
           (Masc_tui_types.runtime_picker_empty_note picker)
       else
         List.iteri
           (fun offset choice ->
              match choice with
              | Masc_tui_types.Lane_choice _ -> ()
              | Masc_tui_types.Runtime_choice runtime ->
              (* A refusal leads the row, as in the provider editor: a note
                 after the label is the first thing the frame cuts. *)
              let refusal_prefix, note =
                match
                  Masc_tui_types.runtime_pick_availability
                    picker.Masc_tui_types.rlp_pick runtime
                with
                | Masc_tui_types.Pick_refused refusal ->
                  ( Ansi.dim ^ "[" ^ Masc_tui_types.runtime_pick_refusal_tag refusal
                    ^ "] " ^ Ansi.reset
                  , "" )
                | Masc_tui_types.Pick_available ->
                  ( ""
                  , if List.exists (String.equal runtime.ro_id) picker.rlp_already
                    then "  (already a slot)"
                    else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
                    then "  (same provider as a current slot)"
                    else "" )
              in
              let mark =
                if picker.Masc_tui_types.rlp_selected_row = Some offset then ">" else " "
              in
              let ctx =
                Printf.sprintf " [%s context]"
                  (format_context_tokens runtime.ro_effective_max_context)
              in
              let def = if runtime.ro_is_default then " [default]" else "" in
              box_line buf cols
                (Printf.sprintf "  %s %s%s%s%s%s"
                   mark refusal_prefix
                   (Masc_tui_types.runtime_model_picker_title runtime)
                   ctx def
                   (Ansi.dim ^ note ^ Ansi.reset));
              box_line_styled buf cols ~style:(Theme.recede ())
                ("      Quota scope " ^ Terminal_text.single_line (runtime_quota_scope_label runtime)
                  ^ " · Connection " ^ Terminal_text.single_line runtime.ro_provider_id
                  ^ " · " ^ Terminal_text.single_line runtime.ro_id))
           picker.Masc_tui_types.rlp_choices));
  let used_rows = count_frame_lines buf in
  for _ = 1 to max 0 (rows - used_rows - 2) do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

(* How a standalone-lane run stands, as the reader sorts it before reading the
   word: it went well, it is going, it waits, it was called off, or it broke
   or was turned down. One mark and one colour per standing, so the status
   column is scanned by shape and the only red in it is a run that asks to be
   read (RFC tui-one-screen-grammar, section 7.2). A label the producer adds
   later decodes to [Lane_run_other] and reads muted, behind the unnamed
   mark, until it is named here. *)
type lane_run_standing =
  | Run_done
  | Run_active
  | Run_waiting
  | Run_stopped
  | Run_failed
  | Run_unnamed

let lane_run_standing = function
  | Tui_decode.Lane_run_succeeded
  | Tui_decode.Lane_run_approved
  | Tui_decode.Lane_run_reviewed
  | Tui_decode.Lane_run_committed -> Run_done
  | Tui_decode.Lane_run_running -> Run_active
  | Tui_decode.Lane_run_deferred -> Run_waiting
  | Tui_decode.Lane_run_cancelled
  | Tui_decode.Lane_run_superseded
  | Tui_decode.Lane_run_review_cancelled -> Run_stopped
  | Tui_decode.Lane_run_failed
  | Tui_decode.Lane_run_rejected
  | Tui_decode.Lane_run_completion_persistence_failed
  | Tui_decode.Lane_run_completion_durability_unknown
  | Tui_decode.Lane_run_infrastructure_unavailable
  | Tui_decode.Lane_run_not_reviewed
  | Tui_decode.Lane_run_commit_failed
  | Tui_decode.Lane_run_raised -> Run_failed
  | Tui_decode.Lane_run_other _ -> Run_unnamed

(* The two ways a run stops short, told apart because a failure asks to be
   read and a run called off does not: a heavy cross, and a pause bar. The
   last is a status this build has no name for. *)
let lane_run_failed_mark = "\xe2\x9c\x95"
let lane_run_stopped_mark = "\xe2\x80\x96"
let lane_run_unnamed_mark = "?"

let lane_run_standing_mark = function
  | Run_done -> Masc_tui_theme.Glyph.progress_done
  | Run_active -> Masc_tui_theme.Glyph.progress_active
  | Run_waiting -> Masc_tui_theme.Glyph.progress_waiting
  | Run_stopped -> lane_run_stopped_mark
  | Run_failed -> lane_run_failed_mark
  | Run_unnamed -> lane_run_unnamed_mark

let lane_run_standing_style = function
  | Run_done -> Theme.ok ()
  | Run_active -> Theme.info ()
  | Run_failed -> Theme.bad ()
  | Run_waiting | Run_stopped | Run_unnamed -> Theme.muted ()

let lane_run_status_style status =
  lane_run_standing_style (lane_run_standing status)

(* The status in the language the screen is drawn in. The wire spelling
   ([completion_durability_unknown]) was drawn as it arrived, in a column too
   narrow for it. A status the decoder kept as [Lane_run_other] has no word
   here, so its own spelling is drawn behind the unnamed mark. *)
let lane_run_status_word ~language status =
  let word ko en =
    match language with
    | Lang_ko -> ko
    | Lang_en -> en
  in
  match status with
  | Tui_decode.Lane_run_running -> word "실행 중" "running"
  | Tui_decode.Lane_run_succeeded -> word "성공" "succeeded"
  | Tui_decode.Lane_run_cancelled -> word "취소" "cancelled"
  | Tui_decode.Lane_run_failed -> word "실패" "failed"
  | Tui_decode.Lane_run_completion_persistence_failed ->
      word "결과 저장 실패" "save failed"
  | Tui_decode.Lane_run_completion_durability_unknown ->
      word "결과 저장 불확실" "save unknown"
  | Tui_decode.Lane_run_approved -> word "승인" "approved"
  | Tui_decode.Lane_run_reviewed -> word "검토 끝" "reviewed"
  | Tui_decode.Lane_run_committed -> word "반영됨" "committed"
  | Tui_decode.Lane_run_superseded -> word "대체됨" "superseded"
  | Tui_decode.Lane_run_rejected -> word "반려" "rejected"
  | Tui_decode.Lane_run_deferred -> word "보류" "deferred"
  | Tui_decode.Lane_run_review_cancelled -> word "검토 취소" "review cancelled"
  | Tui_decode.Lane_run_infrastructure_unavailable ->
      word "인프라 장애" "infra down"
  | Tui_decode.Lane_run_not_reviewed -> word "검토 못 함" "not reviewed"
  | Tui_decode.Lane_run_commit_failed -> word "반영 실패" "commit failed"
  | Tui_decode.Lane_run_raised -> word "예외 발생" "raised"
  | Tui_decode.Lane_run_other wire -> Terminal_text.single_line wire

let lane_run_status_text ~language status =
  lane_run_standing_mark (lane_run_standing status)
  ^ " "
  ^ lane_run_status_word ~language status

let observed_lane_label (target : Lane_run_identity.t) =
  Lane_run_identity.label target

let lane_run_subject (run : Tui_decode.lane_run_summary) =
  match run.lrs_run_kind, run.lrs_subject_id with
  | Tui_decode.Lane_run_task_verification, Some subject -> "task " ^ subject
  | Tui_decode.Lane_run_goal_verification, Some subject -> "goal " ^ subject
  | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    None ->
    run.lrs_actor
;;

(** Recent retained runs of one standalone lane. The list is the paged summary:
    no payload ever crosses it, so Enter fetches one exact detail. *)
let render_lane_run_list (state : state) ~(lane : Lane_run_identity.t) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let runs =
    match state.lane_runs with
    | None -> []
    | Some runs -> runs
  in
  let shown = List.length runs in
  let text ko en = ui_text state ~ko ~en in
  (* How many rows were read and how many the server keeps is the position:
     [3/50] of a list read whole, [3/50 · of 8,347] of one read in part. The
     footer names the key for the older page while there is one. *)
  let position : Masc_tui_value.Position.t option =
    let at = state.lane_runs_cursor + 1 in
    match state.lane_runs_total with
    | _ when shown = 0 -> None
    | Some total when total > shown -> Some (Partial { at; loaded = shown; total })
    | Some _ | None -> Some (Row { at; total = shown })
  in
  let header =
    here_row ~cols state
      ~path:[ observed_lane_label lane; text "실행" "runs" ]
      ~readings:(if state.lane_runs_loading then [ text "읽는 중" "loading" ] else [])
      ~position
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let subject_kind, subject_heading =
    match lane with
    | Lane_run_identity.Verifier ->
        Render_schedule.Run_subject_id, text "대상" "Subject"
    | Lane_run_identity.Librarian
    | Lane_run_identity.Hitl_auto_judge
    | Lane_run_identity.Board_attention
    | Lane_run_identity.Workspace_curator
    | Lane_run_identity.Candle_appraiser ->
        Render_schedule.Run_actor_name, text "요청자" "Actor"
  in
  let run_table =
    Render_schedule.lane_run_table
      ~headers:
        { Render_schedule.lhead_started = text "시작" "Started"
        ; lhead_subject = subject_heading
        ; lhead_status = text "상태" "Status"
        ; lhead_elapsed = text "걸린 시간" "Elapsed"
        ; lhead_slot = text "슬롯" "Slot"
        }
      ~subject:subject_kind
      ~subjects:
        (List.map
           (fun run -> Terminal_text.single_line (lane_run_subject run))
           runs)
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  (* One reading of the clock for the whole list, so two rows of one frame
     cannot disagree about which day today is. *)
  let now = Unix.gettimeofday () in
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Render_schedule.lane_run_header_row run_table);
  box_divider buf cols;
  (match state.lane_runs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let layout = lanes_scrolled state ~cols in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.lane_runs_scroll max_scroll) in
  let runs_window = Rows.of_list ~first:scroll ~height:content_height runs in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.lane_runs ~error:state.lane_runs_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note_while ~reading:state.lane_runs_loading
      | Page_empty ->
          text "  (보관된 실행이 없음)" "  (no retained runs for this lane)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      match Rows.at runs_window (index + scroll) with
      | None -> box_empty buf cols
      | Some (run : Tui_decode.lane_run_summary) ->
          let line =
            "  "
            ^ Render_schedule.lane_run_row run_table ~now
                ~status_style:(lane_run_status_style run.lrs_status)
                { Render_schedule.lrow_started = run.lrs_started_at
                ; lrow_subject =
                    Terminal_text.single_line (lane_run_subject run)
                ; lrow_status =
                    lane_run_status_text ~language:state.ui_language
                      run.lrs_status
                ; lrow_elapsed = run.lrs_elapsed_s
                ; lrow_slot =
                    Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
                      run.lrs_selected_slot
                }
          in
          if index + scroll = state.lane_runs_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf
         (if state.ui_language = Lang_ko then "  [실행 %s]" else "  [runs %s]")
         (Masc_tui_scroll.window_text ~scroll ~height:content_height shown));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints_lanes_run_list ~lang:state.ui_language
            ~has_runs:(shown > 0)
            ~has_older:
              (Option.is_some state.lane_runs_next && not state.lane_runs_loading)));
  finish_surface state ~surface_key:"lane-runs" ~rows:terminal_rows ~cols buf

(* The total preview includes labels, fences and notices. Complete payloads
   that fit stay complete; oversized fields share the space left after each
   field's minimum preview. If even those minima do not fit, preserve the
   original prefix and name the omitted suffix count. Stored bytes do not change. *)
let lane_run_preview_source_max_bytes = 65536

type lane_run_prepared_document =
  { full_text : string
  ; document : string
  ; notice : string
  }

type lane_run_prepared_field =
  { index : int
  ; heading : string
  ; heading_bytes : int
  ; prepared : lane_run_prepared_document
  ; minimum_bytes : int
  ; full_bytes : int
  }

let json_preview_lines ~width text =
  document_json ~width text |> List.map (fun line -> Ansi.reset, line)

let lane_run_payload_lines ~width json =
  let fence = fenced_document_text ~language:"json" in
  let prepare_document value =
    let full_text = Yojson.Safe.pretty_to_string value in
    let document = fence full_text in
    let notice = Printf.sprintf "… truncated, total %d bytes" (String.length full_text) in
    { full_text; document; notice }
  in
  let minimum_document_bytes prepared =
    min (String.length prepared.document)
      (String.length prepared.document - String.length prepared.full_text
       + String.length prepared.notice + 1)
  in
  (* Field allocation reserves the minimum above; non-object payloads receive
     the full preview budget. Both callers therefore leave a non-negative room. *)
  let render_document ~budget prepared =
    let text, notices =
      if String.length prepared.document <= budget then prepared.full_text, []
      else
        let wrapper_bytes = String.length prepared.document - String.length prepared.full_text in
        let room = budget - wrapper_bytes - String.length prepared.notice - 1 in
        let cut =
          match String.rindex_from_opt prepared.full_text room '\n' with
          | Some newline -> newline
          | None -> String_util.utf8_char_boundary prepared.full_text room
        in
        String.sub prepared.full_text 0 cut, [ Theme.warn (), prepared.notice ]
    in
    json_preview_lines ~width text @ notices
  in
  match json with
  | `Assoc (_ :: _ as fields) ->
    let omitted count = Printf.sprintf "… %d more field(s) not rendered" count in
    let fields =
      List.mapi
        (fun index (name, value) ->
          let heading_source = Yojson.Safe.to_string (`String name) in
          (* The preview budget counts source bytes, before visible escapes. *)
          let heading_bytes = String.length heading_source + 1 in
          let heading = Masc.Tui_terminal_json.sanitize_canonical_preview heading_source in
          let prepared = prepare_document value in
          { index; heading; heading_bytes; prepared
          ; minimum_bytes = heading_bytes + minimum_document_bytes prepared
          ; full_bytes = heading_bytes + String.length prepared.document })
        fields
    in
    let render_field budget field =
      (Ansi.bold, field.heading)
      :: render_document ~budget:(budget - field.heading_bytes) field.prepared
    in
    let total = List.fold_left (fun n field -> n + field.full_bytes) 0 fields in
    if total <= lane_run_preview_source_max_bytes then
      List.concat_map (fun field -> render_field field.full_bytes field) fields
    else begin
      let minimum_total fields =
        List.fold_left (fun n field -> n + field.minimum_bytes) 0 fields
      in
      let notice_bytes = function None -> 0 | Some text -> String.length text + 1 in
      let fields, suffix_notice =
        if minimum_total fields <= lane_run_preview_source_max_bytes then fields, None
        else
          let rec prefix used remaining notice acc = function
            | [] -> List.rev acc, None
            | field :: rest ->
              let next_notice =
                if List.is_empty rest then None else Some (omitted (remaining - 1))
              in
              if used + field.minimum_bytes + notice_bytes next_notice <= lane_run_preview_source_max_bytes then
                prefix (used + field.minimum_bytes) (remaining - 1) next_notice (field :: acc) rest
              else List.rev acc, notice
          in
          let count = List.length fields in
          prefix 0 count (Some (omitted count)) [] fields
      in
      let needed field = field.full_bytes - field.minimum_bytes in
      let ranked = List.stable_sort (fun a b -> Int.compare (needed a) (needed b)) fields in
      let rec allocate extra remaining = function
        | [] -> []
        | field :: rest ->
          let added = min (needed field) (extra / remaining) in
          (field, field.minimum_bytes + added) :: allocate (extra - added) (remaining - 1) rest
      in
      let extra = lane_run_preview_source_max_bytes - notice_bytes suffix_notice - minimum_total fields in
      let allocated =
        allocate extra (List.length fields) ranked
        |> List.sort (fun (a, _) (b, _) -> Int.compare a.index b.index)
      in
      let lines = List.concat_map (fun (field, budget) -> render_field budget field) allocated in
      match suffix_notice with None -> lines | Some text -> lines @ [ Theme.warn (), text ]
    end
  | _ ->
    render_document ~budget:lane_run_preview_source_max_bytes (prepare_document json)

let lane_run_decision_badge (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_decision with
  | Tui_decode.Lane_run_decision_approved -> Theme.ok (), "APPROVED"
  | Tui_decode.Lane_run_decision_rejected -> Theme.warn (), "REJECTED"
  | Tui_decode.Lane_run_decision_reviewed -> Theme.ok (), "REVIEWED"
  | Tui_decode.Lane_run_decision_committed -> Theme.ok (), "COMMITTED"
  | Tui_decode.Lane_run_decision_superseded -> Theme.info (), "SUPERSEDED"
  | Tui_decode.Lane_run_decision_pending -> Theme.info (), "NO DECISION YET"
  | Tui_decode.Lane_run_decision_not_reached -> Theme.warn (), "NO DECISION"
  | Tui_decode.Lane_run_not_a_decision -> Theme.info (), "NOT A VERDICT"
  | Tui_decode.Lane_run_decision_unknown -> Theme.muted (), "UNKNOWN"

let lane_run_tool_disposition_presentation = function
  | Tui_decode.Lane_run_tool_completed -> Theme.ok (), "✓"
  | Tui_decode.Lane_run_tool_deferred -> Theme.warn (), "△"
  | Tui_decode.Lane_run_tool_failed -> Theme.bad (), "✗"
  | Tui_decode.Lane_run_tool_disposition_other _ -> Theme.warn (), "?"

let lane_run_tool_call_summary (tool : Tui_decode.lane_run_tool) =
  let style, mark =
    lane_run_tool_disposition_presentation tool.lrt_disposition
  in
  let disposition =
    Tui_decode.lane_run_tool_disposition_label tool.lrt_disposition
    |> Terminal_text.single_line
  in
  Printf.sprintf "%s%s%s %s%s%s ‹%s · %.0fms›%s"
    style Ansi.bold mark
    (Terminal_text.single_line tool.lrt_name)
    Ansi.reset style disposition tool.lrt_duration_ms Ansi.reset

type lane_run_tool_counts =
  { completed : int
  ; deferred : int
  ; failed : int
  ; other : int
  }

let lane_run_tool_count_summary tools =
  let counts =
    List.fold_left
      (fun counts (tool : Tui_decode.lane_run_tool) ->
         match tool.lrt_disposition with
         | Tui_decode.Lane_run_tool_completed ->
           { counts with completed = counts.completed + 1 }
         | Tui_decode.Lane_run_tool_deferred ->
           { counts with deferred = counts.deferred + 1 }
         | Tui_decode.Lane_run_tool_failed ->
           { counts with failed = counts.failed + 1 }
         | Tui_decode.Lane_run_tool_disposition_other _ ->
           { counts with other = counts.other + 1 })
      { completed = 0; deferred = 0; failed = 0; other = 0 }
      tools
  in
  [ Theme.bad (), "✗", counts.failed, "failed"
  ; Theme.warn (), "△", counts.deferred, "deferred"
  ; Theme.warn (), "?", counts.other, "other"
  ; Theme.ok (), "✓", counts.completed, "completed"
  ]
  |> List.filter_map (fun (style, mark, count, label) ->
    if count = 0 then None
    else
      Some
        (Printf.sprintf "%s%s%s %s %s %d %s" style Ansi.reverse Ansi.bold mark
           (String.uppercase_ascii label) count Ansi.reset))
  |> String.concat " "

let lane_run_tool_summary = function
  | Tui_decode.Lane_run_no_tools_by_contract ->
    Theme.muted (), "TOOLS  none · exact-output runs do not use the MASC tool loop"
  | Tui_decode.Lane_run_tools_pending ->
    Theme.info (), "TOOLS  pending · the verifier run is still in progress"
  | Tui_decode.Lane_run_tools_contract_unknown ->
    Theme.muted (), "TOOLS  unknown · this run kind has no typed tool contract"
  | Tui_decode.Lane_run_tools_observed tools ->
    let calls = List.length tools in
    let counts = lane_run_tool_count_summary tools in
    let names =
      List.map lane_run_tool_call_summary tools
      |> String.concat "  │  "
    in
    let evidence =
      [ names ]
      |> List.filter (fun value -> not (String.equal value ""))
      |> String.concat "  ·  "
    in
    let call_count =
      Printf.sprintf "%d %s" calls (if calls = 1 then "CALL" else "CALLS")
    in
    let overview =
      if String.equal counts "" then call_count else counts ^ "  ──  " ^ call_count
    in
    (* fit_width clips the right edge, so put the worst typed disposition
       immediately after the label. Even an ultra-narrow terminal retains the
       operator-significant failure/deferred badge before call metadata. *)
    ( Ansi.reset
    , Printf.sprintf "%sTOOLS%s %s%s" Ansi.bold Ansi.reset overview
        (if String.equal evidence "" then "" else "  │  " ^ evidence) )

let lane_run_skill_summary = function
  | Tui_decode.Lane_run_no_skills_by_contract ->
    Theme.muted (),
    "SKILLS  none · these runs do not load Keeper Skill instructions"
  | Tui_decode.Lane_run_skills_contract_unknown ->
    Theme.muted (), "SKILLS  unknown · this run kind has no typed Skill contract"

let lane_run_gate_judgment_summary = function
  | Tui_decode.Lane_run_not_gate_judgment -> None
  | Tui_decode.Lane_run_gate_judgment_pending ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %spending%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.info ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_judgment_unavailable ->
    Some (Theme.warn (), "JUDGMENT  원문 사용 불가 · 판정 여부를 확인할 수 없습니다")
  | Tui_decode.Lane_run_gate_judgment_not_reached ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %snone%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.warn ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_advisory judgment ->
    let style =
      match judgment with
      | Keeper_approval_queue_rules_types.Approve -> Theme.ok ()
      | Keeper_approval_queue_rules_types.Deny -> Theme.warn ()
      | Keeper_approval_queue_rules_types.Require_human -> Theme.info ()
    in
    let label =
      Keeper_approval_queue_rules_types.advisory_judgment_to_string judgment
      |> String.uppercase_ascii
    in
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %sADVISORY %s%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset style label Ansi.reset )

let lane_run_summary_lines ~cols ~language ~now
    (detail : Tui_decode.lane_run_detail) =
  let subject =
    match detail.lrd_run_kind, detail.lrd_subject_id with
    | Tui_decode.Lane_run_task_verification, Some subject ->
      "  ·  TASK " ^ Terminal_text.single_line subject
    | Tui_decode.Lane_run_goal_verification, Some subject ->
      "  ·  GOAL " ^ Terminal_text.single_line subject
    | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
    | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
      None ->
      ""
  in
  let elapsed =
    match detail.lrd_elapsed_s with
    | None -> ""
    | Some seconds -> (
        match Message_layout.elapsed_text seconds with
        | Some text -> Printf.sprintf "  ·  %s" text
        | None -> "")
  in
  let answer_row =
    match detail.lrd_answer_source, detail.lrd_selected_slot with
    | Some (Tui_decode.Lane_run_answer_exact_attempt slot), _ ->
      Ansi.reset, "응답: EXACT · " ^ Terminal_text.single_line slot
    | Some (Tui_decode.Lane_run_answer_cli_slot slot), _ ->
      Ansi.reset, "응답: CLI · " ^ Terminal_text.single_line slot
    | Some (Tui_decode.Lane_run_answer_vendor_system_one { model; endpoint = _ }), _ ->
      ( Theme.warn ()
      , "응답: VENDOR SYSTEM ONE · "
        ^ Terminal_text.single_line model
        ^ " · NO EXACT-FLOW RECEIPT" )
    | None, Some slot ->
      Ansi.reset, "슬롯: " ^ Terminal_text.single_line slot
    | None, None ->
      Theme.recede (), "응답: 슬롯 미배정"
  in
  let failure_rows =
    match detail.lrd_failure with
    | None -> []
    | Some failure ->
      [ ( Theme.bad ()
        , Printf.sprintf "오류: %s · %s"
            (Terminal_text.single_line failure.lrf_code)
            (Terminal_text.single_line failure.lrf_detail) ) ]
  in
  let decision_style, decision = lane_run_decision_badge detail in
  (* A run that did not end well is coloured by how it ended, the way its row
     in the list is; one that did is coloured by what it decided. *)
  let verdict_and_status_style =
    match lane_run_standing detail.lrd_status with
    | (Run_failed | Run_stopped | Run_waiting) as standing ->
        lane_run_standing_style standing
    | Run_done | Run_active | Run_unnamed ->
      (match detail.lrd_decision with
       | Tui_decode.Lane_run_not_a_decision ->
         lane_run_status_style detail.lrd_status
       | Tui_decode.Lane_run_decision_approved
       | Tui_decode.Lane_run_decision_rejected
       | Tui_decode.Lane_run_decision_reviewed
       | Tui_decode.Lane_run_decision_committed
       | Tui_decode.Lane_run_decision_superseded
       | Tui_decode.Lane_run_decision_pending
       | Tui_decode.Lane_run_decision_not_reached
       | Tui_decode.Lane_run_decision_unknown -> decision_style)
  in
  let tool_style, tools = lane_run_tool_summary detail.lrd_tool_evidence in
  let skill_style, skills = lane_run_skill_summary detail.lrd_skill_evidence in
  let contract_rows, full_width_tools =
    match detail.lrd_tool_evidence, detail.lrd_skill_evidence with
    | Tui_decode.Lane_run_no_tools_by_contract, Tui_decode.Lane_run_no_skills_by_contract ->
      [ Theme.muted (), "도구/스킬: 미사용 (Exact-output 계약)" ], []
    | Tui_decode.Lane_run_tools_observed _,
      (Tui_decode.Lane_run_no_skills_by_contract | Tui_decode.Lane_run_skills_contract_unknown) ->
      [ skill_style, skills ], [ tool_style, "  " ^ tools ]
    | (Tui_decode.Lane_run_tools_pending | Tui_decode.Lane_run_no_tools_by_contract
      | Tui_decode.Lane_run_tools_contract_unknown),
      (Tui_decode.Lane_run_no_skills_by_contract | Tui_decode.Lane_run_skills_contract_unknown) ->
      [ tool_style, tools; skill_style, skills ], []
  in
  let gate_judgment =
    match lane_run_gate_judgment_summary detail.lrd_gate_judgment with
    | None -> []
    | Some (style, line) -> [ style, "  " ^ line ]
  in
  let left_rows =
    [ ( verdict_and_status_style
      , Printf.sprintf "판정: %s  ·  실행: %s" decision
          (lane_run_status_text ~language detail.lrd_status) )
    ; ( Ansi.reset
      , Printf.sprintf "레인: %s  ·  %s%s"
          (Lane_run_identity.to_id detail.lrd_lane)
          (Terminal_text.single_line
             (Tui_decode.lane_run_kind_label detail.lrd_run_kind))
          subject )
    ]
    @ failure_rows
  in
  let right_rows =
    [ answer_row
    ; ( Ansi.dim
      , Printf.sprintf "호출: %s  ·  시작 %s%s"
          (Terminal_text.single_line detail.lrd_actor)
          (Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_second
             ~now detail.lrd_started_at)
          elapsed )
    ]
    @ contract_rows
  in
  split_summary_columns ~titled:true ~cols
    ~left_title:"판정 · 실행 상태" ~left_rows
    ~right_title:"응답 모델 · 호출 주체" ~right_rows
  @ gate_judgment
  @ full_width_tools

let lane_run_panel_titles (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_run_kind, detail.lrd_tool_evidence with
  | Tui_decode.Lane_run_exact_output, _ ->
    "INPUT · RUN INPUT", "OUTPUT · RUN RESULT"
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    Tui_decode.Lane_run_tools_observed tools ->
    ( "INPUT · VERIFICATION REQUEST"
    , Printf.sprintf "OUTPUT · VERDICT + TOOL EVIDENCE (%d %s)"
        (List.length tools)
        (if List.length tools = 1 then "CALL" else "CALLS") )
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    (Tui_decode.Lane_run_tools_pending | Tui_decode.Lane_run_no_tools_by_contract
    | Tui_decode.Lane_run_tools_contract_unknown) ->
    "INPUT · VERIFICATION REQUEST", "OUTPUT · VERDICT + TOOL EVIDENCE"
  | Tui_decode.Lane_run_kind_other _, _ -> "INPUT", "OUTPUT"

let lane_run_payload_availability_lines ~width availability payload =
  match availability with
  | Masc.Exact_lane_run_registry.Available ->
    (match payload with
     | Some value -> lane_run_payload_lines ~width value
     | None -> [ Theme.warn (), "원문 상태 불일치: 사용 가능한 원문 필드가 없습니다" ])
  | Masc.Exact_lane_run_registry.Not_loaded ->
    [ Theme.muted (), "원문을 불러오지 않았습니다" ]
  | Masc.Exact_lane_run_registry.Unavailable error ->
    let text = "원문 사용 불가: " ^ Masc.Exact_lane_run_registry.payload_read_error_to_string error in
    Message_layout.wrap_words ~max_cells:(max 1 width) (Terminal_text.single_line text)
    |> List.map (fun line -> Theme.warn (), line)

let lane_run_input_lines ~width (detail : Tui_decode.lane_run_detail) =
  lane_run_payload_availability_lines ~width detail.lrd_input_availability (Some detail.lrd_input_payload)

let lane_run_output_lines ~details ~width (detail : Tui_decode.lane_run_detail) =
  let preflight_lines = match detail.lrd_librarian_preflight with
    | None -> []
    | Some reading ->
      let decision = match reading.lp_status with
        | Tui_decode.Preflight_awaiting -> "응답 대기"
        | Tui_decode.Preflight_not_called reason -> "호출하지 않음 · " ^ reason
        | Tui_decode.Preflight_failed reason -> if details then "호출 실패 · " ^ reason else "호출 실패"
        | Tui_decode.Preflight_invalid reason -> "답변 거절 · " ^ reason
        | Tui_decode.Preflight_judged judgment ->
          Masc.Typesafeai_librarian_preflight.decision_label judgment.choice in
      let path = match reading.lp_generation_path with
        | Tui_decode.Generation_not_entered -> "생성 Lane 진입 전"
        | Tui_decode.Generation_full_lane -> "생성 Lane 진입 · 실제 요청 수는 별도 기록"
        | Tui_decode.Generation_jev_no_change -> "생성 호출 생략 · 빈 변경 검증 통과" in
      let probabilities = match reading.lp_status with
        | Tui_decode.Preflight_judged judgment ->
          [Printf.sprintf "Confidence %.3f" judgment.confidence]
          @ List.map (fun (decision, probability) ->
              Printf.sprintf "%s %.3f" (Masc.Typesafeai_librarian_preflight.decision_label decision) probability)
              judgment.reported_probabilities
        | Preflight_awaiting | Preflight_not_called _ | Preflight_failed _ | Preflight_invalid _ -> [] in
      let elapsed = match reading.lp_elapsed_s with
        | None -> [] | Some seconds -> [Printf.sprintf "JEV elapsed %.3fs" seconds] in
      let model = match reading.lp_model with None -> [] | Some model -> ["Model " ^ model] in
      let rejection = match reading.lp_domain_rejection with
        | None -> [] | Some reason -> ["검증 거절 → 생성 Lane · " ^ reason] in
      let memory = match reading.lp_memory_scope, reading.lp_memory_result with
        | Tui_decode.Memory_inference_scope, _ -> "기억 판정: 회차 메모리에만 보관 · 저장하지 않음"
        | Tui_decode.Context_only_scope, None -> "기억 snapshot: Context 전용 · 저장하지 않음"
        | Tui_decode.Memory_disposition_scope, None -> "기억 snapshot: 적용 결과가 기록되지 않음"
        | (Tui_decode.Memory_disposition_scope | Tui_decode.Context_only_scope),
          Some (Tui_decode.Librarian_memory_unchanged (revision, facts)) ->
          Printf.sprintf "기억 snapshot: 변경 없음 · revision %d · %d facts" revision facts
        | (Tui_decode.Memory_disposition_scope | Tui_decode.Context_only_scope),
          Some (Tui_decode.Librarian_memory_rewritten {revision;facts;added;removed}) ->
          Printf.sprintf "기억 snapshot: +%d / -%d · revision %d · %d facts" added removed revision facts in
      let side_writes = List.map (fun (kind, status) ->
        let label = match kind with
          | Tui_decode.Context_write -> "Context"
          | Tui_decode.Continuity_write -> "Continuity" in
        let outcome = match status with
          | Tui_decode.Side_not_attempted -> "not attempted"
          | Tui_decode.Side_answer_missing -> "answer missing"
          | Tui_decode.Side_withheld -> "withheld"
          | Tui_decode.Side_outcome_unconfirmed -> "outcome unconfirmed"
          | Tui_decode.Side_committed -> "committed"
          | Tui_decode.Side_answer_refused detail -> "answer refused · " ^ detail
          | Tui_decode.Side_failed detail -> "failed · " ^ detail in
        label ^ ": " ^ outcome) reading.lp_side_writes in
      let document = String.concat "\n"
        ([path; memory] @ side_writes @ ["JEV 판정 · " ^ decision] @ rejection
      @ (if details then model @ elapsed @ probabilities @ [""; "원문 실행 증거"]
         else ["d: 모델·확률·원문 펼치기"])) in
      let document =
        if String.length document <= lane_run_preview_source_max_bytes then document
        else
          let notice = Printf.sprintf "\n… truncated preflight, total %d bytes" (String.length document) in
          let room = lane_run_preview_source_max_bytes - String.length notice in
          let cut = String_util.utf8_char_boundary document room in
          String.sub document 0 cut ^ notice in
      String.split_on_char '\n' document
      |> List.concat_map (fun text ->
          Message_layout.wrap_words ~max_cells:(max 1 width) (Terminal_text.single_line text)
          |> List.map (fun line -> Theme.info (), line))
  in
  let fold_memory_evidence = match detail.lrd_librarian_preflight with
    | Some {lp_memory_scope=Tui_decode.Memory_disposition_scope;_} -> true
    | Some {lp_memory_scope=(Tui_decode.Context_only_scope | Tui_decode.Memory_inference_scope);_} | None -> false in
  preflight_lines @ (if not details && fold_memory_evidence then [] else
  match detail.lrd_output_availability, detail.lrd_output with
  | None, _ -> [ Theme.muted (), "실행 중 · 아직 출력이 기록되지 않았습니다" ]
  | Some availability, output ->
    lane_run_payload_availability_lines ~width availability output)

module Continuity_report = Masc.Librarian_continuity_report

type run_inspection =
  | Inspection_lane of Tui_decode.lane_run_detail
  | Inspection_measurement of string * Measurement.t

let measurement_summary_lines (report : Continuity_report.t) =
  let counts = Measurement.counts report in
  let provenance = match report.provenance with
    | Continuity_report.Synthetic -> "SYNTHETIC INPUT" in
  [ Ansi.reset, "  MEANING PRESERVATION  " ^ Terminal_text.single_line report.run_id
  ; Ansi.dim, "  " ^ provenance ^ "  ·  " ^ Terminal_text.single_line report.started_at
  ; Ansi.reset,
    Printf.sprintf "  SAMPLES  %d  ·  SCORED %d  ·  FAILED %d  ·  INCOMPLETE %d"
      (List.length report.samples) counts.scored counts.failed counts.incomplete
  ]

let measurement_text_lines ~width lines =
  List.concat_map
    (fun (style, text) ->
      String.split_on_char '\n' text
      |> List.concat_map (fun line ->
        Message_layout.wrap_words ~max_cells:(max 1 width)
          (Terminal_text.single_line line)
        |> List.map (fun line -> style, line)))
    lines

let measurement_input_lines ~width ~sha256 (measurement : Measurement.snapshot) =
  let report = measurement.report in
  let module R = Continuity_report in
  let metadata =
    [ "AUTHORITATIVE FILE  " ^ report.output_path
    ; "BLOB SHA256  " ^ sha256
    ; "Published blob is a copy; it may be collected."
    ; "INPUT  " ^ report.input_path
    ; "INPUT SHA256  " ^ report.input_sha256
    ; "CONFIG REVISION  " ^ report.config_revision
    ]
    @ (match report.binary_commit with None -> [] | Some value -> [ "BINARY COMMIT  " ^ value ])
    @ (match report.executable_sha256 with None -> [] | Some value -> [ "EXECUTABLE SHA256  " ^ value ])
    @ List.map (fun (id, sha256) ->
        "CONTEXT SHA256  " ^ id ^ "  " ^ sha256) measurement.context_hashes
  in
  measurement_text_lines ~width (List.map (fun text -> Ansi.dim, text) metadata)
  @ lane_run_payload_lines ~width
      (`List (List.map (fun (sample : R.sample) -> R.case_to_yojson sample.case) report.samples))

type measurement_output_part =
  | Measurement_text of (string * string)
  | Measurement_json of string

(* Apply the same byte ceiling as exact lane payloads before wrapping. The
   report and its full score distribution remain intact; only text is a preview. *)
let measurement_output_preview ~width ~output_path parts =
  let text = function
    | Measurement_text (_, value) | Measurement_json value -> value in
  let with_text part value = match part with
    | Measurement_text (style, _) -> Measurement_text (style, value)
    | Measurement_json _ -> Measurement_json value in
  let rec take remaining reversed = function
    | [] -> List.rev reversed, false
    | part :: rest ->
      let value = text part in
      let bytes = String.length value + 1 in
      if bytes <= remaining then take (remaining - bytes) (part :: reversed) rest
      else
        let prefix = String_util.utf8_prefix ~max_bytes:(max 0 remaining) value in
        (* The final part needs no following separator. *)
        List.rev (with_text part prefix :: reversed),
        String.length prefix < String.length value || not (List.is_empty rest)
  in
  let preview, truncated = take lane_run_preview_source_max_bytes [] parts in
  let notice =
    if truncated then
      [ Theme.warn (), Printf.sprintf
          "PREVIEW · output truncated at %d bytes; full report: %s"
          lane_run_preview_source_max_bytes output_path ]
    else []
  in
  let render = function
    | Measurement_text line -> measurement_text_lines ~width [line]
    | Measurement_json "" -> []
    | Measurement_json value -> json_preview_lines ~width value
  in
  measurement_text_lines ~width notice @ List.concat_map render preview

let measurement_output_lines ~width (report : Continuity_report.t) =
  let module R = Continuity_report in
  let prepared (request : R.generation_request) =
    List.concat_map
      (fun (wire : Llm_provider.Request_wire_observer.observation) ->
        [ "PREPARED REQUEST  " ^ wire.provider ^ "  ·  " ^ wire.model
        ; "PRE-DISPATCH SHA256  " ^ wire.body_sha256 ])
      request.prepared_requests
  in
  let generation label (value : R.generation) =
    [ label ^ "  " ^ value.response.model ^ "  ·  runtime " ^ value.request.runtime_id
    ; "RESPONSE  " ^ value.response.response_id
    ; value.response.text
    ] @ prepared value.request
  in
  let question_lines = function
    | R.Provided text -> [ "QUESTION PROVIDED"; text ]
    | R.Generated value -> generation "QUESTION GENERATED" value
  in
  (* The sample header names the failed stage. Retain the stage when the
     header scrolls away, without repeating the FAILED status. *)
  let failed_generation label (value : R.failed_generation) =
    [ label ^ " CAUSE  " ^ value.error
    ; "REQUESTED  " ^ value.request.requested_model ^ "  ·  runtime " ^ value.request.runtime_id
    ] @ prepared value.request
    @ (match value.incomplete_response with
       | None -> []
       | Some response -> [ "INCOMPLETE RESPONSE  " ^ response.model ^ "  ·  " ^ response.response_id; response.text ])
  in
  let values =
    List.filter_map (fun (sample : R.sample) -> match sample.progress with
      | R.Scored { judgment; _ } -> Some (judgment.probability, sample.case.id)
      | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _
      | R.Answer_ready _ | R.Judge_failed _ -> None) report.samples
    |> List.sort (fun (a, id_a) (b, id_b) ->
        let order = Float.compare a b in if order = 0 then String.compare id_a id_b else order)
  in
  let probabilities =
    (Ansi.bold, "RAW PROBABILITIES · NO PASS THRESHOLD")
    :: (match values with
        | [] -> [ Theme.muted (), "No scored samples" ]
        | values -> List.map (fun (probability, id) ->
            Ansi.reset, id ^ "  " ^ Yojson.Safe.to_string (`Float probability)) values)
  in
  let samples = List.concat_map (fun (sample : R.sample) ->
      let style, status, lines = match sample.progress with
        | R.Not_started -> Theme.muted (), "NOT STARTED", []
        | R.Question_failed failed -> Theme.bad (), "QUESTION FAILED", failed_generation "QUESTION" failed
        | R.Question_ready question -> Theme.info (), "INCOMPLETE · QUESTION READY", question_lines question
        | R.Answer_failed (question, failed) -> Theme.bad (), "ANSWER FAILED",
            question_lines question @ failed_generation "ANSWER" failed
        | R.Answer_ready { question; answer } -> Theme.info (), "INCOMPLETE · ANSWER READY",
            question_lines question @ generation "ANSWER" answer
        | R.Judge_failed { question; answer; failure } -> Theme.bad (), "JUDGE FAILED",
            question_lines question @ generation "ANSWER" answer
            @ [ "JUDGE REQUESTED  " ^ failure.request.model ^ "  ·  " ^ failure.request.endpoint
              ; "JUDGE CAUSE  " ^ failure.error ]
        | R.Scored { question; answer; judgment } -> Ansi.reset, "SCORED",
            question_lines question @ generation "ANSWER" answer
            @ [ "JUDGE  " ^ judgment.response_model ^ "  ·  " ^ judgment.request.endpoint
              ; "Noul  " ^ Yojson.Safe.to_string (`Float judgment.probability)
              ; "TRUE  " ^ judgment.request.true_criteria
              ; "FALSE  " ^ judgment.request.false_criteria
              ; "REQUEST SHA256  " ^ judgment.request_body_sha256 ]
      in
      [ Ansi.dim, ""; style, sample.case.id ^ "  ·  " ^ status ]
      @ List.map (fun line -> Ansi.reset, line) lines) report.samples
  in
  measurement_output_preview ~width ~output_path:report.output_path
    (List.map (fun line -> Measurement_text line) (probabilities @ samples))

module Temporal = Masc.Tui_decode_temporal_continuity

let temporal_summary_lines (report : Temporal.t) =
  let provenance = match report.provenance with
    | Temporal.Live_keeper -> "LIVE KEEPER CAPTURE"
    | Temporal.Assessment -> "ASSESSMENT OF CAPTURED EVIDENCE" in
  let status = match report.status with
    | Temporal.Recording -> "RECORDING" | Temporal.Recorded -> "RECORDED"
    | Temporal.Incomplete -> "INCOMPLETE" in
  [ Ansi.reset, "  KEEPER CONTINUITY  " ^ Terminal_text.single_line report.keeper
  ; Ansi.dim, "  " ^ provenance ^ "  ·  " ^ status
  ; Ansi.dim, "  " ^ Terminal_text.single_line report.started_at
      ^ "  ·  " ^ string_of_int (List.length report.timeline) ^ " STEPS · NO VERDICT"
  ]

let temporal_input_lines ~width ~sha256 (report : Temporal.t) =
  let optional label = function None -> [label ^ "unavailable"] | Some value -> [label ^ value] in
  let metadata =
    [ "AUTHORITATIVE REPORT  " ^ report.report_path
    ; "REPORT SHA256  " ^ report.report_sha256
    ; "VIEW BLOB SHA256  " ^ sha256
    ; "HARNESS SHA256  " ^ report.harness_source_sha256 ]
    @ optional "SOURCE CAPTURE SHA256  " report.source_capture_sha256
    @ optional "BINARY COMMIT  " report.binary_commit
    @ optional "EXECUTABLE SHA256  " report.executable_sha256
    @ (match report.memory_readiness with
       | None | Some Temporal.Memory_unavailable -> ["MEMORY READINESS  UNAVAILABLE"]
       | Some (Temporal.Memory_operations operations) ->
         ["MEMORY READINESS  " ^ String.concat "  ·  "
            (List.map (fun (tool, state) -> tool ^ " " ^ state) operations)])
    @ [ "Durable originals are retained. Omission describes prepared organic ranges."
      ; "Provider receipt and Librarian-only causal attribution remain unestablished."
      ; "Probabilities are separate observations with no pass threshold." ] in
  measurement_text_lines ~width (List.map (fun text -> Ansi.dim, text) metadata)

let temporal_output_lines ~width (report : Temporal.t) =
  let module T = Temporal in
  let natural = function None -> "unknown" | Some value -> string_of_int value in
  let detail (value : T.omission_detail) =
    ("TARGET EXCLUSIVE END  " ^ string_of_int value.target_end_atom)
    :: List.concat_map (fun (request : T.request_range) ->
      [ "REQUEST  " ^ request.capture_id ^ "  ·  W END " ^ natural request.summary_end_atom
        ^ "  ·  ORGANIC FIRST " ^ string_of_int request.first_atom
      ; "BODY SHA256  " ^ request.body_sha256 ]) value.requests in
  let steps = List.concat_map (fun (step : T.step) ->
    let kind = match step.kind with T.Message -> "MESSAGE" | T.Restart -> "LANE RESTART" | T.Await_summary -> "WAIT FOR W" in
    let status = match step.status with
      | T.Started -> "STARTED" | T.Collecting -> "COLLECTING" | T.Captured -> "CAPTURED"
      | T.Restart_observed -> "RESTART OBSERVED" | T.Summary_ready_observed -> "W READY · READINESS ONLY" in
    let identity = [step.id ^ "  ·  " ^ kind ^ "  ·  " ^ status]
      @ (match step.turn_ref with None -> [] | Some value -> ["TURN  " ^ value])
      @ (match step.operation_state with None -> [] | Some value -> ["OPERATION  " ^ value])
      @ (match step.kind with
         | T.Message -> ["W MESSAGES IN LAST REQUEST  " ^ natural step.working_state_messages]
         | T.Restart | T.Await_summary -> [])
      @ (match step.target_end_atom with None -> [] | Some value -> ["WAIT TARGET END  " ^ string_of_int value]) in
    let readiness = match step.readiness with
      | None -> []
      | Some T.Readiness_not_available -> ["SUMMARY READINESS  NOT AVAILABLE"]
      | Some (T.Covered { end_atom; last_atom_digest = _ }) ->
        ["SUMMARY READINESS  COVERED · W END " ^ string_of_int end_atom] in
    let omitted = match step.omission with
      | T.Not_requested -> []
      | T.Omission_unavailable reason -> ["PREFIX OMISSION  UNAVAILABLE"; reason]
      | T.Not_observed (reason, value) -> ["PREFIX OMISSION  NOT OBSERVED"; reason] @ detail value
      | T.Observed value -> ["PREFIX OMISSION  OBSERVED · ALL ATTRIBUTED PREPARED REQUESTS"] @ detail value in
    let judgments = List.map (fun (value : T.judgment) ->
      let scope = match value.scope with T.Reply -> "reply" | T.Working_state -> "W" | T.Tool_calls -> "tool calls" in
      let observation = match value.result with
        | T.Unavailable -> "unavailable" | T.Pending -> "pending"
        | T.Measured { probability; model } ->
          "p=" ^ Yojson.Safe.to_string (`Float probability) ^ "  ·  " ^ model in
      value.criterion_id ^ " (" ^ scope ^ ")  " ^ observation) step.judgments in
    let working_state = match step.working_state with
      | None | Some [] -> []
      | Some messages ->
        [ Measurement_text (Ansi.reset, "W IN LAST PREPARED REQUEST")
        ; Measurement_json (Yojson.Safe.pretty_to_string (`List messages)) ] in
    [Measurement_text (Ansi.dim, "")]
    @ List.map (fun value -> Measurement_text (Ansi.reset, value)) (identity @ readiness @ omitted)
    @ working_state
    @ List.map (fun value -> Measurement_text (Ansi.reset, value))
        ((if step.reply = [] then [] else "ORIGINAL REPLY" :: step.reply) @ judgments)) report.timeline in
  let errors = match report.error with
    | None -> [] | Some value -> [Measurement_text (Theme.warn (), value)] in
  measurement_output_preview ~width ~output_path:report.report_path (errors @ steps)

let inspection_summary_lines ~cols ~language ~now = function
  | Inspection_lane detail -> lane_run_summary_lines ~cols ~language ~now detail
  | Inspection_measurement (_, Measurement.Snapshot measurement) -> measurement_summary_lines measurement.report
  | Inspection_measurement (_, Measurement.Temporal report) -> temporal_summary_lines report

let inspection_panel_titles = function
  | Inspection_lane detail -> lane_run_panel_titles detail
  | Inspection_measurement (_, Measurement.Snapshot measurement) ->
    (match measurement.report.provenance with
     | Continuity_report.Synthetic -> "INPUT · SYNTHETIC CASES"),
    "OBSERVATIONS · NO VERDICT"
  | Inspection_measurement (_, Measurement.Temporal _) ->
    "SOURCE · PREPARED REQUEST EVIDENCE", "TIMELINE · NO VERDICT"

let inspection_input_lines ~width = function
  | Inspection_lane detail -> lane_run_input_lines ~width detail
  | Inspection_measurement (sha256, Measurement.Snapshot report) -> measurement_input_lines ~width ~sha256 report
  | Inspection_measurement (sha256, Measurement.Temporal report) -> temporal_input_lines ~width ~sha256 report

let inspection_output_lines ~details ~width = function
  | Inspection_lane detail -> lane_run_output_lines ~details ~width detail
  | Inspection_measurement (_, Measurement.Snapshot measurement) -> measurement_output_lines ~width measurement.report
  | Inspection_measurement (_, Measurement.Temporal report) -> temporal_output_lines ~width report

let lane_run_stacked_lines ~details ~width detail =
  let input_title, output_title = inspection_panel_titles detail in
  let indent lines = List.map (fun (style, line) -> style, "  " ^ line) lines in
  [ Ansi.bold, "  " ^ input_title ]
  @ indent (inspection_input_lines ~width detail)
  @ [ Ansi.dim, ""; Ansi.bold, "  " ^ output_title ]
  @ indent (inspection_output_lines ~details ~width detail)

let lane_run_split_line buf cols ~left_width ~left ~right =
  let inner = framed_inner_width cols in
  let divider = " │ " in
  let divider_width = 3 in
  let right_width = max 1 (inner - left_width - divider_width) in
  let styled width (style, line) =
    fit_width (style ^ line ^ Ansi.reset) width
  in
  box_line buf cols
    (styled left_width left ^ Theme.recede () ^ divider ^ Ansi.reset
     ^ styled right_width right)

(* Top, header, its divider, bottom and footer. A loaded run also draws
   the divider beneath its summary. Split panes use one payload row for titles. *)
let lane_run_chrome_rows_without_summary = framed_chrome_rows
let lane_run_chrome_rows = lane_run_chrome_rows_without_summary + 1

let render_lane_run_detail (state : state) ~run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let measurement = match state.lanes_mode with
    | Lanes_measurement_detail _ -> true
    | Lanes_overview | Lanes_run_list _ | Lanes_run_detail _ | Lanes_inventory_detail _ -> false in
  let detail =
    if measurement then Option.map (fun report -> Inspection_measurement (run_id, report)) state.measurement_report
    else match state.lane_run_detail with
    | Some detail when String.equal detail.Tui_decode.lrd_run_id run_id ->
        Some (Inspection_lane detail)
    | Some _ | None -> None
  in
  let header =
    let text ko en = ui_text state ~ko ~en in
    let path =
      match state.lanes_mode with
      | Lanes_run_detail (lane, _) ->
          [ observed_lane_label lane; text "실행" "runs"; run_id ]
      | Lanes_measurement_detail _ -> [ text "측정" "measurement"; run_id ]
      | Lanes_overview | Lanes_run_list _ | Lanes_inventory_detail _ -> [ run_id ]
    in
    here_row ~cols state ~path ~readings:[] ~position:None
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.lane_run_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text error);
       if Option.is_none detail then box_divider buf cols);
  let chrome_rows_for_error =
    match detail, state.lane_run_detail_error with
    | Some _, Some _ -> 1
    | None, Some _ -> 2
    | (Some _ | None), None -> 0
  in
  (* The position the footer carries: [None] where the drawing already says
     it -- nothing to read yet, or two panes whose titles each name their
     own window. *)
  let scroll, position, content_height =
    match detail, state.lane_run_detail_error with
    | None, error ->
      let filler_rows = max 1 (rows - lane_run_chrome_rows_without_summary - chrome_rows_for_error) in
      let line =
        match error with
        | None -> Ansi.dim, (if measurement then "  (loading measurement artifact)" else "  (loading exact run record)")
        | Some _ -> Ansi.dim, page_failed_note
      in
      box_line_styled buf cols ~style:(fst line) (snd line);
      for _ = 2 to filler_rows do
        box_empty buf cols
      done;
      0, None, 0
    | Some detail, (Some _ | None) ->
      let summary =
        inspection_summary_lines ~cols ~language:state.ui_language
          ~now:(Unix.gettimeofday ()) detail
      in
      let compact_preflight = match detail with
        | Inspection_lane {Tui_decode.lrd_librarian_preflight=Some _;_} -> not state.lane_run_preflight_details
        | Inspection_lane { lrd_librarian_preflight = None;_} | Inspection_measurement (_, _) -> false in
      let split = cols >= keeper_split_threshold_cols && not compact_preflight in
      let payload_rows =
        max 0
          (rows - List.length summary - lane_run_chrome_rows - chrome_rows_for_error)
      in
      let title_rows = if split then 1 else 0 in
      let content_height = max 0 (payload_rows - title_rows) in
      List.iter
        (fun (style, line) -> box_line_styled buf cols ~style line)
        summary;
      box_divider buf cols;
      if split then begin
        let inner = framed_inner_width cols in
        let divider_width = 3 in
        let left_width = max 1 ((inner - divider_width) / 2) in
        let right_width = max 1 (inner - left_width - divider_width) in
        let input_lines =
          inspection_input_lines ~width:left_width detail
        in
        let output_lines = inspection_output_lines ~details:state.lane_run_preflight_details ~width:right_width detail in
        if payload_rows = 0
        then 0, None, content_height
        else begin
          let input_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length input_lines - content_height)
          in
          let output_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length output_lines - content_height)
          in
          let max_scroll = max input_max_scroll output_max_scroll in
          let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
          let input_scroll = min scroll input_max_scroll in
          let input_lines_window = Rows.of_list ~first:input_scroll ~height:content_height input_lines in
          let output_scroll = min scroll output_max_scroll in
          let input_title, output_title = inspection_panel_titles detail in
          lane_run_split_line buf cols ~left_width
            ~left:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" input_title
                  (Masc_tui_scroll.window_text ~scroll:input_scroll
                     ~height:content_height (List.length input_lines)) )
            ~right:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" output_title
                  (Masc_tui_scroll.window_text ~scroll:output_scroll
                     ~height:content_height (List.length output_lines)) );
            let output_lines_window = Rows.of_list ~first:output_scroll ~height:content_height output_lines in
          for index = 0 to content_height - 1 do
            let left =
              Option.value
                (Rows.at input_lines_window (index + input_scroll))
                ~default:(Ansi.reset, "")
            in
            let right =
              Option.value
                (Rows.at output_lines_window (index + output_scroll))
                ~default:(Ansi.reset, "")
            in
            lane_run_split_line buf cols ~left_width ~left ~right
          done;
          scroll, None, content_height
        end
      end
      else begin
        let lines =
          if compact_preflight then
            inspection_output_lines ~details:false ~width:(max 1 (framed_inner_width cols - 4)) detail
          else lane_run_stacked_lines ~details:state.lane_run_preflight_details ~width:(max 1 (framed_inner_width cols - 4)) detail
        in
        let max_scroll =
          if content_height = 0
          then 0
          else max 0 (List.length lines - content_height)
        in
        let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
        let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
        for index = 0 to content_height - 1 do
          match Rows.at lines_window (index + scroll) with
          | None -> box_empty buf cols
          | Some (style, line) -> box_line_styled buf cols ~style line
        done;
        scroll,
        Some (Masc_tui_scroll.window_text ~scroll ~height:content_height (List.length lines)),
        content_height
      end
  in
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ?position ~hints:(Masc_tui_keys.footer_hints_lanes_run_detail_for
         ~lang:state.ui_language
         ~preflight:(match detail with
           | Some (Inspection_lane {Tui_decode.lrd_librarian_preflight=Some _;_}) -> true
           | Some (Inspection_lane { lrd_librarian_preflight = None;_})
           | Some (Inspection_measurement (_, _)) | None -> false)));
  finish_surface state ~clamped:(Lane_run_detail_scroll { scroll; content_height })
    ~surface_key:"lane-run" ~rows:terminal_rows ~cols buf

(* The clients roster: everyone attached to this workspace in one reading —
   directory agents, state-backed sessions, runtime fibers. The keeper
   roster answers "which Keepers exist"; this answers "who is here now",
   which includes identities no other surface lists, such as a non-keeper
   MCP client. One row per identity, sorted by name on the server, with the
   status dot, the type, the keeper a row is bound to when it is, and what
   task it holds. *)
type client_table_column =
  | Client_status_column | Client_name_column | Client_type_column
  | Client_acting_for_column | Client_task_column | Client_last_seen_column

(* Ages are measured to the server's read of the roster, not to this frame:
   a heartbeat is not announced, so time since the read is not time since the
   client was seen. A Keeper registry or workspace-state row carries no
   observation time of its own, and its cell stays empty rather than showing
   the read time as a fact about the client. *)
let clients_read_at (state : state) =
  Option.bind state.clients_surface (fun (snapshot : Masc.Tui_decode.clients_snapshot) ->
    Time_codec.parse_rfc3339_opt snapshot.Masc.Tui_decode.cls_observed_at)

let client_last_seen_text ~read_at (row : Masc.Tui_decode.client_row) =
  match row.Masc.Tui_decode.cr_last_seen, read_at with
  | Some last_seen, Some read_at -> Masc_tui_wire_age.text ~now:read_at last_seen
  | Some _, None | None, (Some _ | None) -> Masc_tui_theme.Glyph.no_value

let render_client_detail state (client : Masc.Tui_decode.client_row) =
  let terminal_rows, cols = get_terminal_size () in
  let width = max 1 (framed_inner_width cols - 2) in
  let field ?(style = Ansi.reset) label value =
    let prefix = "  " ^ label ^ ": " in
    let prefix_width = Message_layout.display_width prefix in
    let continuation = String.make prefix_width ' ' in
    match
      Message_layout.wrap_words ~max_cells:(max 1 (width - prefix_width))
        (Terminal_text.single_line value)
    with
    | [] -> [ prefix ^ style ^ Masc_tui_theme.Glyph.no_value ^ Ansi.reset ]
    | first :: rest ->
      (Ansi.bold ^ prefix ^ Ansi.reset ^ style ^ first ^ Ansi.reset)
      :: List.map (fun line -> continuation ^ style ^ line ^ Ansi.reset) rest
  in
  let optional = function Some value -> value | None -> Masc_tui_theme.Glyph.no_value in
  let status_style =
    match client.cr_status with
    | Masc.Tui_decode.Client_active | Masc.Tui_decode.Client_busy -> Theme.ok ()
    | Masc.Tui_decode.Client_listening -> Theme.info ()
    | Masc.Tui_decode.Client_inactive -> Theme.recede ()
  in
  let lines =
    detail_section_lines ~first:true "1. 연결 상태 · 현재 작업 (Status & Activity)"
    @ field ~style:status_style "Status"
        (Masc.Tui_decode.client_status_to_string client.cr_status)
    @ field "Acting for" (optional client.cr_keeper_name)
    @ field "Task" (optional client.cr_current_task)
    @ field "Seen before read"
        (client_last_seen_text ~read_at:(clients_read_at state) client)
    @ field ~style:Ansi.dim "Last seen (as read)" (optional client.cr_last_seen)
    @ detail_section_lines "2. 클라이언트 식별 정보 (Identity)"
    @ field "Name" client.cr_name
    @ field "Type" client.cr_agent_type
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"client-detail"
    ~frame:Chrome_overlay
    ~title:
      (here_row ~cols state
         ~path:[ ui_text state ~ko:"클라이언트" ~en:"clients"
               ; Terminal_text.single_line client.cr_name ]
         ~readings:[] ~position:None)
    ~hints:"j/k:scroll  PgUp/PgDn:page  g/G:first/last  Esc:clients"
    ~overflow:(Scrolled {scroll=state.client_detail_scroll;
                        report=(fun scroll -> Client_detail_scroll scroll)})
    ~body:(fun ~budget:_ c -> List.iter c.push lines)

let render_clients (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let clients =
    match state.clients_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.cls_clients
  in
  let shown = List.length clients in
  (* Every row's span is a distance from the same read of the roster. *)
  let read_at = clients_read_at state in
  let header =
    here_row ~cols state
      ~path:[ ui_text state ~ko:"클라이언트" ~en:"clients" ]
      ~readings:[] ~position:None
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Measured from the rows like the verification submitter column: a fixed
     width puts the columns after the longest name out of line with the
     rest, and session names are the column the eye scans by. *)
  let table_width = max 0 (framed_inner_width cols - 2) in
  let last_seen_width =
    List.fold_left (fun widest (row : Masc.Tui_decode.client_row) ->
      max widest (Message_layout.display_width (client_last_seen_text ~read_at row)))
      (Message_layout.display_width "LAST SEEN") clients
    (* The table keeps its status and identity floor. Exact observations that
       exceed this share are read in the selected client's scrollable detail. *)
    |> min (max 9 (table_width - 9 - 16 - 2 * Masc_tui_table.cell_gap))
  in
  let name_width =
    List.fold_left
      (fun widest (row : Masc.Tui_decode.client_row) ->
         max widest
           (Message_layout.display_width
              (Terminal_text.single_line row.Masc.Tui_decode.cr_name)))
      16 clients
    |> min 24
    (* A future or unreadable stamp is deliberately shown verbatim by the age
       projection. Give its measured width priority over the identity floor,
       rather than disguising a raw clock as a folded age. *)
    |> min (max 1 (table_width - 9 - last_seen_width - 2 * Masc_tui_table.cell_gap))
  in
  (* The column carries a reading only where a client is bound to a Keeper
     under a name of its own. Where no row has one, its cells and header are
     seventeen blank columns, and the clock at the end of the row is what
     loses them: "last seen 01:4…" is not a time. *)
  let acting_for_drawn = Masc_tui_types.clients_act_for_others clients in
  let column_width = function
    | Client_status_column | Client_task_column -> 9
    | Client_last_seen_column -> last_seen_width
    | Client_name_column -> name_width
    | Client_type_column -> 10
    | Client_acting_for_column -> 16
  in
  let columns =
    [ Client_status_column; Client_name_column; Client_type_column ]
    @ (if acting_for_drawn then [ Client_acting_for_column ] else [])
    @ [ Client_task_column; Client_last_seen_column ]
  in
  (* Keep identity, state and the observation age. Bindings, implementation
     type and task links yield in that order before the clock is cut. *)
  let layout = Masc_tui_table.fit ~inner_width:table_width
    ~width:column_width ~flex:Client_name_column
    ~drop_order:[ Client_acting_for_column; Client_type_column; Client_task_column ] columns in
  let cells ~status ~name ~agent_type ~keeper ~task ~last_seen =
    List.map (fun column ->
      let header, value = match column with
        | Client_status_column -> "STATUS", status
        | Client_name_column -> "NAME", name
        | Client_type_column -> "TYPE", agent_type
        | Client_acting_for_column -> "ACTING FOR", keeper
        | Client_task_column -> "TASK", task
        | Client_last_seen_column -> "LAST SEEN", last_seen
      in
      let width = if column = Client_name_column then layout.flex_width else column_width column in
      Masc_tui_table.cell ~header ~width value) layout.shown
  in
  let col_hdr = "  " ^ Masc_tui_table.header_row
    (cells ~status:"" ~name:"" ~agent_type:"" ~keeper:"" ~task:"" ~last_seen:"") in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.clients_surface_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = listing_chrome ~error:state.clients_surface_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.clients_surface_scroll max_scroll) in
  let clients_window = Rows.of_list ~first:scroll ~height:content_height clients in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.clients_surface ~error:state.clients_surface_error with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note_while ~reading:state.clients_surface_inflight
      | Page_empty -> "  (nobody attached)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at clients_window idx with
      | None -> box_empty buf cols
      | Some row ->
          let open Masc.Tui_decode in
          let status = client_status_to_string row.cr_status in
          let name = Terminal_text.single_line row.cr_name in
          (* Both sides sanitized before they are compared: the cell is
             drawn from this reading, and a name that differs only in the
             bytes [Terminal_text] strips is the same name on screen. *)
          let keeper =
            match
              Masc_tui_types.client_acting_for ~name
                ~keeper_name:
                  (Option.map Terminal_text.single_line row.cr_keeper_name)
            with
            | Some keeper -> keeper
            | None -> ""
          in
          let task =
            match row.cr_current_task with
            | Some task -> Terminal_text.single_line task
            | None -> Masc_tui_theme.Glyph.no_value
          in
          let line =
            "  " ^ Masc_tui_table.row (cells ~status ~name
              ~agent_type:(Terminal_text.single_line row.cr_agent_type) ~keeper ~task
              (* Age is relative to the roster observation, not render time. *)
              ~last_seen:(client_last_seen_text ~read_at row))
          in
          (* Inactive rows stay in the roster -- "who left" is part of the
             reading -- but they recede, the way the empty-state rows do. *)
          let style =
            match row.cr_status with
            | Client_inactive -> Theme.recede ()
            | Client_active | Client_busy | Client_listening -> Ansi.reset
          in
          if idx = state.clients_surface_cursor then
            box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  box_bottom buf cols;
  let position =
    if shown > content_height then
      Some
        (Printf.sprintf "rows %s"
           (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
    else None
  in
  (* [listing_chrome] already counts this row. Without it the keys the table
     declares for Clients went unshown, and so did an armed search's query,
     which rides the same row. *)
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ?position
       ~hints:
         (Masc_tui_keys.footer_hints ~lang:state.ui_language ~has_rows:(shown > 0)
            Masc_tui_types.Clients));
  finish_surface state ~surface_key:"clients" ~rows:terminal_rows ~cols buf
;;

let render_lane_scrollable_styled_reading (state : state) ~terminal_rows ~cols
    ~surface_key ~path ~hints styled_lines =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let height = max 1 (rows - Masc_tui_frame.chrome_rows) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length styled_lines) ~height
      state.lane_run_detail_scroll
  in
  let window = Rows.of_list ~first:scroll ~height styled_lines in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols (here_row ~cols state ~path ~readings:[] ~position:None);
  box_divider buf cols;
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~position:(Masc_tui_scroll.window_text ~scroll ~height (List.length styled_lines))
       ~hints);
  finish_surface state
    ~clamped:(Lane_run_detail_scroll { scroll; content_height = height })
    ~surface_key ~rows:terminal_rows ~cols buf

let render_lane_scrollable_reading (state : state) ~terminal_rows ~cols
    ~surface_key ~path ~hints lines =
  let max_cells = max 1 (framed_inner_width cols - 2) in
  render_lane_scrollable_styled_reading state ~terminal_rows ~cols
    ~surface_key ~path ~hints (Page_reading.rows ~max_cells lines)

(* The same words as the key that opens the reading ([Space] in the list). *)
let lane_activity_step state = ui_text state ~ko:"켜고 끄기" ~en:"activity"

let lane_activity_hints =
  "Space:draft  s:save  r:read  u:reapply  x:discard  ?:help  Esc:back"

let render_lane_inventory_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let width = max 1 (framed_inner_width cols - 2) in
  let max_cells = max 1 (width - 2) in
  let wrap style text = Page_reading.wrap_indented_line ~max_cells style text in
  let content = match state.lane_inventory with
    | None -> wrap (Theme.recede ()) "Lane inventory has not been read. r: refresh"
    | Some snapshot ->
        (match target with
         | None ->
             wrap Ansi.bold "Inventory diagnostics"
             @ (match Masc_tui_lane_inventory.snapshot_notices snapshot with
                | [] -> wrap (Theme.recede ()) "No inventory read issues observed."
                | notices -> Page_reading.wrap_indented_lines ~max_cells (Theme.warn ()) notices)
         | Some id ->
             (match List.find_opt (fun (row : Masc.Tui_decode_lane_inventory.row) -> String.equal row.id id) snapshot.rows with
              | None ->
                  wrap (Theme.warn ())
                    "This Lane is absent from the current reading. Esc returns to the inventory."
              | Some row ->
                  let detail_for_row row =
                    inventory_row_detail_lines ~width
                      ~selected_output:(Masc_tui_types.lanes_exact_output_name state row)
                      row
                  in
                  (match row.Masc.Tui_decode_lane_inventory.selection with
                   | Exact lane ->
                       (match List.find_opt (fun (item : Tui_decode.standalone_lane) ->
                            Standalone_lane.equal item.sl_lane lane) snapshot.exact_snapshot.sls_lanes with
                        | Some item ->
                            standalone_lane_detail_lines ~now:(Unix.gettimeofday ()) ~width item
                        | None -> detail_for_row row)
                   | Browser _ | Machine _ | Declaration _ | Manual_instance _ ->
                       detail_for_row row))) in
  let content =
    Option.to_list
      (Option.map (fun detail -> wrap (Theme.warn ()) ("STALE · " ^ detail))
         state.standalone_lanes_error)
    |> List.concat
    |> fun stale -> stale
      @ Option.fold ~none:[] ~some:(wrap (Theme.warn ())) state.lanes_action_error
      @ Option.fold ~none:[] ~some:(fun notice ->
          wrap (runtime_lane_notice_style notice)
            (Masc_tui_types.runtime_lane_notice_text notice)) state.runtime_lane_notice
      @ List.concat_map (wrap (Theme.warn ())) (Masc_tui_types.runtime_lane_stale_lines state)
      @ content
  in
  (* The path names the row the list named: its label while the reading
     holds the row, its id when the row is gone from the reading. *)
  let path =
    match target with
    | None -> [ ui_text state ~ko:"문제" ~en:"issues" ]
    | Some id ->
        let label =
          Option.bind state.lane_inventory (fun snapshot ->
            List.find_opt
              (fun (row : Masc.Tui_decode_lane_inventory.row) -> String.equal row.id id)
              snapshot.rows)
          |> Option.fold ~none:id ~some:(fun (row : Masc.Tui_decode_lane_inventory.row) -> row.label)
        in
        [ Terminal_text.single_line label ]
  in
  render_lane_scrollable_styled_reading state ~terminal_rows ~cols
    ~surface_key:"lane-inventory-detail" ~path
    ~hints:"j/k:scroll  PgUp/PgDn:page  Home/End:top/bottom  r:refresh  Esc/Left:inventory"
    content

let render_machine_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  render_lane_scrollable_reading state ~terminal_rows ~cols
    ~surface_key:"machine-activity"
    ~path:[ Masc.Machine_lane.to_wire (Masc_tui_machine_activity.owner session).machine
          ; lane_activity_step state ]
    ~hints:lane_activity_hints
    (Masc_tui_machine_activity.lines session)

let render_exact_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  render_lane_scrollable_reading state ~terminal_rows ~cols
    ~surface_key:"exact-activity"
    ~path:[ Standalone_lane.to_id (Masc_tui_exact_activity.owner session).lane
          ; lane_activity_step state ]
    ~hints:lane_activity_hints
    (Masc_tui_exact_activity.lines session)

let render_lanes (state : state) =
  match Masc_tui_types.shown_machine_activity state with
  | Some session -> render_machine_activity state session
  | None -> match Masc_tui_types.shown_exact_activity state with
  | Some session -> render_exact_activity state session
  | None -> match state.lanes_mode with
  | Lanes_overview -> render_lanes_overview state
  | Lanes_inventory_detail target -> render_lane_inventory_detail state target
  | Lanes_run_list lane -> render_lane_run_list state ~lane
  | Lanes_run_detail (_, run_id) -> render_lane_run_detail state ~run_id
  | Lanes_measurement_detail sha256 -> render_lane_run_detail state ~run_id:sha256

