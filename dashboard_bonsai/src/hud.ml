(** HUD — sticky top strip of KPI cells.

    Generic heads-up display container. 각 cell은 label (k) + value (v) +
    optional semantic color class. Phase 1에서 logs_view.ml에 인라인이었으나
    Phase 2.A shell 추출로 공용 모듈 분리.

    logs 탭은 8 cells (Source/Total/Level/Refresh/Limit/Link/Fleet/Synced)을
    쓰지만, 다른 탭은 자기 필요에 맞게 셀 리스트만 다르게 조립 — API는
    cell 렌더 primitive + strip container만 제공.

    grid column 수는 `strip`의 CSS에 하드코드(6). 8 cell일 때는 그냥
    wrap. 추후 tab별로 column 조절이 필요하면 variant 추가.

    재사용:
    - logs_view.ml 는 이 모듈 opened + `Hud.cell ~k ~v ()` + `Hud.strip [...]` 구성
    - 모든 탭이 동일 strip 스타일 공유 → 시각 일관성
*)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

type v_class =
  [ `Ok
  | `Warn
  | `Bad
  | `Neutral
  ]

module Style =
[%css
stylesheet
  {|
  .hud {
    position: sticky;
    top: 0;
    z-index: 3;
    display: grid;
    grid-template-columns: repeat(6, 1fr);
    gap: 1px;
    background: var(--color-border-default);
    border: 1px solid var(--color-border-strong);
    border-radius: 2px;
    box-shadow:
      inset 0 0 0 1px color-mix(in oklab, var(--color-accent-fg) 8%, transparent),
      0 2px 12px color-mix(in oklab, var(--color-bg-page) 60%, transparent),
      0 16px 24px -16px color-mix(in oklab, var(--color-bg-page) 90%, transparent);
    backdrop-filter: blur(2px);
  }

  .hud::before,
  .hud::after {
    content: "";
    position: absolute;
    width: 14px;
    height: 14px;
    border: 1px solid var(--color-accent-fg);
    pointer-events: none;
    z-index: 1;
  }

  .hud::before {
    top: -1px;
    left: -1px;
    border-right: 0;
    border-bottom: 0;
  }

  .hud::after {
    bottom: -1px;
    right: -1px;
    border-left: 0;
    border-top: 0;
  }

  .cell {
    background: var(--color-bg-surface);
    padding: 10px 14px;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .k {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }

  .v {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 12px;
    color: var(--color-fg-primary);
  }

  .v_ok   { color: var(--color-status-ok); }
  .v_warn { color: var(--color-status-warn); }
  .v_bad  { color: var(--color-status-err); }

  @media (prefers-contrast: more) {
    .hud { border-width: 2px; border-color: var(--text-bright); }
    .k { color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .v_ok { color: Highlight; }
    .v_warn { color: Mark; }
    .v_bad { color: MarkText; }
  }
|}]

let v_class_attr = function
  | `Ok -> Some Style.v_ok
  | `Warn -> Some Style.v_warn
  | `Bad -> Some Style.v_bad
  | `Neutral -> None
;;

let cell ?(v_class : v_class = `Neutral) ~k ~v () =
  let v_attrs =
    match v_class_attr v_class with
    | None -> [ Style.v ]
    | Some c -> [ Style.v; c ]
  in
  Node.div
    ~attrs:[ Style.cell; Attr.create "aria-label" (k ^ ": " ^ v) ]
    [ Node.div ~attrs:[ Style.k ] [ Node.text k ]
    ; Node.div ~attrs:v_attrs [ Node.text v ]
    ]
;;

let strip ?(label : string = "Key metrics") cells =
  Node.div ~attrs:[ Style.hud; Attr.role "status"; Attr.create "aria-label" label ] cells

(** Extract "HH:MM:SS" from an ISO-8601 UTC timestamp
    (e.g. "2026-04-20T04:02:07Z" → "04:02:07"). Falls back to the full
    string if the shape doesn't match — never throws.

    Synced/Updated cell에서 주로 사용되는 helper — HUD 쪽에 위치하는게
    자연스러움. *)
let hhmmss_of_iso (s : string) : string =
  if String.length s >= 19 && Char.equal s.[10] 'T'
  then String.sub s ~pos:11 ~len:8
  else s
;;
