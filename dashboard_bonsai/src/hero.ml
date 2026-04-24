(** Hero header primitive — MASC Design System 탭 페이지 상단의
    eyebrow + title + tail + sub 3-element block.

    탭별로 인라인 중복되어 있던 hero block을 한 API로 수렴. 각 탭은
    [Hero.view ~eyebrow ~title ?tail ?sub ()] 한 번 호출로 같은 시각
    구조 유지. tail은 선택적 brass/blood suffix. sub는 italic
    EB Garamond 서브카피.

    재사용: overview_view / goals_view / archive_runs_view /
    dead_keepers_view / keepers_view 다섯 탭의 hero block 동일 패턴. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .hero { display: flex; flex-direction: column; gap: 6px; }

  .eyebrow {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim, #6a5848);
    margin: 0;
  }

  .title {
    font-family: 'Cinzel', serif;
    font-size: 32px;
    letter-spacing: 0.16em;
    color: var(--text-bright, #e8d9b0);
    text-transform: uppercase;
    margin: 0;
  }

  .tail_brass {
    color: var(--accent-brass, #8a6a28);
    font-size: 18px;
    margin-left: 14px;
  }

  .tail_blood {
    color: var(--accent-blood, #a01818);
    font-size: 18px;
    margin-left: 14px;
  }

  .sub {
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-primary, #c8b88c);
    margin: 0;
    max-width: 640px;
  }
|}]

type tail_color = [ `Brass | `Blood ]

let view
      ?(sub : string option)
      ?(tail : (string * tail_color) option)
      ~(eyebrow : string)
      ~(title : string)
      ()
  : Node.t
  =
  let title_children : Node.t list =
    let head = [ Node.text (title ^ " ") ] in
    match tail with
    | None -> [ Node.text title ]
    | Some (txt, `Brass) ->
      head @ [ Node.span ~attrs:[ Style.tail_brass ] [ Node.text txt ] ]
    | Some (txt, `Blood) ->
      head @ [ Node.span ~attrs:[ Style.tail_blood ] [ Node.text txt ] ]
  in
  let sub_node : Node.t list =
    match sub with
    | Some s when String.length s > 0 ->
      [ Node.p ~attrs:[ Style.sub ] [ Node.text s ] ]
    | _ -> []
  in
  Node.div
    ~attrs:[ Style.hero ]
    ([ Node.p ~attrs:[ Style.eyebrow ] [ Node.text eyebrow ]
     ; Node.h1 ~attrs:[ Style.title ] title_children
     ]
     @ sub_node)
;;
