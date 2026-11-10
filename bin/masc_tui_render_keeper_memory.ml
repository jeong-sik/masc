open Masc_tui_ansi
module View = Masc_tui_keeper_story
module Fetched = Masc_tui_fetched
module Facts = Masc.Tui_decode_memory_facts
module Activity = Masc.Keeper_memory_activity
module Layout = Masc_tui_message_layout
module Table = Masc_tui_table

let quiet text = Theme.recede () ^ text ^ Ansi.reset
let warning text = Theme.warn () ^ text ^ Ansi.reset
let clean = Terminal_text.single_line
let fit width text = Layout.fit_width (clean text) (max 0 width)
let age ~now at = Option.value (Layout.age_text ~now ~since:at) ~default:"—"

let facts_view (state : Masc_tui_types.state) keeper_name =
  Fetched.view_for ~equal:String.equal state.keeper_story_memory_facts ~key:keeper_name
let activity_view (state : Masc_tui_types.state) keeper_name =
  Fetched.view_for ~equal:String.equal state.keeper_story_memory_activity ~key:keeper_name
let facts state keeper_name =
  match Fetched.value (facts_view state keeper_name) with
  | Some ({mfs_ordinary = Facts.Memory_store_present store; _}, _) -> store.mos_facts
  | Some ({mfs_ordinary = Facts.Memory_store_absent | Facts.Memory_store_read_error _; _}, _)
  | None -> []
let recent state keeper_name =
  List.sort (fun (a : Facts.memory_fact) b ->
    let clock = Float.compare b.mf_last_seen a.mf_last_seen in
    if clock = 0 then String.compare a.mf_memory_id b.mf_memory_id else clock)
    (facts state keeper_name)
let frequent state keeper_name =
  List.filter_map (fun (fact : Facts.memory_fact) -> match fact.mf_events.mfe_retrieval with
    | Facts.Never_retrieved -> None
    | Facts.Retrieved {count; last_at; distinct_days = _} -> Some (fact, count, last_at))
    (facts state keeper_name)
  |> List.sort (fun ((a : Facts.memory_fact), ac, at) ((b : Facts.memory_fact), bc, bt) ->
    let count = Int.compare bc ac in
    if count <> 0 then count else let clock = Float.compare bt at in
    if clock <> 0 then clock else String.compare a.mf_memory_id b.mf_memory_id)
let events state keeper_name =
  match Fetched.value (activity_view state keeper_name) with
  | None -> []
  | Some activity -> List.rev activity.events

let row_count state ~keeper_name =
  match state.Masc_tui_types.keeper_story_memory_view with
  | View.Memory_recent -> List.length (recent state keeper_name)
  | View.Memory_frequent -> List.length (frequent state keeper_name)
  | View.Memory_changes -> List.length (events state keeper_name)
  | View.Memory_summary | View.Memory_storage -> 0

let observation_notes ~ko label = function
  | Fetched.Absent -> [quiet (label ^ if ko then " · 미조회" else " · not read")]
  | Fetched.Loading -> [quiet (label ^ if ko then " · 읽는 중" else " · loading")]
  | Fetched.Ready _ -> []
  | Fetched.Failed reason -> [warning (label ^ " · " ^ clean reason)]
  | Fetched.Stale (_, reason) ->
      [warning (label ^ (if ko then " · 이전 관측 · " else " · last observation · ") ^ clean reason)]

let fact_notes ~ko state keeper_name =
  let label = if ko then "기억" else "facts" in
  observation_notes ~ko label (facts_view state keeper_name)
  @ match Fetched.value (facts_view state keeper_name) with
    | None -> []
    | Some (snapshot, usage_error) ->
      (match snapshot.mfs_ordinary with
       | Facts.Memory_store_read_error reason -> [warning (label ^ " · " ^ clean reason)]
       | Facts.Memory_store_absent | Facts.Memory_store_present _ -> [])
      @ (match usage_error with None -> [] | Some reason ->
          [warning ((if ko then "조회 기록 일부 · " else "partial retrieval record · ") ^ clean reason)])

let activity_notes ~ko state keeper_name =
  observation_notes ~ko (if ko then "변화" else "changes") (activity_view state keeper_name)
  @ match Fetched.value (activity_view state keeper_name) with
    | None | Some {notes = []; _} -> []
    | Some activity -> [warning ((if ko then "이력 일부 · " else "partial history · ")
        ^ string_of_int (List.length activity.notes) ^ " · " ^ clean (List.hd activity.notes))]

let kind_word ~ko = function
  | Activity.Created -> if ko then "생성" else "created"
  | Activity.Reobserved -> if ko then "재관측" else "observed"
  | Activity.Revised -> if ko then "수정" else "revised"
  | Activity.Absorbed -> if ko then "흡수" else "absorbed"
  | Activity.Retracted -> if ko then "삭제" else "retracted"
  | Activity.Removed -> if ko then "제외" else "removed"
  | Activity.Invalidated -> if ko then "무효화" else "invalidated"
  | Activity.Relation_unavailable -> if ko then "관계 미확인" else "unresolved"

let endpoints facts = match facts with
  | [] -> "—"
  | facts ->
    let claim (fact : Activity.fact) = match fact.claim with
      | Some claim -> clean claim
      | None -> "[" ^ Layout.truncate_middle 12 fact.memory_id ^ "]" in
    let count = if List.length facts > 1 then string_of_int (List.length facts) ^ " · " else "" in
    count ^ String.concat " + " (List.map claim facts)

let event_cells ~ko ~now ~cols (event : Activity.event) =
  let cell = Table.cell ~fold:Table.Fold_tail in
  let after = match event.after, event.reason with
    | [], Some reason -> clean reason
    | ([] | _ :: _), (None | Some _) -> endpoints event.after in
  let time = cell ~header:(if ko then "시각" else "when") ~width:7 (age ~now event.recorded_at) in
  let kind = cell ~header:(if ko then "변화" else "change") ~width:10 (kind_word ~ko event.kind) in
  if cols < 70 then
    [time; kind; cell ~header:(if ko then "기억의 흐름" else "memory flow")
      ~width:(max 1 (cols - 19)) (endpoints event.before ^ " → " ^ after)]
  else
    let room = max 1 ((cols - 20) / 2) in
    [time; kind;
     cell ~header:(if ko then "이전" else "before") ~width:room (endpoints event.before);
     cell ~header:(if ko then "이후 / 사유" else "after / reason") ~width:room after]

let lines (state : Masc_tui_types.state) ~cols ~max_lines ~now ~keeper_name ~storage =
  let ko = state.ui_language = Masc_tui_types.Lang_ko in
  let text ko_text en = if ko then ko_text else en in
  let width = max 1 (cols - 4) in
  let mode = state.keeper_story_memory_view in
  let nav = quiet (text "0 요약  1 최근  2 조회  3 변화  4 저장  [ ] 이동"
      "0 overview  1 recent  2 retrievals  3 changes  4 storage  [ ] scroll") in
  let offset = if state.keeper_story_memory_owner = Some keeper_name
    then min (max 0 (row_count state ~keeper_name - 1)) state.keeper_story_memory_offset else 0 in
  let notes = match mode with
    | View.Memory_summary | View.Memory_storage ->
        fact_notes ~ko state keeper_name @ activity_notes ~ko state keeper_name
    | View.Memory_recent | View.Memory_frequent -> fact_notes ~ko state keeper_name
    | View.Memory_changes -> activity_notes ~ko state keeper_name in
  let notes = List.take (max 0 (max_lines - 1)) notes in
  let budget = max 0 (max_lines - 1 - List.length notes) in
  let table ?(intro = 0) ~empty make rows =
    let total = List.length rows in
    match rows with
    | [] -> [quiet empty]
    | first :: _ ->
      let shown = List.drop offset rows |> List.take (max 0 (budget - 2 - intro)) in
      quiet (Table.header_row (make first)) :: List.map (fun row -> Table.row (make row)) shown
      @ [quiet (Printf.sprintf "%d–%d / %d" (min total (offset + 1))
          (min total (offset + List.length shown)) total)] in
  let flow rows = table ~intro:1 ~empty:(text "확인된 변경 없음" "no observed changes")
      (event_cells ~ko ~now ~cols:width) rows in
  let recent_cell (fact : Facts.memory_fact) =
    [Table.cell ~header:(text "갱신" "recorded") ~width:9 (age ~now fact.mf_last_seen);
     Table.cell ~fold:Table.Fold_tail ~header:(text "기억" "memory") ~width:(max 1 (width - 10))
       (clean fact.mf_claim)] in
  let frequent_cell ((fact : Facts.memory_fact), count, at) =
    [Table.cell ~align:Table.Right ~header:(text "조회" "returns") ~width:6 (string_of_int count);
     Table.cell ~header:(text "마지막 조회" "last return") ~width:12 (age ~now at);
     Table.cell ~fold:Table.Fold_tail ~header:(text "기억" "memory") ~width:(max 1 (width - 20))
       (clean fact.mf_claim)] in
  let facts_available = match Fetched.value (facts_view state keeper_name) with
    | Some ({mfs_ordinary = Facts.Memory_store_present _ | Facts.Memory_store_absent; _}, _) -> true
    | Some ({mfs_ordinary = Facts.Memory_store_read_error _; _}, _) | None -> false in
  let activity_available = Option.is_some (Fetched.value (activity_view state keeper_name)) in
  let body = match mode with
    | View.Memory_storage -> storage ()
    | View.Memory_recent ->
        if facts_available then
          table ~empty:(text "기록된 기억 없음" "no recorded claims") recent_cell (recent state keeper_name)
        else []
    | View.Memory_frequent ->
        if facts_available then
          quiet (text "기록상 조회순 · 검색 결과로 반환된 횟수" "recorded retrievals · search returns")
          :: table ~intro:1 ~empty:(text "기록된 조회 없음" "no recorded retrievals") frequent_cell (frequent state keeper_name)
        else []
    | View.Memory_changes ->
        let scope = match Fetched.value (activity_view state keeper_name) with
          | None -> [] | Some activity -> [quiet (text
              (Printf.sprintf "최근 처리 기록 %d / 최대 %d회" activity.journal_lines activity.limit)
              (Printf.sprintf "latest %d / up to %d journal entries" activity.journal_lines activity.limit))] in
        if activity_available then scope @ flow (events state keeper_name) else []
    | View.Memory_summary ->
        let left = recent state keeper_name |> List.take 2 |> List.map (fun fact ->
          age ~now fact.Facts.mf_last_seen ^ "  " ^ clean fact.mf_claim) in
        let right = frequent state keeper_name |> List.take 2 |> List.map (fun (fact, count, at) ->
          Printf.sprintf "%d×  %s  %s" count (age ~now at) (clean fact.Facts.mf_claim)) in
        let half = max 1 ((width - 3) / 2) in
        let at rows i empty = Option.value (List.nth_opt rows i) ~default:empty in
        let claims =
          if width >= 90 then
            quiet (fit half (text "최근 갱신" "recently recorded") ^ "   " ^ text "자주 조회" "frequently retrieved")
            :: List.init 2 (fun i ->
              fit half (at left i "—") ^ "   " ^ fit half (at right i "—"))
          else
            [quiet (text "최근 갱신" "recently recorded"); at left 0 "—";
             quiet (text "자주 조회" "frequently retrieved"); at right 0 "—"] in
        let changes = events state keeper_name |> List.take 2 in
        let change_rows = match changes with
          | [] -> if activity_available then [quiet (text "확인된 변경 없음" "no observed changes")] else []
          | rows -> quiet (Table.header_row (event_cells ~ko ~now ~cols:width (List.hd rows)))
            :: List.map (fun event -> Table.row (event_cells ~ko ~now ~cols:width event)) rows in
        let usage = if not facts_available then [] else
          let total = List.length (facts state keeper_name) in
          let used = List.length (frequent state keeper_name) in
          [quiet (text
            (Printf.sprintf "현재 기억 %d · 조회 기록 %d / %d" total used total)
            (Printf.sprintf "%d current memories · %d / %d with recorded retrievals" total used total))] in
        usage @ claims @ change_rows in
  let body = List.take budget body in
  List.take max_lines (List.map (fun line -> "  " ^ line) (notes @ body @ [nav]))
