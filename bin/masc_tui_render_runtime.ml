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
    | Runtime_probe_served_stale -> field_stale ~ko, (Theme.warn ())
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
    | Runtime_probe_no_http_runtimes | Runtime_probe_warming -> Theme.recede ()
    | Runtime_probe_degraded -> (Theme.warn ())
    | Runtime_probe_unreachable -> (Theme.bad ())
  in
  style ^ runtime_overall_label ~ko status ^ Ansi.reset

(* A value the row could not read is one mark (RFC tui-one-screen-grammar
   6.4): not read yet, the read failed, or read and not reported. Why is the
   selected row's detail and the page's own status. *)
let unknown_cell unknown = Theme.recede () ^ Masc_tui_value.Unknown.glyph unknown ^ Ansi.reset

(* The call side of the row: each refusal in warn, else [—] when none is
   recorded and the account usage reads none spent, else the mark of the
   usage that could not be read. A row that reads as it should recedes, so a
   refusal stands out (RFC tui-one-screen-grammar 7.3). *)
let runtime_route_badge state (runtime : Masc.Tui_decode.runtime_option) =
  let ko = state.ui_language = Lang_ko in
  let warn label = Option.map (fun text -> Theme.warn () ^ text ^ Ansi.reset) label in
  let usage = runtime_usage_reading state runtime in
  let spent = match usage with
    | Ok (_ :: _) when runtime_quota_rest_says_spent runtime -> None
    | Ok (_ :: _) -> Some (Theme.warn () ^ (if ko then "계정 한도 소진" else "account limit spent") ^ Ansi.reset)
    | Ok [] | Error _ -> None in
  match
    List.filter_map Fun.id
      [ warn (runtime_credential_refused_label ~ko runtime)
      ; warn (runtime_quota_label ~ko runtime); warn (runtime_rate_limit_label ~ko runtime)
      ; spent ]
  with
  | _ :: _ as badges -> String.concat " " badges
  | [] ->
      (match usage with
       | Ok _ -> Theme.recede () ^ Masc_tui_theme.Glyph.no_value ^ Ansi.reset
       | Error unknown -> unknown_cell unknown)

let runtime_probe_badge state = function
  | None -> unknown_cell (runtime_probe_missing state)
  | Some (probe : Masc.Tui_decode_runtime_probe.runtime_provider_probe) ->
      let ko = state.ui_language = Lang_ko in
      let open Masc.Tui_decode_runtime_probe in
      let style =
        match probe.rpp_status with
        | Runtime_provider_reachable -> (Theme.ok ())
        | Runtime_provider_skipped_cli
        | Runtime_provider_skipped_native_auth
        | Runtime_provider_refused -> Theme.recede ()
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
  runtime_route_badge state runtime ^ " / " ^ runtime_probe_badge state probe

let runtime_probe_detail ~ko = function
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
        Some
          ((if ko then "확인 " else "checked ")
           ^ Terminal_text.clock_timestamp probe.rpp_checked_at)
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

let runtime_table_layout ~ko ~cols ~status_cells ~mode ~lane ~lane_is_label ~candidate ~identity ~status ~detail =
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
  let cells =
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
  in
  (cells, layout.dropped, inner_width)

let runtime_table_cells ~ko ~cols ~status_cells ~mode ~lane ~lane_is_label ~candidate ~identity ~status ~detail =
  let cells, _, _ =
    runtime_table_layout ~ko ~cols ~status_cells ~mode ~lane ~lane_is_label
      ~candidate ~identity ~status ~detail
  in
  cells

let runtime_bool ~ko = function
  | true -> if ko then "예" else "yes"
  | false -> if ko then "아니오" else "no"

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
           (Masc_tui_types.runtime_lane_notice_text ~ko notice))
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
        @ fact (text "설정 원본" "Source") (Option.value resolved.rrs_config_path ~default:(text "보고 안 됨" "not reported"))
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
               (text "보고 안 됨" "not reported")
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
             (runtime_fact ~tone:Page_line.Attention
                (if ko then "런타임" else "Runtime")
                (if ko then "새로고침된 목록에 이 런타임 행이 더 이상 없습니다"
                 else "This runtime row is no longer present in the refreshed projection")))
  | Some (runtime, lanes, position, probe) ->
      let say korean english = if ko then korean else english in
      let fact = runtime_fact in
      let model_fields =
        fact (say "런타임 ID" "Runtime ID") runtime.ro_id
        @ fact (say "제공자" "Provider") runtime.ro_provider
        @ fact (say "모델" "Model") runtime.ro_model
        @ fact (say "적용 컨텍스트" "Effective context")
            (Printf.sprintf (if ko then "%s 토큰" else "%s tokens")
               (Masc_tui_value.Count.grouped runtime.ro_effective_max_context))
        @ fact (say "컨텍스트 출처" "Context source")
            (runtime_context_source_label runtime.ro_max_context_source)
        @ fact (say "최대 출력" "Max output")
            (match runtime.ro_max_output_tokens with
             | Some tokens ->
                 Printf.sprintf (if ko then "%s 토큰" else "%s tokens") (Masc_tui_value.Count.grouped tokens)
             | None -> say "미지정" "not specified")
        @ fact (say "로컬 런타임" "Local runtime")
            (runtime_bool ~ko runtime.ro_is_local)
      in
      let connection_fields =
        fact (say "연결 / 제공자 ID" "Connection / provider ID") runtime.ro_provider_id
        @ fact (say "쿼터 범위" "Quota scope") (runtime_quota_scope_label ~ko runtime)
        @ fact (say "응답 로컬 쿼터 범위" "Response-local quota scope")
            (Option.value ~default:(say "보고 안 됨" "not reported") runtime.ro_quota_scope)
      in
      let assignment_fields =
        (match position with
         | None -> []
         | Some (lane, at, total) ->
             (* The lane is named because "Used by lanes" below can now hold
                several, and a position without its lane is a place in an
                unnamed list. *)
             fact (say "레인 순번" "Lane position")
               (if ko then Printf.sprintf "%s 중 %d/%d번째" lane at total
                else Printf.sprintf "%d of %d in %s" at total lane))
        @ fact (say "사용 레인" "Used by lanes")
            (match lanes with [] -> say "미배정" "unassigned" | values -> String.concat ", " values)
        @ fact (say "기본 런타임" "Default runtime")
            (runtime_bool ~ko runtime.ro_is_default)
      in
      let quota =
        match runtime.ro_quota_rest with
        | None -> []
        | Some spent ->
            fact ~tone:Page_line.Attention (say "쿼터" "Quota")
              (Printf.sprintf "%s, %s"
                 (runtime_quota_cause_label spent.Runtime_quota_window.cause)
                 (runtime_quota_end_label spent.Runtime_quota_window.rest))
      in
      let rate_limit =
        match runtime.ro_rate_limited, runtime.ro_rate_limit_resets_at with
        | false, _ -> []
        | true, Some resets_at ->
          fact ~tone:Page_line.Attention (say "속도 제한" "Rate limit")
            (Printf.sprintf
               (if ko then "%s까지 또는 다음 성공 응답까지"
                else "until %s or the next successful answer")
               (runtime_moment_text resets_at))
        | true, None ->
          fact ~tone:Page_line.Attention (say "속도 제한" "Rate limit")
            (say "대기 시각 미지정 · 다음 성공 응답 시 해제"
               "no wait stated, cleared by the next successful answer")
      in
      let credential =
        match runtime.ro_credential_refused_at with
        | None -> []
        | Some at ->
          fact ~tone:Page_line.Attention (say "인증" "Credential")
            (Printf.sprintf
               (if ko then "%s 거부됨 · 호출 응답 성공 시 해제"
                else "refused %s, until a call on it is answered")
               (runtime_moment_text at))
      in
      let probe_lines =
        match probe with
        | None ->
            fact ~tone:Page_line.Quiet (say "프로브" "Probe")
              (runtime_unknown_words ~ko ~subject_ko:"결과" ~subject_en:"result"
                 (runtime_probe_missing state))
        | Some row ->
            let transport =
              match row.rpp_transport with
              | Runtime_probe_http -> "http"
              | Runtime_probe_cli -> "cli"
            in
            fact (say "프로브 상태" "Probe status")
              (runtime_probe_status_label ~ko row.rpp_status)
            @ fact (say "전송 방식" "Probe transport") transport
            @ (match row.rpp_latency_ms with
               | None -> []
               | Some value ->
                   fact (say "지연 시간" "Latency")
                     (Printf.sprintf "%.0fms" value))
            @ (match row.rpp_http_status with
               | None -> []
               | Some value ->
                   fact (say "HTTP 상태" "HTTP status")
                     (string_of_int value))
            @ fact (say "확인 시각" "Checked at")
                (Terminal_text.short_timestamp row.rpp_checked_at)
            (* No Reachable row: the decoder admits a probe only when its
               reachable flag agrees with its status, so the row could only
               repeat the status two rows above it -- "reachable" then
               "yes". *)
            @ (match runtime_probe_annotation ~status:row.rpp_status row.rpp_error with
               | None -> []
               | Some (Runtime_probe_note note) ->
                   fact ~tone:Page_line.Quiet (say "프로브 참고" "Probe note") note
               | Some (Runtime_probe_failure error) ->
                   fact ~tone:Page_line.Failure (say "프로브 오류" "Probe error") error)
      in
      let probe_limitations =
        match state.runtime_surface with
        | Some { rss_probe = Some snapshot; _ } ->
            runtime_items (say "프로브 한계" "Probe limitation") snapshot.rps_limitations
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
            fact ~tone:Page_line.Quiet (say "배정 키퍼" "Bound keepers") (say "없음" "none")
        | ks ->
            let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) ks) in
            let activity_str = match aggregate_keeper_stats ks with
              | None -> say "활동 보고 없음" "activity not reported"
              | Some (turns, tokens, cost) ->
                Printf.sprintf
                  (if ko then "%s턴 · %s 토큰 · %s" else "%s turns · %s tokens · %s")
                  (Masc_tui_value.Count.grouped turns) (format_context_tokens tokens) (Tui_decode.keeper_cost_summary cost)
            in
            fact (say "배정 키퍼" "Bound keepers") names
            @ fact (say "키퍼 누적 활동" "Keeper lifetime")
                (activity_str ^ say " · 전체 런타임 합산" " · across all runtimes")
      in
      let usage_lines =
        match state.runtime_surface with
        | None ->
            fact ~tone:Page_line.Quiet (say "계정 사용량" "Account usage")
              (say "조회 불가" "unavailable")
        | Some snapshot ->
          match runtime_spent_usage snapshot.rss_resolved runtime with
          | Error detail -> fact ~tone:Page_line.Quiet (say "계정 사용량" "Account usage")
              (Terminal_text.single_line detail)
          | Ok [] -> []
          | Ok windows ->
            fact ~tone:Page_line.Attention (say "계정 사용량" "Account usage")
              (say "모델 호출 한도가 소진되었습니다. 이 계정 보고서는 거부되는 개별 모델을 구분하지 않습니다."
                 "A model-call limit is spent; this account report does not identify which models are refused.")
            @ List.concat_map (fun (window : Masc.Tui_decode_usage.provider_usage_window) ->
                let limit = match window.puw_limit_id with
                  | Some id -> Terminal_text.single_line id
                  | None -> say "계정" "account" in
                let observed = runtime_moment_text window.puw_observed_at in
                fact ~tone:Page_line.Attention (say "소진된 한도" "Spent limit")
                  (Printf.sprintf
                     (if ko then "%s (%s 관측)" else "%s (observed %s)")
                     limit observed)) windows
      in
      let evidence_lines = match state.runtime_evidence with
        | None ->
            fact ~tone:Page_line.Quiet (say "런타임 이력" "Runtime history")
              (say "미조회" "not read")
        | Some (Error detail) ->
            fact ~tone:Page_line.Quiet (say "런타임 이력" "Runtime history") detail
        | Some (Ok evidence) ->
          Masc_tui_runtime_evidence.lines ~ko evidence ~runtime_id:runtime.ro_id
          |> List.concat_map (fun (label, value) -> fact label value) in
      let failed_attempt =
        match runtime.ro_failed_attempt with
        | None -> []
        | Some attempt ->
          fact ~tone:Page_line.Attention (say "최근 실패" "Last failure")
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
  let lines = runtime_detail_lines state target ~width:(max 1 (framed_inner_width cols - 4)) in
  let total = List.length lines in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.runtime_detail_scroll max_scroll) in
  box_top buf cols;
  box_line buf cols
    (here_row ~cols state ~path:[ runtime_step state; target_label ]
       ~readings:[]
       ~position:(Masc_tui_value.Position.window ~first:scroll ~shown:content_height ~total));
  box_divider buf cols;
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints_runtime_detail
            ~lang:state.ui_language
            ~routes:(target = Runtime_routes)));
  finish_surface state ~clamped:(Runtime_detail_scroll scroll)
    ~surface_key:"runtime-detail" ~rows:terminal_rows ~cols buf

(* The picker keeps the selected row at the head of its existing window.
   Optional exact-slot identity detail follows that same candidate. *)
let runtime_picker_choice_rows ~ko picker =
  let say korean english = if ko then korean else english in
  let rows = ref [] in
  let push ?(selected = false) row = rows := (selected, row) :: !rows in
  if picker.rlp_choices = [] then
    push
      (Masc_tui_types.runtime_picker_empty_note ~ko picker)
  else
    List.iteri (fun offset choice ->
      let selected = picker.rlp_selected_row = Some offset in
      let mark = if selected then "\xe2\x80\xba" else " " in
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
            then say "  (현재 경로)" "  (current route)" else "" in
          push ~selected
            (Printf.sprintf "  %s %s%s" mark
               label
               (if String.equal note "" then "" else Theme.recede () ^ note ^ Ansi.reset))
      | Masc_tui_types.Runtime_choice runtime ->
          let note =
            if List.exists (String.equal runtime.ro_id) picker.rlp_already
            then (match picker.rlp_pick with
              | Masc_tui_types.Pick_route_default -> say "  (현재 경로)" "  (current route)"
              | Pick_media_failover | Pick_conversation_lane _ | Pick_exact_lane _
              | Pick_exact_lane_replacement (_, _, _) | Pick_new_lane _ ->
                  say "  (이미 후보)" "  (already a candidate)")
            else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
            then say "  (현재 후보와 같은 제공자)" "  (same provider as a current candidate)"
            else ""
          in
          let ctx =
            Printf.sprintf " [%s %s]"
              (format_context_tokens runtime.ro_effective_max_context)
              (match picker.rlp_pick with
               | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ ->
                   say "컨텍스트" "context"
               | Pick_media_failover | Pick_route_default | Pick_conversation_lane _
               | Pick_new_lane _ -> "ctx")
          in
          let def = if runtime.ro_is_default then
            (match picker.rlp_pick with
             | Masc_tui_types.Pick_route_default -> say " [진입 런타임]" " [entry runtime]"
             | Pick_media_failover | Pick_conversation_lane _ | Pick_exact_lane _
             | Pick_exact_lane_replacement (_, _, _) | Pick_new_lane _ ->
                 say " [기본]" " [default]") else "" in
          push ~selected
            (Printf.sprintf "  %s %s%s%s%s" mark
               label
               ctx def
               (if String.equal note "" then "" else Theme.recede () ^ note ^ Ansi.reset));
          (match picker.rlp_pick with
           | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ ->
               push (say "      쿼터 범위 " "      Quota scope "
                 ^ Terminal_text.single_line (runtime_quota_scope_label ~ko runtime)
                 ^ say " · 연결 " " · Connection "
                 ^ Terminal_text.single_line runtime.ro_provider_id
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
    | [] -> if ko then " 런타임 › " else " Runtime › "
    | _ :: _ ->
        Printf.sprintf
          (if ko then "안내 %d개 · 닫고 v · 런타임 › " else "%d notices · close, v · Runtime › ")
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
             Printf.sprintf (if ko then "관측 %s" else "reading %s") (runtime_moment_text generated_at))
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
          | None -> (Theme.warn ()) ^ (if ko then "프로브 보고 안 됨" else "probe not reported") ^ Ansi.reset
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
  let now = Unix.gettimeofday () in
  let runtime_op =
    match state.runtime_lane_write with
    | Masc_tui_types.Lane_write_posting ->
        Some
          ( "lane-write-posting"
          , ui_text state ~ko:"런타임 경로 변경 저장 중" ~en:"Saving runtime lane change"
          , Some (ui_text state
              ~ko:"서버 설정 저장과 반영 영수증을 기다리고 있습니다"
              ~en:"Waiting for configuration save and receipt")
          , true )
    | Masc_tui_types.Lane_write_rereading _ ->
        Some
          ( "lane-write-rereading"
          , ui_text state ~ko:"런타임 상태 다시 읽는 중" ~en:"Reloading runtime state"
          , Some (ui_text state
              ~ko:"저장 후 최신 실행 상태를 확인하고 있습니다"
              ~en:"Verifying latest execution state after save")
          , false )
    | Masc_tui_types.Lane_write_idle ->
        if state.runtime_surface_force_pending then
          Some
            ( "force-probe"
            , ui_text state ~ko:"런타임 프로브 다시 실행 중" ~en:"Re-probing runtimes"
            , Some (ui_text state
                ~ko:"각 런타임 연결 상태를 새로 점검하고 있습니다"
                ~en:"Checking each runtime connection live")
            , false )
        else if Option.is_some state.runtime_surface_inflight then
          Some
            ( "surface-read"
            , ui_text state ~ko:"런타임 상태 읽는 중" ~en:"Reading runtime state"
            , Some (ui_text state
                ~ko:"구성된 레인과 런타임 프로브 결과를 불러오고 있습니다"
                ~en:"Loading configured lanes and runtime probe status")
            , false )
        else None
  in
  let runtime_op_started =
    Masc_tui_types.progress_clock_option state ~slot:"runtime-surface-op" ~now
      (Option.map (fun (tok, _, _, _) -> tok) runtime_op)
  in
  let progress_sheet =
    Option.map
      (fun (_, title, detail, blocking) ->
        { ps_title = title
        ; ps_detail = detail
        ; ps_started_at = runtime_op_started
        ; ps_meter = None
        ; ps_action_hint = None
        ; ps_blocking = blocking
        })
      runtime_op
  in
  let sheet_rows =
    let has_recovery =
      Option.is_some (recovery_slot state ~max_cells:(framed_inner_width cols))
    in
    let total_budget = max 1 (rows - chrome_rows_for ~frame:Chrome_screen ~has_recovery) in
    Option.fold ~none:0
      ~some:(progress_sheet_height ~available:total_budget ~cols:(framed_inner_width cols))
      progress_sheet
  in
  let effective_rows = max 1 (rows - sheet_rows) in
  let authority_rows = Masc_tui_types.runtime_authority_rows ~cols state in
  let selection_rows = runtime_selection_summary_for_viewport ~rows:effective_rows ~cols state in
  (* One measured status width for the whole reading, shared by the header and
     every row. A report that has several independent limits can still exceed
     the pane; full evidence stays in the selected summary or Enter's detail. *)
  let status_cells =
    (* Measured from the cell each row draws, so the column fits what it shows. *)
    let statuses = match state.runtime_mode with
      | Runtime_lanes -> List.map (fun row -> runtime_route_probe_badge state
          row.Tui_decode.rcr_runtime row.rcr_probe) candidates
      | Runtime_all -> List.map (fun (runtime, _) ->
          let probe = Option.bind state.runtime_surface (fun snapshot ->
            Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.rss_probe ~runtime_id:runtime.Tui_decode.ro_id) in
          runtime_route_probe_badge state runtime probe) all_runtimes in
    List.fold_left (fun width cell ->
      max width (Message_layout.display_width (Masc_tui_theme.strip_sgr cell))) 0 statuses in
  (* The budget counts the rows this screen draws, so it comes from the same
     call the drawing reads rather than a fixed one. *)
  let chrome_rows = runtime_surface_listing_chrome ~rows:effective_rows ~cols state in
  let content_height = max 0 (effective_rows - chrome_rows) in
  let cursor =
    if shown = 0 then 0 else max 0 (min state.runtime_cursor (shown - 1))
  in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.runtime_surface_scroll max_scroll) in
  let scroll =
    if content_height = 0 then scroll
    else if cursor < scroll then cursor
    else if cursor >= scroll + content_height
    then min max_scroll (cursor - content_height + 1)
    else scroll in
  let all_runtimes_window = Rows.of_list ~first:scroll ~height:content_height all_runtimes in
  report_drawn_list Runtime_rows ~height:content_height;
  let candidates_window = Rows.of_list ~first:scroll ~height:content_height candidates in
  let hints =
    Masc_tui_keys.footer_hints_runtime ~lang:state.ui_language
      ~mode:state.runtime_mode ~picker:None
  in
  surface_chrome ~overflow:Paged_by_cursor ?progress_sheet ~now state ~terminal_rows ~cols
    ~surface_key:"runtime" ~title:header ~hints
    ~body:(fun ~budget:_ c ->
  if shown > 0 then
    c.position
      (Masc_tui_value.Position.row ~selected:(Some cursor) ~total:shown);
  let authority_style =
    match state.runtime_surface with
    | Some snapshot when Option.is_some snapshot.rss_probe_error -> (Theme.warn ())
    | Some _ | None -> Theme.recede ()
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
         | None -> field_missing_reading ~ko:(state.ui_language = Lang_ko) ~error:None
         | Some _ -> Theme.recede () ^ Masc_tui_theme.Glyph.no_value ^ Ansi.reset
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
              | [], [] -> Theme.recede () ^ (if ko then "없음 · 비전 런타임 없음" else "none · no vision runtimes") ^ Ansi.reset
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
       if not (Masc_tui_types.runtime_media_row_folded ~rows:effective_rows ~cols state) then begin
         c.push
           (Printf.sprintf "  %s  %s  %s"
              (Theme.recede () ^ runtime_column runtime_lane_width "media_failover" ^ Ansi.reset)
              (runtime_column runtime_candidate_width media_text)
              (Theme.recede () ^ (if ko then "m:편집 · 비전 호출 순서" else "m edits it · the vision runtimes, in call order") ^ Ansi.reset));
         c.push_divider ()
       end);
  let header_cells, dropped_cols, table_inner_width =
    runtime_table_layout ~ko ~cols ~status_cells ~mode:state.runtime_mode
      ~lane:"" ~lane_is_label:false ~candidate:"" ~identity:"" ~status:"" ~detail:""
  in
  let table_cells = runtime_table_cells ~ko ~cols ~status_cells ~mode:state.runtime_mode in
  c.push_styled ~style:(Theme.recede ())
    ("  "
     ^ Masc_tui_table.header_row_with_dropped ~ko ~inner_width:table_inner_width
         ~dropped:dropped_cols header_cells);
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
               (Masc_tui_types.runtime_lane_notice_text ~ko notice)));
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
    if content_height > 0 then begin
      (match
         empty_page_of ~snapshot:state.runtime_surface
           ~error:state.runtime_surface_error
       with
       | Page_failed ->
           c.push_styled ~style:(Theme.recede ()) (page_failed_note ~ko)
       | Page_unread when Option.is_some state.runtime_surface_inflight ->
           c.push
             ("  " ^ progress_inline ~ko ~now ?started_at:runtime_op_started
                (ui_text state ~ko:"런타임 상태 읽는 중" ~en:"reading runtime state"))
       | Page_unread ->
           c.push_styled ~style:(Theme.recede ())
             (page_unread_note_while ~ko ~reading:false)
       | Page_empty ->
           c.push_styled ~style:(Theme.recede ())
             (match state.runtime_mode with
              | Masc_tui_types.Runtime_lanes ->
                  ui_text state ~ko:"  (설정된 런타임 후보 순서 없음)"
                    ~en:"  (no runtime candidate orders configured)"
              | Masc_tui_types.Runtime_all ->
                  ui_text state ~ko:"  (설정된 런타임 없음)" ~en:"  (no runtimes configured)"));
      for _ = 1 to content_height - 1 do
        c.push_empty ()
      done
    end
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
                 | [] ->
                     (Theme.recede ())
                     ^ (if ko then "미배정" else "unassigned")
                     ^ Ansi.reset
                 | [ one ] -> Terminal_text.single_line one
                 | many ->
                     Printf.sprintf
                       (if ko then "레인 %d개" else "%d lanes")
                       (List.length many)
               in
               let bound_keepers =
                 keepers_for_runtime_with_lanes state ~lanes runtime.ro_id
               in
               let default_fact =
                 if runtime.ro_is_default then
                   [ (Theme.ok ()) ^ (if ko then "[기본]" else "[DEFAULT]") ^ Ansi.reset ]
                 else []
               in
               let assignment_fact =
                 match bound_keepers with
                 | [] ->
                     [ (Theme.recede ()) ^ (if ko then "[배정 없음]" else "[no keepers]") ^ Ansi.reset ]
                 | [ one ] ->
                     let stats = Terminal_text.single_line (keeper_assignment_activity bound_keepers) in
                     [ (Theme.info ())
                       ^ Printf.sprintf
                           (if ko then "[배정: %s%s]" else "[assigned: %s%s]")
                           (Terminal_text.single_line one.k_name) stats
                       ^ Ansi.reset ]
                 | many ->
                     let stats = Terminal_text.single_line (keeper_assignment_activity bound_keepers) in
                     let names =
                       String.concat ", "
                         (List.map (fun (k : Tui_decode.keeper) -> Terminal_text.single_line k.k_name) many)
                     in
                     [ (Theme.info ())
                       ^ Printf.sprintf
                           (if ko then "[배정: %s%s]" else "[assigned: %s%s]")
                           names stats
                       ^ Ansi.reset ]
               in
               let detail =
                 String.concat " \xc2\xb7 "
                   (default_fact @ assignment_fact
                    @ (match lanes with
                       | [] -> []
                       | l -> [ String.concat ", " (List.map Terminal_text.single_line l) ])
                    @ runtime_probe_detail ~ko
                        (Option.bind state.runtime_surface (fun snapshot ->
                           Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id)))
               in
               let is_selected = index + scroll = cursor in
               let line = (if is_selected then "\xe2\x80\xba " else "  ") ^ Masc_tui_table.row
                 (table_cells ~lane:used_by ~lane_is_label:(lanes = [])
                   ~candidate:(Terminal_text.single_line runtime.ro_id)
                   ~identity:(Terminal_text.single_line (runtime.ro_provider ^ " / " ^ runtime.ro_model))
                   ~status:(runtime_route_probe_badge state runtime
                     (Option.bind state.runtime_surface (fun snapshot ->
                       Masc.Tui_decode_runtime_probe.runtime_probe_for_id snapshot.Masc.Tui_decode.rss_probe ~runtime_id:runtime.ro_id)))
                   ~detail) in
               if is_selected then
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
                ; (if ko then "예비" else "fallback")
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
              | [] -> [ (Theme.recede ()) ^ (if ko then "[미배정]" else "[unassigned]") ^ Ansi.reset ]
              | [ one ] ->
                  let stats = Terminal_text.single_line (keeper_assignment_activity lane_keepers) in
                  [ (Theme.info ())
                    ^ Printf.sprintf
                        (if ko then "[배정: %s%s]" else "[assigned: %s%s]")
                        (Terminal_text.single_line one.k_name) stats
                    ^ Ansi.reset ]
              | many ->
                  let stats = Terminal_text.single_line (keeper_assignment_activity lane_keepers) in
                  let names =
                    String.concat ", "
                      (List.map (fun (k : Tui_decode.keeper) -> Terminal_text.single_line k.k_name) many)
                  in
                  [ (Theme.info ())
                    ^ Printf.sprintf
                        (if ko then "[배정: %s%s]" else "[assigned: %s%s]")
                        names stats
                    ^ Ansi.reset ]
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
              [ (Theme.recede ())
                ^ (if ko then "선언된 레인 아님(단독 런타임)" else "runtime, not a declared lane")
                ^ Ansi.reset ]
            | Masc_tui_types.Lane_single_candidate ->
                [ if ko then "단일 후보" else "single candidate" ]
            | Masc_tui_types.Lane_head -> [ if ko then "우선" else "head" ]
            | Masc_tui_types.Lane_fallback position ->
              [ Printf.sprintf (if ko then "예비 #%d" else "fallback #%d") position ]
          in
          let default_fact =
            if runtime.ro_is_default then
              [ (Theme.ok ()) ^ (if ko then "[기본]" else "[default]") ^ Ansi.reset ]
            else []
          in
          (* The detail column leads with the lane fact. When it does not fit,
             Enter still opens the complete candidate reading. *)
          let detail =
            String.concat " \xc2\xb7 "
              (lane_fact @ assignment_fact @ default_fact
               @ runtime_probe_detail ~ko candidate.rcr_probe)
          in
          let is_selected = index + scroll = cursor in
          let line = (if is_selected then "\xe2\x80\xba " else "  ") ^ Masc_tui_table.row
            (table_cells ~lane:lane_cell
              ~lane_is_label:(candidate.rcr_candidate_count > 1 && not is_first)
              ~candidate:candidate_label ~identity:provider_model ~status:route_probe
              ~detail) in
          if is_selected then
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
    | Runtime_prompt_parent (Lane_name_prompt _) -> text "런타임 › 새 경로 이름" "Runtime › new lane name"
    | Runtime_prompt_parent (Lane_rename_prompt (lane, _)) ->
        text "이름 변경 › " "Rename › " ^ Terminal_text.single_line lane
    | Runtime_prompt_parent (Lane_remove_prompt lane) ->
        text "제거 확인 › " "Remove › " ^ Terminal_text.single_line lane in
  let header = if projection.rpp_notices = 0 then
    here_row ~cols state ~path:[ title ] ~readings:[] ~position:projection.rpp_position
  else
    let door = match projection.rpp_parent with
      | Runtime_media_parent | Runtime_prompt_parent (Lane_remove_prompt _) -> "v"
      | Runtime_prompt_parent (Lane_name_prompt _ | Lane_rename_prompt _) -> "PgUp" in
    let lead = Printf.sprintf (if ko then "안내 %d · %s · " else "%d notices · %s · ")
        projection.rpp_notices door in
    (* The parts share what the position leaves, so the cut never reaches
       the connection notice at the end. Own notice count/reader key survive
       a one-row body even when a global connection warning also needs the
       title. Identity uses what is left. *)
    zone_two_title ~cols state ~position:projection.rpp_position
      ~title:(fun ~cols ->
        let available =
          max 0 (framed_inner_width cols - Message_layout.display_width lead) in
        let connection = match reading_connection_notice state with
          | None -> ""
          | Some _ -> reading_connection_summary
              ~width:(max 0 (available - Message_layout.display_width " ")) state
              |> String.trim in
        let connection =
          if Message_layout.display_width connection = 0 then "" else connection in
        let separator = if String.equal connection "" then "" else " " in
        let label_width =
          max 0 (available - Message_layout.display_width (separator ^ connection)) in
        screen_title lead ^ Message_layout.fit_middle label_width title
        ^ separator ^ connection) in
  let hints = Masc_tui_keys.footer_hints_runtime_parent
      ~lang:state.ui_language ~parent:projection.rpp_parent in
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
          let choices = runtime_picker_choice_rows ~ko picker in
          (* With just one body row the selected candidate takes it. With
             room, the filter/count precedes the same cursor-following page. *)
          let primary =
            if budget > 1 then
              (false, (Theme.info ()) ^ "  " ^ picker.rlp_summary ^ Ansi.reset) :: choices
            else choices
          in
          let visible = List.take budget primary in
          List.iter
            (fun (selected, row) ->
              if selected then c.push_selected (Masc_tui_theme.strip_sgr row)
              else c.push row)
            visible;
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
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let volume_gc_op =
    match state.volume_gc.Masc_tui_volume_gc.phase with
    | Masc_tui_volume_gc.Reporting ->
        Some
          ( "reporting"
          , ui_text state ~ko:"샌드박스 볼륨 정리 보고 생성 중" ~en:"Scanning sandbox volumes"
          , Some (ui_text state
              ~ko:"은퇴한 키퍼 볼륨과 컨테이너 점유 상태를 확인하고 있습니다"
              ~en:"Inspecting retired keeper volumes and container claims")
          , false )
    | Masc_tui_volume_gc.Reclaiming ->
        Some
          ( "reclaiming"
          , ui_text state ~ko:"은퇴한 키퍼 볼륨 회수 중" ~en:"Reclaiming retired keeper volumes"
          , Some (ui_text state
              ~ko:"서버가 대상 볼륨을 재확인한 뒤 안전하게 정리하고 있습니다"
              ~en:"Server is re-checking candidate volumes and reclaiming them")
          , true )
    | Masc_tui_volume_gc.Idle | Masc_tui_volume_gc.Armed _ -> None
  in
  let volume_gc_started =
    Masc_tui_types.progress_clock_option state ~slot:"tools-volume-gc" ~now
      (Option.map (fun (tok, _, _, _) -> tok) volume_gc_op)
  in
  let volume_gc_sheet =
    Option.map
      (fun (_, title, detail, blocking) ->
        { ps_title = title
        ; ps_detail = detail
        ; ps_started_at = volume_gc_started
        ; ps_meter = None
        ; ps_action_hint = Some (ui_text state ~ko:"Esc:목록으로 (요청 계속됨)" ~en:"Esc:back (request continues)")
        ; ps_blocking = blocking
        })
      volume_gc_op
  in
  let header ~position =
    let readings =
      match volume_gc_sheet with
      | None -> []
      | Some sheet ->
          [ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title ]
    in
    here_row ~cols state
      ~path:[ ui_text state ~ko:"도구·스킬" ~en:"tools & skills" ]
      ~readings ~position
  in
  let display = Render_tools.tools_display ~cols ~terminal_rows state in
  let display_lines = display.lines in
  let layout = tools_scrolled_for_lines state display_lines in
  let drawable = layout.sc_count in
  let full_content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:drawable ~preview_keep:layout.sc_preview_keep
  in
  let sheet_lines =
    match volume_gc_sheet with
    | Some sheet ->
        render_progress_sheet ~ko ~now ~available:(max 0 (full_content_height - 1))
          ~width:(framed_inner_width cols) sheet
    | None ->
        let reserve =
          if full_content_height >= 16 then min 8 (full_content_height / 3)
          else 0
        in
        Render_tools.selected_skill_bottom_sheet ~cols ~height:reserve state
  in
  let content_height = max 0 (full_content_height - List.length sheet_lines) in
  let max_scroll = max 0 (drawable - content_height) in
  let scroll = max 0 (min (tools_task_render_scroll state) max_scroll) in
  Option.iter
    (fun (list, height) -> report_drawn_list list ~height)
    (Render_tools.drawn_page display ~rows:content_height);
  frame_tools_task := Option.map (fun owner ->
    {ttf_owner=owner; ttf_count=drawable; ttf_height=content_height;
     ttf_offset=scroll; ttf_waiting=tools_task_waiting state ~source:owner.tto_source ~cols;
     ttf_cols=cols}) (tools_task_display_owner state);
  box_line buf cols
    (header
       ~position:(Masc_tui_value.Position.window ~first:scroll ~shown:content_height ~total:drawable));
  box_line buf cols (" " ^ Render_tools.tools_pane_strip ~cols state);
  box_line_styled buf cols ~style:(Theme.recede ())
    (Render_tools.tools_selection_line ~cols state);
  box_divider buf cols;
  (match (selected_tools_error state) with
   | None -> ()
   | Some failure ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text
            (request_failure_text ~ko:(state.ui_language = Lang_ko)
               ~request:Kept_request.Tool_inventory_read failure));
       box_divider buf cols);
  let display_lines_window = Rows.of_list ~first:scroll ~height:content_height display_lines in
  Option.iter Masc_tui_value.Redraw.note_change_at
    (Render_tools.drawn_change display display_lines_window);
  let sel_style = Theme.selection_style () in
  for i = 0 to content_height - 1 do
    match Rows.at display_lines_window (i + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) ->
        if String.equal style sel_style then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
        else box_line_styled buf cols ~style line
  done;
  List.iter (box_line buf cols) sheet_lines;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_tools ~lang:state.ui_language ~pane:state.tools_pane
                 ~keys:(Masc_tui_list_moves.tools_keys state)));
  finish_surface state ~surface_key:"tools" ~rows:terminal_rows ~cols buf


let provider_history_lines ~cols ~rows (state : state) =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  match usage_history_reading state with
  | Provider_history_unread ->
      [ Printf.sprintf
          (if ko then " 쿼터 범위 추이 (%d일 UTC) · 미조회"
           else " Quota scope trend (%d UTC days) · not read")
          state.provider_history_days ]
  | Provider_history_error reason ->
      [ Printf.sprintf
          (if ko then " 쿼터 범위 추이 (%d일 UTC) · 조회 불가: %s"
           else " Quota scope trend (%d UTC days) · unavailable: %s")
          state.provider_history_days (Terminal_text.single_line reason) ]
  | Provider_history_read trend ->
      let days = trend.Masc_tui_usage_trend.days in
      let as_of = Masc_tui_value.Utc_day.of_moment trend.generated_at in
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
            say "범위 " "scope "
            ^ Message_layout.truncate_end Overview_providers.scope_id_cells
                (Terminal_text.single_line scope_id)
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
        | None -> say "구간 표본 없음" "no window sample"
        | Some { Masc_tui_usage_trend.report = Reported_no_windows; _ } ->
            say "보고된 구간 없음" "reported no windows"
        | Some { report = Measured (value, _); _ } ->
            match value with
            | Masc.Tui_decode_usage.Utilization_fraction value ->
                float_text value ^ say " / 한도" " of limit"
            | Utilization_percent value -> Printf.sprintf "%d%%" value
            | Utilization_usd { used; limit = Some limit } ->
                Printf.sprintf "$%s / $%s" (float_text used) (float_text limit)
            | Utilization_usd { used; limit = None } ->
                Printf.sprintf
                  (if ko then "$%s (상한 없음)" else "$%s (uncapped)")
                  (float_text used)
            | Utilization_credit_balance { currency; total; remaining } ->
                Overview_providers.utilization_text
                  (Masc.Tui_decode_usage.Utilization_credit_balance { currency; total; remaining })
            | Utilization_credit_unlimited -> say "크레딧 무제한" "Credit unlimited"
            | Utilization_credit_retracted -> say "크레딧 회수됨" "Credit retracted" in
      let chart (row : Masc_tui_usage_trend.row) =
        let unmetered_credit = Masc_tui_usage_trend.has_unmetered_credit row in
        let account = List.find_opt (fun account ->
          String.equal (Overview_providers.scope_id account) row.scope_id) scopes in
        let email = Option.bind account (Overview_providers.account_email
          ~account_emails:state.overview_account_emails) in
        let limit = Option.fold ~none:"" ~some:(fun id -> id ^ " ") row.limit_id in
        let latest = match Masc_tui_usage_trend.latest row with
          | None -> say "이 기간의 보고 없음" "No reports in this window"
          | Some sample ->
            Printf.sprintf
              (if ko then "최근 보고 %s · %s" else "Latest report %s · %s")
              (daily_value (Some sample)) (runtime_moment_text sample.observed_at) in
        let name = text (label row.scope_id) in
        let full_name =
          if not bare && Message_layout.display_width name <= inner then []
          else wrap name
        in
        let daily =
          if not bare && not unmetered_credit && not (Masc_tui_usage_trend.compact ~width:inner row) then []
          else
            say "일별 수치 (UTC)" "Daily values (UTC)" ::
            List.map (fun (day, sample) ->
              Masc_tui_value.Utc_day.date day ^ " " ^ daily_value sample)
              (Masc_tui_usage_trend.dated_samples trend row)
            |> List.concat_map wrap in
        let kind_label =
          let raw = Terminal_text.single_line row.kind in
          if String.equal raw "account report" then say "계정 보고" "account report"
          else raw
        in
        let recede_lines lines =
          List.map (fun l -> Theme.recede () ^ l ^ Ansi.reset) lines
        in
        let body = full_name @ wrap (Terminal_text.single_line limit ^ kind_label)
          @ (match email with None -> [] | Some email -> recede_lines (wrap email))
          @ wrap latest
          @ (if unmetered_credit then [] else Masc_tui_usage_trend.plot ~ko ~width:inner trend row)
          @ daily
          @ recede_lines
              (wrap
                 (Printf.sprintf
                    (if ko then "%d/%d일(UTC) 보고됨" else "%d/%d UTC days reported")
                    row.reported_days days)) in
        if bare then body
        else
          let card_edge =
            { Masc_tui_card.name = Terminal_text.single_line name
            ; key = None
            ; status = None
            ; count = None
            ; focus = Masc_tui_card.Unfocused
            ; border_accent = Masc_tui_doc.panel_border_accent Masc_tui_theme.Panel_usage
            ; footer_keys = []
            }
          in
          let card_height = max Masc_tui_card.min_height (2 + List.length body) in
          Masc_tui_card.render ~ko ~style:(Masc_tui_doc.card_style ())
            ~width:card_width ~height:card_height
            { Masc_tui_card.edge = card_edge; body = (fun ~cells:_ -> body) }
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
      let first =
        Masc_tui_value.Utc_day.of_moment (trend.generated_at -. float_of_int (days - 1) *. 86400.0)
      in
      (" " ^ Ansi.bold
       ^ Printf.sprintf
           (if ko then "쿼터 범위 추이 (%d일 UTC) · 일별 최근 보고 · %s 기준"
            else "Quota scope trend (%d UTC days) · latest report per day · as of %s")
           days (runtime_moment_text trend.generated_at)
       ^ Ansi.reset)
      :: (" " ^ Theme.recede ()
          ^ Printf.sprintf
              (if ko then "%s → %s UTC · 0–100%% 사용 · 0 = 0 보고 · · = 보고 없음 · ○ = 구간 없음 · $ = 상한 없는 USD · C = 미계량 크레딧"
               else "%s → %s UTC · 0–100%% used · 0 = reported zero · · = no report · ○ = reported no windows · $ = uncapped USD use · C = Credit without a meter")
              (Masc_tui_value.Utc_day.month_day first) (Masc_tui_value.Utc_day.month_day as_of)
          ^ Ansi.reset)
      :: (" " ^ Theme.recede () ^ say "↓ 0 미만 · ↑ 한도 초과" "↓ below zero · ↑ above limit" ^ Ansi.reset)
      :: (match trend.unreadable_reports with
          | 0 -> []
          | count ->
              [ "   " ^ Theme.warn ()
                ^ Printf.sprintf
                    (if ko then "저장된 보고 %d건 읽기 실패%s · 누락된 날은 비워 둠"
                     else "%d stored reports could not be read%s; missing days stay absent")
                    count
                    (if Option.is_some state.usage_scope_id then
                       say " (전체 이력)" " (whole history)"
                     else "")
                ^ Ansi.reset ])
      @ (match trend.rows with
         | [] ->
             [ "   " ^ Theme.recede ()
               ^ (if Option.is_some state.usage_scope_id then
                    say "선택한 계정의 보고가 이 기간에 없습니다"
                      "No reports for the selected account in this window"
                  else
                    say "이 기간에 기록된 보고가 없습니다"
                      "No reports recorded in this window")
               ^ Ansi.reset ]
         | rows -> arrange rows)

let usage_lines ~cols ~rows (state : state) =
  let open Masc.Tui_decode_usage in
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let text = Overview_providers.text_for_viewport ~columns:(framed_inner_width cols) ~rows in
  let scopes () =
    match Overview_providers.section_cards ~ko
            ~providers:(usage_providers_reading state) ~runtimes:state.overview_quota
            ~account_emails:state.overview_account_emails
            ~show_limit_exhausted:state.usage_show_limit_exhausted
            ~now:(Unix.gettimeofday ()) ~width:(max 1 (framed_inner_width cols)) ~rows with
    | Some section -> section.lines
    (* [section] answers [None] only before the first read. *)
    | None -> [ui_text state ~ko:" 계정 한도 미조회" ~en:" Plan usage · not read"]
  in
  let keepers () =
    match state.keeper_usage with
    | Keeper_usage_unread ->
        (* The window is the server's to state: only a read carries
           kuw_window_minutes, and the request names none. Before a read, or
           when it fails, the heading names no window. *)
        [ say " 키퍼 사용량 · 미조회" " Keeper usage · not read" ]
    | Keeper_usage_error reason ->
        [ say " 키퍼 사용량 · 조회 불가: " " Keeper usage · unavailable: "
          ^ Terminal_text.single_line reason ]
    | Keeper_usage_read { kuw_rows; kuw_window_minutes; kuw_generated_at } ->
        let readable row = match row.kur_coverage with
          | Keeper_usage_failed _ | Keeper_usage_partial _ -> false
          | Keeper_usage_complete -> true
        in
        let token_value row = Option.map float_of_int row.kur_tokens in
        let cost_value row = row.kur_cost_usd in
        let valid value = Float.is_finite value && value >= 0. in
        let count = Masc_tui_value.Count.grouped in
        let not_reported = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported in
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
              say "산출 불가 (완전한 기간 없음)" "unavailable (no complete window)"
          | None -> not_reported
        in
        let width = max 1 (framed_inner_width cols - 3) in
        let tokens_text row =
          Option.fold ~none:not_reported ~some:count row.kur_tokens in
        let cost_text row =
          Option.fold ~none:not_reported ~some:(Printf.sprintf "$%.4f") row.kur_cost_usd in
        let metric_text_plain label value reported missing =
          Printf.sprintf
            (if ko then "%s %s · 보고 %s, 누락 %s" else "%s %s · %s reported, %s missing")
            label value (count reported) (count missing)
        in
        let metric_text_styled label value reported missing =
          let missing_style = if missing > 0 then Theme.warn () else Theme.recede () in
          let reported_part =
            if ko then "보고 " ^ count reported else count reported ^ " reported"
          in
          let missing_part =
            if ko then "누락 " ^ count missing else count missing ^ " missing"
          in
          Theme.recede () ^ label ^ Ansi.reset ^ " " ^ value
          ^ Theme.recede () ^ " · " ^ reported_part ^ ", " ^ Ansi.reset
          ^ missing_style ^ missing_part ^ Ansi.reset
        in
        let tok_label = say "토큰" "Tokens" and cost_label = say "비용" "Cost" in
        let widest_metric = List.fold_left (fun widest row ->
          let width_of label text reported missing value =
            match value row with
            | Some amount when readable row && valid amount ->
                Message_layout.display_width (metric_text_plain label text reported missing)
            | _ -> 0
          in
          max widest (max
            (width_of tok_label (tokens_text row) row.kur_tokens_reported row.kur_tokens_missing token_value)
            (width_of cost_label (cost_text row) row.kur_cost_reported row.kur_cost_missing cost_value)))
          0 kuw_rows in
        (* One width per metric set keeps the relative bars comparable. *)
        let beside = width - widest_metric - 2 in
        let bar_cells =
          if beside >= Overview_providers.bar_cells_min then min 32 beside
          else min 32 (max 1 width) in
        let paint = Theme.paint () in
        let meter ~series value highest row =
          match value row with
          | Some amount when readable row && valid amount ->
              let maximum = Option.value ~default:0. highest in
              let share = if maximum <= 0. then 0. else amount /. maximum in
              let clamped =
                if not (Float.is_finite share) then 0.0
                else Float.min 1.0 (Float.max 0.0 share)
              in
              let scaled =
                if clamped <= 0.0 then 0
                else max 1 (int_of_float (Float.round (clamped *. 1000.0)))
              in
              let scale = Masc_tui_chart.Series { paint; series } in
              Some
                (Masc_tui_chart.dot_meter_bar ~width:bar_cells ~value:scaled
                   ~max_value:1000 ~scale
                   ~track_style:(Theme.recede ()) ~reset:Ansi.reset ())
          | _ -> None
        in
        [ " " ^ Ansi.bold
          ^ Printf.sprintf
              (if ko then "키퍼 사용량 · 최근 %s · 기록된 턴 지표"
               else "Keeper usage · last %s · recorded turn metrics")
              (Overview_providers.minutes_label kuw_window_minutes)
          ^ Ansi.reset
        ; " " ^ Theme.recede ()
          ^ (if ko then "기준 " ^ runtime_moment_text kuw_generated_at
             else "As of " ^ runtime_moment_text kuw_generated_at)
          ^ Ansi.reset
        ; " " ^ Theme.recede ()
          ^ say "막대: 지표별 최대 관측값 대비 상대 비율 (쿼터 한도 아님)."
              "Bars: relative to largest read value per metric; not quota."
          ^ Ansi.reset
        ; " " ^ Theme.recede ()
          ^ say "부분 관측 행은 막대를 생략합니다. 누락된 값이 있으면 합계가 실제보다 적을 수 있습니다."
              "Partial rows: no bars. Missing values can understate totals."
          ^ Ansi.reset
        ; " " ^ Theme.recede ()
          ^ Printf.sprintf
              (if ko then "기준치: 토큰 %s · 비용 %s" else "Scale: tokens %s · cost %s")
              (scale token_value (fun value -> count (Float.to_int (Float.round value))) token_max)
              (scale cost_value (Printf.sprintf "$%.4f") cost_max)
          ^ Ansi.reset
        ; "" ]
        @ (if kuw_rows = [] then
             [ "   " ^ Theme.recede ()
               ^ say "조회된 목록에 키퍼가 없습니다" "No Keepers in the returned roster"
               ^ Ansi.reset ]
            else List.concat_map
              (fun (row : Masc.Tui_decode_usage.keeper_usage_row) ->
                let tokens = tokens_text row in
                let cost = cost_text row in
                let coverage =
                  match row.kur_coverage with
                  | Keeper_usage_complete ->
                      Theme.recede () ^ say "조회됨" "read" ^ Ansi.reset
                  | Keeper_usage_partial { malformed_rows; unread_turn_rows } ->
                      Theme.warn ()
                      ^ Printf.sprintf
                          (if ko then "일부 관측 (형식 오류 %d, 미조회 턴 %d) · 합계는 하한값"
                           else "partial (%d malformed rows, %d unread turn rows) · reported totals are lower bounds")
                          malformed_rows unread_turn_rows
                      ^ Ansi.reset
                  | Keeper_usage_failed reason ->
                      Theme.bad ()
                      ^ say "조회 불가: " "unavailable: " ^ Terminal_text.single_line reason
                      ^ Ansi.reset
                in
                let width = max 1 (framed_inner_width cols - 3) in
                let heading =
                  Masc_tui_ansi.Section.style ^ text (Terminal_text.single_line row.kur_name)
                  ^ Ansi.reset
                  ^ Theme.recede ()
                  ^ Printf.sprintf
                      (if ko then " · %s턴 · " else " · %s turns · ")
                      (count row.kur_turn_samples)
                  ^ Ansi.reset ^ coverage
                in
                let metric label value reported missing bar =
                  metric_text_styled label value reported missing
                  ^ Option.fold ~none:"" ~some:(fun bar -> "  " ^ bar) bar
                in
                List.concat_map
                    (fun line -> List.map (fun text -> "   " ^ text)
                        (Masc_tui_message_layout.wrap_styled_words ~max_cells:width line))
                    [ heading
                    ; metric tok_label tokens row.kur_tokens_reported row.kur_tokens_missing
                        (meter ~series:Masc_tui_theme.Usage token_value token_max row)
                    ; metric cost_label cost row.kur_cost_reported row.kur_cost_missing
                        (meter ~series:Masc_tui_theme.Memory cost_value cost_max row)
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
        let label = Option.fold ~none:(say "범위 " "scope " ^ scope_id)
            ~some:Overview_providers.scope_name account in
        let missing = match state.overview_providers, account with
          | Providers_read _, None ->
              [ say "현재 목록에 없는 계정입니다. 선택은 유지됩니다."
                  "Account absent from the current inventory; selection retained." ]
          | Providers_read _, Some _ | (Providers_unread | Providers_failed _), _ -> [] in
        Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols))
          (String.concat "\n"
             ((say "계정 · " "Account · " ^ label
               ^ say "  f:계정 선택  a:전체 계정" "  f:choose  a:all accounts") :: missing))
        @ [""] in
  match state.usage_section with
  (* Plan cards already have a cell-sized border and wrapped contents. *)
  | Usage_plan -> selection_lines @ wrap_evidence (scopes ())
  | Usage_trend -> selection_lines @ wrap_evidence (provider_history_lines ~cols ~rows state)
  | Usage_keepers ->
      let currency = match Masc_tui_candle.summary_lines ~now:(Unix.gettimeofday ()) state.candle_observation with
        | [] -> []
        | lines ->
            [ " " ^ Ansi.bold ^ say "Candle · 워크스페이스 공급량" "Candle · workspace supply" ^ Ansi.reset ]
            @ List.map (fun line -> "   " ^ Terminal_text.single_line line) lines
            @ [ Theme.recede () ^ draw_hline (framed_inner_width cols) ^ Ansi.reset ]
      in
      wrap_evidence (currency @ keepers ())
  (* Tool calls belong to the workspace, not to an account, so the account
     selection does not narrow them. *)
  | Usage_calls ->
      (match state.tool_series with
       | Tool_series_read calls ->
           Masc_tui_usage_calls.lines ~ko ~width:(max 1 (framed_inner_width cols)) ~rows calls
       | Tool_series_unread ->
           wrap_evidence
             (Masc_tui_usage_calls.note_lines ~ko ~days:state.provider_history_days
                (say "미조회" "not read"))
       | Tool_series_error reason ->
           wrap_evidence
             (Masc_tui_usage_calls.note_lines ~ko ~days:state.provider_history_days
                (say "조회 불가: " "unavailable: " ^ Terminal_text.single_line reason)))

let render_metrics (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The section being read is marked on the strip under this row, so the
     title does not name it a second time. *)
  let heading =
    here_path state
      ~path:
        (if state.usage_telemetry_open then
           [ ui_text state ~ko:"사용량" ~en:"Usage"
           ; ui_text state ~ko:"진단" ~en:"Telemetry" ]
         else [ ui_text state ~ko:"사용량" ~en:"Usage" ])
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
        | Compact_reading
        | Compact_http (Degraded | Connecting | Booting | Account_server _ | Disconnected) ->
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
          ~hand_position:c.position
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
        let draw_tabs ?(numbered = true) ~width tabs =
          tab_strip ~numbered ~width ~press:(fun () text -> text) tabs in
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
              (fun widest section ->
                max widest (tab_strip_min_width ~numbered:true (usage_tabs section)))
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
              draw_tabs ~numbered:false ~width:(room hint)
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
                    ^ metrics_status_at_end ~ko:(state.ui_language = Lang_ko)
                    ^ Ansi.reset);
        let content_budget = max 0 (budget - navigation_rows - spacing_rows) in
        (* Put variable-length status details after account rows: refreshes do
           not move the account the reader is already scrolling through. *)
        let lines = usage_lines ~cols ~rows:content_budget state @ connection_rows in
        let height = content_budget in
        let max_scroll = max 0 (List.length lines - height) in
        let scroll = min max_scroll (max 0 state.metrics_scroll) in
        drawn_metrics_scroll := scroll;
        drawn_metrics_height := height;
        drawn_metrics_card_rows := Some 0;
        Option.iter c.position
          (Masc_tui_value.Position.window ~first:scroll ~shown:height
             ~total:(List.length lines));
        List.iteri
          (fun index line ->
            if index >= scroll && index < scroll + height then c.push line)
          lines
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
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let active_assignment_sheet =
    Option.bind (Masc_tui_types.runtime_assignment_target_key state) (fun key ->
      Option.bind
        (List.find_opt
           (fun attempt -> Masc_tui_types.keeper_settings_same_origin key attempt.raa_request.ras_key)
           (Runtime_assignment_saves.all state.runtime_assignment_saves))
        (fun attempt ->
          let started_at =
            Some (Masc_tui_types.progress_started_at_of_monotonic_ns ~now attempt.raa_request.ras_started_ns)
          in
          match attempt.raa_status with
          | Assignment_checking ->
              Some
                { ps_title = ui_text state ~ko:"런타임 배정 확인 중" ~en:"Checking runtime assignment"
                ; ps_detail = Some (Terminal_text.single_line key.ksk_keeper)
                ; ps_started_at = started_at
                ; ps_meter = None
                ; ps_action_hint = Some (ui_text state ~ko:"Esc:돌아가기" ~en:"Esc:back")
                ; ps_blocking = true
                }
          | Assignment_reading ->
              Some
                { ps_title = ui_text state ~ko:"현재 배정 버전 조회 중" ~en:"Reading current assignment revision"
                ; ps_detail = Some (Terminal_text.single_line key.ksk_keeper)
                ; ps_started_at = started_at
                ; ps_meter = None
                ; ps_action_hint = Some (ui_text state ~ko:"Esc:돌아가기" ~en:"Esc:back")
                ; ps_blocking = true
                }
          | Assignment_posting _ ->
              Some
                { ps_title = ui_text state ~ko:"런타임 배정 저장 중" ~en:"Saving runtime assignment"
                ; ps_detail = Some (Terminal_text.single_line key.ksk_keeper)
                ; ps_started_at = started_at
                ; ps_meter = None
                ; ps_action_hint = Some (ui_text state ~ko:"Esc:돌아가기" ~en:"Esc:back")
                ; ps_blocking = true
                }
          | Assignment_finished _ -> None))
  in
  let catalog_loading =
    match state.runtime_catalog_reading with
    | Runtime_catalog_loading | Runtime_catalog_refreshing _ -> true
    | Runtime_catalog_read | Runtime_catalog_unread | Runtime_catalog_stale _
    | Runtime_catalog_failed _ -> false
  in
  let catalog_started =
    Masc_tui_types.progress_clock_option state ~slot:"runtime-catalog" ~now
      (if catalog_loading then Some "loading" else None)
  in
  let progress_sheet =
    match active_assignment_sheet with
    | Some _ as s -> s
    | None ->
        if catalog_loading then
          Some
            { ps_title = ui_text state ~ko:"런타임 목록 조회 중" ~en:"Loading runtime catalogue"
            ; ps_detail = None
            ; ps_started_at = catalog_started
            ; ps_meter = None
            ; ps_action_hint = None
            ; ps_blocking = false
            }
        else None
  in
  let sheet_rows =
    let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
    let has_recovery =
      Option.is_some (recovery_slot state ~max_cells:(framed_inner_width cols))
    in
    let total_budget = max 1 (rows - chrome_rows_for ~frame:Chrome_screen ~has_recovery) in
    Option.fold ~none:0
      ~some:(progress_sheet_height ~available:total_budget ~cols:(framed_inner_width cols))
      progress_sheet
  in
  let view =
    Masc_tui_types.keeper_runtime_picker_view state
      ~terminal_rows:(max 1 (terminal_rows - sheet_rows))
  in
  let current_id = Masc_tui_types.runtime_pick_current_id state in
  surface_chrome ~overflow:Paged_by_cursor ?progress_sheet ~now state ~terminal_rows ~cols ~surface_key:"runtime-pick"
    ~title:
      (here_row ~cols state
         ~path:[ keeper_name; runtime_step state ]
         ~readings:
           ([ Theme.recede () ^ ui_text state ~ko:"지금: " ~en:"current: " ^ current
              ^ Ansi.reset ]
            @ (match progress_sheet with
               | None -> []
               | Some sheet ->
                   [ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title ]))
         ~position:
           (* The cursor indexes the list the filter keeps. *)
           (if view.Masc_tui_pick_list.shown = 0 then None
            else
              Some
                (Masc_tui_value.Position.row
                   ~selected:(Some state.runtime_pick_list.Masc_tui_pick_list.cursor)
                   ~total:view.Masc_tui_pick_list.shown)))
    ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language (Keepers Keeper_runtime_pick))
    ~body:(fun ~budget:_ c ->
      let mark_prefix =
        if catalog_loading then Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way ^ " " else ""
      in
      c.push_styled ~style:(Theme.info ())
        ("  " ^ mark_prefix ^ Masc_tui_types.keeper_runtime_picker_summary ~ko view
          ^ Masc_tui_types.runtime_catalog_reading_suffix ~ko
              state.runtime_catalog_reading);
      (match state.runtime_catalog_reading, Masc_tui_types.keeper_runtime_picker_empty_note ~ko ~reading:state.runtime_catalog_reading view with
       | Runtime_catalog_failed err, _ -> c.push (data_unreliable_row ~cols err)
       | (Runtime_catalog_loading | Runtime_catalog_refreshing _), Some note ->
           c.push
             ("  " ^ progress_inline ~ko ~now ?started_at:catalog_started (String.trim note))
       | (Runtime_catalog_unread | Runtime_catalog_read | Runtime_catalog_stale _), Some note ->
           c.push (Theme.recede () ^ note ^ Ansi.reset)
       | (Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_read
          | Runtime_catalog_refreshing _ | Runtime_catalog_stale _), None ->
           (* The first header cell spans badge and target, as the rows
              do. *)
           let header =
             Printf.sprintf "  %s  %s  %s"
               (fit_width (ui_text state ~ko:"종류   대상" ~en:"KIND   TARGET")
                  (Masc_tui_types.runtime_pick_badge_cells + target_width))
               (fit_width (ui_text state ~ko:"설정된 경로 / 모델" ~en:"CONFIGURED ROUTE / MODEL") route_width)
               (fit_width (ui_text state ~ko:"속성 / 후보" ~en:"PROPERTIES / CANDIDATES")
                  (Masc_tui_types.runtime_pick_properties_room ~cols
                     ~target:target_width ~route:route_width))
           in
           c.push_styled ~style:(Theme.recede ()) header);
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
              | Masc_tui_types.Pick_lane _ -> Theme.info ()
              | Masc_tui_types.Pick_model _ -> Theme.recede ()
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
            c.push_selected ("\xe2\x80\xba " ^ Masc_tui_theme.strip_sgr line)
          else
            (* The Keeper's own assignment is starred; the cursor row keeps
               its [>], and the title still names the assignment. *)
            let current =
              Option.equal String.equal current_id
                (Some (Masc_tui_types.runtime_pick_item_id item))
            in
            c.push ((if current then "* " else "  ") ^ line))
        view.Masc_tui_pick_list.rows)
