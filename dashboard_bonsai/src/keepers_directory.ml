open! Core
open! Bonsai_web
open Virtual_dom.Vdom

let selected_name_var : string option Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create None
;;

type band =
  [ `Active
  | `Attention
  | `Paused
  | `Offline
  ]

type row =
  { name : string
  ; band : band
  ; status_label : string
  ; status_color : Pill.color
  ; phase_label : string option
  ; context_pct : int option
  ; context_detail : string option
  ; recent_label : string
  ; recent_value : string
  ; keeper : Keepers_types.keeper
  }

type counts =
  { total : int
  ; active : int
  ; attention : int
  ; paused : int
  ; offline : int
  }

module Style =
[%css
stylesheet
  {|
  .directory {
    border: 1px solid var(--color-border-default);
    background: color-mix(in oklab, var(--color-bg-page) 48%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--text-bright) 3%, transparent);
    overflow-x: auto;
  }

  .head {
    display: grid;
    grid-template-columns: 52px minmax(0, 1.1fr) minmax(0, 1.6fr) 176px 96px;
    gap: 14px;
    align-items: center;
    padding: 10px 16px;
    border-bottom: 1px solid color-mix(in oklab, var(--color-border-strong) 16%, transparent);
    background: linear-gradient(180deg, color-mix(in oklab, var(--color-bg-surface) 80%, var(--color-bg-page)), var(--color-bg-page));
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.28em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }

  .row {
    position: relative;
    display: grid;
    grid-template-columns: 52px minmax(0, 1.1fr) minmax(0, 1.6fr) 176px 96px;
    gap: 14px;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid color-mix(in oklab, var(--color-border-strong) 12%, transparent);
    cursor: pointer;
    transition: background 120ms ease;
  }

  .row:last-child { border-bottom: 0; }

  .row:hover,
  .row:focus-visible {
    background: color-mix(in oklab, var(--color-accent-fg) 4%, transparent);
  }

  .row:focus-visible {
    outline: 1px solid var(--color-accent-fg);
    outline-offset: -1px;
  }

  .row_selected {
    background: linear-gradient(90deg, color-mix(in oklab, var(--color-accent-fg) 8%, transparent), transparent 72%);
  }

  .row_selected::before {
    content: "";
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 2px;
    background: var(--color-accent-fg);
    box-shadow: 0 0 12px var(--color-accent-fg);
  }

  .sigil {
    width: 40px;
    height: 40px;
    border: 1px solid var(--color-accent-fg-dim);
    background:
      radial-gradient(circle at 35% 30%, color-mix(in oklab, var(--text-bright) 16%, transparent), transparent 58%),
      var(--color-bg-panel-alt, #1b140f);
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
    color: var(--color-fg-muted);
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
    color: var(--color-fg-muted);
  }

  .summary_v {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 12px;
    color: var(--color-fg-primary);
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

  .metric_v_warn { color: var(--color-accent-fg); }
  .metric_v_bad { color: var(--accent-blood); }

  .metric_sub {
    margin-top: 3px;
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    color: var(--color-fg-muted);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .vial_fill_warn {
    background: linear-gradient(90deg, var(--color-accent-fg-dim), var(--color-accent-fg));
    box-shadow: 0 0 6px color-mix(in oklab, var(--color-accent-fg) 35%, transparent);
  }

  .vial_fill_bad {
    background: linear-gradient(90deg, var(--accent-blood-dim), var(--accent-blood));
    box-shadow: 0 0 6px color-mix(in oklab, var(--accent-blood) 35%, transparent);
  }

  .meta_strip {
    margin: 0 0 12px;
  }

  .note_box {
    border: 1px solid var(--color-border-default);
    background: color-mix(in oklab, var(--color-bg-page) 40%, transparent);
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
    color: var(--color-fg-muted);
  }

  .note_v {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 12px;
    line-height: 1.55;
    color: var(--color-fg-primary);
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
    color: var(--color-fg-muted);
  }

  .list_v {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    line-height: 1.5;
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
    word-break: break-word;
  }

  .quiet {
    padding: 24px 18px;
    border: 1px dashed var(--color-border-default);
    font-family: var(--font-body, 'EB Garamond', serif);
    font-size: 15px;
    font-style: italic;
    color: var(--color-fg-muted);
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

  @media (prefers-contrast: more) {
    .card { border-width: 2px; border-color: var(--text-bright); }
    .card_header { border-bottom-width: 2px; border-color: var(--text-bright); }
    .section_title { color: var(--text-bright); }
    .k { color: var(--text-bright); }
    .metric_v_bad { color: var(--accent-blood); font-weight: 700; }
    .filter_input { border-width: 2px; border-color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .metric_v_bad { color: MarkText; }
    .metric_v_warn { color: Mark; }
    .row_selected { background: Highlight; color: HighlightText; }
  }
|}]

let row_sigil name =
  if String.is_empty name
  then "·"
  else Char.to_string (Char.uppercase name.[0])
;;

let phase_label_of_stat stat =
  match String.lowercase (String.strip stat) with
  | "reading" -> Some "읽는중"
  | "retrying" -> Some "재시도"
  | "thinking" -> Some "사고"
  | "tool_use" -> Some "도구"
  | "idle" | "listening" -> Some "대기"
  | "paused" -> Some "일시정지"
  | "offline" -> Some "오프라인"
  | "inactive" -> Some "비활성"
  | "stopped" -> Some "정지"
  | "dead" -> Some "종료"
  | "failing" -> Some "오류중"
  | "compacting" -> Some "압축중"
  | "handoff" -> Some "승계중"
  | "draining" -> Some "종료중"
  | "crashed" -> Some "중단"
  | "restarting" -> Some "재시작중"
  | "" -> None
  | _ -> Some stat
;;

let format_compact_int value =
  let f = Float.of_int value in
  if value >= 1_000_000
  then Printf.sprintf "%.1fM" (f /. 1_000_000.0)
  else if value >= 1000
  then Printf.sprintf "%.1fK" (f /. 1000.0)
  else Int.to_string value
;;

let band_of_keeper (keeper : Keepers_types.keeper) =
  match keeper.status with
  | Dead -> `Offline
  | Warn -> `Attention
  | Live -> `Active
;;

let status_meta (keeper : Keepers_types.keeper) (band : band) =
  let phase_label = phase_label_of_stat keeper.stat in
  let status_label, status_color =
    match band with
    | `Active -> "가동중", `Ok
    | `Attention -> "주의 필요", `Warn
    | `Paused -> "일시정지", `Paused
    | `Offline -> "오프라인", `Neutral
  in
  phase_label, status_label, status_color
;;

let build_rows ~(keepers : Keepers_types.response) : row list =
  List.map keepers.keepers ~f:(fun keeper ->
    let band = band_of_keeper keeper in
    let phase_label, status_label, status_color = status_meta keeper band in
    let context_pct =
      if keeper.ctx_pct > 0
      then Some (Int.min 100 keeper.ctx_pct)
      else None
    in
    let context_detail =
      if keeper.mem_kb > 0
      then Some (format_compact_int keeper.mem_kb)
      else None
    in
    let recent_label, recent_value =
      if keeper.turn > 0
      then "턴", Printf.sprintf "%d/%d" keeper.turn keeper.turn_cap
      else "최근성", "기록 없음"
    in
    { name = keeper.name
    ; band
    ; status_label
    ; status_color
    ; phase_label
    ; context_pct
    ; context_detail
    ; recent_label
    ; recent_value
    ; keeper
    })
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

let default_selected_name rows =
  List.find_map rows ~f:(fun row ->
    match row.band with
    | `Active | `Attention -> Some row.name
    | `Paused | `Offline -> None)
  |> Option.first_some (match rows with first :: _ -> Some first.name | [] -> None)
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
  ; Attr.on_keydown (fun ev ->
      (* Vdom keyboard event API moved out of Virtual_dom.Vdom.Event
         in newer bonsai_web; read the raw JS [key] field instead.
         Same activation contract as the click handler. *)
      let key_str =
        Js_of_ocaml.Js.Optdef.case
          ev##.key
          (fun () -> "")
          Js_of_ocaml.Js.to_string
      in
      if String.equal key_str "Enter" || String.equal key_str " "
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

let view_summary_strip ~(rows : row list) =
  let summary = counts rows in
  Meta.strip
    ~label:"Keepers summary"
    [ Meta.cell
        ~color:`Ok
        ~k:"total"
        ~v:(Printf.sprintf "%d" summary.total)
        ()
    ; Meta.cell
        ~color:(if summary.attention > 0 then `Blood else `Default)
        ~k:"attention"
        ~v:(Printf.sprintf "%d" summary.attention)
        ()
    ; Meta.cell
        ~color:(if summary.offline > 0 then `Default else `Brass)
        ~k:"offline"
        ~v:(Printf.sprintf "%d" summary.offline)
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
              "keepers summary가 아직 조용합니다."
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
             [ row.keeper.last_tool
             ; (match row.keeper.turn_cap with
                | 0 -> None
                | cap -> Some (Printf.sprintf "cap:%d" cap))
             ]
         in
         let summary_k, summary_v =
           match row.keeper.last_tool with
           | Some tool -> "최근 도구", tool
           | None -> "상태", row.keeper.stat
         in
         let row_attrs =
           [ Style.row
           ; Attr.tabindex 0
           ; Attr.role "row"
           ; Attr.create "aria-label" row.name
           ; Attr.create "aria-selected" (if is_selected then "true" else "false")
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
                   ]
               ; Node.div
                   ~attrs:[ Style.subline ]
                   [ Node.text
                       (Option.value
                          row.phase_label
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
  Node.div
    [ Shell_view.aside_title ~right:row.status_label "Focus"
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
                        [ Node.text row.keeper.stat ]
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
                             | None -> "")
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
                    ~label:"Turn"
                    ~value:(Printf.sprintf "%d/%d" row.keeper.turn row.keeper.turn_cap)
                ; stat_cell
                    ~label:"Latency"
                    ~value:(Printf.sprintf "%dms" row.keeper.latency_ms)
                ; stat_cell
                    ~label:"Memory"
                    ~value:(format_compact_int row.keeper.mem_kb)
                ]
            ]
        ]
    ]
;;

let aside
      ~(rows : row list)
      ~(selected_name : string option)
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
      [ focus_card row ]
;;
