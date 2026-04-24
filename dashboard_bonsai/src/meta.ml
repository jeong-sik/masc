(** Meta strip primitive — MASC Design System 키–값 메타 strip.

    탭 페이지에서 반복되는 `<key> <value>` 쌍 나열. 3 탭(Dead_keepers,
    Goals, Archive_runs)이 거의 동일한 `.meta_strip + .meta_item + .meta_k
    + .meta_v{,_blood,_ok,_brass}` 블록을 각자 정의하던 것을 하나로 통합.

    `cell`은 value_color로 4색(기본/ok/brass/blood) 중 하나를 선택한다.
    theme 토큰 변경 시 이 한 파일만 건드리면 3 탭이 함께 반영된다. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .strip {
    display: flex;
    flex-wrap: wrap;
    gap: 24px;
    padding: 12px 16px;
    border: 1px solid var(--border-main, #3a2e20);
    background: linear-gradient(
      180deg,
      color-mix(in oklab, var(--bg-card) 35%, transparent),
      color-mix(in oklab, var(--bg-deep) 65%, transparent)
    );
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim, #9a846e);
  }

  .item { display: flex; align-items: baseline; gap: 8px; }

  .k {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--text-dim, #9a846e);
  }

  .v {
    font-variant-numeric: tabular-nums;
    color: var(--text-bright, #e8d9b0);
  }

  .v_ok    { color: var(--status-ok, #6a9a4a); font-variant-numeric: tabular-nums; }
  .v_brass { color: var(--accent-brass, #968228); font-variant-numeric: tabular-nums; }
  .v_blood { color: var(--accent-blood, #e85050); font-variant-numeric: tabular-nums; }
|}]

type value_color = [ `Default | `Ok | `Brass | `Blood ]

let cell ?(color : value_color = `Default) ~(k : string) ~(v : string) () : Node.t =
  let v_attr =
    match color with
    | `Default -> Style.v
    | `Ok -> Style.v_ok
    | `Brass -> Style.v_brass
    | `Blood -> Style.v_blood
  in
  Node.div
    ~attrs:[ Style.item ]
    [ Node.span ~attrs:[ Style.k ] [ Node.text k ]
    ; Node.span ~attrs:[ v_attr ] [ Node.text v ]
    ]
;;

let strip ?(label : string option) (cells : Node.t list) : Node.t =
  let base = [ Style.strip; Attr.role "status" ] in
  let attrs =
    match label with
    | Some l -> Attr.create "aria-label" l :: base
    | None -> base
  in
  Node.div ~attrs cells
;;
