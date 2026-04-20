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

  .main {
    padding: 2.5rem 2.5rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
    overflow: auto;
  }

  .hero { display: flex; flex-direction: column; gap: 6px; }

  .eyebrow {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 10px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
    margin: 0;
  }

  .title {
    font-family: 'Cinzel', serif;
    font-size: 30px;
    letter-spacing: 0.16em;
    color: var(--text-bright);
    text-transform: uppercase;
    margin: 0;
  }

  .title_tail {
    color: var(--accent-brass);
    font-size: 18px;
    margin-left: 14px;
  }

  .sub {
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-primary);
    margin: 0;
    max-width: 640px;
  }

  .quiet {
    padding: 28px 20px;
    text-align: center;
    border: 1px dashed var(--border-main);
    font-family: 'EB Garamond', serif;
    font-style: italic;
    color: var(--text-dim);
  }
|}]

let view_hero (keepers : Keepers_types.response) =
  let live_n, warn_n, dead_n =
    List.fold keepers.keepers ~init:(0, 0, 0)
      ~f:(fun (l, w, d) (k : Keepers_types.keeper) ->
        match k.status with
        | Live -> l + 1, w, d
        | Warn -> l, w + 1, d
        | Dead -> l, w, d + 1)
  in
  let tail =
    if live_n + warn_n + dead_n = 0
    then "— offline"
    else Printf.sprintf "· %d live · %d warn · %d dead" live_n warn_n dead_n
  in
  Hero.view
    ~eyebrow:"runtime · keepers"
    ~title:"fleet"
    ~tail:(tail, `Brass)
    ~sub:
      "3s 폴링으로 본 fleet 전체. 아래 섹션은 roster(현재) · \
       swim(60s 활동) · pressure(60m ctx)로 시간축이 짧아진다."
    ()
;;

let view_hud_strip (keepers : Keepers_types.response) =
  let live_n, warn_n, dead_n =
    List.fold keepers.keepers ~init:(0, 0, 0)
      ~f:(fun (l, w, d) (k : Keepers_types.keeper) ->
        match k.status with
        | Live -> l + 1, w, d
        | Warn -> l, w + 1, d
        | Dead -> l, w, d + 1)
  in
  let total = live_n + warn_n + dead_n in
  let synced =
    match keepers.generated_at with
    | "" -> "—"
    | ts ->
      if String.length ts >= 19 && Char.equal ts.[10] 'T'
      then Printf.sprintf "%s UTC" (String.sub ts ~pos:11 ~len:8)
      else ts
  in
  let dead_cls : Hud.v_class =
    if dead_n > 0 then `Bad else `Neutral
  in
  let warn_cls : Hud.v_class =
    if warn_n > 0 then `Warn else `Neutral
  in
  let live_cls : Hud.v_class =
    if live_n > 0 then `Ok else `Neutral
  in
  Hud.strip
    [ Hud.cell ~k:"Fleet" ~v:(Printf.sprintf "%02d" total) ()
    ; Hud.cell ~v_class:live_cls ~k:"Live"
        ~v:(Printf.sprintf "%02d" live_n) ()
    ; Hud.cell ~v_class:warn_cls ~k:"Warn"
        ~v:(Printf.sprintf "%02d" warn_n) ()
    ; Hud.cell ~v_class:dead_cls ~k:"Dead"
        ~v:(Printf.sprintf "%02d" dead_n) ()
    ; Hud.cell
        ~k:"Cycle"
        ~v:(if keepers.cycle <= 0
            then "—"
            else Printf.sprintf "%d" keepers.cycle)
        ()
    ; Hud.cell ~k:"Synced" ~v:synced ()
    ]
;;

let render (keepers : Keepers_types.response) : Node.t =
  let has_fleet = not (List.is_empty keepers.keepers) in
  Shell_view.view
    ~active:Keepers
    [ view_hero keepers
    ; view_hud_strip keepers
    ; (if has_fleet
       then
         Node.div
           ~attrs:[]
           [ Sec.view ~title:"roster" ~sub:"현재"
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
         Node.div
           ~attrs:[ Style.quiet ]
           [ Node.text
               "fleet endpoint is quiet — no keepers reported yet."
           ])
    ]
;;

let component (_graph @ local) =
  Bonsai.map (Bonsai.Expert.Var.value Keepers_var.var) ~f:render
;;
