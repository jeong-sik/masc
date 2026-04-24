(** Section title primitive — MASC Design System `.sec` pattern.

    dashboard_v2 ui_kit의 `.sec` 섹션 구분선을 Bonsai view primitive로
    옮긴 것. 브라스 타이틀(uppercase Cinzel) + optional 이탈릭 서브카피
    + flex-grow hairline + optional 우측 메타(JetBrains Mono).

    재사용: keepers_view / overview_view / goals_view / archive_runs_view
    등 탭 내부 섹션 구분에 사용. 기존 탭은 각자 `section_h` 직접 CSS를
    갖고 있으나, 점진적으로 이 primitive로 수렴시킬 예정. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .sec {
    display: flex;
    align-items: baseline;
    gap: 14px;
    margin: 28px 0 12px;
  }
  .sec_title {
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 13px;
    letter-spacing: 0.26em;
    color: var(--accent-brass, #968228);
    text-transform: uppercase;
    margin: 0;
    flex-shrink: 0;
  }
  .sec_sub {
    font-family: var(--font-body, 'EB Garamond', serif);
    font-style: italic;
    color: var(--text-dim, #9a846e);
    font-size: 13px;
    flex-shrink: 0;
  }
  .sec_hr {
    flex: 1;
    height: 1px;
    background: linear-gradient(
      90deg,
      var(--border-highlight, #5a3028) 0%,
      var(--border-main, #2a1a14) 60%,
      transparent 100%
    );
  }
  .sec_right {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    color: var(--text-dim, #9a846e);
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
  }
|}]

let view ?(sub : string option) ?(right : string option) ~(title : string) () : Node.t =
  let nodes : Node.t list =
    List.concat
      [ [ Node.h3 ~attrs:[ Style.sec_title ] [ Node.text title ] ]
      ; (match sub with
         | Some s when String.length s > 0 ->
           [ Node.span ~attrs:[ Style.sec_sub ] [ Node.text s ] ]
         | _ -> [])
      ; [ Node.div ~attrs:[ Style.sec_hr ] [] ]
      ; (match right with
         | Some r when String.length r > 0 ->
           [ Node.div ~attrs:[ Style.sec_right ] [ Node.text r ] ]
         | _ -> [])
      ]
  in
  Node.div ~attrs:[ Style.sec ] nodes
;;
