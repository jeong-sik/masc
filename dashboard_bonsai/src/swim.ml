(** Swimlane strip — keeper-activity timeline.

    design_v2 IA의 "what each keeper did · 60s" 섹션. 140px meta | 1fr track.
    track 위의 frame은 도구 카테고리별 배경색 (llm / tool / err / wait /
    think). Phase 1에서 logs_view.ml에 인라인이었으나 Phase 2.A shell
    추출로 공용 모듈 분리.

    재사용 대상: Keepers, Goals, Tools, Sessions — 시간축 위에 span을
    얹는 모든 탭. frame_kind를 늘리고 싶으면 variant 확장 + seg_class 추가.

    좌표계: left/width 모두 % (track 가로 기준). 0..100. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

type frame_kind =
  [ `Llm
  | `Tool
  | `Err
  | `Wait
  | `Think
  ]

type lane_status =
  [ `Live
  | `Warn
  | `Dead
  ]

module Style =
[%css
stylesheet
  {|
  .swim {
    border: 1px solid var(--border-main);
    background: color-mix(in oklab, var(--bg-deep) 40%, transparent);
    margin-top: 6px;
  }
  .axis {
    display: grid;
    grid-template-columns: 140px 1fr;
    border-bottom: 1px solid var(--border-main);
  }
  .axis_sp {
    border-right: 1px solid var(--border-main);
    padding: 6px 14px;
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.24em;
    text-transform: uppercase;
    color: var(--text-dim);
  }
  .axis_ax {
    position: relative;
    height: 24px;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
  }
  .tick {
    position: absolute;
    top: 0;
    bottom: 0;
    border-left: 1px solid var(--border-main);
  }
  .tick_lbl {
    position: absolute;
    top: 6px;
    left: 4px;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  .lane {
    display: grid;
    grid-template-columns: 140px 1fr;
    border-bottom: 1px solid var(--border-main);
  }
  .lane:last-child { border-bottom: 0; }
  .lane_meta {
    border-right: 1px solid var(--border-main);
    padding: 8px 14px;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--status-ok);
    flex-shrink: 0;
    box-shadow: 0 0 6px var(--status-ok);
  }
  .dot_warn { background: var(--status-warn); box-shadow: 0 0 6px var(--status-warn); }
  .dot_bad { background: var(--accent-blood); box-shadow: 0 0 6px var(--accent-blood); }
  .nm {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 12px;
    color: var(--text-bright);
    letter-spacing: 0.04em;
    flex: 1;
  }
  .nm_dead {
    color: var(--text-dim);
    text-decoration: line-through;
    text-decoration-color: var(--accent-blood);
  }
  .stat {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.18em;
    color: var(--text-dim);
    text-transform: uppercase;
  }
  .track {
    position: relative;
    height: 32px;
    background: repeating-linear-gradient(to right, transparent 0 99px, color-mix(in oklab, var(--border-highlight) 5%, transparent) 99px 100px);
  }
  .frame {
    position: absolute;
    top: 9px;
    height: 14px;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--bg-deep);
    padding: 0 4px;
    line-height: 14px;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    border: 1px solid transparent;
    cursor: default;
    border-radius: 1px;
  }
  .frame:hover { border-color: var(--text-bright); z-index: 2; }
  .frame_llm  { background: var(--t-llm); }
  .frame_tool { background: var(--t-tool); }
  .frame_err  { background: var(--t-err); color: var(--text-bright); }
  .frame_wait { background: var(--t-wait); color: var(--text-dim); }
  .frame_think { background: var(--t-think); color: var(--text-primary); }
|}]

let frame_class = function
  | `Llm -> Style.frame_llm
  | `Tool -> Style.frame_tool
  | `Err -> Style.frame_err
  | `Wait -> Style.frame_wait
  | `Think -> Style.frame_think
;;

let kind_label = function
  | `Llm -> "LLM"
  | `Tool -> "Tool"
  | `Think -> "Think"
  | `Err -> "Error"
  | `Wait -> "Wait"
;;

let frame ~(kind : frame_kind) ~left ~width ~label =
  let style =
    Attr.create
      "style"
      (Printf.sprintf "left:%d%%; width:%d%%" left width)
  in
  Node.div
    ~attrs:[ Style.frame; frame_class kind; style
           ; Attr.title (Printf.sprintf "%s: %s" (kind_label kind) label) ]
    [ Node.text label ]
;;

(** Map JSON "kind" string to our [frame_kind] variant. Unknown kinds
    fall back to [`Wait] — neutral grey so unexpected telemetry renders
    legibly instead of crashing the lane. *)
let frame_kind_of_string = function
  | "llm" -> `Llm
  | "tool" -> `Tool
  | "think" -> `Think
  | "err" -> `Err
  | "wait" | _ -> `Wait
;;

let lane_status_of_keeper_status (s : Keepers_types.keeper_status) : lane_status =
  match s with
  | Live -> `Live
  | Warn -> `Warn
  | Dead -> `Dead
;;

let view_lane ~name ~stat ~(status : lane_status) ~frames =
  let dot_cls =
    match status with
    | `Live -> Style.dot
    | `Warn -> Style.dot_warn
    | `Dead -> Style.dot_bad
  in
  let nm_attrs =
    match status with
    | `Dead -> [ Style.nm; Style.nm_dead ]
    | `Live | `Warn -> [ Style.nm ]
  in
  Node.div
    ~attrs:[ Style.lane; Attr.role "listitem"; Attr.create "aria-label" (name ^ ": " ^ stat) ]
    [ Node.div
        ~attrs:[ Style.lane_meta ]
        [ Node.span ~attrs:[ Style.dot; dot_cls; Attr.create "aria-hidden" "true" ] []
        ; Node.span ~attrs:nm_attrs [ Node.text name ]
        ; Node.span ~attrs:[ Style.stat ] [ Node.text stat ]
        ]
    ; Node.div ~attrs:[ Style.track ] frames
    ]
;;

let view_lane_of_keeper (k : Keepers_types.keeper) =
  let fs =
    List.map k.lane_frames ~f:(fun (f : Keepers_types.lane_frame) ->
      frame
        ~kind:(frame_kind_of_string f.kind)
        ~left:f.left
        ~width:f.width
        ~label:f.label)
  in
  view_lane
    ~name:k.name
    ~stat:k.stat
    ~status:(lane_status_of_keeper_status k.status)
    ~frames:fs
;;

(** Static fallback — matches the hand-coded mock before live wiring. *)
let view_static () =
  [ view_lane
      ~name:"luna"
      ~stat:"reading"
      ~status:`Live
      ~frames:
        [ frame ~kind:`Llm ~left:5 ~width:18 ~label:"llm"
        ; frame ~kind:`Tool ~left:28 ~width:10 ~label:"read"
        ; frame ~kind:`Think ~left:42 ~width:8 ~label:"think"
        ; frame ~kind:`Llm ~left:54 ~width:22 ~label:"llm"
        ; frame ~kind:`Tool ~left:80 ~width:14 ~label:"edit"
        ]
  ; view_lane
      ~name:"brass-owl"
      ~stat:"retrying"
      ~status:`Warn
      ~frames:
        [ frame ~kind:`Llm ~left:3 ~width:20 ~label:"llm"
        ; frame ~kind:`Tool ~left:26 ~width:12 ~label:"fetch"
        ; frame ~kind:`Wait ~left:40 ~width:24 ~label:"wait"
        ; frame ~kind:`Tool ~left:66 ~width:10 ~label:"fetch"
        ]
  ; view_lane
      ~name:"moth"
      ~stat:"idle · listening"
      ~status:`Live
      ~frames:
        [ frame ~kind:`Wait ~left:0 ~width:40 ~label:"wait"
        ; frame ~kind:`Llm ~left:42 ~width:14 ~label:"llm"
        ; frame ~kind:`Wait ~left:58 ~width:40 ~label:"wait"
        ]
  ; view_lane
      ~name:"ash-hound"
      ~stat:"crashed t-34"
      ~status:`Dead
      ~frames:
        [ frame ~kind:`Llm ~left:2 ~width:18 ~label:"llm"
        ; frame ~kind:`Tool ~left:22 ~width:8 ~label:"exec"
        ; frame ~kind:`Err ~left:32 ~width:6 ~label:"err"
        ]
  ]
;;

let view ?(keepers : Keepers_types.response = Keepers_types.fixture) () =
  let axis_ticks =
    List.init 6 ~f:(fun i ->
      let left_pct = i * 20 in
      let style =
        Attr.create "style" (Printf.sprintf "left:%d%%" left_pct)
      in
      Node.div
        ~attrs:[ Style.tick; style ]
        [ Node.span
            ~attrs:[ Style.tick_lbl ]
            [ Node.text (Printf.sprintf "t-%d" ((5 - i) * 12)) ]
        ])
  in
  let lanes =
    match keepers.keepers with
    | [] -> view_static ()
    | live_keepers -> List.map live_keepers ~f:view_lane_of_keeper
  in
  Node.div
    ~attrs:[ Style.swim; Attr.role "list"; Attr.create "aria-label" "Keeper activity timeline" ]
    ([ Node.div
         ~attrs:[ Style.axis ]
         [ Node.div
             ~attrs:[ Style.axis_sp ]
             [ Node.text "keeper · cycle" ]
         ; Node.div ~attrs:[ Style.axis_ax ] axis_ticks
         ]
     ] @ lanes)
;;
