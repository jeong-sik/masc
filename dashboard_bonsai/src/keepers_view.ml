(** Keepers view — fleet 전체 상태 대시보드.

    Phase 2.C 두 번째 탭. Phase 2.A에서 추출된 shell 모듈 4개를 조립:
    - [Hud]       : KPI strip (total / live / warn / dead)
    - [Roster]    : sticky bottom keeper slot 그리드
    - [Swim]      : 60s per-keeper activity timeline
    - [Ctx_chart] : 60m per-keeper context pressure

    Single-source: Keepers summary endpoint만 소비. execution/mission 투영은
    제거됨 — SSOT 단일화. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .quiet {
    padding: 28px 20px;
    text-align: center;
    border: 1px dashed var(--color-border-default);
    font-family: 'EB Garamond', serif;
    font-style: italic;
    color: var(--color-fg-muted);
  }

  @media (prefers-contrast: more) {
    .quiet { border-width: 2px; border-style: solid; border-color: var(--text-bright); color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .quiet { border-color: CanvasText; color: CanvasText; }
  }
|}]

let view_hero (rows : Keepers_directory.row list) =
  let counts = Keepers_directory.counts rows in
  let tail =
    if counts.total = 0
    then "· directory pending"
    else
      Printf.sprintf
        "· %d active · %d attention · %d paused · %d offline"
        counts.active
        counts.attention
        counts.paused
        counts.offline
  in
  Hero.view
    ~eyebrow:"summary · keepers"
    ~title:"fleet"
    ~tail:(tail, `Brass)
    ~sub:
      "keepers summary endpoint로 directory를 구성한다. 아래 섹션은 roster(축약) · swim(60s 활동) · pressure(60m ctx) 순으로 이어진다."
    ~sub_lang:"ko"
    ()
;;

let view_hud_strip ~(rows : Keepers_directory.row list) =
  let counts = Keepers_directory.counts rows in
  Hud.strip ~label:"Fleet KPIs"
    [ Hud.cell ~k:"Fleet" ~v:(Printf.sprintf "%02d" counts.total) ()
    ; Hud.cell ~v_class:(if counts.active > 0 then `Ok else `Neutral)
        ~k:"Active"
        ~v:(Printf.sprintf "%02d" counts.active) ()
    ; Hud.cell
        ~v_class:(if counts.attention > 0 then `Warn else `Neutral)
        ~k:"Attention"
        ~v:(Printf.sprintf "%02d" counts.attention) ()
    ; Hud.cell
        ~v_class:(if counts.paused > 0 then `Warn else `Neutral)
        ~k:"Paused"
        ~v:(Printf.sprintf "%02d" counts.paused) ()
    ; Hud.cell
        ~v_class:(if counts.offline > 0 then `Bad else `Neutral)
        ~k:"Offline"
        ~v:(Printf.sprintf "%02d" counts.offline) ()
    ]
;;

let render
      ~(shell : Overview_types.response)
      ~(keepers : Keepers_types.response)
      ~(selected_name : string option)
  : Node.t
  =
  let rows = Keepers_directory.build_rows ~keepers in
  let has_fleet = not (List.is_empty keepers.keepers) in
  let page_sections =
    [ Sec.view ~title:"directory" ~sub:"summary"
        ~right:(Printf.sprintf "%d keepers" (List.length rows))
        ()
    ; Node.div
        ~attrs:[ Keepers_directory.Style.meta_strip ]
        [ Keepers_directory.view_summary_strip ~rows ]
    ; Keepers_directory.view ~rows ~selected_name
    ]
    @ if has_fleet
      then
        [ Sec.view ~title:"roster" ~sub:"condensed"
            ~right:
              (Printf.sprintf
                 "fleet %d"
                 (List.length keepers.keepers))
            ()
        ; Roster.view ~keepers ()
        ; Sec.view ~title:"swim" ~sub:"60s"
            ~right:"lane · activity" ()
        ; Swim.view ~keepers ()
        ; Sec.view ~title:"pressure" ~sub:"60m"
            ~right:"ctx %" ()
        ; Ctx_chart.view ~keepers ()
        ]
      else
        [ Node.div
            ~attrs:[ Style.quiet; Attr.role "status"; Attr.create "aria-label" "No live keepers" ]
            [ Node.span ~attrs:[ Attr.create "lang" "ko" ]
                [ Node.text
                    "keepers summary endpoint is quiet — directory snapshot만 먼저 올라와 있습니다."
                ]
            ]
        ]
  in
  Shell_view.view
    ~shell
    ~aside:(Keepers_directory.aside ~rows ~selected_name)
    ~active:Keepers
    [ view_hero rows
    ; view_hud_strip ~rows
    ; Node.div ~attrs:[] page_sections
    ]
;;

let component (_graph @ local) =
  Bonsai.map
    (Bonsai.both
       (Bonsai.both
          (Bonsai.Expert.Var.value Keepers_var.var)
          (Bonsai.Expert.Var.value Overview_var.var))
       (Bonsai.Expert.Var.value Keepers_directory.selected_name_var))
    ~f:(fun ((keepers, shell), selected_name) ->
      render ~shell ~keepers ~selected_name)
;;
