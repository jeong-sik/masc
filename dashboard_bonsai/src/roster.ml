(** Roster — sticky bottom strip of keeper slots.

    4-column grid of keeper "slots" (sigil + name + state dot + latency).
    Phase 1에서 logs_view.ml에 인라인이었으나 Phase 2.A shell 추출로
    공용 모듈 분리. Keepers 탭, Sessions, Dead_keepers가 재사용 예정.

    CSS는 ppx_css로 scope되므로 logs_view.ml 옛 블록과 충돌 없음.
    `@keyframes pulse-beat` 는 logs_view.ml에도 존재 — 이름 동일하지만
    scope 내에서만 참조되므로 독립 정의해도 안전.

    API:
    - [state] : 4-가지 상태 polymorphic variant
    - [state_of_status] : Keepers 상태 → roster 상태 매핑 helper
    - [view_slot] : 개별 slot 렌더
    - [view_slot_of_keeper] : Keepers_types.keeper → slot 축약
    - [view] : 전체 roster — keepers 비면 static fallback
*)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

type state =
  [ `Live
  | `Thinking
  | `Idle
  | `Failed
  ]

module Style =
[%css
stylesheet
  {|
  @keyframes roster_pulse {
    0%, 100% { opacity: 0.55; }
    50% { opacity: 1; }
  }

  .roster {
    position: sticky;
    bottom: 0;
    z-index: 3;
    margin-top: 1rem;
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 1px;
    background: var(--border-main);
    border: 1px solid #3a2a20;
    border-radius: 2px;
    box-shadow:
      inset 0 0 0 1px rgba(196, 162, 101, 0.06),
      0 -8px 24px -12px rgba(0, 0, 0, 0.85);
    backdrop-filter: blur(2px);
  }

  .slot {
    background: var(--bg-panel);
    padding: 10px 14px;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .sigil {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    border: 1px solid var(--accent-brass);
    background: radial-gradient(circle at 35% 30%, rgba(232, 216, 184, 0.22), transparent 55%), var(--bg-panel);
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 11px;
    color: var(--text-bright);
    text-transform: uppercase;
    box-shadow: inset 0 0 0 1px rgba(232, 216, 184, 0.08), 0 0 8px rgba(138, 106, 40, 0.22);
    flex-shrink: 0;
  }

  .body {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .name {
    font-family: 'Cinzel', serif;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--text-bright);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .state {
    display: flex;
    align-items: center;
    gap: 6px;
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: var(--text-dim);
  }

  .dot_live     { background: var(--status-ok); box-shadow: 0 0 6px var(--status-ok); animation: roster_pulse 1.8s ease-in-out infinite; }
  .dot_thinking { background: var(--accent-brass); box-shadow: 0 0 6px var(--accent-brass); animation: roster_pulse 1.2s ease-in-out infinite; }
  .dot_idle     { background: var(--text-dim); }
  .dot_failed   { background: var(--accent-blood); box-shadow: 0 0 8px var(--accent-blood); }

  .when_ {
    margin-left: auto;
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 11px;
    color: var(--text-dim);
    flex-shrink: 0;
  }

  @media (prefers-reduced-motion: reduce) {
    .dot_live, .dot_thinking { animation: none; }
  }
|}]

(** Keeper 상태 → roster dot 상태 매핑. `Warn` → `Thinking` (뭔가
    진행 중이지만 걱정스러움). `Dead` → `Failed` (blood). *)
let state_of_status (s : Keepers_types.keeper_status) : state =
  match s with
  | Live -> `Live
  | Warn -> `Thinking
  | Dead -> `Failed
;;

let view_slot ~(state : state) ~sigil ~name ~state_label ~when_ =
  let dot_cls =
    match state with
    | `Live -> Style.dot_live
    | `Thinking -> Style.dot_thinking
    | `Idle -> Style.dot_idle
    | `Failed -> Style.dot_failed
  in
  Node.div
    ~attrs:[ Style.slot; Attr.role "listitem"; Attr.create "aria-label" (name ^ " · " ^ state_label ^ " · " ^ when_) ]
    [ Node.div ~attrs:[ Style.sigil ] [ Node.text sigil ]
    ; Node.div
        ~attrs:[ Style.body ]
        [ Node.span ~attrs:[ Style.name ] [ Node.text name ]
        ; Node.div
            ~attrs:[ Style.state ]
            [ Node.span ~attrs:[ Style.dot; dot_cls; Attr.create "aria-hidden" "true" ] []
            ; Node.text state_label
            ]
        ]
    ; Node.span ~attrs:[ Style.when_ ] [ Node.text when_ ]
    ]
;;

let view_slot_of_keeper (k : Keepers_types.keeper) =
  let sigil =
    if String.length k.name = 0
    then "·"
    else Char.to_string (Char.uppercase k.name.[0])
  in
  let when_ =
    match k.latency_ms with
    | 0 -> "×"
    | n when n < 1000 -> Printf.sprintf "%dms" n
    | n -> Printf.sprintf "%.1fs" (Float.of_int n /. 1000.0)
  in
  view_slot
    ~state:(state_of_status k.status)
    ~sigil
    ~name:k.name
    ~state_label:k.stat
    ~when_
;;

(** 서버 응답이 비었을 때 보이는 fixture. 4명 1-row, 4개 상태 다 노출. *)
let view_static () =
  [ view_slot ~sigil:"P" ~name:"keeper · poe" ~state:`Live
      ~state_label:"speaking" ~when_:"3s"
  ; view_slot ~sigil:"J" ~name:"janitor" ~state:`Thinking
      ~state_label:"thinking" ~when_:"12s"
  ; view_slot ~sigil:"G" ~name:"governance" ~state:`Idle
      ~state_label:"idle · ok" ~when_:"2m"
  ; view_slot ~sigil:"I" ~name:"improver" ~state:`Failed
      ~state_label:"paused · auth" ~when_:"7m"
  ]
;;

let view ?(keepers : Keepers_types.response = Keepers_types.fixture) () =
  let slots =
    match keepers.keepers with
    | [] -> view_static ()
    | live -> List.map live ~f:view_slot_of_keeper
  in
  Node.div ~attrs:[ Style.roster; Attr.role "list"; Attr.create "aria-label" "Keeper slots" ] slots
;;
