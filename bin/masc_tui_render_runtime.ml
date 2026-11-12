(** System / Runtime, Features / Tools, Operations / Usage, and Keeper runtime picker screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Page_line = Masc_tui_page_line
module Keeper_chat = Masc_tui_keeper_chat_projection
module Overview_providers = Masc_tui_overview_providers
module Render_tools = Masc_tui_render_tools
module Metrics_page = Masc_tui_render_metrics

let runtime_lane_notice_style = Masc_tui_render_lanes.runtime_lane_notice_style
let runtime_lane_notice_tone = Masc_tui_render_lanes.runtime_lane_notice_tone

(* The runtime picker measures this string to decide its column widths, so the
   format lives beside that arithmetic. *)
let format_context_tokens = Masc_tui_types.format_context_tokens

let keepers_for_lane = Masc_tui_types.keepers_for_lane
let keepers_for_runtime_with_lanes = Masc_tui_types.keepers_for_runtime_with_lanes


let runtime_refresh_badge ~ko refresh_state =
  let open Masc.Tui_decode_runtime_probe in
  let label, style =
    match refresh_state with
    | Runtime_probe_fresh -> (if ko then "최신" else "fresh"), (Theme.ok ())
    | Runtime_probe_recent -> (if ko then "최근" else "recent"), (Theme.info ())
    | Runtime_probe_served_stale -> (if ko then "이전 관측" else "stale"), (Theme.warn ())
    | Runtime_probe_warming_up -> (if ko then "준비 중" else "warming"), (Theme.warn ())
  in
  style ^ label ^ Ansi.reset

let runtime_overall_label ~ko status =
  let open Masc.Tui_decode_runtime_probe in
  if ko then
    match status with
    | Runtime_probe_reachable -> "연결 가능"
    | Runtime_probe_no_http_runtimes -> "HTTP 런타임 없음"
    | Runtime_probe_warming -> "준비 중"
    | Runtime_probe_degraded -> "일부 실패"
    | Runtime_probe_unreachable -> "연결 불가"
  else runtime_probe_status_to_string status

let runtime_overall_badge ~ko status =
  let open Masc.Tui_decode_runtime_probe in
  let style =
    match status with
    | Runtime_probe_reachable -> (Theme.ok ())
    | Runtime_probe_no_http_runtimes | Runtime_probe_warming -> Ansi.dim
    | Runtime_probe_degraded -> (Theme.warn ())
    | Runtime_probe_unreachable -> (Theme.bad ())
  in
  style ^ runtime_overall_label ~ko status ^ Ansi.reset

let runtime_usage_badge state runtime =
  let ko = state.ui_language = Lang_ko in
  match state.runtime_surface with
  | None -> Some (Ansi.dim ^ (if ko then "사용량 미확인" else "usage unknown") ^ Ansi.reset)
  | Some snapshot ->
      match runtime_spent_usage snapshot.rss_resolved runtime with
      | Error _ -> Some (Ansi.dim ^ (if ko then "사용량 미확인" else "usage unknown") ^ Ansi.reset)
      | Ok [] -> None
      | Ok (_ :: _) -> Some (Theme.warn () ^ (if ko then "계정 한도 소진" else "account limit spent") ^ Ansi.reset)

let runtime_route_badge state (runtime : Masc.Tui_decode.runtime_option) =
  let ko = state.ui_language = Lang_ko in
  let warn label = Option.map (fun text -> Theme.warn () ^ text ^ Ansi.reset) label in
  match
    List.filter_map Fun.id
      [ warn (runtime_credential_refused_label ~ko runtime)
      ; warn (runtime_quota_label ~ko runtime); warn (runtime_rate_limit_label ~ko runtime)
      ; runtime_usage_badge state runtime ]
  with
  | [] -> (Theme.info ()) ^ (if ko then "거절 없음" else "no refusal") ^ Ansi.reset
  | badges -> String.concat " " badges

let runtime_probe_badge ~ko = function
  | None -> Ansi.dim ^ (if ko then "미관측" else "unobserved") ^ Ansi.reset
  | Some (probe : Masc.Tui_decode_runtime_probe.runtime_provider_probe) ->
      let open Masc.Tui_decode_runtime_probe in
      let style =
        match probe.rpp_status with
        | Runtime_provider_reachable -> (Theme.ok ())
        | Runtime_provider_skipped_cli
        | Runtime_provider_skipped_native_auth
        | Runtime_provider_refused -> Ansi.dim
        | Runtime_provider_missing_auth | Runtime_provider_auth_failed ->
            (Theme.warn ())
        | Runtime_provider_network_error
        | Runtime_provider_server_error
        | Runtime_provider_endpoint_not_found
        | Runtime_provider_http_error
        | Runtime_provider_unknown_http_status
        | Runtime_provider_invalid_endpoint
        | Runtime_provider_invalid_execution_transport -> (Theme.bad ())
      in
      let label = runtime_probe_status_label ~ko probe.rpp_status in
      style ^ label ^ Ansi.reset

let runtime_route_probe_badge state runtime probe =
  runtime_route_badge state runtime ^ " / "
  ^ runtime_probe_badge ~ko:(state.ui_language = Lang_ko) probe

let runtime_probe_detail = function
  | None -> []
  | Some (probe : Masc.Tui_decode_runtime_probe.runtime_provider_probe) ->
      let latency =
        Option.map (fun value -> Printf.sprintf "%.0fms" value) probe.rpp_latency_ms
      in
      let http =
        Option.map (fun value -> Printf.sprintf "HTTP %d" value) probe.rpp_http_status
      in
      let error = Terminal_text.optional_single_line probe.rpp_error in
      let checked =
        Some ("checked " ^ Terminal_text.clock_timestamp probe.rpp_checked_at)
      in
      List.filter_map Fun.id [ latency; http; error; checked ]

let runtime_column_widths cols =
  if cols >= 140 then 18, 30, 30, 22
  else if cols >= 120 then 14, 24, 24, 22
  else 10, 20, 20, 22

let runtime_column width text =
  let clipped = fit_width text width in
  clipped
  ^ String.make
      (max 0 (width - Message_layout.display_width clipped))
      ' '

type runtime_table_column =
  | Runtime_lane_column
  | Runtime_candidate_column
  | Runtime_identity_column
  | Runtime_status_column
  | Runtime_detail_column

let runtime_table_cells ~ko ~cols ~status_cells ~mode ~lane ~lane_is_label ~candidate ~identity ~status ~detail =
  let lane_width, candidate_width, identity_width, minimum_status_width = runtime_column_widths cols in
  let status_width = max minimum_status_width status_cells in
  let inner_width = max 1 (framed_inner_width cols - 2) in
  let candidate_heading =
    match mode with
    | Masc_tui_types.Runtime_lanes -> if ko then "후보" else "CANDIDATE"
    | Runtime_all -> if ko then "런타임" else "RUNTIME"
  in
  (* Reserve the mode's identifying columns before allocating long status. *)
  let status_width, candidate_floor, drop_order = match mode with
    | Masc_tui_types.Runtime_lanes ->
        (* Lane identity and candidate order stay visible even when another
           row has a long combined status. Full status is in summary/detail. *)
        let remaining = inner_width - lane_width - (2 * Masc_tui_table.cell_gap) in
        let candidate_floor = min candidate_width (max 1 (remaining - 1)) in
        min status_width (max 1 (remaining - candidate_floor)), candidate_floor,
        [Runtime_detail_column; Runtime_identity_column]
    | Runtime_all ->
        let status_width = min status_width
          (max 1 (inner_width - Message_layout.display_width candidate_heading
                  - Masc_tui_table.cell_gap)) in
        status_width, min candidate_width (max 1 (inner_width - status_width - Masc_tui_table.cell_gap)),
        [Runtime_detail_column; Runtime_identity_column; Runtime_lane_column]
  in
  let width = function
    | Runtime_lane_column -> lane_width
    | Runtime_candidate_column -> candidate_floor
    | Runtime_identity_column -> identity_width
    | Runtime_status_column -> status_width
    | Runtime_detail_column ->
        max (Message_layout.display_width "single candidate")
          (inner_width - lane_width - candidate_floor - identity_width - status_width
           - (4 * Masc_tui_table.cell_gap)) in
  let layout = Masc_tui_table.fit ~inner_width ~width
    ~flex:Runtime_candidate_column
    ~drop_order
    [Runtime_lane_column; Runtime_candidate_column; Runtime_identity_column;
     Runtime_status_column; Runtime_detail_column] in
  List.map (fun column ->
    let header, value, fold = match column with
      | Runtime_lane_column ->
          (match mode with
           | Masc_tui_types.Runtime_lanes -> if ko then "레인" else "LANE"
           | Runtime_all -> if ko then "사용 레인" else "USED BY"),
          lane, (if lane_is_label then Masc_tui_table.Fold_tail else Fold_middle)
      | Runtime_candidate_column ->
          candidate_heading, candidate, Masc_tui_table.Fold_middle
      | Runtime_identity_column -> (if ko then "제공자 / 모델" else "PROVIDER / MODEL"), identity, Masc_tui_table.Fold_middle
      | Runtime_status_column -> (if ko then "호출 / 연결" else "ROUTE / PROBE"), status, Masc_tui_table.Fold_tail
      | Runtime_detail_column -> (if ko then "상세" else "DETAIL"), detail, Masc_tui_table.Fold_tail in
    let column_width = if column = Runtime_candidate_column then layout.flex_width else width column in
    Masc_tui_table.cell ~header ~width:column_width ~fold value) layout.shown

let runtime_bool = function true -> "yes" | false -> "no"

(* A field as one fact line, so an absent field is [[]] and a repeated one is a
   [List.concat_map]. A blank value draws the empty mark, as it did when each
   page formatted its own fields. *)
let runtime_fact ?(tone = Page_line.Plain) label value =
  let value =
    if String.equal (String.trim (Terminal_text.single_line value)) ""
    then Masc_tui_theme.Glyph.no_value
    else value
  in
  [ Page_line.fact ~tone label value ]

(* A repeated field as one list under its label: the label stands once and each
   entry is a numbered row, so a page with fifty entries does not print the
   label fifty times. A lone entry stays one fact line and an empty list draws
   nothing. A blank entry draws the empty mark, as [runtime_fact] does. *)
let runtime_items ?(tone = Page_line.Plain) label values =
  let entry value =
    if String.equal (String.trim (Terminal_text.single_line value)) ""
    then Masc_tui_theme.Glyph.no_value
    else value
  in
  match List.map entry values with
  | [] -> []
  | [ value ] -> [ Page_line.fact ~tone label value ]
  | values -> [ Page_line.items ~tone label values ]

(* A route is not a candidate. This reading remains available when the
   inventory is empty, and retains diagnostics beside a last-good snapshot. *)
let runtime_routes_detail_lines state ~width =
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  let fact = runtime_fact in
  let optional label = function
    | None -> []
    | Some value -> fact ~tone:Page_line.Attention label value
  in
  let notice_and_stale =
    runtime_items ~tone:Page_line.Attention (text "후보 목록 조회" "Catalogue reading")
      (Masc_tui_types.runtime_picker_catalogue_notices state)
    @ (match state.runtime_lane_notice with
     | None -> []
     | Some notice ->
         fact ~tone:(runtime_lane_notice_tone notice) (text "작업 결과" "Action result")
           (Masc_tui_types.runtime_lane_notice_text notice))
    @ runtime_items ~tone:Page_line.Attention (text "이전 설정 관측" "Stale configuration")
        (Masc_tui_types.runtime_lane_stale_lines state)
  in
  let parent_fields = match Masc_tui_types.runtime_lane_prompt state with
    | None -> []
    | Some (Lane_name_prompt draft) ->
        fact (text "편집" "Editing") (text "새 경로 이름 초안" "New lane name draft")
        @ fact (text "초안" "Draft") draft
    | Some (Lane_rename_prompt (lane, draft)) ->
        fact (text "원래 경로" "Original lane") lane
        @ fact (text "이름 초안" "Name draft") draft
        @ fact (text "변경 범위" "Rename scope")
            (text "이름과 모든 참조를 함께 변경" "The lane name and all references change together")
    | Some (Lane_remove_prompt lane) -> fact (text "제거 확인 대상" "Removal target") lane in
  let notice_and_stale = parent_fields @ notice_and_stale in
  let default_routes = text "1. 기본 라우트 · 진입 런타임" "1. Default routes" in
  match state.runtime_surface with
  | None ->
      detail_page ~width
        [ ( default_routes
          , optional (text "런타임 조회 경고" "Runtime read warning") state.runtime_surface_error
            @ fact (text "설정" "Resolved") (text "관측 없음" "No configuration observation")
            @ notice_and_stale ) ]
  | Some snapshot ->
      let resolved = snapshot.Tui_decode.rss_resolved in
      let route label values =
        match values with
        | [] -> fact label (text "없음" "none")
        | values -> runtime_items label values
      in
      let dropped =
        List.filter
          (fun id -> not (List.exists (String.equal id) resolved.rrs_media_failover))
          resolved.rrs_media_failover_declared
      in
      let routes =
        fact (text "기본 라우트" "Default route") (Option.value resolved.rrs_default_route ~default:(text "없음" "none"))
        @ fact (text "시작 런타임" "Entry runtime") (Option.value resolved.rrs_default_runtime_id ~default:(text "없음" "none"))
        @ fact (text "설정 원본" "Source") (Option.value resolved.rrs_config_path ~default:(text "미확인" "unavailable"))
        @ fact (text "생성 시각" "Recorded") resolved.rrs_generated_at_iso
        @ (match runtime_fleet_summary state with
           | None -> []
           | Some summary -> fact (text "키퍼 전체" "Fleet") summary)
        @ notice_and_stale
      in
      let media =
        route (text "해소된 미디어 후보" "Admitted media") resolved.rrs_media_failover
        @ route (text "선언된 미디어 후보" "Declared media") resolved.rrs_media_failover_declared
        @ route (text "미해결 미디어 후보" "Unresolved media") dropped
      in
      let probe =
        optional (text "런타임 조회 경고" "Runtime read warning") state.runtime_surface_error
        @ optional (text "프로브 조회 오류" "Probe read error") snapshot.rss_probe_error
        @ (if snapshot.rss_unassigned_probe_count = 0 then []
           else fact (text "후보 순서 외 프로브" "Probes outside candidate orders")
                  (string_of_int snapshot.rss_unassigned_probe_count))
        @ (match snapshot.rss_probe with
           | None -> fact (text "프로브" "Probe")
               (text "미확인; 관측을 읽지 못함" "unavailable; no observation has been read")
           | Some probe ->
               fact (text "프로브 상태" "Probe status") (runtime_overall_label ~ko probe.rps_status)
               @ runtime_items ~tone:Page_line.Attention (text "프로브 오류" "Probe error") probe.rps_errors
               @ runtime_items (text "프로브 한계" "Probe limitation") probe.rps_limitations)
      in
      detail_page ~width
        [ default_routes, routes
        ; text "2. 미디어 대체 순서" "2. Media failover", media
        ; text "3. 연결 진단 · 프로브 상태" "3. Probe & diagnostics", probe
        ]
;;

let runtime_detail_lines state target ~width =
  let open Masc.Tui_decode in
  let ko = state.ui_language = Lang_ko in
  let reading =
    match state.runtime_surface, target with
    | None, _ | Some _, Runtime_routes -> None
    | Some snapshot, Runtime_lane_candidate { lane_id; runtime_id } ->
        snapshot.rss_candidates
        |> List.find_opt (fun row ->
               String.equal row.rcr_lane_id lane_id
               && String.equal row.rcr_runtime.ro_id runtime_id)
        |> Option.map (fun row ->
               (* Not [[ row.rcr_lane_id ]]: that is the lane the reader came
                  through, which the header already names, and the field is
                  labelled "Used by lanes". A runtime several lanes fall back
                  to answered this door with one lane and the catalog door
                  with all of them. *)
               ( row.rcr_runtime
               , runtime_lanes_using snapshot ~runtime_id:row.rcr_runtime.ro_id
               , Some
                   ( row.rcr_lane_id
                   , row.rcr_position
                   , row.rcr_candidate_count )
               , row.rcr_probe ))
    | Some snapshot, Runtime_catalog_entry { runtime_id } ->
        runtime_all_rows snapshot
        |> List.find_opt (fun (runtime, _) -> String.equal runtime.ro_id runtime_id)
        |> Option.map (fun (runtime, lanes) ->
               let probe =
                 Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id
               in
               runtime, lanes, None, probe)
  in
  match reading with
  | None ->
      (match target with
       | Runtime_routes -> runtime_routes_detail_lines state ~width
       | Runtime_lane_candidate _ | Runtime_catalog_entry _ ->
           Masc_tui_page_reading.rows
             ~max_cells:(max 1 (width - String.length Masc_tui_page_reading.detail_indent))
             (runtime_fact ~tone:Page_line.Attention "Runtime"
                "This runtime row is no longer present in the refreshed projection"))
  | Some (runtime, lanes, position, probe) ->
      let fact = runtime_fact in
      let model_fields =
        fact "Runtime ID" runtime.ro_id
        @ fact "Provider" runtime.ro_provider
        @ fact "Model" runtime.ro_model
        @ fact "Effective context"
            (Printf.sprintf "%d tokens" runtime.ro_effective_max_context)
        @ fact "Context source"
            (runtime_context_source_label runtime.ro_max_context_source)
        @ fact "Max output"
            (match runtime.ro_max_output_tokens with
             | Some tokens -> Printf.sprintf "%d tokens" tokens
             | None -> "not specified")
        @ fact "Local runtime"
            (runtime_bool runtime.ro_is_local)
      in
      let connection_fields =
        fact "Connection / provider ID" runtime.ro_provider_id
        @ fact "Quota scope" (runtime_quota_scope_label runtime)
        @ fact "Response-local quota scope"
            (Option.value ~default:"not reported" runtime.ro_quota_scope)
      in
      let assignment_fields =
        (match position with
         | None -> []
         | Some (lane, at, total) ->
             (* The lane is named because "Used by lanes" below can now hold
                several, and a position without its lane is a place in an
                unnamed list. *)
             fact "Lane position"
               (Printf.sprintf "%d of %d in %s" at total lane))
        @ fact "Used by lanes"
            (match lanes with [] -> "unassigned" | values -> String.concat ", " values)
        @ fact "Default runtime"
            (runtime_bool runtime.ro_is_default)
      in
      let quota =
        match runtime_quota_badge runtime with
        | None -> []
        | Some _ ->
            fact ~tone:Page_line.Attention "Quota"
              (match runtime.ro_quota_resets_at with
               | Some resets_at ->
                 let tm = Unix.localtime resets_at in
                 Printf.sprintf "exhausted, resets %02d:%02d"
                   tm.Unix.tm_hour tm.Unix.tm_min
               | None -> "exhausted, no reset stated")
      in
      let rate_limit =
        match runtime.ro_rate_limited, runtime.ro_rate_limit_resets_at with
        | false, _ -> []
        | true, Some resets_at ->
          let tm = Unix.localtime resets_at in
          fact ~tone:Page_line.Attention "Rate limit"
            (Printf.sprintf "until %02d:%02d or the next successful answer"
               tm.Unix.tm_hour tm.Unix.tm_min)
        | true, None ->
          fact ~tone:Page_line.Attention "Rate limit"
            "no wait stated, cleared by the next successful answer"
      in
      let credential =
        match runtime.ro_credential_refused_at with
        | None -> []
        | Some at ->
          let tm = Unix.localtime at in
          fact ~tone:Page_line.Attention "Credential"
            (Printf.sprintf "refused %02d-%02d %02d:%02d, until a call on it is answered"
               (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min)
      in
      let probe_lines =
        match probe with
        | None -> fact ~tone:Page_line.Quiet "Probe" "unobserved"
        | Some row ->
            let transport =
              match row.rpp_transport with
              | Runtime_probe_http -> "http"
              | Runtime_probe_cli -> "cli"
            in
            fact "Probe status"
              (runtime_probe_status_label ~ko row.rpp_status)
            @ fact "Probe transport" transport
            @ (match row.rpp_latency_ms with
               | None -> []
               | Some value ->
                   fact "Latency"
                     (Printf.sprintf "%.0fms" value))
            @ (match row.rpp_http_status with
               | None -> []
               | Some value ->
                   fact "HTTP status"
                     (string_of_int value))
            @ fact "Checked at"
                (Terminal_text.short_timestamp row.rpp_checked_at)
            (* No Reachable row: the decoder admits a probe only when its
               reachable flag agrees with its status, so the row could only
               repeat the status two rows above it -- "reachable" then
               "yes". *)
            @ (match runtime_probe_annotation ~status:row.rpp_status row.rpp_error with
               | None -> []
               | Some (Runtime_probe_note note) ->
                   fact ~tone:Page_line.Quiet "Probe note" note
               | Some (Runtime_probe_failure error) ->
                   fact ~tone:Page_line.Failure "Probe error" error)
      in
      let probe_limitations =
        match state.runtime_surface with
        | Some { rss_probe = Some snapshot; _ } ->
            runtime_items "Probe limitation" snapshot.rps_limitations
        | Some { rss_probe = None; _ } | None -> []
      in
      let keeper_lines =
        let target_keepers =
          match target with
          | Runtime_routes -> []
          | Runtime_lane_candidate { lane_id; runtime_id = _ } ->
              keepers_for_lane state lane_id
          | Runtime_catalog_entry { runtime_id } ->
              keepers_for_runtime_with_lanes state ~lanes runtime_id
        in
        match target_keepers with
        | [] ->
            fact ~tone:Page_line.Quiet "Bound keepers" "none"
        | ks ->
            let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) ks) in
            let activity_str = match aggregate_keeper_stats ks with
              | None -> "activity not observed"
              | Some (turns, tokens, cost) ->
                Printf.sprintf "%d turns · %s tokens · %s" turns
                  (format_context_tokens tokens) (Tui_decode.keeper_cost_summary cost)
            in
            fact "Bound keepers" names
            @ fact "Keeper lifetime" (activity_str ^ " · across all runtimes")
      in
      let usage_lines =
        match state.runtime_surface with
        | None -> fact ~tone:Page_line.Quiet "Account usage" "unavailable"
        | Some snapshot ->
          match runtime_spent_usage snapshot.rss_resolved runtime with
          | Error detail -> fact ~tone:Page_line.Quiet "Account usage"
              (Terminal_text.single_line detail)
          | Ok [] -> []
          | Ok windows ->
            fact ~tone:Page_line.Attention "Account usage"
              "A model-call limit is spent; this account report does not identify which models are refused."
            @ List.concat_map (fun (window : Masc.Tui_decode_usage.provider_usage_window) ->
                let limit = match window.puw_limit_id with
                  | Some id -> Terminal_text.single_line id
                  | None -> "account" in
                let tm = Unix.localtime window.puw_observed_at in
                let observed = Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
                    tm.Unix.tm_hour tm.Unix.tm_min in
                fact ~tone:Page_line.Attention "Spent limit"
                  (limit ^ " (observed " ^ observed ^ ")")) windows
      in
      let evidence_lines = match state.runtime_evidence with
        | None -> fact ~tone:Page_line.Quiet "Runtime history" "not read"
        | Some (Error detail) -> fact ~tone:Page_line.Quiet "Runtime history" detail
        | Some (Ok evidence) ->
          Masc_tui_runtime_evidence.lines evidence ~runtime_id:runtime.ro_id
          |> List.concat_map (fun (label, value) -> fact label value) in
      let failed_attempt =
        match runtime.ro_failed_attempt with
        | None -> []
        | Some attempt ->
          fact ~tone:Page_line.Attention "Last failure"
            (Terminal_text.single_line (runtime_failed_attempt_text attempt))
      in
      detail_page ~width
        [ (if ko then "1. 현재 상태 · 연결 진단" else "1. Health & probe"),
          probe_lines @ failed_attempt @ credential @ quota @ rate_limit @ usage_lines @ probe_limitations
        ; (if ko then "2. 레인 배정 · 실행 성적" else "2. Assignment & history"),
          assignment_fields @ keeper_lines @ evidence_lines
        ; (if ko then "3. 모델 · 컨텍스트" else "3. Model & context"), model_fields
        ; (if ko then "4. 쿼터 범위 · 계정 연결" else "4. Quota & connection"),
          connection_fields
        ]

let render_runtime_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let target_label =
    match target with
    | Runtime_routes -> if state.ui_language = Lang_ko then "라우트 / 상태" else "routes / status"
    | Runtime_lane_candidate { lane_id; runtime_id } -> lane_id ^ " / " ^ runtime_id
    | Runtime_catalog_entry { runtime_id } -> runtime_id
  in
  box_top buf cols;
  box_line buf cols
    (here_row ~cols state ~path:[ runtime_step state; target_label ]
       ~readings:[] ~position:None);
  box_divider buf cols;
  let lines = runtime_detail_lines state target ~width:(max 1 (framed_inner_width cols - 4)) in
  let total = List.length lines in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.runtime_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  let position =
    if total > content_height then
      Some
        (Printf.sprintf (if state.ui_language = Lang_ko then "행 %s" else "lines %s")
           (Masc_tui_scroll.window_text ~scroll ~height:content_height total))
    else None
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ?position
       ~hints:
         (Masc_tui_keys.footer_hints_runtime_detail
            ~ko:(state.ui_language = Lang_ko)
            ~routes:(target = Runtime_routes) ()));
  finish_surface state ~clamped:(Runtime_detail_scroll scroll)
    ~surface_key:"runtime-detail" ~rows:terminal_rows ~cols buf

(* The picker keeps the selected row at the head of its existing window.
   Optional exact-slot identity detail follows that same candidate. *)
let runtime_picker_choice_rows picker =
  let rows = ref [] in
  let push row = rows := row :: !rows in
  if picker.rlp_choices = [] then
    push
      (Masc_tui_types.runtime_picker_empty_note picker)
  else
    List.iteri (fun offset choice ->
      let mark = if picker.rlp_selected_row = Some offset then ">" else " " in
      let label = match choice, picker.rlp_pick with
        | Masc_tui_types.Runtime_choice runtime,
          (Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _) ->
            Masc_tui_types.runtime_model_picker_title runtime
        | Masc_tui_types.Runtime_choice _,
          (Masc_tui_types.Pick_route_default | Masc_tui_types.Pick_media_failover
          | Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_new_lane _)
        | Masc_tui_types.Lane_choice _,
          (Masc_tui_types.Pick_route_default | Masc_tui_types.Pick_media_failover
          | Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_exact_lane _
          | Masc_tui_types.Pick_exact_lane_replacement _ | Masc_tui_types.Pick_new_lane _) ->
            Masc_tui_types.runtime_picker_label_for picker.rlp_pick choice in
      match choice with
      | Masc_tui_types.Lane_choice lane ->
          let note =
            if List.exists (String.equal lane.rrl_id) picker.rlp_already
            then "  (current route)" else "" in
          push
            (Printf.sprintf "  %s %s%s" mark
               label
               (Ansi.dim ^ note ^ Ansi.reset))
      | Masc_tui_types.Runtime_choice runtime ->
          let note =
            if List.exists (String.equal runtime.ro_id) picker.rlp_already
            then (match picker.rlp_pick with
              | Masc_tui_types.Pick_route_default -> "  (current route)"
              | Pick_media_failover | Pick_conversation_lane _ | Pick_exact_lane _
              | Pick_exact_lane_replacement (_, _, _) | Pick_new_lane _ -> "  (already a candidate)")
            else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
            then "  (same provider as a current candidate)"
            else ""
          in
          let ctx =
            Printf.sprintf " [%s %s]"
              (format_context_tokens runtime.ro_effective_max_context)
              (match picker.rlp_pick with
               | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ -> "context"
               | Pick_media_failover | Pick_route_default | Pick_conversation_lane _
               | Pick_new_lane _ -> "ctx")
          in
          let def = if runtime.ro_is_default then
            (match picker.rlp_pick with
             | Masc_tui_types.Pick_route_default -> " [entry runtime]"
             | Pick_media_failover | Pick_conversation_lane _ | Pick_exact_lane _
             | Pick_exact_lane_replacement (_, _, _) | Pick_new_lane _ -> " [default]") else "" in
          push
            (Printf.sprintf "  %s %s%s%s%s" mark
               label
               ctx def
               (Ansi.dim ^ note ^ Ansi.reset));
          (match picker.rlp_pick with
           | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ ->
               push ("      Quota scope " ^ Terminal_text.single_line (runtime_quota_scope_label runtime)
                 ^ " · Connection " ^ Terminal_text.single_line runtime.ro_provider_id
                 ^ " · " ^ Terminal_text.single_line runtime.ro_id)
           | Pick_media_failover | Pick_route_default | Pick_conversation_lane _
           | Pick_new_lane _ -> ())) picker.rlp_choices;
  List.rev !rows

let runtime_picker_title ~ko ~notices pick =
  let lane = Terminal_text.single_line (runtime_lane_pick_name pick) in
  let purpose = match pick with
    | Pick_route_default -> if ko then "기본 경로 선택" else "Choose default route"
    | Pick_media_failover -> if ko then "이미지 예비 경로에 추가" else "Add media fallback"
    | Pick_new_lane _ ->
        Printf.sprintf (if ko then "새 경로 %s" else "Create lane %s") lane
    | Pick_conversation_lane _ | Pick_exact_lane _ ->
        Printf.sprintf (if ko then "%s에 런타임 추가" else "Add runtime to %s") lane
    | Pick_exact_lane_replacement _ ->
        Printf.sprintf (if ko then "%s 런타임 교체" else "Replace runtime in %s") lane
  in
  let heading = match notices with
    | [] -> " MASC Runtime / "
    | _ :: _ ->
        Printf.sprintf
          (if ko then "안내 %d개 · 닫고 v · Runtime / " else "%d notices · close, v · Runtime / ")
          (List.length notices)
  in
  screen_title (heading ^ purpose)

let render_runtime_reading (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let ( runtime_lane_width
      , runtime_candidate_width
      , _
      , _ ) =
    runtime_column_widths cols
  in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let candidates =
    match state.runtime_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.rss_candidates
  in
  (* The roster the lane view cannot show: every runtime the workspace can
     call, with the lanes that name it. A runtime no lane names has an empty
     [lanes] and is exactly what an operator is looking for when they ask why
     a model they configured is nowhere on this screen. *)
  let all_runtimes =
    match state.runtime_surface with
    | None -> []
    | Some snapshot -> runtime_all_rows snapshot
  in
  let shown =
    match state.runtime_mode with
    | Masc_tui_types.Runtime_lanes -> List.length candidates
    | Masc_tui_types.Runtime_all -> List.length all_runtimes
  in
  let timestamp =
    match state.runtime_surface with
    | None -> if ko then "관측 없음" else "reading unavailable"
    | Some snapshot ->
        (match Masc_domain.parse_iso8601_opt snapshot.rss_resolved.rrs_generated_at_iso with
         | None -> if ko then "관측 시각 없음" else "reading time unavailable"
         | Some generated_at ->
             let recorded = Unix.localtime generated_at in
             Printf.sprintf (if ko then "관측 %02d:%02d:%02d" else "reading %02d:%02d:%02d")
               recorded.Unix.tm_hour recorded.Unix.tm_min recorded.Unix.tm_sec)
  in
  let header =
    match state.runtime_surface with
    | None ->
        let reading_note =
          match state.runtime_surface_error with
          | None -> here_missing_reading state ~error:None
          | Some _ -> ""
        in
        here_row ~cols state ~path:[ runtime_step state ]
          ~readings:[ reading_note; timestamp ] ~position:None
    | Some snapshot ->
        let probe_status =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> (Theme.warn ()) ^ (if ko then "프로브 미확인" else "probe unavailable") ^ Ansi.reset
          | Some probe ->
              runtime_overall_badge ~ko probe.rps_status ^ " / "
              ^ runtime_refresh_badge ~ko probe.rps_refresh_state
        in
        let probe_read =
          if Option.is_some snapshot.rss_probe_error then
            (Theme.warn ()) ^ (if ko then " / 조회 실패" else " / read failed") ^ Ansi.reset
          else ""
        in
        let current =
          match state.runtime_mode with
          | Masc_tui_types.Runtime_lanes -> `Runtime_lanes
          | Masc_tui_types.Runtime_all -> `Runtime_all
        in
        runtime_substrate_heading state ~cols
          ~title:(here_path state ~path:[ runtime_step state ])
          ~current
          ~after:[ Printf.sprintf "  %s%s" probe_status probe_read; "  " ^ timestamp ]
  in
  let authority_rows = Masc_tui_types.runtime_authority_rows ~cols state in
  let selection_rows = runtime_selection_summary_for_viewport ~rows ~cols state in
  (* One measured status width for the whole reading, shared by the header and
     every row. A report that has several independent limits can still exceed
     the pane; full evidence stays in the selected summary or Enter's detail. *)
  let status_cells =
    let statuses = match state.runtime_mode with
      | Runtime_lanes -> List.map (fun row -> runtime_route_probe_text state
          row.Tui_decode.rcr_runtime row.rcr_probe) candidates
      | Runtime_all -> List.map (fun (runtime, _) ->
          let probe = Option.bind state.runtime_surface (fun snapshot ->
            Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.rss_probe ~runtime_id:runtime.Tui_decode.ro_id) in
          runtime_route_probe_text state runtime probe) all_runtimes in
    List.fold_left (fun width text -> max width (Message_layout.display_width text)) 0 statuses in
  (* The budget counts the rows this screen draws, so it comes from the same
     call the drawing reads rather than a fixed one. *)
  let chrome_rows = runtime_surface_listing_chrome ~rows ~cols state in
  let content_height = max 0 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.runtime_surface_scroll max_scroll) in
  let scroll =
    if content_height = 0 then scroll
    else if state.runtime_cursor < scroll then max 0 state.runtime_cursor
    else if state.runtime_cursor >= scroll + content_height
    then min max_scroll (state.runtime_cursor - content_height + 1)
    else scroll in
  let all_runtimes_window = Rows.of_list ~first:scroll ~height:content_height all_runtimes in
  let candidates_window = Rows.of_list ~first:scroll ~height:content_height candidates in
  let scroll_hint =
    if shown > content_height then
      Printf.sprintf (if ko then "[행 %s]  " else "[rows %s]  ")
        (Masc_tui_scroll.window_text ~scroll ~height:content_height shown)
    else ""
  in
  let hints =
    scroll_hint
    ^ Masc_tui_keys.footer_hints_runtime ~lang:state.ui_language
        ~mode:state.runtime_mode ~picker:None
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"runtime" ~title:header ~hints
    ~body:(fun ~budget:_ c ->
  let authority_style =
    match state.runtime_surface with
    | Some snapshot when Option.is_some snapshot.rss_probe_error -> (Theme.warn ())
    | Some _ | None -> Ansi.dim
  in
  List.iter (fun row -> c.push_styled ~style:authority_style row) authority_rows;
  c.push_divider ();
  if selection_rows <> [] then begin
    List.iter c.push selection_rows;
    c.push_divider ()
  end;
  (* The two routes that are not lanes. They hold runtime ids and nothing
     dispatches a keeper turn to them, so they sit above the lane table rather
     than among its rows, where the lane count and the lane-editing keys would
     both be wrong about them. *)
  (match state.runtime_mode with
   | Masc_tui_types.Runtime_all -> ()
   | Masc_tui_types.Runtime_lanes ->
       let missing_resolved_value =
         match state.runtime_surface_error with
         | None -> field_missing_reading ~error:None
         | Some _ -> Ansi.dim ^ Masc_tui_theme.Glyph.no_value ^ Ansi.reset
       in
       let resolved =
         Option.map (fun (s : Tui_decode.runtime_surface_snapshot) -> s.rss_resolved)
           state.runtime_surface
       in
       let media_text =
         match resolved with
         | None -> missing_resolved_value
         | Some resolved ->
             let declared = resolved.rrs_media_failover_declared in
             let admitted = resolved.rrs_media_failover in
             let dropped =
               List.filter
                 (fun id -> not (List.exists (String.equal id) admitted))
                 declared
             in
             (match declared, dropped with
              | [], [] -> Ansi.dim ^ (if ko then "없음 — 비전 런타임 없음" else "none — no vision runtimes") ^ Ansi.reset
              | declared, dropped ->
                  String.concat " → "
                    (List.map Terminal_text.single_line declared)
                  ^
                  (match dropped with
                   | [] -> ""
                   | _ ->
                     (Theme.warn ())
                     ^ (if ko then
                          Printf.sprintf "  (시작 시 미해결 %d개: %s)"
                            (List.length dropped) (String.concat ", " (List.map Terminal_text.single_line dropped))
                        else Printf.sprintf "  (%s unresolved at boot: %s)"
                          (Message_layout.count_noun (List.length dropped) "entry")
                          (String.concat ", " (List.map Terminal_text.single_line dropped)))
                     ^ Ansi.reset))
       in
       List.iter
         (fun line -> c.push_styled ~style:(Theme.recede ()) ("  " ^ line))
         (Masc_tui_types.runtime_default_route_lines ~cols state);
       (* A short viewport folds the media_failover row and its divider away so
          the table header and the selected row keep a place (#41143's rule for
          the status column, applied to height). *)
       if not (Masc_tui_types.runtime_media_row_folded ~rows ~cols state) then begin
         c.push_styled ~style:(Theme.recede ())
           (Printf.sprintf "  %s %s   %s"
              (runtime_column runtime_lane_width "media_failover")
              (runtime_column runtime_candidate_width media_text)
              (Ansi.dim ^ (if ko then "m:편집 · 비전 호출 순서" else "m edits it · the vision runtimes, in call order") ^ Ansi.reset));
         c.push_divider ()
       end);
  let table_cells = runtime_table_cells ~ko ~cols ~status_cells ~mode:state.runtime_mode in
  c.push_styled ~style:(Theme.recede ())
    ("  " ^ Masc_tui_table.header_row
      (table_cells ~lane:"" ~lane_is_label:false ~candidate:"" ~identity:"" ~status:"" ~detail:""));
  c.push_divider ();
  (match state.runtime_surface_error with
   | None -> ()
   | Some detail ->
       c.push_styled ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       c.push_divider ());
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
       List.iter
         (fun line ->
            c.push_styled ~style:(runtime_lane_notice_style notice) ("  " ^ line))
         (String.split_on_char '\n'
            (Keeper_chat.terminal_safe_text ~preserve_newlines:true
               (Masc_tui_types.runtime_lane_notice_text notice)));
       c.push_divider ());
  (* Counted in [runtime_surface_listing_chrome] as one row each and a
     divider. *)
  (match Masc_tui_types.runtime_lane_stale_lines state with
   | [] -> ()
   | lines ->
       List.iter
         (fun line ->
            c.push_styled ~style:(Theme.warn ())
              ("  " ^ Keeper_chat.terminal_safe_text line))
         lines;
       c.push_divider ());
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.runtime_surface
          ~error:state.runtime_surface_error
      with
      | Page_failed -> page_failed_note
      | Page_unread ->
          page_unread_note_while
            ~reading:(Option.is_some state.runtime_surface_inflight)
      | Page_empty ->
          (match state.runtime_mode with
           | Masc_tui_types.Runtime_lanes -> "  (no runtime candidate orders configured)"
           | Masc_tui_types.Runtime_all -> "  (no runtimes configured)")
    in
    c.push_styled ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      c.push_empty ()
    done
  end
  else
    for index = 0 to content_height - 1 do
      match state.runtime_mode with
      | Masc_tui_types.Runtime_all ->
          (match Rows.at all_runtimes_window (index + scroll) with
           | None -> c.push_empty ()
           | Some (runtime, lanes) ->
               let open Masc.Tui_decode in
               let used_by =
                 match lanes with
                 | [] -> (Theme.recede ()) ^ "unassigned" ^ Ansi.reset
                 | [ one ] -> one
                 | many -> Printf.sprintf "%d lanes" (List.length many)
               in
               let bound_keepers =
                 keepers_for_runtime_with_lanes state ~lanes runtime.ro_id
               in
               let default_fact =
                 if runtime.ro_is_default then [ (Theme.ok ()) ^ "[DEFAULT]" ^ Ansi.reset ] else []
               in
               let assignment_fact =
                 match bound_keepers with
                 | [] -> [ (Theme.recede ()) ^ "[no keepers]" ^ Ansi.reset ]
                 | [ one ] ->
                     let stats = keeper_assignment_activity bound_keepers in
                     [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" one.k_name stats ^ Ansi.reset ]
                 | many ->
                     let stats = keeper_assignment_activity bound_keepers in
                     let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) many) in
                     [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" names stats ^ Ansi.reset ]
               in
               let detail =
                 String.concat " \xc2\xb7 "
                   (default_fact @ assignment_fact
                    @ (match lanes with [] -> [] | l -> [ String.concat ", " l ])
                    @ runtime_probe_detail
                        (Option.bind state.runtime_surface (fun snapshot ->
                           Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id)))
               in
               let line = "  " ^ Masc_tui_table.row
                 (table_cells ~lane:(Terminal_text.single_line (Masc_tui_theme.strip_sgr used_by)) ~lane_is_label:(lanes = [])
                   ~candidate:(Terminal_text.single_line runtime.ro_id)
                   ~identity:(Terminal_text.single_line (runtime.ro_provider ^ " / " ^ runtime.ro_model))
                   ~status:(runtime_route_probe_badge state runtime
                     (Option.bind state.runtime_surface (fun snapshot ->
                       Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id)))
                   ~detail:(Terminal_text.single_line (Masc_tui_theme.strip_sgr detail))) in
               if index + scroll = state.runtime_cursor then
                 c.push_selected (Masc_tui_theme.strip_sgr line)
               else if Masc_tui_types.runtime_row_deemphasized state runtime then
                 c.push_styled ~style:(Theme.recede ()) (Masc_tui_theme.strip_sgr line)
               else c.push line)
      | Masc_tui_types.Runtime_lanes ->
      match Rows.at candidates_window (index + scroll) with
      | None -> c.push_empty ()
      | Some candidate ->
          let open Masc.Tui_decode in
          let runtime = candidate.rcr_runtime in
          let is_first = candidate.rcr_position = 1 in
          let is_last = candidate.rcr_position = candidate.rcr_candidate_count in
          (* Names preserve both ends. The fallback label is the branch mark,
             then the word, then the number, and the lane column keeps as many
             of them as it holds whole: a cut word named a fallback by half a
             word. The candidate column's "2/3" gives the position either way. *)
          let lane_cell =
            if candidate.rcr_candidate_count <= 1 || is_first then
              Terminal_text.single_line candidate.rcr_lane_id
            else
              Message_layout.join_fitting ~sep:" " ~cells:runtime_lane_width
                [ "  " ^ (if is_last then "\xe2\x94\x94\xe2\x94\x80" else "\xe2\x94\x9c\xe2\x94\x80")
                ; "fallback"
                ; Printf.sprintf "#%d" (candidate.rcr_position - 1)
                ]
          in
          let candidate_label =
            Printf.sprintf "%d/%d %s"
              candidate.rcr_position
              candidate.rcr_candidate_count
              (Terminal_text.single_line runtime.ro_id)
          in
          let provider_model =
            Terminal_text.single_line
              (runtime.ro_provider ^ " / " ^ runtime.ro_model)
          in
          let route_probe =
            runtime_route_probe_badge state runtime candidate.rcr_probe
          in
          let lane_keepers = keepers_for_lane state candidate.rcr_lane_id in
          let assignment_fact =
            if is_first then
              match lane_keepers with
              | [] -> [ (Theme.recede ()) ^ "[unassigned]" ^ Ansi.reset ]
              | [ one ] ->
                  let stats = keeper_assignment_activity lane_keepers in
                  [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" one.k_name stats ^ Ansi.reset ]
              | many ->
                  let stats = keeper_assignment_activity lane_keepers in
                  let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) many) in
                  [ (Theme.info ()) ^ Printf.sprintf "[assigned: %s%s]" names stats ^ Ansi.reset ]
            else []
          in
          let lane_fact =
            (* [Lane_undeclared] reads like a one-candidate lane on the wire --
               one candidate, first position -- so until this row said so there
               was nothing on the surface telling them apart. A declared lane
               of one candidate has no next candidate either; what separates this
               one is that [D] has no table to remove. *)
            match Masc_tui_types.runtime_lane_fact_of_row candidate with
            | Masc_tui_types.Lane_undeclared ->
              [ (Theme.recede ()) ^ "runtime, not a declared lane" ^ Ansi.reset ]
            | Masc_tui_types.Lane_single_candidate -> [ "single candidate" ]
            | Masc_tui_types.Lane_head -> [ "head" ]
            | Masc_tui_types.Lane_fallback position ->
              [ Printf.sprintf "fallback #%d" position ]
          in
          let default_fact = if runtime.ro_is_default then [ (Theme.ok ()) ^ "[default]" ^ Ansi.reset ] else [] in
          (* The detail column leads with the lane fact. When it does not fit,
             Enter still opens the complete candidate reading. *)
          let detail =
            String.concat " \xc2\xb7 "
              (lane_fact @ assignment_fact @ default_fact
               @ runtime_probe_detail candidate.rcr_probe)
          in
          let line = "  " ^ Masc_tui_table.row
            (table_cells ~lane:lane_cell
              ~lane_is_label:(candidate.rcr_candidate_count > 1 && not is_first)
              ~candidate:candidate_label ~identity:provider_model ~status:route_probe
              ~detail:(Terminal_text.single_line (Masc_tui_theme.strip_sgr detail))) in
          if index + scroll = state.runtime_cursor then
            c.push_selected (Masc_tui_theme.strip_sgr line)
          else if Masc_tui_types.runtime_row_deemphasized state runtime then
            c.push_styled ~style:(Theme.recede ()) (Masc_tui_theme.strip_sgr line)
          else c.push line
    done;
)
;;

let render_runtime_parent state ~terminal_rows ~cols projection =
  let ko = state.ui_language = Lang_ko in
  let text korean english = if ko then korean else english in
  let title = match projection.rpp_parent with
    | Runtime_media_parent -> text "미디어 호출 순서" "Media call order"
    | Runtime_prompt_parent (Lane_name_prompt _) -> text "Runtime / 새 경로 이름" "Runtime / new lane name"
    | Runtime_prompt_parent (Lane_rename_prompt (lane, _)) ->
        text "이름 변경 / " "Rename / " ^ Terminal_text.single_line lane
    | Runtime_prompt_parent (Lane_remove_prompt lane) ->
        text "제거 확인 / " "Remove / " ^ Terminal_text.single_line lane in
  let header = if projection.rpp_notices = 0 then
    here_row ~cols state ~path:[ title ] ~readings:[] ~position:None
  else
    let door = match projection.rpp_parent with
      | Runtime_media_parent | Runtime_prompt_parent (Lane_remove_prompt _) -> "v"
      | Runtime_prompt_parent (Lane_name_prompt _ | Lane_rename_prompt _) -> "PgUp" in
    let lead = Printf.sprintf (if ko then "안내 %d · %s · " else "%d notices · %s · ")
        projection.rpp_notices door in
    let width = framed_inner_width cols in
    let available = max 0 (width - Message_layout.display_width lead) in
    let connection = match reading_connection_notice state with
      | None -> ""
      | Some _ -> reading_connection_summary
          ~width:(max 0 (available - Message_layout.display_width " ")) state |> String.trim in
    let connection = if Message_layout.display_width connection = 0 then "" else connection in
    let separator = if String.equal connection "" then "" else " " in
    let label_width = max 0 (available - Message_layout.display_width (separator ^ connection)) in
    (* Own notice count/reader key survive a one-row body even when a global
       connection warning also needs the title. Identity uses what is left. *)
    screen_title lead ^ Message_layout.fit_middle label_width title ^ separator ^ connection in
  let position = match projection.rpp_position with
    | None -> ""
    | Some position -> Printf.sprintf "[%s]  " position in
  let hints = position ^ Masc_tui_keys.footer_hints_runtime_parent
      ~ko ~parent:projection.rpp_parent in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols
    ~surface_key:"runtime-parent"
    ~title:header ~hints
    ~body:(fun ~budget:_ c ->
      List.iter (function
        | Parent_focus line -> c.push_selected line
        | Parent_text line -> c.push line
        | Parent_notice (Some notice, line) -> c.push_styled ~style:(runtime_lane_notice_style notice) line
        | Parent_notice (None, line) -> c.push_styled ~style:(Theme.warn ()) line)
        projection.rpp_rows)

(* The active picker or parent owns the body; the inactive listing cannot
   consume its input, selected-slot or diagnostic row budget. *)
let render_runtime (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let page = runtime_exact_picker_page state ~terminal_rows ~cols in
  match runtime_picker_projection ~page state with
  | None ->
      (match runtime_parent_projection state ~terminal_rows ~cols with
       | None -> render_runtime_reading state
       | Some projection -> render_runtime_parent state ~terminal_rows ~cols projection)
  | Some picker ->
      let ko = state.ui_language = Lang_ko in
      let notices = runtime_picker_notices state in
      let notes = runtime_picker_notice_rows ~cols state in
      let hints =
        Masc_tui_keys.footer_hints_runtime ~lang:state.ui_language
          ~mode:state.runtime_mode ~picker:(Some picker)
      in
      surface_chrome ~overflow:Fits state ~terminal_rows ~cols
        ~surface_key:"runtime" ~title:(runtime_picker_title ~ko ~notices picker.rlp_pick)
        ~hints ~body:(fun ~budget c ->
          let choices = runtime_picker_choice_rows picker in
          (* With just one body row the selected candidate takes it. With
             room, the filter/count precedes the same cursor-following page. *)
          let primary =
            if budget > 1 then
              ((Theme.info ()) ^ "  " ^ picker.rlp_summary ^ Ansi.reset) :: choices
            else choices
          in
          let visible = List.take budget primary in
          List.iter c.push visible;
          let remaining = budget - List.length visible in
          let count = List.length notes in
          List.iteri
            (fun index row ->
              let row =
                if count > remaining && index = remaining - 1 then
                  "… " ^ row
                else row
              in
              c.push_styled ~style:(Theme.warn ()) row)
            (List.take remaining notes))
;;

let tools_scrolled state =
  let terminal_rows, cols = get_terminal_size () in
  tools_scrolled_for_lines state (Render_tools.tools_display_lines ~cols ~terminal_rows state)
;;

let render_tools (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let header =
    here_row ~cols state
      ~path:[ ui_text state ~ko:"도구·스킬" ~en:"tools & skills" ]
      ~readings:[] ~position:None
  in
  box_top buf cols;
  box_line buf cols header;
  box_line buf cols (" " ^ Render_tools.tools_pane_strip ~cols state);
  box_line_styled buf cols ~style:Theme.selection
    (Render_tools.tools_selection_line ~cols state);
  box_divider buf cols;
  (match (selected_tools_error state) with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let display_lines = Render_tools.tools_display_lines ~cols ~terminal_rows state in
  let layout = tools_scrolled_for_lines state display_lines in
  let drawable = layout.sc_count in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:drawable ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (drawable - content_height) in
  let scroll = max 0 (min (tools_task_render_scroll state) max_scroll) in
  frame_tools_task := Option.map (fun owner ->
    {ttf_owner=owner; ttf_count=drawable; ttf_height=content_height;
     ttf_offset=scroll; ttf_waiting=tools_task_waiting state ~source:owner.tto_source ~cols;
     ttf_cols=cols}) (tools_task_display_owner state);
  let display_lines_window = Rows.of_list ~first:scroll ~height:content_height display_lines in
  for i = 0 to content_height - 1 do
    match Rows.at display_lines_window (i + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  if drawable > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "  [rows %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height drawable));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_tools ~lang:state.ui_language ~pane:state.tools_pane));
  finish_surface state ~surface_key:"tools" ~rows:terminal_rows ~cols buf


let provider_history_lines ~cols ~rows (state : state) =
  match usage_history_reading state with
  | Provider_history_unread ->
      [ Printf.sprintf " Quota scope trend (%d UTC days) · not observed"
          state.provider_history_days ]
  | Provider_history_error reason ->
      [ Printf.sprintf " Quota scope trend (%d UTC days) · unavailable: %s"
          state.provider_history_days (Terminal_text.single_line reason) ]
  | Provider_history_read trend ->
      let days = trend.Masc_tui_usage_trend.days in
      let as_of = Unix.gmtime trend.generated_at in
      let scopes =
        match state.overview_providers with
        | Providers_read reading -> reading.puws_accounts
        | Providers_unread | Providers_failed _ -> []
      in
      let label scope_id =
        match List.find_opt
                (fun account ->
                  String.equal (Overview_providers.scope_id account) scope_id)
                scopes with
        | None ->
            "scope "
            ^ Terminal_text.single_line
                (String.sub scope_id 0
                   (min Overview_providers.scope_id_cells
                      (String.length scope_id)))
        | Some account -> Overview_providers.scope_name account
      in
      let frame_width = max 1 (framed_inner_width cols) in
      (* Drop the card before its border would split every daily date. *)
      let card_chrome = 4 in
      let minimum_content = String.length "0000-00-00" in
      let indent = min 3 (max 0 (frame_width - card_chrome - minimum_content)) in
      let width = frame_width - indent in
      let text = Overview_providers.text_for_viewport ~columns:width ~rows in
      let minimum_card_cells = max 64 (7 + days * 2 + 4) in
      let paired = width >= 2 * minimum_card_cells + 2 in
      let card_width = if paired then (width - 2) / 2 else width in
      let bare = card_width < card_chrome + minimum_content in
      let inner = if bare then card_width else card_width - card_chrome in
      let wrap text = Message_layout.wrap_words ~max_cells:inner text in
      (* Keep the reported value round-trippable without filling the usual
         short decimals with binary noise or multiplying a fraction to overflow. *)
      let float_text value =
        let short = Printf.sprintf "%.12g" value in
        if Float.equal (float_of_string short) value then short
        else Printf.sprintf "%.17g" value in
      let daily_value = function
        | None -> "no window sample"
        | Some { Masc_tui_usage_trend.report = Reported_no_windows; _ } ->
            "reported no windows"
        | Some { report = Measured (value, _); _ } ->
            match value with
            | Masc.Tui_decode_usage.Utilization_fraction value ->
                float_text value ^ " of limit"
            | Utilization_percent value -> Printf.sprintf "%d%%" value
            | Utilization_usd { used; limit = Some limit } ->
                Printf.sprintf "$%s / $%s" (float_text used) (float_text limit)
            | Utilization_usd { used; limit = None } ->
                Printf.sprintf "$%s (uncapped)" (float_text used) in
      let chart (row : Masc_tui_usage_trend.row) =
        let account = List.find_opt (fun account ->
          String.equal (Overview_providers.scope_id account) row.scope_id) scopes in
        let email = Option.bind account (Overview_providers.account_email
          ~account_emails:state.overview_account_emails) in
        let limit = Option.fold ~none:"" ~some:(fun id -> id ^ " ") row.limit_id in
        let latest = match Masc_tui_usage_trend.latest row with
          | None -> "No reports in this window"
          | Some sample ->
            let time = Unix.gmtime sample.observed_at in
            Printf.sprintf "Latest report %s · %02d-%02d %02d:%02d UTC"
              (daily_value (Some sample))
              (time.Unix.tm_mon + 1) time.Unix.tm_mday time.Unix.tm_hour time.Unix.tm_min in
        let name = text (label row.scope_id) in
        let full_name =
          if not bare && Message_layout.display_width name <= inner then []
          else wrap name
        in
        let daily =
          if not bare && not (Masc_tui_usage_trend.compact ~width:inner row) then []
          else
            "Daily values (UTC)" ::
            List.map (fun (day, sample) ->
              Printf.sprintf "%04d-%02d-%02d %s"
                (day.Unix.tm_year + 1900) (day.Unix.tm_mon + 1) day.Unix.tm_mday
                (daily_value sample))
              (Masc_tui_usage_trend.dated_samples trend row)
            |> List.concat_map wrap in
        let body = full_name @ wrap (Terminal_text.single_line limit ^ Terminal_text.single_line row.kind)
          @ (match email with None -> [] | Some email -> wrap email)
          @ wrap latest
          @ Masc_tui_usage_trend.plot ~width:inner trend row
          @ daily
          @ wrap (Printf.sprintf "%d/%d UTC days reported" row.reported_days days) in
        let heading = Message_layout.truncate_middle inner name in
        let line text = Theme.recede () ^ Ansi.box_v ^ Ansi.reset ^ " "
          ^ Message_layout.fit_width text inner ^ " " ^ Theme.recede () ^ Ansi.box_v ^ Ansi.reset in
        if bare then body else
          (Theme.info () ^ Ansi.box_tl ^ " " ^ Ansi.bold ^ heading ^ Ansi.reset ^ Theme.info ()
           ^ " " ^ draw_hline (max 0 (card_width - Message_layout.display_width heading - 4))
           ^ Ansi.box_tr ^ Ansi.reset)
          :: List.map line body
          @ [Theme.recede () ^ Ansi.box_bl ^ draw_hline (max 0 (card_width - 2)) ^ Ansi.box_br ^ Ansi.reset]
      in
      let prefix = String.make indent ' ' in
      let rec arrange = function
        | [] -> []
        | left :: right :: rest when paired ->
          let left = chart left and right = chart right in
          let height = max (List.length left) (List.length right) in
          let row lines index = Option.value ~default:(String.make card_width ' ') (List.nth_opt lines index) in
          List.init height (fun index -> prefix ^ row left index ^ "  " ^ row right index)
          @ [""] @ arrange rest
        | row :: rest -> List.map (fun line -> prefix ^ line) (chart row) @ [""] @ arrange rest in
      let first = Unix.gmtime (trend.generated_at -. float_of_int (days - 1) *. 86400.0) in
      (Printf.sprintf
         " Quota scope trend (%d UTC days) · latest report per day · as of %02d-%02d %02d:%02d UTC"
         days (as_of.Unix.tm_mon + 1) as_of.Unix.tm_mday as_of.Unix.tm_hour as_of.Unix.tm_min)
      :: Printf.sprintf " %02d-%02d → %02d-%02d UTC · 0–100%% used · 0 = reported zero · · = no report · ○ = reported no windows · $ = uncapped USD use"
           (first.Unix.tm_mon + 1) first.Unix.tm_mday (as_of.Unix.tm_mon + 1) as_of.Unix.tm_mday
      :: " ↓ below zero · ↑ above limit"
      :: (match trend.unreadable_reports with
          | 0 -> []
          | count -> [Printf.sprintf "   %d stored reports could not be read%s; missing days stay absent" count
              (if Option.is_some state.usage_scope_id then " (whole history)" else "")])
      @ (match trend.rows with
         | [] -> [if Option.is_some state.usage_scope_id then "   No reports for the selected account in this window"
                  else "   No reports recorded in this window"]
         | rows -> arrange rows)

let usage_lines ~cols ~rows (state : state) =
  let open Masc.Tui_decode_usage in
  let text = Overview_providers.text_for_viewport ~columns:(framed_inner_width cols) ~rows in
  let scopes () =
    match Overview_providers.section_cards
            ~providers:(usage_providers_reading state) ~runtimes:state.overview_quota
            ~account_emails:state.overview_account_emails
            ~show_limit_exhausted:state.usage_show_limit_exhausted
            ~now:(Unix.gettimeofday ()) ~width:(max 1 (framed_inner_width cols)) ~rows with
    | Some section -> section.lines
    (* [section] answers [None] only before the first read. *)
    | None -> [ui_text state ~ko:" 계정 한도 미관측" ~en:" Plan usage · not observed"]
  in
  let keepers () =
    match state.keeper_usage with
    | Keeper_usage_unread -> [ " Keeper usage (24h) · not observed" ]
    | Keeper_usage_error reason ->
        [ " Keeper usage (24h) · unavailable: " ^ Terminal_text.single_line reason ]
    | Keeper_usage_read { kuw_rows; kuw_window_minutes; kuw_generated_at } ->
        let readable row = match row.kur_coverage with
          | Keeper_usage_failed _ | Keeper_usage_partial _ -> false
          | Keeper_usage_complete -> true
        in
        let token_value row = Option.map float_of_int row.kur_tokens in
        let cost_value row = row.kur_cost_usd in
        let valid value = Float.is_finite value && value >= 0. in
        let count = Masc_tui_value.Count.grouped in
        let largest value = List.fold_left
            (fun highest row ->
              if readable row then
                match value row with
                | Some amount when valid amount ->
                    Some (Option.fold ~none:amount ~some:(max amount) highest)
                | _ -> highest
              else highest) None kuw_rows in
        let token_max = largest token_value and cost_max = largest cost_value in
        let scale value format = function
          | Some amount -> format amount
          | None when List.exists (fun row ->
              Option.fold ~none:false ~some:valid (value row)) kuw_rows ->
              "unavailable (no complete window)"
          | None -> "unreported"
        in
        let width = max 1 (framed_inner_width cols - 3) in
        let tokens_text row = Option.fold ~none:"unreported" ~some:count row.kur_tokens in
        let cost_text row =
          Option.fold ~none:"unreported" ~some:(Printf.sprintf "$%.4f") row.kur_cost_usd in
        let metric_text label value reported missing =
          Printf.sprintf "%s %s · %s reported, %s missing" label value (count reported) (count missing)
        in
        let widest_metric = List.fold_left (fun widest row ->
          let width_of label text reported missing value =
            match value row with
            | Some amount when readable row && valid amount ->
                Message_layout.display_width (metric_text label text reported missing)
            | _ -> 0
          in
          max widest (max
            (width_of "Tokens" (tokens_text row) row.kur_tokens_reported row.kur_tokens_missing token_value)
            (width_of "Cost" (cost_text row) row.kur_cost_reported row.kur_cost_missing cost_value)))
          0 kuw_rows in
        (* One width per metric set keeps the relative bars comparable. *)
        let beside = width - widest_metric - 4 in
        let bar_cells =
          if beside >= Overview_providers.bar_cells_min then min 32 beside
          else min 32 (max 1 (width - 2)) in
        let meter value highest row =
          match value row with
          | Some amount when readable row && valid amount ->
              let maximum = Option.value ~default:0. highest in
              let share = if maximum = 0. then 0. else amount /. maximum in
              Some ("[" ^ Overview_providers.meter ~cells:bar_cells share ^ "]")
          | _ -> None
        in
        let generated = Unix.gmtime kuw_generated_at in
        [ Printf.sprintf " Keeper usage · last %s · recorded turn metrics"
            (Overview_providers.minutes_label kuw_window_minutes)
        ; Printf.sprintf " As of %04d-%02d-%02d %02d:%02d UTC"
            (generated.Unix.tm_year + 1900) (generated.Unix.tm_mon + 1)
            generated.Unix.tm_mday generated.Unix.tm_hour generated.Unix.tm_min
        ; " Bars: relative to largest read value per metric; not quota."
        ; " Partial rows: no bars. Missing values can understate totals."
        ; Printf.sprintf " Scale: tokens %s · cost %s"
            (scale token_value (fun value -> count (Float.to_int (Float.round value))) token_max)
            (scale cost_value (Printf.sprintf "$%.4f") cost_max)
        ; "" ]
        @ (if kuw_rows = [] then [ "   No Keepers in the returned roster" ]
            else List.concat_map
              (fun (row : Masc.Tui_decode_usage.keeper_usage_row) ->
                let tokens = tokens_text row in
                let cost = cost_text row in
                let coverage =
                  match row.kur_coverage with
                  | Keeper_usage_complete -> "read"
                  | Keeper_usage_partial { malformed_rows; unread_turn_rows } ->
                      Printf.sprintf "partial (%d malformed rows, %d unread turn rows) · reported totals are lower bounds"
                        malformed_rows unread_turn_rows
                  | Keeper_usage_failed reason ->
                      "unavailable: " ^ Terminal_text.single_line reason
                in
                let width = max 1 (framed_inner_width cols - 3) in
                let heading =
                  Theme.info () ^ Ansi.bold ^ text (Terminal_text.single_line row.kur_name)
                  ^ Ansi.reset ^ Printf.sprintf " · %s turns · %s" (count row.kur_turn_samples) coverage
                in
                let metric label value reported missing bar =
                  metric_text label value reported missing
                  ^ Option.fold ~none:"" ~some:(fun bar -> "  " ^ Theme.info () ^ bar ^ Ansi.reset) bar
                in
                List.concat_map
                    (fun line -> List.map (fun text -> "   " ^ text)
                        (Masc_tui_message_layout.wrap_styled_words ~max_cells:width line))
                    [ heading
                    ; metric "Tokens" tokens row.kur_tokens_reported row.kur_tokens_missing
                        (meter token_value token_max row)
                    ; metric "Cost" cost row.kur_cost_reported row.kur_cost_missing
                        (meter cost_value cost_max row)
                    ]
                @ [ "" ])
              kuw_rows)
  in
  let wrap_evidence lines =
    (* Wrap before the scroll window is counted. Coverage and missing samples
       remain reachable rows on narrow terminals. *)
    let width = max 1 (framed_inner_width cols) in
    List.concat_map
      (fun line ->
        if String.equal line "" then [ "" ]
        else if Message_layout.display_width line <= width then [line]
        else
          let rec leading index =
            if index < String.length line && Char.equal line.[index] ' '
            then leading (index + 1) else index in
          let indent_cells = leading 0 in
          (* Do not let decoration consume the cells needed by a wide glyph. *)
          let indent = String.make (min indent_cells (max 0 (width - 2))) ' ' in
          let body = String.sub line indent_cells (String.length line - indent_cells) in
          Message_layout.split_styled_cells
            ~max_cells:(max 1 (width - String.length indent)) body
          |> List.map (fun text -> indent ^ text))
      lines
  in
  let selection_lines = match state.usage_scope_id, state.usage_section with
    | None, (Usage_plan | Usage_trend) -> []
    | (None | Some _), (Usage_keepers | Usage_calls) -> []
    | Some scope_id, (Usage_plan | Usage_trend) ->
        let accounts = match state.overview_providers with
          | Providers_unread | Providers_failed _ -> []
          | Providers_read reading -> reading.puws_accounts in
        let account = List.find_opt (fun account -> String.equal account.pua_scope_id scope_id) accounts in
        let label = Option.fold ~none:("scope " ^ scope_id)
            ~some:Overview_providers.scope_name account in
        let missing = match state.overview_providers, account with
          | Providers_read _, None -> ["Account absent from the current inventory; selection retained."]
          | Providers_read _, Some _ | (Providers_unread | Providers_failed _), _ -> [] in
        Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols))
          (String.concat "\n" (("Account · " ^ label ^ " · f:choose · a:all accounts") :: missing))
        @ [""] in
  match state.usage_section with
  (* Plan cards already have a cell-sized border and wrapped contents. *)
  | Usage_plan -> selection_lines @ wrap_evidence (scopes ())
  | Usage_trend -> selection_lines @ wrap_evidence (provider_history_lines ~cols ~rows state)
  | Usage_keepers ->
      let currency = match Masc_tui_candle.summary_lines ~now:(Unix.gettimeofday ()) state.candle_observation with
        | [] -> []
        | lines ->
            [ " " ^ Ansi.bold ^ "Candle · workspace supply" ^ Ansi.reset ]
            @ List.map (fun line -> "   " ^ Terminal_text.single_line line) lines
            @ [ Theme.recede () ^ draw_hline (framed_inner_width cols) ^ Ansi.reset ]
      in
      wrap_evidence (currency @ keepers ())
  (* Tool calls belong to the workspace, not to an account, so the account
     selection does not narrow them. *)
  | Usage_calls ->
      (match state.tool_series with
       | Tool_series_read calls ->
           Masc_tui_usage_calls.lines ~width:(max 1 (framed_inner_width cols)) ~rows calls
       | Tool_series_unread ->
           wrap_evidence
             (Masc_tui_usage_calls.note_lines ~days:state.provider_history_days
                "not observed")
       | Tool_series_error reason ->
           wrap_evidence
             (Masc_tui_usage_calls.note_lines ~days:state.provider_history_days
                ("unavailable: " ^ Terminal_text.single_line reason)))

let render_metrics (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The section being read is marked on the strip under this row, so the
     title does not name it a second time. *)
  let heading =
    screen_title
      (if state.usage_telemetry_open then
         ui_text state ~ko:" 운영 · 사용량 · 진단" ~en:" Operations · Usage · Telemetry"
       else ui_text state ~ko:" 운영 · 사용량" ~en:" Operations · Usage")
  in
  let connection = connection_badge state in
  let full_title = Printf.sprintf "%s  %s" heading connection in
  let width = framed_inner_width cols in
  let title, connection_rows =
    if Message_layout.display_width full_title <= width then full_title, []
    else
      let summary, details =
        match compact_connection_state state with
        | Compact_http Connected ->
            let name = screen_title
                (if state.usage_telemetry_open then ui_text state ~ko:"진단" ~en:"Telemetry"
                 else ui_text state ~ko:"사용량" ~en:"Usage") in
            let available = width - Message_layout.display_width name - 1 in
            let status, details = compact_connection_badge state ~width:available in
            if Message_layout.display_width status <= available then name ^ " " ^ status, details
            else compact_connection_badge state ~width
        | Compact_workspace_mismatch | Compact_workspace_unconfirmed | Compact_workspace_unread | Compact_read_failed
        | Compact_read_partial | Compact_read_interrupted | Compact_read_unfinished
        | Compact_reading | Compact_http (Degraded | Connecting | Booting | Disconnected) ->
            compact_connection_badge state ~width in
      let rows = Option.fold ~none:[] ~some:(fun details ->
        let wrap = Message_layout.split_styled_cells ~max_cells:(max 1 width) in
        wrap (ui_text state ~ko:"연결 상태" ~en:"Status") @ wrap details) details in
      summary, rows
  in
  (* The section's lines are formatted by the drawing, so the row it could
     start at is known only once it has. The body writes it here and the
     contract reads it back out. *)
  let drawn_metrics_scroll = ref state.metrics_scroll in
  let drawn_metrics_height = ref state.metrics_content_height in
  let drawn_metrics_card_rows = ref state.metrics_scroll_card_rows in
  surface_chrome
    ~overflow:(Self_scrolled (fun () ->
      Metrics_scroll { scroll = !drawn_metrics_scroll;
                       content_height = !drawn_metrics_height;
                       card_rows = !drawn_metrics_card_rows }))
    state ~terminal_rows ~cols ~surface_key:"metrics"
    ~title
    ~hints:(Masc_tui_keys.footer_hints_metrics
              ~lang:state.ui_language ~section:state.usage_section
              ~telemetry:state.usage_telemetry_open)
    ~body:(fun ~budget c ->
      if state.usage_telemetry_open then
        Metrics_page.render_metrics_body ~cols ~budget ~suffix_lines:connection_rows state
          ~report_scroll:(fun scroll height card_rows ->
            drawn_metrics_scroll := scroll;
            drawn_metrics_height := height;
            drawn_metrics_card_rows := Some card_rows)
          ~push:c.push ~push_styled:c.push_styled
          ~push_selected:c.push_selected ~push_divider:c.push_divider
          ~push_empty:c.push_empty
      else begin
        (* The four sections go through the strip every other screen draws: a
           mark on the one being read, the rest dim, and a count where a narrow
           row has to hold sections back. The screen title does not name the
           section, so the section being read outranks the hint on this row. *)
        let usage_label = function
          | Usage_plan -> ui_text state ~ko:"계정 한도" ~en:"Plan"
          | Usage_trend -> ui_text state ~ko:"추이" ~en:"Trend"
          | Usage_keepers -> ui_text state ~ko:"키퍼" ~en:"Keepers"
          | Usage_calls -> ui_text state ~ko:"도구 호출" ~en:"Calls" in
        let usage_sections = [ Usage_plan; Usage_trend; Usage_keepers; Usage_calls ] in
        let usage_tabs reading =
          List.map (fun section -> (usage_label section, section = reading, ())) usage_sections in
        let draw_tabs ~width tabs = tab_strip ~width ~press:(fun () text -> text) tabs in
        let navigation =
          let lead = " "
          and wide_hint = ui_text state ~ko:"   v:다음 보기" ~en:"   v:next view"
          and compact_hint = ui_text state ~ko:"  v:다음" ~en:"  v:next" in
          let room hint = tab_strip_width ~cols ~before:lead ~after:hint in
          (* What gives way when the row is short, first to last: the long hint,
             the short hint, the neighbours and their counts. The section being
             read stays. The hint keeps its place only while the widest of the
             four strips still draws beside it, so it does not come and go as
             [v] moves between sections. *)
          let widest_floor =
            List.fold_left
              (fun widest section -> max widest (tab_strip_min_width (usage_tabs section)))
              0 usage_sections in
          let reading = usage_tabs state.usage_section in
          let hint =
            if Message_layout.display_width (draw_tabs ~width:max_int reading) <= room wide_hint
            then wide_hint
            else if widest_floor <= room compact_hint then compact_hint
            else "" in
          let strip = draw_tabs ~width:(room hint) reading in
          (* Below the cells the neighbours' counts need, the strip draws
             nothing; the section being read is then drawn alone. *)
          let strip =
            if strip <> "" then strip
            else
              draw_tabs ~width:(room hint)
                [ (usage_label state.usage_section, true, ()) ] in
          lead ^ strip ^ hint
        in
        (* Keep one navigation row so page movement still matches the body height. *)
        let navigation_rows = if budget >= 3 then 1 else 0 in
        let spacing_rows = if budget >= 6 then 1 else 0 in
        if navigation_rows > 0 then c.push navigation;
        if spacing_rows > 0 then
          c.push (if connection_rows = [] then ""
                  else Theme.recede ()
                    ^ ui_text state ~ko:"End: 연결 상태" ~en:"End: status" ^ Ansi.reset);
        let content_budget = max 0 (budget - navigation_rows - spacing_rows) in
        (* Put variable-length status details after account rows: refreshes do
           not move the account the reader is already scrolling through. *)
        let lines = usage_lines ~cols ~rows:content_budget state @ connection_rows in
        let overflow_rows = if content_budget >= 2 && List.length lines > content_budget then 1 else 0 in
        let height = content_budget - overflow_rows in
        let max_scroll = max 0 (List.length lines - height) in
        let scroll = min max_scroll (max 0 state.metrics_scroll) in
        drawn_metrics_scroll := scroll;
        drawn_metrics_height := height;
        drawn_metrics_card_rows := Some 0;
        List.iteri
          (fun index line ->
            if index >= scroll && index < scroll + height then c.push line)
          lines;
        if overflow_rows > 0 then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf (if state.ui_language = Lang_ko then
                 "  [줄 %s · j/k:스크롤]" else "  [rows %s · j/k to scroll]")
               (Masc_tui_scroll.window_text ~scroll ~height
                  (List.length lines)))
      end)

(** Render the runtime picker: the dispatchable catalogue, with the keeper it
    is choosing for and where that keeper points today in the header. *)
(* Through the surface contract. Drawn by hand, the frame spent [rows - 7] on
   its rows and did not count the failure or loading row above the options, so
   the footer stood one row above the composer, or two once the list filled.
   Its failure row was a seventh spelling of [data_unreliable_row] with its own
   width, which padded the error and then cut the closing bracket off. Its
   footer named the keys "assign", "back to default" and "cancel" where the key
   table and the help sheet say "choose", "use the default" and "back". *)
let render_runtime_pick (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let keeper_name =
    Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
      state.runtime_pick_keeper
  in
  let current =
    match
      List.find_opt
        (fun (a : Tui_decode.runtime_assignment) ->
          match state.runtime_pick_keeper with
          | Some keeper -> String.equal a.ra_keeper keeper
          | None -> false)
        state.runtime_assignments
    with
    | Some a -> runtime_assignment_label a
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let items = Masc_tui_types.runtime_picker_items state in
  (* The columns are measured over every item, not the filtered window, so
     typing a filter does not move them. *)
  let target_width, route_width =
    Masc_tui_types.runtime_pick_column_widths ~cols items
  in
  let view = Masc_tui_types.keeper_runtime_picker_view state ~terminal_rows in
  let current_id = Masc_tui_types.runtime_pick_current_id state in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"runtime-pick"
    ~title:
      (here_row ~cols state
         ~path:[ keeper_name; runtime_step state ]
         ~readings:
           [ Ansi.dim ^ ui_text state ~ko:"지금: " ~en:"current: " ^ current
             ^ Ansi.reset ]
         ~position:None)
    ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language (Keepers Keeper_runtime_pick))
    ~body:(fun ~budget:_ c ->
      c.push_styled ~style:(Theme.info ())
        ("  " ^ Masc_tui_types.keeper_runtime_picker_summary view
          ^ Masc_tui_types.runtime_catalog_reading_suffix state.runtime_catalog_reading);
      (match state.runtime_catalog_reading, Masc_tui_types.keeper_runtime_picker_empty_note ~reading:state.runtime_catalog_reading view with
       | Runtime_catalog_failed err, _ -> c.push (data_unreliable_row ~cols err)
       | (Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_read
          | Runtime_catalog_refreshing _ | Runtime_catalog_stale _), Some note -> c.push (Ansi.dim ^ note ^ Ansi.reset)
       | (Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_read
          | Runtime_catalog_refreshing _ | Runtime_catalog_stale _), None ->
           (* The first header cell spans badge and target, as the rows
              do. *)
           let header =
             Printf.sprintf "  %s  %s  %s"
               (fit_width "KIND   TARGET"
                  (Masc_tui_types.runtime_pick_badge_cells + target_width))
               (fit_width "CONFIGURED ROUTE / MODEL" route_width)
               (fit_width "PROPERTIES / CANDIDATES"
                  (Masc_tui_types.runtime_pick_properties_room ~cols
                     ~target:target_width ~route:route_width))
           in
           c.push (Ansi.dim ^ header ^ Ansi.reset));
      List.iteri
        (fun row item ->
          let line =
            (* The target column draws ids, and an id tells its neighbours
               apart at both ends: [claude_code.claude-sonnet-5-low] and
               [-high] share everything but the last four cells, which a
               head-keeping cut drops. [fit_middle] keeps both ends, which
               is what it says it is for. *)
            let columns = Masc_tui_types.runtime_pick_columns item in
            let badge_style =
              match item with
              | Masc_tui_types.Pick_lane _ -> Ansi.cyan
              | Masc_tui_types.Pick_model _ -> Ansi.dim
            in
            let badge =
              badge_style
              ^ fit_width columns.Masc_tui_types.rpc_badge
                  Masc_tui_types.runtime_pick_badge_cells
              ^ Ansi.reset
            in
            let target =
              Message_layout.fit_middle target_width columns.Masc_tui_types.rpc_target
            in
            let route_col =
              Message_layout.fit_middle route_width columns.Masc_tui_types.rpc_route
            in
            let facts =
              Masc_tui_types.runtime_pick_visible_facts ~cols item
              |> List.map (fun (fact : Masc_tui_types.runtime_pick_fact) ->
                   if fact.rpf_warn
                   then (Theme.warn ()) ^ fact.rpf_text ^ Ansi.reset
                   else fact.rpf_text)
              |> String.concat " "
            in
            Printf.sprintf "%s%s  %s  %s" badge target route_col facts
          in
          if view.Masc_tui_pick_list.selected_row = Some row then
            c.push_selected ("> " ^ Masc_tui_theme.strip_sgr line)
          else
            (* The Keeper's own assignment is starred; the cursor row keeps
               its [>], and the title still names the assignment. *)
            let current =
              Option.equal String.equal current_id
                (Some (Masc_tui_types.runtime_pick_item_id item))
            in
            c.push ((if current then "* " else "  ") ^ line))
        view.Masc_tui_pick_list.rows)
