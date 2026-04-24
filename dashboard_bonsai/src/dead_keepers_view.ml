(** Dead keepers view — 추락한 키퍼 목록.

    Phase 2.C 첫 탭 이식. 새 endpoint/fetch 없이 기존 [Keepers_var] 의
    응답을 status=Dead 로 필터링만 한다. 4-파일 패턴 (types/fetch/var/view)
    중 view 만 신규 — 가장 가벼운 탭.

    design_v2 IA의 "crypt · dead keepers" 섹션. fleet에서 죽은 자들의
    기록:
    - 이름 · 마지막 상태(stat) · 지연시간(latency_ms가 × 로 표시)
    - 경고 없음 상태(0명 Dead)는 조용한 배너
    - 최근 crash timestamp는 keepers.generated_at 을 UTC 로

    shell 재사용: [Placeholder_view.sidebar] (IA 일관성) + 자체 main. *)

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
      radial-gradient(ellipse 40% 50% at 92% 95%, rgba(232,80,80,0.08), transparent 60%),
      linear-gradient(170deg, #0e0a08 0%, #140c08 60%, #080504 100%);
    color: var(--text-primary);
    font-family: 'Noto Sans KR', 'EB Garamond', sans-serif;
  }

  .main {
    padding: 3rem 3rem 2rem;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    overflow: auto;
  }

  .eyebrow {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    color: var(--text-dim);
    margin: 0;
  }

  .title {
    font-family: 'Cinzel', serif;
    font-size: 32px;
    letter-spacing: 0.16em;
    color: var(--text-bright);
    text-transform: uppercase;
    margin: 0;
  }

  .title_blood { color: var(--accent-blood); }

  .sub {
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-primary);
    margin: 0;
    max-width: 620px;
  }

  .meta_strip {
    display: flex;
    flex-wrap: wrap;
    gap: 24px;
    padding: 12px 16px;
    border: 1px solid var(--border-main);
    background: linear-gradient(180deg, rgba(42,20,14,0.35), rgba(20,12,8,0.65));
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
  }
  .meta_item { display: flex; align-items: baseline; gap: 8px; }
  .meta_k {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--text-dim);
  }
  .meta_v {
    font-variant-numeric: tabular-nums;
    color: var(--text-bright);
  }
  .meta_v_blood { color: var(--accent-blood); }

  .quiet {
    padding: 40px 20px;
    text-align: center;
    border: 1px dashed var(--border-main);
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-dim);
  }
|}]

let hhmmss_of_iso (s : string) : string =
  if String.length s >= 19 && Char.equal s.[10] 'T'
  then String.sub s ~pos:11 ~len:8
  else s
;;

let view_meta_strip ~(total : int) ~(dead : int) ~(synced : string) =
  Meta.strip
    ~label:"Dead keepers summary"
    [ Meta.cell ~k:"fleet" ~v:(Printf.sprintf "%02d" total) ()
    ; Meta.cell ~color:`Blood ~k:"dead" ~v:(Printf.sprintf "%02d" dead) ()
    ; Meta.cell ~k:"synced" ~v:synced ()
    ]
;;

let view_dead_list (dead : Keepers_types.keeper list) =
  match dead with
  | [] ->
    Node.div
      ~attrs:[ Style.quiet ]
      [ Node.text "fleet is whole — no keepers have fallen." ]
  | ks ->
    Node.div
      ~attrs:[ Attr.role "list"; Attr.arialabel "Dead keepers list" ]
      (List.map ks ~f:Roster.view_slot_of_keeper)
;;

let render ~(shell : Overview_types.response) (keepers : Keepers_types.response) : Node.t =
  let total = List.length keepers.keepers in
  let dead =
    List.filter keepers.keepers ~f:(fun (k : Keepers_types.keeper) ->
      match k.status with
      | Dead -> true
      | Live | Warn -> false)
  in
  let dead_n = List.length dead in
  let synced =
    match keepers.generated_at with
    | "" -> "—"
    | ts -> Printf.sprintf "%s UTC" (hhmmss_of_iso ts)
  in
  Shell_view.view
    ~shell
    ~active:Dead_keepers
    [ Hero.view
        ~eyebrow:"crypt · the fallen"
        ~title:"dead keepers"
        ~tail:(Printf.sprintf "· %02d" dead_n, `Blood)
        ~sub:
          "fleet의 추락한 자들. 이 목록은 Keepers 엔드포인트의 status=Dead \
           필터링 — 별도 endpoint 없음. 각 slot은 마지막으로 관측된 \
           state와 latency를 기록한다."
        ()
    ; view_meta_strip ~total ~dead:dead_n ~synced
    ; view_dead_list dead
    ]
;;

let component (_graph @ local) =
  Bonsai.map2
    (Bonsai.Expert.Var.value Keepers_var.var)
    (Bonsai.Expert.Var.value Overview_var.var)
    ~f:(fun keepers shell -> render ~shell keepers)
;;
