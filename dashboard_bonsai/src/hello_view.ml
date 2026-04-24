(** Landing view — placeholder at [/dashboard/b] until a real home page lands.

    Styling follows the MASC Design System (dark-fantasy theme). Tokens are
    inlined here instead of referenced via CSS variables because [ppx_css]
    generates scoped class names and we are not sharing the system's
    stylesheet yet. When [colors_and_type.css] ships into
    [assets/dashboard_bonsai/], switch the raw values below for
    [var(--bg-deep)] / [var(--accent-brass)] / etc. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .root {
    min-height: 100vh;
    background: #0a0706;
    color: #b8a488;
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    padding: 3rem 4rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .eyebrow {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: #6a5848;
    margin: 0;
  }

  .title {
    font-family: 'Cinzel', serif;
    font-weight: 500;
    font-size: 2.25rem;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: #e8d8b8;
    margin: 0;
    text-shadow: 0 0 40px rgba(160, 24, 24, 0.28);
  }

  .sub {
    font-family: 'EB Garamond', Georgia, serif;
    font-size: 1rem;
    color: #b8a488;
    margin: 0;
    max-width: 38rem;
    line-height: 1.55;
  }

  .divider {
    border: 0;
    border-top: 1px solid #2a1a14;
    margin: 1rem 0;
  }

  .meta {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 0.75rem;
    color: #6a5848;
  }
|}]

let component (_graph @ local) =
  Bonsai.return
    (Node.div
       ~attrs:[ Style.root; Attr.role "main" ]
       [ Node.p ~attrs:[ Style.eyebrow ] [ Node.text "masc · runtime" ]
       ; Node.h1 ~attrs:[ Style.title ] [ Node.text "dark manor · bonsai" ]
       ; Node.p
           ~attrs:[ Style.sub ]
           [ Node.text
               "네 명의 키퍼, 폭풍 속의 저택. Bonsai 섬은 조용히 숨쉬는 \
                관찰자이다. 이 페이지는 런타임 입구를 지킬 뿐, 곧 관조 \
                판이 들어설 예정."
           ]
       ; Node.hr ~attrs:[ Style.divider ] ()
       ; Node.div
           ~attrs:[ Style.meta ]
           [ Node.text "preview · /dashboard/b · runtime shell" ]
       ])
;;
