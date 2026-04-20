(** Placeholder view for routes that haven't been migrated to Bonsai yet.

    Renders the same dark-fantasy shell (brand + nav + centered card) but
    the main content is a single "Phase 2" panel with a link back to the
    Preact counterpart if applicable. Keeps the sidebar fully clickable so
    the operator can keep exploring without a broken tab trap.

    nav은 logs_view의 것과 구조가 거의 동일하지만 여기서는 단순화 —
    theme chip이나 brand 상세는 생략. logs_view가 canonical, 여기는
    "다른 탭이 있다" 사실만 표시하면 됨. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .root {
    display: grid;
    grid-template-columns: 232px 1fr;
    min-height: 100vh;
    background:
      radial-gradient(ellipse 60% 40% at 12% 8%, rgba(212,169,64,0.06), transparent 55%),
      radial-gradient(ellipse 40% 50% at 92% 95%, rgba(160,24,24,0.08), transparent 60%),
      linear-gradient(170deg, #0e0a08 0%, #140c08 60%, #080504 100%);
    color: var(--text-primary);
    font-family: 'Noto Sans KR', 'EB Garamond', sans-serif;
  }

  .nav {
    background: linear-gradient(180deg, #18110c, #0e0806);
    border-right: 1px solid var(--border-main);
    padding: 24px 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
    overflow: auto;
  }
  .nav_brand {
    padding: 0 20px 20px;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .nav_brand_rune {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--accent-brass-dim);
    color: var(--accent-brass);
    font-family: 'Cinzel', serif;
    font-size: 15px;
    letter-spacing: 0.08em;
  }
  .nav_brand_word {
    font-family: 'Cinzel', serif;
    font-size: 15px;
    letter-spacing: 0.24em;
    color: var(--text-bright);
    text-transform: uppercase;
  }
  .nav_brand_blood { color: var(--accent-blood); }

  .nav_section {
    padding: 14px 20px 6px;
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 9px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
  }
  .nav_link {
    display: flex;
    align-items: center;
    gap: 11px;
    padding: 8px 20px;
    color: var(--text-primary);
    font-size: 11px;
    text-decoration: none;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    border-left: 2px solid transparent;
    transition: background 0.1s, color 0.1s;
  }
  .nav_link:hover {
    color: var(--accent-brass);
    background: rgba(212, 169, 64, 0.05);
  }
  .nav_link_active {
    color: var(--accent-brass);
    border-left-color: var(--accent-brass);
    background: linear-gradient(90deg, rgba(212, 169, 64, 0.1), transparent 70%);
  }
  .nav_link_soon {
    color: var(--text-dim);
    opacity: 0.55;
  }
  .nav_link_soon:hover {
    color: var(--accent-brass-dim);
  }

  .main {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4rem 3rem;
  }
  .card {
    max-width: 560px;
    border: 1px solid var(--border-highlight);
    background:
      linear-gradient(180deg, rgba(42, 30, 20, 0.4), rgba(20, 12, 8, 0.7));
    padding: 2rem 2.25rem;
    display: flex;
    flex-direction: column;
    gap: 14px;
    box-shadow: 0 4px 22px rgba(0, 0, 0, 0.55);
  }
  .badge {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 10px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--accent-brass);
    border: 1px solid var(--accent-brass-dim);
    padding: 4px 10px;
    align-self: flex-start;
  }
  .title {
    font-family: 'Cinzel', serif;
    font-size: 28px;
    letter-spacing: 0.16em;
    color: var(--text-bright);
    text-transform: uppercase;
    margin: 0;
  }
  .sub {
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-primary);
    margin: 0;
  }
  .link_row {
    display: flex;
    gap: 14px;
    margin-top: 12px;
  }
  .link {
    color: var(--accent-brass);
    text-decoration: none;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    border-bottom: 1px solid var(--accent-brass-dim);
    padding-bottom: 2px;
  }
  .link:hover {
    color: var(--text-bright);
    border-bottom-color: var(--accent-brass);
  }
|}]

let brand =
  Node.div
    ~attrs:[ Style.nav_brand ]
    [ Node.div ~attrs:[ Style.nav_brand_rune ] [ Node.text "M" ]
    ; Node.span
        ~attrs:[ Style.nav_brand_word ]
        [ Node.text "ma"
        ; Node.span ~attrs:[ Style.nav_brand_blood ] [ Node.text "s" ]
        ; Node.text "c"
        ]
    ]
;;

let nav_link ~active (route : Route.t) =
  let classes =
    let base = [ Style.nav_link ] in
    let base = if active then Style.nav_link_active :: base else base in
    if Route.is_implemented route then base else Style.nav_link_soon :: base
  in
  Node.a
    ~attrs:(Attr.href (Route.path route) :: classes)
    [ Node.text (Route.label route) ]
;;

let section label = Node.div ~attrs:[ Style.nav_section ] [ Node.text label ]

let sidebar ~(active : Route.t) =
  let lnk route = nav_link ~active:(Route.equal route active) route in
  Node.div
    ~attrs:[ Style.nav ]
    [ brand
    ; section "chronicle"
    ; lnk Overview
    ; lnk Logs
    ; lnk Goals
    ; section "runtime"
    ; lnk Keepers
    ; lnk Observatory
    ; lnk Intervene
    ; section "lab"
    ; lnk Tools
    ; lnk Sessions
    ; lnk Social_board
    ; section "crypt"
    ; lnk Dead_keepers
    ; lnk Archive_runs
    ]
;;

let component ~(route : Route.t) (_graph @ local) =
  Bonsai.return
    (Node.div
       ~attrs:[ Style.root ]
       [ sidebar ~active:route
       ; Node.div
           ~attrs:[ Style.main ]
           [ Node.div
               ~attrs:[ Style.card ]
               [ Node.span ~attrs:[ Style.badge ] [ Node.text "phase 2 · 작업 중" ]
               ; Node.h1 ~attrs:[ Style.title ] [ Node.text (Route.label route) ]
               ; Node.p
                   ~attrs:[ Style.sub ]
                   [ Node.text
                       "이 탭은 아직 Bonsai로 이식되지 않았다. \
                        logs · 저널이 유일한 이식 탭."
                   ]
               ; Node.div
                   ~attrs:[ Style.link_row ]
                   [ Node.a
                       ~attrs:
                         [ Attr.href (Route.path Logs); Style.link ]
                       [ Node.text "← 저널로" ]
                   ; Node.a
                       ~attrs:
                         [ Attr.href "/dashboard/"; Style.link ]
                       [ Node.text "preact 대시보드 →" ]
                   ]
               ]
           ]
       ])
;;
