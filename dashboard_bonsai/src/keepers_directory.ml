open! Core
open! Bonsai_web
open Virtual_dom.Vdom

let selected_name_var : string option Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create None
;;

type source =
  [ `Runtime
  | `Mission
  | `Runtime_and_mission
  ]

type band =
  [ `Active
  | `Attention
  | `Paused
  | `Offline
  ]

type model_meta =
  { label : string
  ; display_value : string
  ; raw_value : string option
  }

type note =
  { label : string
  ; text : string
  }

type row =
  { name : string
  ; agent_name : string option
  ; source : source
  ; band : band
  ; status_label : string
  ; status_color : Pill.color
  ; phase_label : string option
  ; stage_label : string option
  ; model : model_meta option
  ; context_pct : int option
  ; context_detail : string option
  ; recent_label : string
  ; recent_value : string
  ; note : note option
  ; current_work : string option
  ; sparse_reasons : string list
  ; runtime : Directory_execution_types.keeper option
  ; mission : Directory_mission_types.keeper_brief option
  ; agent : Directory_mission_types.agent_brief option
  }

type counts =
  { total : int
  ; active : int
  ; attention : int
  ; paused : int
  ; offline : int
  }

type coverage =
  { shared : int
  ; runtime_only : int
  ; mission_only : int
  ; raw_models : int
  ; sparse_rows : int
  }

module Style =
[%css
stylesheet
  {|
  .directory {
    border: 1px solid var(--border-main);
    background: color-mix(in oklab, var(--bg-deep) 48%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--text-bright) 3%, transparent);
  }

  .head {
    display: grid;
    grid-template-columns: 52px minmax(0, 1.1fr) minmax(0, 1.6fr) 176px 96px;
    gap: 14px;
    align-items: center;
    padding: 10px 16px;
    border-bottom: 1px solid color-mix(in oklab, var(--border-highlight) 16%, transparent);
    background: linear-gradient(180deg, color-mix(in oklab, var(--bg-panel) 80%, var(--bg-deep)), var(--bg-deep));
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.28em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .row {
    position: relative;
    display: grid;
    grid-template-columns: 52px minmax(0, 1.1fr) minmax(0, 1.6fr) 176px 96px;
    gap: 14px;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid color-mix(in oklab, var(--border-highlight) 12%, transparent);
    cursor: pointer;
    transition: background 120ms ease;
  }

  .row:last-child { border-bottom: 0; }

  .row:hover,
  .row:focus-visible {
    background: color-mix(in oklab, var(--accent-brass) 4%, transparent);
  }

  .row:focus-visible {
    outline: 1px solid var(--accent-brass);
    outline-offset: -1px;
  }

  .row_selected {
    background: linear-gradient(90deg, color-mix(in oklab, var(--accent-brass) 8%, transparent), transparent 72%);
  }

  .row_selected::before {
    content: "";
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 2px;
    background: var(--accent-brass);
    box-shadow: 0 0 12px var(--accent-brass);
  }

  .sigil {
    width: 40px;
    height: 40px;
    border: 1px solid var(--accent-brass-dim);
    background:
      radial-gradient(circle at 35% 30%, color-mix(in oklab, var(--text-bright) 16%, transparent), transparent 58%),
      var(--bg-panel-alt, #1b140f);
    display: grid;
    place-items: center;
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 16px;
    letter-spacing: 0.1em;
    color: var(--text-bright);
    text-transform: uppercase;
  }

  .identity,
  .summary {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .name {
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 13px;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--text-bright);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .subline {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    line-height: 1.35;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .summary_k {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .summary_v {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 12px;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .chip_stack {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 6px;
  }

  .chip_row {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .metric {
    text-align: right;
    min-width: 0;
  }

  .metric_v {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 12px;
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
  }

  .metric_v_warn { color: var(--accent-brass); }
  .metric_v_bad { color: var(--accent-blood); }

  .metric_sub {
    margin-top: 3px;
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .vial_fill_warn {
    background: linear-gradient(90deg, var(--accent-brass-dim), var(--accent-brass));
    box-shadow: 0 0 6px color-mix(in oklab, var(--accent-brass) 35%, transparent);
  }

  .vial_fill_bad {
    background: linear-gradient(90deg, var(--accent-blood-dim), var(--accent-blood));
    box-shadow: 0 0 6px color-mix(in oklab, var(--accent-blood) 35%, transparent);
  }

  .meta_strip {
    margin: 0 0 12px;
  }

  .note_box {
    border: 1px solid var(--border-main);
    background: color-mix(in oklab, var(--bg-deep) 40%, transparent);
    padding: 12px 14px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .note_k {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .note_v {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 12px;
    line-height: 1.55;
    color: var(--text-primary);
  }

  .list {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .list_row {
    display: flex;
    align-items: flex-start;
    gap: 10px;
  }

  .list_k {
    min-width: 92px;
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .list_v {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    line-height: 1.5;
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
    word-break: break-word;
  }

  .preview_box {
    border: 1px solid color-mix(in oklab, var(--border-highlight) 18%, transparent);
    background: color-mix(in oklab, var(--bg-deep) 42%, transparent);
    padding: 10px 12px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .preview_label {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .preview_text {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 12px;
    line-height: 1.55;
    color: var(--text-primary);
    white-space: pre-wrap;
  }

  .quiet {
    padding: 24px 18px;
    border: 1px dashed var(--border-main);
    font-family: var(--font-body, 'EB Garamond', serif);
    font-size: 15px;
    font-style: italic;
    color: var(--text-dim);
    text-align: center;
  }

  @media (max-width: 1180px) {
    .head,
    .row {
      grid-template-columns: 44px minmax(0, 1fr) minmax(0, 1.1fr) 144px 82px;
      gap: 10px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      transition-duration: 0.01ms !important;
    }
  }
|}]

let normalize_lookup_key value = String.lowercase (String.strip value)

let present value =
  let trimmed = String.strip value in
  if String.is_empty trimmed then None else Some trimmed
;;

let add_first tbl key data =
  let normalized = normalize_lookup_key key in
  if not (Hashtbl.mem tbl normalized) then Hashtbl.set tbl ~key:normalized ~data
;;

let register_lookup tbl candidates data =
  List.iter candidates ~f:(function
    | None -> ()
    | Some candidate ->
      (match present candidate with
       | None -> ()
       | Some key -> add_first tbl key data))
;;

let short_hhmmss value =
  if String.length value >= 19 && Char.equal value.[10] 'T'
  then Printf.sprintf "%s UTC" (String.sub value ~pos:11 ~len:8)
  else value
;;

let compact_model_label value =
  match present value with
  | None -> None
  | Some model ->
    (match String.lsplit2 model ~on:':' with
     | Some (provider, suffix) ->
       let suffix = String.strip suffix in
       if String.is_empty suffix
       then Some model
       else if String.Caseless.equal suffix "auto"
       then
         let provider =
           let provider = String.strip provider in
           let drop suffix_len = String.drop_suffix provider suffix_len in
           if String.is_suffix ~suffix:"_cli" provider
           then drop 4
           else if String.is_suffix ~suffix:"-cli" provider
           then drop 4
           else if String.is_suffix ~suffix:"_code" provider
           then drop 5
           else if String.is_suffix ~suffix:"-code" provider
           then drop 5
           else provider
         in
         present provider
       else Some suffix
     | None -> Some model)
;;

let format_compact_int value =
  let f = Float.of_int value in
  if value >= 1_000_000
  then Printf.sprintf "%.1fM" (f /. 1_000_000.0)
  else if value >= 1000
  then Printf.sprintf "%.1fK" (f /. 1000.0)
  else Int.to_string value
;;

let format_age seconds =
  let seconds = Int.max 0 (Int.of_float (Float.round seconds)) in
  if seconds < 90
  then Printf.sprintf "%ds" seconds
  else if seconds < 5400
  then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 172800
  then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)
;;

let normalized_eq value target =
  String.equal (normalize_lookup_key value) (normalize_lookup_key target)
;;

let is_one_of value values =
  List.exists values ~f:(fun candidate -> normalized_eq value candidate)
;;

let phase_label_of_token token =
  match normalize_lookup_key token with
  | "running" | "active" -> Some "가동중"
  | "busy" -> Some "작업중"
  | "idle" | "listening" -> Some "대기"
  | "paused" -> Some "일시정지"
  | "offline" -> Some "오프라인"
  | "inactive" -> Some "비활성"
  | "stopped" -> Some "정지"
  | "unbooted" -> Some "미기동"
  | "dead" -> Some "종료"
  | "failing" -> Some "오류중"
  | "overflowed" -> Some "컨텍스트 초과"
  | "compacting" -> Some "압축중"
  | "handoff" | "handingoff" | "handing_off" -> Some "승계중"
  | "draining" -> Some "종료중"
  | "crashed" -> Some "중단"
  | "restarting" -> Some "재시작중"
  | _ -> present token
;;

let stage_label_of_token token =
  match normalize_lookup_key token with
  | "thinking" -> Some "사고"
  | "tool_use" -> Some "도구"
  | "compacting" -> Some "압축"
  | "handoff" -> Some "승계"
  | "scheduled_autonomous" -> Some "자율"
  | "failing" -> Some "오류"
  | "draining" -> Some "종료"
  | "paused" -> Some "일시정지"
  | "crashed" -> Some "중단"
  | "restarting" -> Some "재시작"
  | "idle" -> Some "활동 없음"
  | "offline" -> Some "오프라인"
  | _ -> present token
;;

let context_meta
      (runtime : Directory_execution_types.keeper option)
      (mission : Directory_mission_types.keeper_brief option)
  =
  let ratio =
    Option.first_some
      (Option.bind runtime ~f:(fun row -> row.context_ratio))
      (Option.bind mission ~f:(fun row -> row.context_ratio))
  in
  let pct =
    Option.map ratio ~f:(fun value ->
      Int.max 0 (Int.min 100 (Int.of_float (Float.round (value *. 100.0)))))
  in
  let detail =
    match runtime with
    | Some row ->
      (match row.context_tokens, row.context_max with
       | Some tokens, Some max ->
         Some
           (Printf.sprintf
              "%s / %s"
              (format_compact_int tokens)
              (format_compact_int max))
       | Some tokens, None -> Some (format_compact_int tokens)
       | _ -> None)
    | None -> None
  in
  pct, detail
;;

let model_meta (runtime : Directory_execution_types.keeper option) =
  let of_field ~label ~raw =
    match present raw with
    | None -> None
    | Some raw_value ->
      Some
        { label
        ; display_value =
            Option.value (compact_model_label raw_value) ~default:raw_value
        ; raw_value = Some raw_value
        }
  in
  match runtime with
  | None -> None
  | Some row ->
    Option.first_some
      (Option.map
         (present (Option.value row.last_model_used_label ~default:""))
         ~f:(fun label ->
           { label = "최근 모델"; display_value = label; raw_value = None }))
      (Option.first_some
         (of_field
            ~label:"최근 모델"
            ~raw:(Option.value row.last_model_used ~default:""))
         (Option.first_some
            (Option.map
               (present (Option.value row.active_model_label ~default:""))
               ~f:(fun label ->
                 { label = "현재 모델"; display_value = label; raw_value = None }))
            (Option.first_some
               (of_field
                  ~label:"현재 모델"
                  ~raw:(Option.value row.active_model ~default:""))
               (of_field
                  ~label:"모델"
                  ~raw:(Option.value row.model ~default:"")))))
;;

let trust_disposition (runtime : Directory_execution_types.keeper option) =
  Option.bind runtime ~f:(fun row ->
    Option.bind row.disposition ~f:present)
;;

let trust_disposition_reason (runtime : Directory_execution_types.keeper option) =
  Option.bind runtime ~f:(fun row ->
    Option.bind row.disposition_reason ~f:present)
;;

let trust_badge (runtime : Directory_execution_types.keeper option) =
  Option.map (trust_disposition runtime) ~f:(fun label ->
    let color =
      if normalized_eq label "pass"
      then `Ok
      else if is_one_of label [ "pause"; "paused" ]
      then `Warn
      else `Bad
    in
    label, color)
;;

let latest_causal_event_text (runtime : Directory_execution_types.keeper option) =
  Option.bind runtime ~f:(fun row ->
    Option.bind row.latest_causal_event ~f:(fun event ->
      let text =
        match present event.title, present event.summary with
        | Some title, Some summary when not (String.equal title summary) ->
          Some (title ^ " · " ^ summary)
        | Some title, _ -> Some title
        | None, Some summary -> Some summary
        | None, None -> present event.kind
      in
      Option.map text ~f:(fun value ->
        match present event.ts with
        | Some ts -> value ^ " · " ^ short_hhmmss ts
        | None -> value)))
;;

let next_human_action (runtime : Directory_execution_types.keeper option) =
  Option.first_some
    (Option.bind runtime ~f:(fun row ->
       Option.bind row.next_human_action ~f:present))
    (Option.bind runtime ~f:(fun row ->
       Option.bind row.latest_causal_event ~f:(fun event ->
         Option.bind event.next_human_action ~f:present)))
;;

let note_entries
      (runtime : Directory_execution_types.keeper option)
      (mission : Directory_mission_types.keeper_brief option)
      (agent : Directory_mission_types.agent_brief option)
  =
  let trust_note =
    Option.map (trust_disposition runtime) ~f:(fun label ->
      let text =
        match trust_disposition_reason runtime with
        | Some reason -> label ^ " · " ^ reason
        | None -> label
      in
      { label = "Trust"; text })
  in
  List.filter_opt
    [ trust_note
    ; Option.map (next_human_action runtime) ~f:(fun text ->
        { label = "Next action"; text })
    ; Option.map (latest_causal_event_text runtime) ~f:(fun text ->
        { label = "Causal event"; text })
    ; Option.bind runtime ~f:(fun row ->
        Option.map (present (Option.value row.runtime_blocker_summary ~default:""))
          ~f:(fun text -> { label = "최근 차단"; text }))
    ; Option.bind runtime ~f:(fun row ->
        Option.map (present (Option.value row.last_blocker ~default:""))
          ~f:(fun text -> { label = "최근 차단"; text }))
    ; Option.bind runtime ~f:(fun row ->
        Option.bind row.diagnostic ~f:(fun diagnostic ->
          Option.map (present (Option.value diagnostic.last_error ~default:""))
            ~f:(fun text -> { label = "최근 오류"; text })))
    ; Option.bind mission ~f:(fun row ->
        Option.map (present (Option.value row.current_work ~default:""))
          ~f:(fun text -> { label = "현재 작업"; text }))
    ; Option.bind agent ~f:(fun row ->
        Option.map (present (Option.value row.recent_output_preview ~default:""))
          ~f:(fun text -> { label = "최근 출력"; text }))
    ]
;;

let note_meta
      (runtime : Directory_execution_types.keeper option)
      (mission : Directory_mission_types.keeper_brief option)
      (agent : Directory_mission_types.agent_brief option)
  =
  List.hd (note_entries runtime mission agent)
;;

let recent_meta
      (runtime : Directory_execution_types.keeper option)
      (mission : Directory_mission_types.keeper_brief option)
      (agent : Directory_mission_types.agent_brief option)
  =
  match Option.bind runtime ~f:(fun row -> row.last_turn_ago_s) with
  | Some seconds -> "최근 턴", format_age seconds
  | None ->
    (match Option.bind agent ~f:(fun row -> row.last_activity_age_sec) with
     | Some seconds -> "최근 활동", format_age seconds
     | None ->
       (match Option.bind mission ~f:(fun row -> row.last_turn_ago_s) with
        | Some seconds -> "최근 턴", format_age seconds
        | None ->
          (match Option.bind mission ~f:(fun row -> row.tool_audit_at) with
           | Some timestamp -> "최근 audit", short_hhmmss timestamp
           | None ->
             (match Option.bind runtime ~f:(fun row -> row.last_heartbeat) with
              | Some timestamp -> "최근 heartbeat", short_hhmmss timestamp
              | None -> "최근성", "기록 없음"))))
;;

let current_work
      (_runtime : Directory_execution_types.keeper option)
      (mission : Directory_mission_types.keeper_brief option)
      (agent : Directory_mission_types.agent_brief option)
  =
  Option.first_some
    (Option.bind mission ~f:(fun row -> row.current_work))
    (Option.bind agent ~f:(fun row -> row.current_work))
;;

let runtime_has_attention (runtime : Directory_execution_types.keeper) =
  let phase_attention =
    Option.exists runtime.phase ~f:(fun value ->
      is_one_of
        value
        [ "failing"
        ; "overflowed"
        ; "compacting"
        ; "handoff"
        ; "handingoff"
        ; "handing_off"
        ; "draining"
        ; "crashed"
        ; "restarting"
        ])
  in
  let stage_attention =
    Option.exists runtime.pipeline_stage ~f:(fun value ->
      is_one_of
        value
        [ "failing"
        ; "compacting"
        ; "handoff"
        ; "draining"
        ; "crashed"
        ; "restarting"
        ])
  in
  let degraded =
    Option.exists runtime.diagnostic ~f:(fun diagnostic ->
      Option.exists diagnostic.health_state ~f:(fun value ->
        is_one_of value [ "degraded"; "warning"; "critical" ])
      || Option.exists diagnostic.continuity_state ~f:(fun value ->
        is_one_of value [ "recovering"; "warning"; "critical" ]))
  in
  let has_blocker =
    List.exists
      [ runtime.runtime_blocker_summary
      ; runtime.last_blocker
      ; Option.bind runtime.diagnostic ~f:(fun diagnostic -> diagnostic.last_error)
      ]
      ~f:Option.is_some
  in
  let high_ctx =
    Option.value_map runtime.context_ratio ~default:false ~f:(fun ratio ->
      Float.(ratio >= 0.95))
  in
  let trust_attention =
    Option.exists runtime.disposition ~f:(fun value ->
      not (normalized_eq value "pass"))
    || Option.is_some (next_human_action (Some runtime))
  in
  phase_attention
  || stage_attention
  || degraded
  || has_blocker
  || high_ctx
  || trust_attention
;;

let runtime_is_offline
      (runtime : Directory_execution_types.keeper)
      (_mission : Directory_mission_types.keeper_brief option)
      (_agent : Directory_mission_types.agent_brief option)
  =
  List.exists
    [ Some runtime.status
    ; runtime.phase
    ; Option.bind runtime.diagnostic ~f:(fun diagnostic -> diagnostic.health_state)
    ; Option.bind runtime.diagnostic ~f:(fun diagnostic -> diagnostic.continuity_state)
    ]
    ~f:(function
      | None -> false
      | Some value ->
        is_one_of value [ "offline"; "inactive"; "stopped"; "dead"; "not_running" ])
;;

let band_of_row
      (runtime : Directory_execution_types.keeper option)
      (mission : Directory_mission_types.keeper_brief option)
      (agent : Directory_mission_types.agent_brief option)
  =
  let is_paused =
    Option.value_map runtime ~default:false ~f:(fun row ->
      Option.value row.paused ~default:false
      || is_one_of row.status [ "paused" ]
      || Option.exists row.phase ~f:(fun value -> is_one_of value [ "paused" ]))
    || Option.exists mission ~f:(fun row ->
      Option.exists row.status ~f:(fun value -> is_one_of value [ "paused" ]))
  in
  if is_paused
  then `Paused
  else (
    match runtime with
    | Some row ->
      if runtime_is_offline row mission agent
      then `Offline
      else if runtime_has_attention row
      then `Attention
      else `Active
    | None ->
      if Option.exists mission ~f:(fun row ->
        Option.exists row.status ~f:(fun value ->
          is_one_of value [ "offline"; "inactive"; "stopped" ]))
         || Option.exists agent ~f:(fun row ->
           Option.exists row.status ~f:(fun value ->
             is_one_of value [ "offline"; "inactive"; "stopped" ]))
      then `Offline
      else if Option.exists agent ~f:(fun row ->
        Option.exists row.signal_truth ~f:(fun value ->
          is_one_of value [ "stale"; "archived" ]))
      then `Attention
      else `Active)
;;

let status_meta
      (runtime : Directory_execution_types.keeper option)
      (mission : Directory_mission_types.keeper_brief option)
      (band : band)
  =
  let phase_label =
    Option.first_some
      (Option.bind runtime ~f:(fun row -> Option.bind row.phase ~f:phase_label_of_token))
      (Option.bind runtime ~f:(fun row -> phase_label_of_token row.status))
  in
  let has_error_note =
    Option.value_map runtime ~default:false ~f:(fun row ->
      List.exists
        [ row.runtime_blocker_summary
        ; row.last_blocker
        ; Option.bind row.diagnostic ~f:(fun diagnostic -> diagnostic.last_error)
        ]
        ~f:Option.is_some)
  in
  let trust_label =
    Option.map (trust_badge runtime) ~f:(fun (label, _color) -> label)
  in
  let status_label, status_color =
    match band with
    | `Paused -> "일시정지", `Paused
    | `Offline ->
      let generation =
        Option.first_some
          (Option.bind runtime ~f:(fun row -> row.generation))
          (Option.bind mission ~f:(fun row -> row.generation))
      in
      let turn_count = Option.bind runtime ~f:(fun row -> row.turn_count) in
      let had_activity =
        Option.is_some (Option.bind runtime ~f:(fun row -> row.last_turn_ago_s))
        || Option.is_some (Option.bind mission ~f:(fun row -> row.last_turn_ago_s))
        || Option.exists generation ~f:(fun value -> value > 0)
        || Option.exists turn_count ~f:(fun value -> value > 0)
      in
      let label =
        if not had_activity
        then "미기동"
        else if Option.exists runtime ~f:(fun row ->
          Option.exists row.keepalive_running ~f:not)
        then "오프라인"
        else "정지"
      in
      label, `Neutral
    | `Attention ->
      let label =
        if has_error_note
        then "활동 오류"
        else Option.value (Option.first_some trust_label phase_label) ~default:"주의 필요"
      in
      let color = if has_error_note then `Bad else `Warn in
      label, color
    | `Active ->
      (match Option.bind runtime ~f:(fun row -> Option.bind row.pipeline_stage ~f:stage_label_of_token) with
       | Some stage when not (String.equal stage "활동 없음") -> stage, `Ok
       | _ -> "가동중", `Ok)
  in
  phase_label, status_label, status_color
;;

let source_of_row runtime mission =
  match runtime, mission with
  | Some _, Some _ -> `Runtime_and_mission
  | Some _, None -> `Runtime
  | None, Some _ -> `Mission
  | None, None -> `Runtime
;;

let source_label = function
  | `Runtime_and_mission -> "runtime + mission"
  | `Runtime -> "runtime only"
  | `Mission -> "mission only"
;;

let source_short = function
  | `Runtime_and_mission -> "rt+ms"
  | `Runtime -> "rt"
  | `Mission -> "ms"
;;

let row_sigil name =
  if String.is_empty name
  then "·"
  else Char.to_string (Char.uppercase name.[0])
;;

let build_rows
      ~(keepers : Keepers_types.response)
      (execution : Directory_execution_types.response)
      (mission : Directory_mission_types.response)
  : row list
  =
  let runtime_tbl = Hashtbl.create (module String) in
  let mission_tbl = Hashtbl.create (module String) in
  let agent_tbl = Hashtbl.create (module String) in
  List.iter execution.keepers ~f:(fun row ->
    register_lookup runtime_tbl [ Some row.name; row.agent_name ] row);
  List.iter mission.keeper_briefs ~f:(fun row ->
    register_lookup mission_tbl [ Some row.name; row.agent_name ] row);
  List.iter mission.agent_briefs ~f:(fun row ->
    register_lookup agent_tbl [ Some row.agent_name; row.display_name ] row);
  let all_names =
    List.concat
      [ List.map keepers.keepers ~f:(fun row -> row.name)
      ; List.map execution.keepers ~f:(fun row -> row.name)
      ; List.map mission.keeper_briefs ~f:(fun row -> row.name)
      ]
  in
  let seen = Hash_set.create (module String) in
  List.filter_map all_names ~f:(fun raw_name ->
    match present raw_name with
    | None -> None
    | Some lookup_name ->
      let normalized = normalize_lookup_key lookup_name in
      if Hash_set.mem seen normalized
      then None
      else (
        Hash_set.add seen normalized;
        let runtime = Hashtbl.find runtime_tbl normalized in
        let mission_keeper = Hashtbl.find mission_tbl normalized in
        match runtime, mission_keeper with
        | None, None -> None
        | _ ->
          let name =
            match runtime, mission_keeper with
            | Some row, _ -> row.name
            | None, Some row -> row.name
            | None, None -> lookup_name
          in
          let agent_name =
            Option.first_some
              (Option.bind runtime ~f:(fun row -> row.agent_name))
              (Option.bind mission_keeper ~f:(fun row -> row.agent_name))
          in
          let agent =
            List.find_map
              [ agent_name; Some name ]
              ~f:(fun key ->
                Option.bind key ~f:(fun value ->
                  Hashtbl.find agent_tbl (normalize_lookup_key value)))
          in
          let source = source_of_row runtime mission_keeper in
          let band = band_of_row runtime mission_keeper agent in
          let phase_label, status_label, status_color =
            status_meta runtime mission_keeper band
          in
          let stage_label =
            Option.bind runtime ~f:(fun row ->
              Option.bind row.pipeline_stage ~f:stage_label_of_token)
          in
          let context_pct, context_detail = context_meta runtime mission_keeper in
          let recent_label, recent_value = recent_meta runtime mission_keeper agent in
          let model = model_meta runtime in
          let note = note_meta runtime mission_keeper agent in
          let current_work = current_work runtime mission_keeper agent in
          let sparse_reasons =
            List.filter_opt
              [ (match runtime with
                 | None -> Some "runtime 없음"
                 | Some _ -> None)
              ; (match mission_keeper with
                 | None -> Some "mission brief 없음"
                 | Some _ -> None)
              ; (match agent with
                 | None -> Some "agent brief 없음"
                 | Some _ -> None)
              ; (match model with
                 | Some { raw_value = Some _; _ } -> Some "display label 미해결(raw)"
                 | _ -> None)
              ]
          in
          Some
            { name
            ; agent_name
            ; source
            ; band
            ; status_label
            ; status_color
            ; phase_label
            ; stage_label
            ; model
            ; context_pct
            ; context_detail
            ; recent_label
            ; recent_value
            ; note
            ; current_work
            ; sparse_reasons
            ; runtime
            ; mission = mission_keeper
            ; agent
            }))
;;

let counts rows =
  List.fold rows ~init:{ total = 0; active = 0; attention = 0; paused = 0; offline = 0 }
    ~f:(fun acc row ->
      match row.band with
      | `Active ->
        { acc with total = acc.total + 1; active = acc.active + 1 }
      | `Attention ->
        { acc with total = acc.total + 1; attention = acc.attention + 1 }
      | `Paused ->
        { acc with total = acc.total + 1; paused = acc.paused + 1 }
      | `Offline ->
        { acc with total = acc.total + 1; offline = acc.offline + 1 })
;;

let coverage rows =
  List.fold rows
    ~init:{ shared = 0; runtime_only = 0; mission_only = 0; raw_models = 0; sparse_rows = 0 }
    ~f:(fun acc row ->
      let shared, runtime_only, mission_only =
        match row.source with
        | `Runtime_and_mission -> acc.shared + 1, acc.runtime_only, acc.mission_only
        | `Runtime -> acc.shared, acc.runtime_only + 1, acc.mission_only
        | `Mission -> acc.shared, acc.runtime_only, acc.mission_only + 1
      in
      let raw_models =
        match row.model with
        | Some { raw_value = Some _; _ } -> acc.raw_models + 1
        | _ -> acc.raw_models
      in
      let sparse_rows =
        if List.is_empty row.sparse_reasons
        then acc.sparse_rows
        else acc.sparse_rows + 1
      in
      { shared; runtime_only; mission_only; raw_models; sparse_rows })
;;

let default_selected_name rows =
  List.find_map rows ~f:(fun row ->
    match row.band with
    | `Active | `Attention -> Some row.name
    | `Paused | `Offline -> None)
  |> Option.first_some (List.hd rows |> Option.map ~f:(fun row -> row.name))
;;

let selected_row rows selected_name =
  let chosen_name =
    match selected_name with
    | Some name when List.exists rows ~f:(fun row -> String.equal row.name name) ->
      Some name
    | _ -> default_selected_name rows
  in
  Option.bind chosen_name ~f:(fun name ->
    List.find rows ~f:(fun row -> String.equal row.name name))
;;

let row_click_effect name =
  let select () = Bonsai.Expert.Var.set selected_name_var (Some name) in
  [ Attr.on_click (fun _ -> Effect.of_sync_fun select ())
  ; Attr.on_key_down (fun ev ->
      let open Virtual_dom.Vdom.Event.Keyboard in
      if Key.equal ev.key Key.Enter || Key.equal ev.key (Key.of_string " ")
      then Effect.of_sync_fun select ()
      else Effect.of_sync_fun (fun () -> ()) ())
  ]
;;

let context_class pct =
  match pct with
  | Some value when value >= 95 -> Style.metric_v_bad
  | Some value when value >= 80 -> Style.metric_v_warn
  | _ -> Style.metric_v
;;

let view_summary_strip
      ~(rows : row list)
      ~(execution : Directory_execution_types.response)
      ~(mission : Directory_mission_types.response)
  =
  let execution_generated_at =
    let open Directory_execution_types in
    execution.generated_at
  in
  let mission_generated_at =
    let open Directory_mission_types in
    mission.generated_at
  in
  let summary = coverage rows in
  Meta.strip
    ~label:"Keepers summary"
    [ Meta.cell
        ~color:
          (if String.is_empty execution_generated_at then `Default else `Ok)
        ~k:"runtime snapshot"
        ~v:
          (if String.is_empty execution_generated_at
           then "pending"
           else short_hhmmss execution_generated_at)
        ()
    ; Meta.cell
        ~color:
          (if String.is_empty mission_generated_at then `Default else `Ok)
        ~k:"mission snapshot"
        ~v:
          (if String.is_empty mission_generated_at
           then "pending"
           else short_hhmmss mission_generated_at)
        ()
    ; Meta.cell
        ~color:(if summary.shared > 0 then `Brass else `Default)
        ~k:"coverage"
        ~v:
          (Printf.sprintf
             "%d shared · %d rt · %d ms"
             summary.shared
             summary.runtime_only
             summary.mission_only)
        ()
    ; Meta.cell
        ~color:(if summary.raw_models > 0 then `Brass else `Default)
        ~k:"raw model"
        ~v:(Printf.sprintf "%d unresolved" summary.raw_models)
        ()
    ; Meta.cell
        ~color:(if summary.sparse_rows > 0 then `Blood else `Default)
        ~k:"sparse rows"
        ~v:(Printf.sprintf "%d rows" summary.sparse_rows)
        ()
    ]
;;

let view
      ~(rows : row list)
      ~(selected_name : string option)
  : Node.t
  =
  match rows with
  | [] ->
    Node.div
      ~attrs:[ Style.quiet; Attr.role "status"; Attr.create "aria-label" "Directory loading" ]
      [ Node.span ~attrs:[ Attr.create "lang" "ko" ]
          [ Node.text
              "runtime/mission snapshot이 아직 조용합니다. keepers summary만 먼저 올라왔을 가능성이 있습니다."
          ]
      ]
  | _ ->
    let selected = selected_row rows selected_name in
    Node.div
      ~attrs:[ Style.directory; Attr.role "table"; Attr.create "aria-label" "Keepers directory" ]
      ([ Node.div
           ~attrs:[ Style.head; Attr.role "row" ]
           [ Node.div ~attrs:[ Attr.role "columnheader" ] [ Node.text "Sigil" ]
           ; Node.div ~attrs:[ Attr.role "columnheader" ] [ Node.text "Keeper" ]
           ; Node.div ~attrs:[ Attr.role "columnheader" ] [ Node.text "Brief" ]
           ; Node.div ~attrs:[ Attr.role "columnheader" ] [ Node.text "State" ]
           ; Node.div ~attrs:[ Attr.role "columnheader"; Style.metric ] [ Node.text "Recent" ]
           ]
       ]
       @ List.map rows ~f:(fun row ->
         let is_selected =
           Option.exists selected ~f:(fun current ->
             String.equal current.name row.name)
         in
         let subtitle_bits =
           List.filter_opt
             [ row.agent_name
             ; Option.map row.model ~f:(fun model ->
                 let suffix =
                   match model.raw_value with
                   | Some _ -> " raw"
                   | None -> ""
                 in
                 Printf.sprintf
                   "%s %s%s"
                   model.label
                   model.display_value
                   suffix)
             ; Some (source_short row.source)
             ]
         in
         let summary_k, summary_v =
           match row.note with
           | Some note -> note.label, note.text
           | None ->
             "현재 작업"
             , Option.value
                 row.current_work
                 ~default:"mission/runtime note가 아직 없습니다."
         in
         let row_attrs =
           [ Style.row
           ; Attr.tabindex 0
           ; Attr.role "row"
           ; Attr.create "aria-label" row.name
           ]
           @ row_click_effect row.name
           @ if is_selected then [ Style.row_selected ] else []
         in
         Node.div
           ~attrs:row_attrs
           [ Node.div ~attrs:[ Style.sigil; Attr.role "cell" ] [ Node.text (row_sigil row.name) ]
           ; Node.div
               ~attrs:[ Style.identity; Attr.role "cell" ]
               [ Node.div ~attrs:[ Style.name ] [ Node.text row.name ]
               ; Node.div
                   ~attrs:[ Style.subline ]
                   [ Node.text (String.concat ~sep:" · " subtitle_bits) ]
               ]
           ; Node.div
               ~attrs:[ Style.summary; Attr.role "cell" ]
               [ Node.div ~attrs:[ Style.summary_k ] [ Node.text summary_k ]
               ; Node.div ~attrs:[ Style.summary_v ] [ Node.text summary_v ]
               ]
           ; Node.div
               ~attrs:[ Style.chip_stack; Attr.role "cell" ]
               [ Node.div
                   ~attrs:[ Style.chip_row ]
                   [ Pill.view ~size:`Sm ~color:row.status_color
                       ~label:row.status_label ()
                   ; Pill.view
                       ~size:`Sm
                       ~color:
                         (match row.source with
                          | `Runtime_and_mission -> `Brass
                          | `Runtime | `Mission -> `Neutral)
                       ~label:(source_short row.source)
                       ()
                   ; (match row.model with
                      | Some { raw_value = Some _; _ } ->
                        Pill.view ~size:`Sm ~color:`Warn ~label:"raw" ()
                      | _ -> Node.span [])
                   ; (match trust_badge row.runtime with
                      | Some (label, color) ->
                        Pill.view ~size:`Sm ~color ~label ()
                      | None -> Node.span [])
                   ]
               ; Node.div
                   ~attrs:[ Style.subline ]
                   [ Node.text
                       (Option.value
                          (Option.first_some row.phase_label row.stage_label)
                          ~default:"상세 phase 없음")
                   ]
               ]
           ; Node.div
               ~attrs:[ Style.metric; Attr.role "cell" ]
               [ Node.div
                   ~attrs:[ context_class row.context_pct ]
                   [ Node.text
                       (match row.context_pct with
                        | Some pct -> Printf.sprintf "%d%%" pct
                        | None -> "—")
                   ]
               ; Node.div
                   ~attrs:[ Style.metric_sub ]
                   [ Node.text
                       (Option.value
                          (Option.first_some row.context_detail (Some row.recent_value))
                          ~default:"—")
                   ]
               ; Node.div
                   ~attrs:[ Style.metric_sub ]
                   [ Node.text (row.recent_label ^ " · " ^ row.recent_value) ]
               ]
           ]))
;;

let stat_cell ~label ~value =
  Node.div
    [ Node.div ~attrs:[ Shell_view.Style.stat_l ] [ Node.text label ]
    ; Node.div ~attrs:[ Shell_view.Style.stat_v ] [ Node.text value ]
    ]
;;

let focus_card row =
  let vial_pct = Option.value row.context_pct ~default:0 in
  let vial_style =
    Attr.style
      (Css_gen.create ~field:"width" ~value:(Printf.sprintf "%d%%" vial_pct))
  in
  let vial_fill_attrs =
    [ vial_style ]
    @ if Option.exists row.context_pct ~f:(fun pct -> pct >= 95)
      then [ Style.vial_fill_bad ]
      else if Option.exists row.context_pct ~f:(fun pct -> pct >= 80)
      then [ Style.vial_fill_warn ]
      else []
  in
  let role_bits =
    List.filter_opt
      [ row.agent_name
      ; Some (source_label row.source)
      ]
  in
  let model_value =
    match row.model with
    | Some model ->
      (match model.raw_value with
       | Some _ -> model.display_value ^ " (raw)"
       | None -> model.display_value)
    | None -> "—"
  in
  let trust_value =
    match trust_disposition row.runtime with
    | Some label ->
      (match trust_disposition_reason row.runtime with
       | Some reason -> label ^ " · " ^ reason
       | None -> label)
    | None -> "—"
  in
  Node.div
    [ Shell_view.aside_title ~right:(row.status_label ^ " · " ^ source_short row.source) "Focus"
    ; Node.div
        ~attrs:[ Shell_view.Style.focus ]
        [ Node.div
            ~attrs:[ Shell_view.Style.focus_inner ]
            [ Node.div
                ~attrs:[ Shell_view.Style.focus_row ]
                [ Node.div ~attrs:[ Shell_view.Style.portrait ]
                    [ Node.text (row_sigil row.name) ]
                ; Node.div
                    [ Node.div ~attrs:[ Shell_view.Style.focus_name ] [ Node.text row.name ]
                    ; Node.div
                        ~attrs:[ Shell_view.Style.focus_role ]
                        [ Node.text (String.concat ~sep:" · " role_bits) ]
                    ]
                ]
            ; Node.div
                [ Node.div
                    ~attrs:[ Shell_view.Style.vial_lbl ]
                    [ Node.span [ Node.text "Context" ]
                    ; Node.span
                        [ Node.b
                            [ Node.text
                                (match row.context_pct with
                                 | Some pct -> Printf.sprintf "%d%%" pct
                                 | None -> "—") ]
                        ; Node.text
                            (match row.context_detail with
                             | Some detail -> " . " ^ detail
                             | None -> " . runtime sparse")
                        ]
                    ]
                ; Node.div
                    ~attrs:[ Shell_view.Style.vial ]
                    [ Node.span ~attrs:(Attr.create "aria-hidden" "true" :: vial_fill_attrs) [] ]
                ]
            ; Node.div
                ~attrs:[ Shell_view.Style.stats ]
                [ stat_cell ~label:"상태" ~value:row.status_label
                ; stat_cell ~label:"최근성" ~value:row.recent_value
                ; stat_cell
                    ~label:"Phase"
                    ~value:(Option.value row.phase_label ~default:"—")
                ; stat_cell
                    ~label:"Stage"
                    ~value:(Option.value row.stage_label ~default:"—")
                ; stat_cell ~label:"Trust" ~value:trust_value
                ; stat_cell ~label:"모델" ~value:model_value
                ; stat_cell ~label:"Source" ~value:(source_label row.source)
                ]
            ]
        ]
    ]
;;

let note_section row =
  let notes =
    note_entries row.runtime row.mission row.agent
    |> List.map ~f:(fun note -> note.label, note.text)
  in
  Node.div
    [ Shell_view.aside_title "Note"
    ; (match notes with
       | [] ->
         Node.div
           ~attrs:[ Style.quiet; Attr.role "status"; Attr.create "aria-label" "No keeper notes" ]
           [ Node.span ~attrs:[ Attr.create "lang" "ko" ] [ Node.text "trust/note/current_work evidence가 아직 없습니다." ] ]
       | entries ->
         Node.div
           ~attrs:[ Style.list; Attr.role "list"; Attr.create "aria-label" "Keeper notes" ]
           (List.map entries ~f:(fun (label, text) ->
              Node.div
                ~attrs:[ Style.note_box; Attr.role "listitem" ]
                [ Node.div ~attrs:[ Style.note_k ] [ Node.text label ]
                ; Node.div ~attrs:[ Style.note_v ] [ Node.text text ]
                ])))
    ]
;;

let data_section row execution mission =
  let execution_generated_at =
    let open Directory_execution_types in
    execution.generated_at
  in
  let mission_generated_at =
    let open Directory_mission_types in
    mission.generated_at
  in
  let rows =
    [ "runtime snapshot"
    , (if String.is_empty execution_generated_at
       then "pending"
       else short_hhmmss execution_generated_at)
    ; "mission snapshot"
    , (if String.is_empty mission_generated_at
       then "pending"
       else short_hhmmss mission_generated_at)
    ; "signal"
    , (match row.agent with
       | Some agent ->
         let truth =
           Option.value agent.signal_truth ~default:"unknown"
         in
       let source =
           Option.value agent.evidence_source ~default:"none"
         in
         truth ^ " via " ^ source
       | None -> "agent brief 없음")
    ]
    @
    (match trust_disposition row.runtime with
     | Some label ->
       [ ( "trust",
           match trust_disposition_reason row.runtime with
           | Some reason -> label ^ " · " ^ reason
           | None -> label )
       ]
     | None -> [])
    @
    (match next_human_action row.runtime with
     | Some action -> [ "next action", action ]
     | None -> [])
    @
    (match latest_causal_event_text row.runtime with
     | Some event -> [ "causal event", event ]
     | None -> [])
    @
    match row.model with
    | Some { raw_value = Some raw; _ } -> [ "raw model", raw ]
    | _ -> []
  in
  let sparse_rows =
    match row.sparse_reasons with
    | [] -> []
    | reasons -> [ "sparse", String.concat ~sep:" · " reasons ]
  in
  Node.div
    [ Shell_view.aside_title "Data"
    ; Node.div
        ~attrs:[ Style.list; Attr.role "list"; Attr.create "aria-label" "Keeper data" ]
        (List.map (rows @ sparse_rows) ~f:(fun (label, value) ->
           Node.div
             ~attrs:[ Style.list_row; Attr.role "listitem" ]
             [ Node.div ~attrs:[ Style.list_k ] [ Node.text label ]
             ; Node.div ~attrs:[ Style.list_v ] [ Node.text value ]
             ]))
    ]
;;

let preview_section row =
  let previews =
    match row.agent with
    | None -> []
    | Some agent ->
      List.filter_opt
        [ Option.map agent.recent_input_preview ~f:(fun text -> "최근 입력", text)
        ; Option.map agent.recent_output_preview ~f:(fun text -> "최근 출력", text)
        ]
  in
  if List.is_empty previews
  then
    Node.div
      [ Shell_view.aside_title "Preview"
      ; Node.div
          ~attrs:[ Style.quiet; Attr.role "status"; Attr.create "aria-label" "No brief preview" ]
          [ Node.span ~attrs:[ Attr.create "lang" "ko" ] [ Node.text "agent brief preview가 아직 없습니다." ] ]
      ]
  else
    Node.div
      [ Shell_view.aside_title "Preview"
      ; Node.div
          ~attrs:[ Style.list; Attr.role "list"; Attr.create "aria-label" "Brief preview" ]
          (List.map previews ~f:(fun (label, text) ->
             Node.div
               ~attrs:[ Style.preview_box; Attr.role "listitem" ]
               [ Node.div ~attrs:[ Style.preview_label ] [ Node.text label ]
               ; Node.div ~attrs:[ Style.preview_text ] [ Node.text text ]
               ]))
      ]
;;

let aside
      ~(rows : row list)
      ~(selected_name : string option)
      ~(execution : Directory_execution_types.response)
      ~(mission : Directory_mission_types.response)
  : Node.t
  =
  match selected_row rows selected_name with
  | None ->
    Node.div
      ~attrs:[ Shell_view.Style.aside; Attr.role "complementary"; Attr.create "aria-label" "Keeper details" ]
      [ Shell_view.aside_title ~right:"fleet quiet" "Focus"
      ; Node.div
          ~attrs:[ Style.quiet; Attr.role "status"; Attr.create "aria-label" "No directory row selected" ]
          [ Node.span ~attrs:[ Attr.create "lang" "ko" ] [ Node.text "선택 가능한 directory row가 아직 없습니다." ] ]
      ]
  | Some row ->
    Node.div
      ~attrs:[ Shell_view.Style.aside; Attr.role "complementary"; Attr.create "aria-label" "Keeper details" ]
      [ focus_card row
      ; note_section row
      ; data_section row execution mission
      ; preview_section row
      ]
;;
