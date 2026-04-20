(** Flame mini — tool category stacked bar.

    "Last cycle"의 시간 배분을 도구 카테고리로 나눈 단일 horizontal bar +
    아래 legend (color chip + label + %). Phase 1 에서 logs_view.ml에
    inline되어 있었으나 Phase 2 shell 추출에서 공용 모듈로 분리.

    재사용 대상: Tools · Sessions · (차후) 도구 호출 분포를 그리고 싶은
    모든 탭. 색 토큰은 `--t-*` namespace (colors_and_type.css).

    CSS는 ppx_css로 scope 되므로 logs_view.ml 내 옛 블록과 클래스 충돌
    없음. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

type kind =
  [ `Llm
  | `Tool
  | `Think
  | `Wait
  | `Err
  ]

module Style =
[%css
stylesheet
  {|
  .flame { padding: 10px 14px; }
  .flame_bar {
    display: flex;
    height: 14px;
    border: 1px solid var(--border-main);
    background: var(--bg-deep);
    overflow: hidden;
  }
  .flame_seg {
    height: 100%;
    border-right: 1px solid rgba(0, 0, 0, 0.35);
  }
  .flame_seg:last-child { border-right: 0; }
  .flame_seg_llm   { background: var(--t-llm); }
  .flame_seg_tool  { background: var(--t-tool); }
  .flame_seg_think { background: var(--t-think); }
  .flame_seg_wait  { background: var(--t-wait); }
  .flame_seg_err   { background: var(--t-err); }
  .flame_legend {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
    margin-top: 10px;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 10px;
    color: var(--text-dim);
    letter-spacing: 0.04em;
  }
  .flame_item { display: inline-flex; align-items: center; gap: 6px; }
  .flame_chip {
    width: 10px;
    height: 10px;
    display: inline-block;
    border: 1px solid rgba(0, 0, 0, 0.45);
  }
  .flame_lbl { color: var(--text-primary); }
  .flame_pct {
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
  }
|}]

let seg_class = function
  | `Llm -> Style.flame_seg_llm
  | `Tool -> Style.flame_seg_tool
  | `Think -> Style.flame_seg_think
  | `Wait -> Style.flame_seg_wait
  | `Err -> Style.flame_seg_err
;;

let label = function
  | `Llm -> "llm"
  | `Tool -> "tool"
  | `Think -> "think"
  | `Wait -> "wait"
  | `Err -> "err"
;;

let view_mini ~(segments : (kind * int) list) =
  let bar =
    Node.div
      ~attrs:[ Style.flame_bar ]
      (List.map segments ~f:(fun (kind, pct) ->
         let style = Attr.create "style" (Printf.sprintf "width:%d%%" pct) in
         Node.div ~attrs:[ Style.flame_seg; seg_class kind; style ] []))
  in
  let legend =
    Node.div
      ~attrs:[ Style.flame_legend ]
      (List.map segments ~f:(fun (kind, pct) ->
         Node.span
           ~attrs:[ Style.flame_item ]
           [ Node.span ~attrs:[ Style.flame_chip; seg_class kind ] []
           ; Node.span ~attrs:[ Style.flame_lbl ] [ Node.text (label kind) ]
           ; Node.span
               ~attrs:[ Style.flame_pct ]
               [ Node.text (Printf.sprintf "%d" pct) ]
           ]))
  in
  Node.div ~attrs:[ Style.flame ] [ bar; legend ]
;;
