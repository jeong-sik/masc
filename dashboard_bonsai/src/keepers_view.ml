(** Keepers view — fleet 전체 상태 대시보드.

    Phase 2.C 두 번째 탭. Phase 2.A에서 추출된 shell 모듈 4개를 조립:
    - [Hud]       : KPI strip (total / live / warn / dead / synced)
    - [Roster]    : sticky bottom keeper slot 그리드
    - [Swim]      : 60s per-keeper activity timeline
    - [Ctx_chart] : 60m per-keeper context pressure

    기존 `Keepers_var` 폴링 재사용 — 새 endpoint 無. Keepers 탭은 Dead_keepers
    처럼 derived view가 아니라 fleet 전체를 **확대 투영**. logs 탭에서 보이던
    HUD/Swim/Ctx/Roster를 독립 페이지로 끄집어낸 형태. *)

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
    border: 1px dashed var(--border-main);
    font-family: 'EB Garamond', serif;
    font-style: italic;
    color: var(--text-dim);
  }

  @media (prefers-contrast: more) {
    .quiet { border-width: 2px; border-style: solid; border-color: var(--text-bright); color: var(--text-bright); }
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
    ~eyebrow:"runtime + mission · keepers"
    ~title:"fleet"
    ~tail:(tail, `Brass)
    ~sub:
      "keepers summary에 execution + mission snapshot을 덧입혀 directory를 먼저 보여준다. 아래 섹션은 roster(축약) · swim(60s 활동) · pressure(60m ctx) 순으로 이어진다."
    ~sub_lang:"ko"
    ()
;;

let view_hud_strip
      ~(rows : Keepers_directory.row list)
      ~(execution : Directory_execution_types.response)
      ~(mission : Directory_mission_types.response)
  =
  let execution_generated_at =
    let open Directory_execution_types in
    execution.generated_at
  in
  let mission_generated_at =
    let open Directory_mission_types in
    mission.generated_at
  in
  let counts = Keepers_directory.counts rows in
  let coverage = Keepers_directory.coverage rows in
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
    ; Hud.cell
        ~k:"Shared"
        ~v:
          (if coverage.shared = 0 && String.is_empty execution_generated_at
              && String.is_empty mission_generated_at
           then "—"
           else Printf.sprintf "%02d" coverage.shared)
        ()
    ]
;;

let render
      ~(shell : Overview_types.response)
      ~(keepers : Keepers_types.response)
      ~(execution : Directory_execution_types.response)
      ~(mission : Directory_mission_types.response)
      ~(selected_name : string option)
  : Node.t
  =
  let rows = Keepers_directory.build_rows ~keepers execution mission in
  let has_fleet = not (List.is_empty keepers.keepers) in
  let page_sections =
    [ Sec.view ~title:"directory" ~sub:"runtime + mission"
        ~right:(Printf.sprintf "%d merged" (List.length rows))
        ()
    ; Node.div
        ~attrs:[ Keepers_directory.Style.meta_strip ]
        [ Keepers_directory.view_summary_strip ~rows ~execution ~mission ]
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
    ~aside:(Keepers_directory.aside ~rows ~selected_name ~execution ~mission)
    ~active:Keepers
    [ view_hero rows
    ; view_hud_strip ~rows ~execution ~mission
    ; Node.div ~attrs:[] page_sections
    ]
;;

let component (_graph @ local) =
  Bonsai.map
    (Bonsai.both
       (Bonsai.both
          (Bonsai.both
             (Bonsai.Expert.Var.value Keepers_var.var)
             (Bonsai.Expert.Var.value Overview_var.var))
          (Bonsai.both
             (Bonsai.Expert.Var.value Directory_execution_var.var)
             (Bonsai.Expert.Var.value Directory_mission_var.var)))
       (Bonsai.Expert.Var.value Keepers_directory.selected_name_var))
    ~f:(fun (((keepers, shell), (execution, mission)), selected_name) ->
      render ~shell ~keepers ~execution ~mission ~selected_name)
;;
