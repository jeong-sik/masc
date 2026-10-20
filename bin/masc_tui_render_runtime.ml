(** System / Runtime, Tools, Usage / Metrics, and Keeper runtime picker screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection
module Overview_providers = Masc_tui_overview_providers
module Render_tools = Masc_tui_render_tools
module Metrics_page = Masc_tui_render_metrics

let runtime_lane_notice_style = Masc_tui_render_lanes.runtime_lane_notice_style

(* The runtime picker measures this string to decide its column widths, so the
   format lives beside that arithmetic. *)
let format_context_tokens = Masc_tui_types.format_context_tokens

let keepers_for_lane = Masc_tui_types.keepers_for_lane
let keepers_for_runtime_with_lanes = Masc_tui_types.keepers_for_runtime_with_lanes


let runtime_refresh_badge refresh_state =
  let open Masc.Tui_decode_runtime_probe in
  let label, style =
    match refresh_state with
    | Runtime_probe_fresh -> "fresh", (Theme.ok ())
    | Runtime_probe_recent -> "recent", (Theme.info ())
    | Runtime_probe_served_stale -> "stale", (Theme.warn ())
    | Runtime_probe_warming_up -> "warming", (Theme.warn ())
  in
  style ^ label ^ Ansi.reset

let runtime_overall_badge status =
  let open Masc.Tui_decode_runtime_probe in
  let style =
    match status with
    | Runtime_probe_reachable -> (Theme.ok ())
    | Runtime_probe_no_http_runtimes | Runtime_probe_warming -> Ansi.dim
    | Runtime_probe_degraded -> (Theme.warn ())
    | Runtime_probe_unreachable -> (Theme.bad ())
  in
  style ^ runtime_probe_status_to_string status ^ Ansi.reset

let runtime_usage_badge state runtime =
  match state.runtime_surface with
  | None -> Some (Ansi.dim ^ "usage unknown" ^ Ansi.reset)
  | Some snapshot ->
      match runtime_spent_usage snapshot.rss_resolved runtime with
      | Error _ -> Some (Ansi.dim ^ "usage unknown" ^ Ansi.reset)
      | Ok [] -> None
      | Ok (_ :: _) -> Some (Theme.warn () ^ "account limit spent" ^ Ansi.reset)

let runtime_route_badge state (runtime : Masc.Tui_decode.runtime_option) =
  match
    List.filter_map Fun.id
      [ runtime_quota_badge runtime; runtime_rate_limit_badge runtime; runtime_usage_badge state runtime ]
  with
  | [] -> (Theme.info ()) ^ "no refusal" ^ Ansi.reset
  | badges -> String.concat " " badges

let runtime_probe_badge = function
  | None -> Ansi.dim ^ "unobserved" ^ Ansi.reset
  | Some (probe : Masc.Tui_decode_runtime_probe.runtime_provider_probe) ->
      let open Masc.Tui_decode_runtime_probe in
      let style =
        match probe.rpp_status with
        | Runtime_provider_reachable -> (Theme.ok ())
        | Runtime_provider_skipped_cli | Runtime_provider_skipped_native_auth -> Ansi.dim
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
      let label = runtime_probe_status_label probe.rpp_status in
      style ^ label ^ Ansi.reset

let runtime_route_probe_badge state runtime probe =
  runtime_route_badge state runtime ^ " / " ^ runtime_probe_badge probe

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

let runtime_table_cells ~cols ~status_cells ~mode ~lane ~lane_is_label ~candidate ~identity ~status ~detail =
  let lane_width, candidate_width, identity_width, minimum_status_width = runtime_column_widths cols in
  let status_width = max minimum_status_width status_cells in
  let inner_width = max 1 (framed_inner_width cols - 2) in
  let candidate_heading =
    match mode with Masc_tui_types.Runtime_lanes -> "CANDIDATE" | Runtime_all -> "RUNTIME"
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
          (match mode with Masc_tui_types.Runtime_lanes -> "LANE" | Runtime_all -> "USED BY"),
          lane, (if lane_is_label then Masc_tui_table.Fold_tail else Fold_middle)
      | Runtime_candidate_column ->
          candidate_heading, candidate, Masc_tui_table.Fold_middle
      | Runtime_identity_column -> "PROVIDER / MODEL", identity, Masc_tui_table.Fold_middle
      | Runtime_status_column -> "ROUTE / PROBE", status, Masc_tui_table.Fold_tail
      | Runtime_detail_column -> "DETAIL", detail, Masc_tui_table.Fold_tail in
    let column_width = if column = Runtime_candidate_column then layout.flex_width else width column in
    Masc_tui_table.cell ~header ~width:column_width ~fold value) layout.shown

let runtime_detail_field ~width ~style label value =
  let prefix = "  " ^ label ^ ": " in
  let continuation = String.make (Message_layout.display_width prefix) ' ' in
  let lines =
    Message_layout.wrap_words
      ~max_cells:(max 1 (width - Message_layout.display_width prefix))
      (Terminal_text.single_line value)
  in
  if Message_layout.display_width prefix >= width then
    Message_layout.wrap_words ~max_cells:width
      (prefix ^ Terminal_text.single_line value)
    |> List.map (fun line -> style, line)
  else match lines with
  | [] -> [ style, prefix ^ Masc_tui_theme.Glyph.no_value ]
  | first :: rest ->
      (style, prefix ^ first)
      :: List.map (fun line -> style, continuation ^ line) rest

let runtime_bool = function true -> "yes" | false -> "no"

(* A route is not a candidate. This reading remains available when the
   inventory is empty, and retains diagnostics beside a last-good snapshot. *)
let runtime_routes_detail_lines state ~width =
  let field ?(style = Ansi.reset) label value =
    runtime_detail_field ~width ~style label value
  in
  let optional label = function
    | None -> []
    | Some value -> field ~style:(Theme.warn ()) label value
  in
  let resolved =
    match state.runtime_surface with
    | None -> field "Resolved" "Configuration has not been read"
    | Some snapshot ->
        let resolved = snapshot.Tui_decode.rss_resolved in
        let route label values =
          match values with
          | [] -> field label "none"
          | values ->
              List.mapi
                (fun index value ->
                  field (Printf.sprintf "%s %d" label (index + 1)) value)
                values
              |> List.concat
        in
        let dropped =
          List.filter
            (fun id -> not (List.exists (String.equal id) resolved.rrs_media_failover))
            resolved.rrs_media_failover_declared
        in
        field "Source" (Option.value resolved.rrs_config_path ~default:"unavailable")
        @ field "Recorded" resolved.rrs_generated_at_iso
        @ field "Default route" (Option.value resolved.rrs_default_route ~default:"none")
        @ field "Entry runtime" (Option.value resolved.rrs_default_runtime_id ~default:"none")
        @ route "Declared media" resolved.rrs_media_failover_declared
        @ route "Admitted media" resolved.rrs_media_failover
        @ route "Unresolved media" dropped
        @ optional "Probe read error" snapshot.rss_probe_error
        @ (match snapshot.rss_probe with
           | None -> field "Probe" "unavailable; no observation has been read"
           | Some probe ->
               field "Probe status" (Masc.Tui_decode_runtime_probe.runtime_probe_status_to_string probe.rps_status)
               @ List.concat_map (field ~style:(Theme.warn ()) "Probe error") probe.rps_errors
               @ List.concat_map (field "Probe limitation") probe.rps_limitations)
  in
  optional "Runtime read warning" state.runtime_surface_error
  @ resolved
  @ (match state.runtime_lane_notice with
     | None -> []
     | Some notice ->
         field ~style:(runtime_lane_notice_style notice) "Action result"
           (Masc_tui_types.runtime_lane_notice_text notice))
  @ List.concat_map (field ~style:(Theme.warn ()) "Stale configuration")
      (Masc_tui_types.runtime_lane_stale_lines state)
;;

let runtime_detail_lines state target ~width =
  let open Masc.Tui_decode in
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
           runtime_detail_field ~width ~style:(Theme.warn ()) "Runtime"
             "This runtime row is no longer present in the refreshed projection")
  | Some (runtime, lanes, position, probe) ->
      let fields =
        runtime_detail_field ~width ~style:Ansi.reset "Runtime ID" runtime.ro_id
        @ runtime_detail_field ~width ~style:Ansi.reset "Provider" runtime.ro_provider
        @ runtime_detail_field ~width ~style:Ansi.reset "Quota scope" (runtime_quota_scope_label runtime)
        @ runtime_detail_field ~width ~style:Ansi.reset "Response-local quota scope"
            (Option.value ~default:"not reported" runtime.ro_quota_scope)
        @ runtime_detail_field ~width ~style:Ansi.reset "Connection / provider ID" runtime.ro_provider_id
        @ runtime_detail_field ~width ~style:Ansi.reset "Model" runtime.ro_model
        @ runtime_detail_field ~width ~style:Ansi.reset "Effective context"
            (Printf.sprintf "%d tokens" runtime.ro_effective_max_context)
        @ runtime_detail_field ~width ~style:Ansi.reset "Context source"
            (runtime_context_source_label runtime.ro_max_context_source)
        @ runtime_detail_field ~width ~style:Ansi.reset "Max output"
            (match runtime.ro_max_output_tokens with
             | Some tokens -> Printf.sprintf "%d tokens" tokens
             | None -> "not specified")
        @ runtime_detail_field ~width ~style:Ansi.reset "Local runtime"
            (runtime_bool runtime.ro_is_local)
        @ runtime_detail_field ~width ~style:Ansi.reset "Used by lanes"
            (match lanes with [] -> "unassigned" | values -> String.concat ", " values)
        @ runtime_detail_field ~width ~style:Ansi.reset "Default runtime"
            (runtime_bool runtime.ro_is_default)
      in
      let candidate =
        match position with
        | None -> []
        | Some (lane, at, total) ->
            (* The lane is named because "Used by lanes" above can now hold
               several, and a position without its lane is a place in an
               unnamed list. *)
            runtime_detail_field ~width ~style:Ansi.reset "Lane position"
              (Printf.sprintf "%d of %d in %s" at total lane)
      in
      let quota =
        match runtime_quota_badge runtime with
        | None -> []
        | Some _ ->
            runtime_detail_field ~width ~style:(Theme.warn ()) "Quota"
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
          runtime_detail_field ~width ~style:(Theme.warn ()) "Rate limit"
            (Printf.sprintf "until %02d:%02d or the next successful answer"
               tm.Unix.tm_hour tm.Unix.tm_min)
        | true, None ->
          runtime_detail_field ~width ~style:(Theme.warn ()) "Rate limit"
            "no wait stated, cleared by the next successful answer"
      in
      let probe_lines =
        match probe with
        | None -> [ Ansi.dim, "  Probe: unobserved" ]
        | Some row ->
            let transport =
              match row.rpp_transport with
              | Runtime_probe_http -> "http"
              | Runtime_probe_cli -> "cli"
            in
            runtime_detail_field ~width ~style:Ansi.reset "Probe status"
              (runtime_probe_status_label row.rpp_status)
            @ runtime_detail_field ~width ~style:Ansi.reset "Probe transport" transport
            @ runtime_detail_field ~width ~style:Ansi.reset "Checked at"
                (Terminal_text.short_timestamp row.rpp_checked_at)
            (* No Reachable row: the decoder admits a probe only when its
               reachable flag agrees with its status, so the row could only
               repeat the status two rows above it -- "reachable" then
               "yes". *)
            @ (match row.rpp_http_status with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "HTTP status"
                     (string_of_int value))
            @ (match row.rpp_latency_ms with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "Latency"
                     (Printf.sprintf "%.0fms" value))
            @ (match runtime_probe_annotation ~status:row.rpp_status row.rpp_error with
               | None -> []
               | Some (Runtime_probe_note note) ->
                   runtime_detail_field ~width ~style:Ansi.dim "Probe note" note
               | Some (Runtime_probe_failure error) ->
                   runtime_detail_field ~width ~style:(Theme.bad ()) "Probe error" error)
      in
      let probe_limitations =
        match state.runtime_surface with
        | Some { rss_probe = Some snapshot; _ } ->
            List.concat_map
              (runtime_detail_field ~width ~style:Ansi.reset "Probe limitation")
              snapshot.rps_limitations
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
            runtime_detail_field ~width ~style:Ansi.dim "Bound keepers" "none"
        | ks ->
            let names = String.concat ", " (List.map (fun (k : Tui_decode.keeper) -> k.k_name) ks) in
            let activity_str = match aggregate_keeper_stats ks with
              | None -> "activity not observed"
              | Some (turns, tokens, cost) ->
                Printf.sprintf "%d turns · %s tokens · $%.4f" turns
                  (format_context_tokens tokens) cost
            in
            runtime_detail_field ~width ~style:Ansi.reset "Bound keepers" names
            @ runtime_detail_field ~width ~style:Ansi.reset "Keeper lifetime" (activity_str ^ " · across all runtimes")
      in
      let usage_lines =
        match state.runtime_surface with
        | None -> runtime_detail_field ~width ~style:Ansi.dim "Account usage" "unavailable"
        | Some snapshot ->
          match runtime_spent_usage snapshot.rss_resolved runtime with
          | Error detail -> runtime_detail_field ~width ~style:Ansi.dim "Account usage"
              (Terminal_text.single_line detail)
          | Ok [] -> []
          | Ok windows ->
            runtime_detail_field ~width ~style:(Theme.warn ()) "Account usage"
              "A model-call limit is spent; this account report does not identify which models are refused."
            @ List.concat_map (fun (window : Masc.Tui_decode_usage.provider_usage_window) ->
                let limit = match window.puw_limit_id with
                  | Some id -> Terminal_text.single_line id
                  | None -> "account" in
                let tm = Unix.localtime window.puw_observed_at in
                let observed = Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
                    tm.Unix.tm_hour tm.Unix.tm_min in
                runtime_detail_field ~width ~style:(Theme.warn ()) "Spent limit"
                  (limit ^ " (observed " ^ observed ^ ")")) windows
      in
      let evidence_lines = match state.runtime_evidence with
        | None -> runtime_detail_field ~width ~style:Ansi.dim "Runtime history" "not read"
        | Some (Error detail) -> runtime_detail_field ~width ~style:Ansi.dim "Runtime history" detail
        | Some (Ok evidence) ->
          Masc_tui_runtime_evidence.lines evidence ~runtime_id:runtime.ro_id
          |> List.concat_map (fun (label, value) ->
            runtime_detail_field ~width ~style:Ansi.reset label value) in
      let failed_attempt =
        match runtime.ro_failed_attempt with
        | None -> []
        | Some attempt ->
          runtime_detail_field ~width ~style:(Theme.warn ()) "Last failure"
            (Terminal_text.single_line (runtime_failed_attempt_text attempt))
      in
      fields @ candidate @ evidence_lines @ usage_lines @ quota @ rate_limit @ failed_attempt
      @ keeper_lines @ probe_lines @ probe_limitations

let render_runtime_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let target_label =
    match target with
    | Runtime_routes -> "routes / status"
    | Runtime_lane_candidate { lane_id; runtime_id } -> lane_id ^ " / " ^ runtime_id
    | Runtime_catalog_entry { runtime_id } -> runtime_id
  in
  box_top buf cols;
  box_line buf cols
    (detail_heading ~cols
       ~lead:(Lead_text (screen_title runtime_detail_title ^ "  "))
       ~id:target_label ~after:"" ~tail:(connection_badge state));
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
        (Printf.sprintf "lines %s"
           (Masc_tui_scroll.window_text ~scroll ~height:content_height total))
    else None
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ?position
       ~hints:
         (Masc_tui_keys.footer_hints_runtime_detail
            ~routes:(target = Runtime_routes) ()));
  finish_surface state ~clamped:(Runtime_detail_scroll scroll)
    ~surface_key:"runtime-detail" ~rows:terminal_rows ~cols buf

(* Lane candidates come from /runtime/resolved; reachability comes from the
   cached runtime-probe document. Exact runtime-id joining happened in the
   decoder module, so drawing never parses ids or reconstructs a lane. *)
let render_runtime (state : state) =
  let terminal_rows, cols = get_terminal_size () in
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
    | None -> "reading unavailable"
    | Some snapshot ->
        (match Masc_domain.parse_iso8601_opt snapshot.rss_resolved.rrs_generated_at_iso with
         | None -> "reading time unavailable"
         | Some generated_at ->
             let recorded = Unix.localtime generated_at in
             Printf.sprintf "reading %02d:%02d:%02d"
               recorded.Unix.tm_hour recorded.Unix.tm_min recorded.Unix.tm_sec)
  in
  let header =
    match state.runtime_surface with
    | None ->
        let reading_note =
          match state.runtime_surface_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC System / Runtime") reading_note timestamp
          (connection_badge state)
    | Some snapshot ->
        let lane_count = List.length snapshot.rss_resolved.rrs_lanes in
        let probe_status =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> (Theme.warn ()) ^ "probe unavailable" ^ Ansi.reset
          | Some probe ->
              runtime_overall_badge probe.rps_status ^ " / "
              ^ runtime_refresh_badge probe.rps_refresh_state
        in
        let probe_read =
          if Option.is_some snapshot.rss_probe_error then
            (Theme.warn ()) ^ " / read failed" ^ Ansi.reset
          else ""
        in
        let all_count =
          List.length snapshot.rss_resolved.Masc.Tui_decode.rrs_runtimes
        in
        (* [standalone_lanes] is the Lanes screen's reading, which this one
           does not load, so its absence is not a count of zero. *)
        let standalone_reading =
          Option.map
            (fun (snapshot : Masc.Tui_decode.standalone_lanes_snapshot) ->
              string_of_int (List.length snapshot.sls_lanes))
            state.standalone_lanes
        in
        let lanes_active = state.runtime_mode = Masc_tui_types.Runtime_lanes in
        Printf.sprintf "%s  %s  %s%s  %s  %s"
          (screen_title " MASC System / Runtime")
          (tab_strip
             ~width:
               (tab_strip_width ~cols
                  ~before:(screen_title " MASC System / Runtime" ^ tab_strip_gap)
                  ~after:
                    (Printf.sprintf "  %s%s  %s  %s" probe_status probe_read
                       timestamp (connection_badge state)))
             ~press:pressable
             [ ( tab_entry_label "Candidate orders"
                   (Some
                      (Printf.sprintf "%s, %s"
                         (Masc_tui_message_layout.count_noun lane_count "lane")
                         (Masc_tui_message_layout.count_noun
                            (List.length snapshot.rss_candidates) "slot")))
               , lanes_active
               , Press_runtime_mode Masc_tui_types.Runtime_lanes )
             ; ( tab_entry_label "All runtimes" (Some (string_of_int all_count))
               , not lanes_active
               , Press_runtime_mode Masc_tui_types.Runtime_all )
             ; ( tab_entry_label "Lanes" standalone_reading
               , false
               , Press_standalone_lanes )
             ])
          probe_status probe_read timestamp (connection_badge state)
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
      Printf.sprintf "[rows %s]  " (Masc_tui_scroll.window_text ~scroll ~height:content_height shown)
    else ""
  in
  let hints =
    scroll_hint ^ Masc_tui_keys.footer_hints_runtime ~mode:state.runtime_mode
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
              | [], [] -> Ansi.dim ^ "none — no vision runtimes" ^ Ansi.reset
              | declared, dropped ->
                  String.concat " → "
                    (List.map Terminal_text.single_line declared)
                  ^
                  (match dropped with
                   | [] -> ""
                   | _ ->
                     (Theme.warn ())
                     ^ Printf.sprintf "  (%s unresolved at boot: %s)"
                         (Message_layout.count_noun (List.length dropped) "entry")
                         (String.concat ", " (List.map Terminal_text.single_line dropped))
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
              (Ansi.dim ^ "m edits it · the vision runtimes, in call order" ^ Ansi.reset));
         c.push_divider ()
       end);
  let table_cells = runtime_table_cells ~cols ~status_cells ~mode:state.runtime_mode in
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
  (* Counted in [runtime_surface_listing_chrome] as two rows, like the refusal
     above, so the footer keeps its row while the prompt is up. *)
  (match Masc_tui_types.runtime_lane_prompt state with
   | None -> ()
   | Some (Masc_tui_types.Lane_rename_prompt (lane, draft)) ->
       c.push_styled ~style:(Theme.info ())
         (Printf.sprintf
            "  rename lane %s to: %s_  — Enter renames it and every reference, Esc cancel"
            (Terminal_text.single_line lane)
            (Terminal_text.single_line draft));
       c.push_divider ()
   | Some (Masc_tui_types.Lane_name_prompt draft) ->
       c.push_styled ~style:(Theme.info ())
         (Printf.sprintf "  new lane name: %s_  — Enter pick its first runtime, Esc cancel"
            (Terminal_text.single_line draft));
       c.push_divider ()
   | Some (Masc_tui_types.Lane_remove_prompt lane) ->
       c.push_styled ~style:(Theme.warn ())
         (Printf.sprintf "  press D again to remove lane %s"
            (Terminal_text.single_line lane));
       c.push_divider ());
  (* The route editor, drawn here when it was opened on media_failover. The
     Lanes surface draws the same editor for an exact lane's slots; both show
     one ordered list of runtime ids and take the same keys. *)
  (match state.slot_editor with
   | None | Some { Masc_tui_types.se_target = Masc_tui_types.Exact_lane_slots _; _ } -> ()
   | Some { se_target = Masc_tui_types.Media_failover_slots; _ } ->
       c.push_styled ~style:(Theme.info ())
         "  [runtime].media_failover — the order the vision runtimes are called in";
       let entries = Masc_tui_types.slot_editor_rows state in
       let selected_index = Masc_tui_types.slot_editor_cursor_index state in
       if entries = [] then
         c.push_styled ~style:(Theme.recede ())
           "  (empty — no vision runtimes; a adds the first runtime)"
       else
         List.iteri
           (fun index (row : Masc_tui_types.slot_editor_row) ->
              c.push
                (Printf.sprintf "  %s %d  %s"
                   (if Some index = selected_index then ">" else " ")
                   (index + 1)
                   (Terminal_text.single_line row.Masc_tui_types.sr_slot)))
           entries;
       if entries <> [] && Option.is_none (selected_index) then
         c.push_styled ~style:(Theme.warn ())
           "  no slot selected; j/k selects a current slot";
       c.push_styled ~style:(Theme.recede ())
         "  j/k move · a add · x drop · J/K reorder · Esc close";
       c.push_divider ());
  (match runtime_picker_projection state with
   | None -> ()
   | Some picker ->
       let what, enter =
         match picker.rlp_pick with
         | Masc_tui_types.Pick_new_lane lane ->
             ( Printf.sprintf "first runtime of new lane %s" (Terminal_text.single_line lane)
             , "Enter create" )
         | (Masc_tui_types.Pick_conversation_lane _ | Masc_tui_types.Pick_exact_lane _) as pick ->
             ( Printf.sprintf "adding a candidate to the candidate order of %s"
                 (Terminal_text.single_line (Masc_tui_types.runtime_lane_pick_name pick))
             , "Enter append" )
         | Masc_tui_types.Pick_media_failover ->
             ( "adding to [runtime].media_failover, the order the vision runtimes are called in"
             , "Enter append" )
         | Masc_tui_types.Pick_exact_lane_replacement _ ->
             ("Replace selected candidate at its current position", "Enter replace")
         | Masc_tui_types.Pick_route_default ->
             (* Replaces rather than appends, and the row it replaces is
                marked "(already a candidate)" in the choices below. *)
             ("the route an unassigned keeper walks", "Enter replace")
       in
       c.push_styled ~style:(Theme.info ())
         (Printf.sprintf "  %s — %s — %s" what picker.rlp_summary
            (Masc_tui_types.runtime_picker_keys enter picker.rlp_filter));
       if picker.rlp_choices = [] then
         c.push_styled ~style:(Theme.recede ())
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
               c.push
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
               c.push
                 (Printf.sprintf "  %s %s%s%s%s" mark
                    label
                    ctx def
                    (Ansi.dim ^ note ^ Ansi.reset));
               (match picker.rlp_pick with
                | Masc_tui_types.Pick_exact_lane _ | Masc_tui_types.Pick_exact_lane_replacement _ ->
                    c.push ("      Quota scope " ^ Terminal_text.single_line (runtime_quota_scope_label runtime)
                      ^ " · Connection " ^ Terminal_text.single_line runtime.ro_provider_id
                      ^ " · " ^ Terminal_text.single_line runtime.ro_id)
                | Pick_media_failover | Pick_route_default | Pick_conversation_lane _
                | Pick_new_lane _ -> ())) picker.rlp_choices;
       c.push_divider ());
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.runtime_surface
          ~error:state.runtime_surface_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
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
          (* Names preserve both ends; the fallback label preserves its head. *)
          let lane_cell =
            if candidate.rcr_candidate_count <= 1 || is_first then
              Terminal_text.single_line candidate.rcr_lane_id
            else
              (Printf.sprintf "  %s fallback #%d"
                   (if is_last then "\xe2\x94\x94\xe2\x94\x80" else "\xe2\x94\x9c\xe2\x94\x80")
                   (candidate.rcr_position - 1))
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

let tools_scrolled state =
  let _, cols = get_terminal_size () in
  tools_scrolled_for_lines state (Render_tools.tools_display_lines ~cols state)
;;

let render_tools (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    Printf.sprintf "%s  %s  %s"
      (screen_title " MASC System / Tools") timestamp
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_line buf cols (" " ^ Render_tools.tools_pane_strip ~cols state);
  box_line_styled buf cols ~style:Theme.selection
    (Render_tools.tools_selection_line ~cols state);
  box_divider buf cols;
  (match state.tools_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let display_lines = Render_tools.tools_display_lines ~cols state in
  let layout = tools_scrolled_for_lines state display_lines in
  let drawable = layout.sc_count in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:drawable ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (drawable - content_height) in
  let scroll = max 0 (min state.tools_scroll max_scroll) in
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
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"tools" ~rows:terminal_rows ~cols buf


let provider_history_lines ~cols (state : state) =
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
      let width = max 1 (framed_inner_width cols - 3) in
      let minimum_card_cells = max 64 (7 + days * 2 + 4) in
      let paired = width >= 2 * minimum_card_cells + 2 in
      let card_width = if paired then (width - 2) / 2 else width in
      let inner = max 1 (card_width - 4) in
      let wrap text = Message_layout.wrap_words ~max_cells:inner text in
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
              (match sample.report with
               | Masc_tui_usage_trend.Measured (value, _) -> Overview_providers.utilization_text value
               | Masc_tui_usage_trend.Reported_no_windows -> "reported no windows")
              (time.Unix.tm_mon + 1) time.Unix.tm_mday time.Unix.tm_hour time.Unix.tm_min in
        let body = wrap (Terminal_text.single_line limit ^ Terminal_text.single_line row.kind)
          @ (match email with None -> [] | Some email -> wrap email)
          @ wrap latest
          @ Masc_tui_usage_trend.plot ~width:inner trend row
          @ wrap (Printf.sprintf "%d/%d UTC days reported" row.reported_days days) in
        let heading = Message_layout.truncate_middle inner (label row.scope_id) in
        let line text = Theme.recede () ^ Ansi.box_v ^ Ansi.reset ^ " "
          ^ Message_layout.fit_width text inner ^ " " ^ Theme.recede () ^ Ansi.box_v ^ Ansi.reset in
        (Theme.info () ^ Ansi.box_tl ^ " " ^ Ansi.bold ^ heading ^ Ansi.reset ^ Theme.info ()
         ^ " " ^ draw_hline (max 0 (card_width - Message_layout.display_width heading - 4))
         ^ Ansi.box_tr ^ Ansi.reset)
        :: List.map line body
        @ [Theme.recede () ^ Ansi.box_bl ^ draw_hline (max 0 (card_width - 2)) ^ Ansi.box_br ^ Ansi.reset]
      in
      let rec arrange = function
        | [] -> []
        | left :: right :: rest when paired ->
          let left = chart left and right = chart right in
          let height = max (List.length left) (List.length right) in
          let row lines index = Option.value ~default:(String.make card_width ' ') (List.nth_opt lines index) in
          List.init height (fun index -> "   " ^ row left index ^ "  " ^ row right index)
          @ [""] @ arrange rest
        | row :: rest -> List.map (fun line -> "   " ^ line) (chart row) @ [""] @ arrange rest in
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

let usage_lines ~cols (state : state) =
  let open Masc.Tui_decode_usage in
  let scopes =
    match Overview_providers.section
            ~providers:(usage_providers_reading state) ~runtimes:state.overview_quota
            ~account_emails:state.overview_account_emails
            ~show_unusable:state.usage_show_unusable
            ~now:(Unix.gettimeofday ()) ~width:(max 20 (framed_inner_width cols)) with
    | Some section -> section.title :: section.lines
    (* [section] answers [None] only before the first read. *)
    | None -> [ " Plan usage · not observed" ]
  in
  let keepers =
    match state.keeper_usage with
    | Keeper_usage_unread -> [ " Keeper usage (24h) · not observed" ]
    | Keeper_usage_error reason ->
        [ " Keeper usage (24h) · unavailable: " ^ Terminal_text.single_line reason ]
    | Keeper_usage_read Keeper_usage_loading ->
        [ " Keeper usage (24h) · collecting" ]
    | Keeper_usage_read (Keeper_usage_window { kuw_rows; kuw_window_minutes; kuw_freshness; kuw_generated_at }) ->
        let freshness = match kuw_freshness with
          | Keeper_usage_fresh -> ""
          | Keeper_usage_stale { age_s; last_error } ->
              Printf.sprintf " · %.0fs old%s" age_s
                (Option.fold ~none:" · refreshing"
                   ~some:(fun reason -> " · refresh failed: " ^ Terminal_text.single_line reason)
                   last_error)
        in
        let readable row = match row.kur_coverage with
          | Keeper_usage_failed _ | Keeper_usage_partial _ -> false
          | Keeper_usage_complete -> true
        in
        let token_value row = Option.map float_of_int row.kur_tokens in
        let cost_value row = row.kur_cost_usd in
        let valid value = Float.is_finite value && value >= 0. in
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
        let bar_cells = min 32 (max 1 (width - 2)) in
        let meter value highest row =
          match value row with
          | Some amount when readable row && valid amount ->
              let maximum = Option.value ~default:0. highest in
              let filled = if maximum = 0. then 0
                else min bar_cells (int_of_float (amount /. maximum *. float_of_int bar_cells)) in
              "[" ^ String.concat "" (List.init bar_cells
                (fun index -> if index < filled then "█" else "░")) ^ "]"
              ^ (if amount = 0. then " 0" else "")
          | _ -> "[unavailable · no comparison bar]"
        in
        let generated = Unix.gmtime kuw_generated_at in
        [ Printf.sprintf " Keeper usage · last %dm · recorded turn metrics%s"
            kuw_window_minutes freshness
        ; Printf.sprintf " As of %04d-%02d-%02d %02d:%02d UTC"
            (generated.Unix.tm_year + 1900) (generated.Unix.tm_mon + 1)
            generated.Unix.tm_mday generated.Unix.tm_hour generated.Unix.tm_min
        ; " Bars compare read windows; each metric scales to its largest Keeper."
        ; " Partial windows have no comparison bar; missing metrics can understate totals; bars are not quota."
        ; Printf.sprintf " Scale: tokens %s · cost %s"
            (scale token_value (Printf.sprintf "%.0f") token_max)
            (scale cost_value (Printf.sprintf "$%.4f") cost_max)
        ; "" ]
        @ (if kuw_rows = [] then [ "   No Keepers in the returned roster" ]
            else List.concat_map
              (fun (row : Masc.Tui_decode_usage.keeper_usage_row) ->
                let tokens =
                  Option.fold ~none:"unreported" ~some:string_of_int row.kur_tokens in
                let cost =
                  Option.fold ~none:"unreported"
                    ~some:(Printf.sprintf "$%.4f") row.kur_cost_usd in
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
                let heading = Masc_tui_message_layout.fit_middle width
                    (Terminal_text.single_line row.kur_name) in
                [ "   " ^ Theme.info () ^ Ansi.bold ^ heading ^ Ansi.reset ]
                @ List.concat_map
                    (fun line -> List.map (fun text -> "   " ^ text)
                        (Masc_tui_message_layout.wrap_words ~max_cells:width line))
                    [ Printf.sprintf "%d turns · %s" row.kur_turn_samples coverage
                    ; Printf.sprintf "Tokens  %s · %d reported, %d missing"
                        tokens row.kur_tokens_reported row.kur_tokens_missing
                    ; meter token_value token_max row
                    ; Printf.sprintf "Cost    %s · %d reported, %d missing"
                        cost row.kur_cost_reported row.kur_cost_missing
                    ; meter cost_value cost_max row
                    ; "" ])
              kuw_rows)
  in
  let wrap_evidence lines =
    (* Wrap before the scroll window is counted. Coverage and missing samples
       remain reachable rows on narrow terminals. *)
    List.concat_map
      (fun line ->
        if String.equal line "" then [ "" ]
        else if Message_layout.display_width line <= framed_inner_width cols then [line]
        else
          let rec leading index =
            if index < String.length line && Char.equal line.[index] ' '
            then leading (index + 1) else index in
          let indent_cells = leading 0 in
          let indent = String.make indent_cells ' ' in
          let body = String.sub line indent_cells (String.length line - indent_cells) in
          Message_layout.split_styled_cells
            ~max_cells:(max 1 (framed_inner_width cols - indent_cells)) body
          |> List.map (fun text -> indent ^ text))
      lines
  in
  let selection_lines = match state.usage_scope_id, state.usage_section with
    | None, (Usage_plan | Usage_trend) -> []
    | (None | Some _), Usage_keepers -> []
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
        Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2))
          (String.concat "\n" (("Account · " ^ label ^ " · f:choose · a:all accounts") :: missing))
        @ [""] in
  match state.usage_section with
  (* Plan cards already have a cell-sized border and wrapped contents. *)
  | Usage_plan -> selection_lines @ scopes
  | Usage_trend -> selection_lines @ wrap_evidence (provider_history_lines ~cols state)
  | Usage_keepers ->
      let currency = match Masc_tui_candle.summary_lines state.candle_observation with
        | [] -> []
        | lines ->
            [ " " ^ Ansi.bold ^ "Candle · workspace supply" ^ Ansi.reset ]
            @ List.map (fun line -> "   " ^ Terminal_text.single_line line) lines
            @ [ Theme.recede () ^ draw_hline (framed_inner_width cols) ^ Ansi.reset ]
      in
      wrap_evidence (currency @ keepers)

let render_metrics (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec
  in
  (* The section being read is marked on the strip under this row, so the
     title does not name it a second time. *)
  let title =
    Printf.sprintf "%s  %s  %s"
      (screen_title
         (if state.usage_telemetry_open then " MASC Usage / Telemetry"
          else " MASC Usage"))
      timestamp (connection_badge state)
  in
  (* The section's lines are formatted by the drawing, so the row it could
     start at is known only once it has. The body writes it here and the
     contract reads it back out. *)
  let drawn_metrics_scroll = ref state.metrics_scroll in
  surface_chrome
    ~overflow:(Self_scrolled (fun () -> Metrics_scroll !drawn_metrics_scroll))
    state ~terminal_rows ~cols ~surface_key:"metrics"
    ~title
    ~hints:(Masc_tui_keys.footer_hints_metrics
              ~telemetry:state.usage_telemetry_open)
    ~body:(fun ~budget c ->
      if state.usage_telemetry_open then
        Metrics_page.render_metrics_body ~cols ~budget state
          ~report_scroll:(fun scroll -> drawn_metrics_scroll := scroll)
          ~push:c.push ~push_styled:c.push_styled
          ~push_selected:c.push_selected ~push_divider:c.push_divider
          ~push_empty:c.push_empty
      else begin
        let pill section label =
          if state.usage_section = section then Ansi.reverse ^ " " ^ label ^ " " ^ Ansi.reset
          else Theme.recede () ^ " " ^ label ^ " " ^ Ansi.reset
        in
        let navigation_rows = if budget >= 3 then 1 else 0 in
        let spacing_rows = if budget >= 6 then 1 else 0 in
        if navigation_rows > 0 then
          c.push (pill Usage_plan "Plan" ^ "  " ^ pill Usage_trend "Trend"
                  ^ "  " ^ pill Usage_keepers "Keepers" ^ "   v:next view");
        if spacing_rows > 0 then c.push "";
        let lines = usage_lines ~cols state in
        let content_budget = max 0 (budget - navigation_rows - spacing_rows) in
        let overflow_rows = if content_budget >= 2 && List.length lines > content_budget then 1 else 0 in
        let height = content_budget - overflow_rows in
        let max_scroll = max 0 (List.length lines - height) in
        let scroll = min max_scroll (max 0 state.metrics_scroll) in
        drawn_metrics_scroll := scroll;
        List.iteri
          (fun index line ->
            if index >= scroll && index < scroll + height then c.push line)
          lines;
        if overflow_rows > 0 then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "  [rows %s · j/k to scroll]"
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
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"runtime-pick"
    ~title:
      (Printf.sprintf "%s  %scurrent: %s%s"
         (screen_title
            (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 runtime" keeper_name))
         Ansi.dim current Ansi.reset)
    ~hints:(Masc_tui_keys.footer_hints (Keepers Keeper_runtime_pick))
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
          else c.push ("  " ^ line))
        view.Masc_tui_pick_list.rows)
