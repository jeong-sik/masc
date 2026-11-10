open Masc_tui_ansi
module Fetched = Masc_tui_fetched
module Facts = Masc.Tui_decode_memory_facts
module Activity = Masc.Keeper_memory_activity
module Layout = Masc_tui_message_layout
module Table = Masc_tui_table
module Card = Masc_tui_card

let quiet text = Theme.recede () ^ text ^ Ansi.reset
let warning text = Theme.warn () ^ text ^ Ansi.reset
let clean = Terminal_text.single_line
let age ~now at = Option.value (Layout.age_text ~now ~since:at) ~default:"—"

let facts_view (state : Masc_tui_types.state) keeper_name =
  Fetched.view_for ~equal:String.equal state.memory_facts ~key:keeper_name
let activity_view (state : Masc_tui_types.state) keeper_name =
  Fetched.view_for ~equal:String.equal state.memory_activity ~key:keeper_name
let facts state keeper_name =
  match Fetched.value (facts_view state keeper_name) with
  | Some ({mfs_ordinary = Facts.Memory_store_present store; _}, _) -> store.mos_facts
  | Some ({mfs_ordinary = Facts.Memory_store_absent | Facts.Memory_store_read_error _; _}, _)
  | None -> []
let ordered_facts sort state keeper_name =
  match Fetched.value (facts_view state keeper_name) with
  | None -> []
  | Some (snapshot, _) ->
    Masc_tui_types.project_memory_facts ~category:Masc_tui_types.Category_all
      ~sort ~query:"" ~fleet:false snapshot
    |> List.filter_map (function
      | Masc_tui_types.Memory_row_fact fact -> Some fact
      | Masc_tui_types.Memory_row_source_fact _ | Masc_tui_types.Memory_row_invalidation _ -> None)
let recent = ordered_facts Masc_tui_types.Sort_recency
let frequent state keeper_name =
  ordered_facts Masc_tui_types.Sort_retrieved_count state keeper_name
  |> List.filter_map (fun (fact : Facts.memory_fact) -> match fact.mf_events.mfe_retrieval with
    | Facts.Never_retrieved -> None
    | Facts.Retrieved {count; last_at; distinct_days = _} -> Some (fact, count, last_at))
let events state keeper_name =
  match Fetched.value (activity_view state keeper_name) with
  | None -> []
  | Some activity -> List.rev activity.events
let change_count state ~keeper_name = List.length (events state keeper_name)

let selected_event state keeper_name =
  let rows = events state keeper_name in
  List.nth_opt rows (max 0 (min (max 0 (List.length rows - 1)) state.Masc_tui_types.memory_changes_cursor))

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
    | Some (snapshot, coverage_error) ->
      (match snapshot.mfs_ordinary with
       | Facts.Memory_store_read_error reason -> [warning (label ^ " · " ^ clean reason)]
       | Facts.Memory_store_absent | Facts.Memory_store_present _ -> [])
      @ (match coverage_error with None -> [] | Some reason ->
          [warning ((if ko then "일부 관측 · " else "partial observation · ") ^ clean reason)])
      @ (match snapshot.mfs_events_read_error with None -> [] | Some reason ->
          [warning ((if ko then "조회 기록 일부 · " else "partial retrieval record · ") ^ clean reason)])

let activity_notes ~ko state keeper_name =
  observation_notes ~ko (if ko then "변화" else "changes") (activity_view state keeper_name)
  @ match Fetched.value (activity_view state keeper_name) with
    | None | Some {notes = []; _} -> []
    | Some activity -> [warning ((if ko then "이력 일부 · " else "partial history · ")
        ^ string_of_int (List.length activity.notes) ^ " · " ^ clean (List.hd activity.notes))]

let kind_word = Masc_tui_memory_lineage.kind_label

let kind_style = function
  | Activity.Created | Activity.Reobserved -> Theme.ok ()
  | Activity.Revised | Activity.Absorbed -> Theme.info ()
  | Activity.Retracted | Activity.Invalidated -> Theme.bad ()
  | Activity.Removed | Activity.Relation_unavailable -> Theme.warn ()

let endpoints facts = match facts with
  | [] -> "—"
  | facts ->
    let claim (fact : Activity.fact) = match fact.claim with
      | Some claim -> clean claim
      | None -> "[" ^ Layout.truncate_middle 12 fact.memory_id ^ "]" in
    let count = if List.length facts > 1 then string_of_int (List.length facts) ^ " · " else "" in
    count ^ String.concat " + " (List.map claim facts)

let event_cells ?(selected=false) ~ko ~now ~cols (event : Activity.event) =
  let cell = Table.cell ~fold:Table.Fold_tail in
  let after = match event.after, event.reason with
    | [], Some reason -> clean reason
    | ([] | _ :: _), (None | Some _) -> endpoints event.after in
  let time = cell ~header:(if ko then "시각" else "when") ~width:7 (age ~now event.recorded_at) in
  let kind = cell ~header:(if ko then "변화" else "change") ~width:12
    ~style:(if selected then "" else kind_style event.kind) (kind_word ~ko event.kind) in
  if cols < 70 then
    [time; kind; cell ~header:(if ko then "기억의 흐름" else "memory flow")
      ~width:(max 1 (cols - 21)) (endpoints event.before ^ " → " ^ after)]
  else
    let room = max 1 ((cols - 22) / 2) in
    [time; kind;
     cell ~header:(if ko then "이전" else "before") ~width:room (endpoints event.before);
     cell ~header:(if ko then "이후 / 사유" else "after / reason") ~width:room after]

let summary_lines (state : Masc_tui_types.state) ~cols ~max_lines ~now ~keeper_name =
  let ko = state.ui_language = Masc_tui_types.Lang_ko in
  let text ko_text en = if ko then ko_text else en in
  let width = max 1 (cols - 4) in
  let notes = fact_notes ~ko state keeper_name @ activity_notes ~ko state keeper_name in
  let nav = quiet (text "Enter 목록  1 최근  2 조회  3 변화  4 저장"
      "Enter browse  1 recent  2 retrievals  3 changes  4 storage") in
  let notes = List.take (max 0 (max_lines - 1)) notes in
  let budget = max 0 (max_lines - 1 - List.length notes) in
  let left = recent state keeper_name |> List.take 2 |> List.map (fun fact ->
    age ~now fact.Facts.mf_last_seen ^ "  " ^ clean fact.mf_claim) in
  let right = frequent state keeper_name |> List.take 2 |> List.map (fun (fact, count, at) ->
    Printf.sprintf "%d×  %s  %s" count (age ~now at) (clean fact.Facts.mf_claim)) in
  let half = max 1 ((width - 2) / 2) in
  let at rows i = Option.value (List.nth_opt rows i) ~default:"—" in
  let card ~width ~height title rows =
    let style : Card.style = {edge=Theme.recede (); title_style=Theme.info (); reset=Ansi.reset} in
    Card.render ~rounded:true ~style ~width ~height {title; body=(fun ~cells:_ -> rows)} in
  let claims = if width >= 90 && budget >= 5 then
      let left = card ~width:half ~height:4 (text "↻ 최근 갱신" "↻ Recently recorded") [at left 0; at left 1] in
      let right = card ~width:(width-half-2) ~height:4 (text "◇ 자주 조회" "◇ Frequently retrieved") [at right 0; at right 1] in
      List.map2 (fun a b -> a ^ "  " ^ b) left right
    else if budget >= 7 && width >= Card.min_width then
      card ~width ~height:3 (text "↻ 최근 갱신" "↻ Recently recorded") [at left 0]
      @ card ~width ~height:3 (text "◇ 자주 조회" "◇ Frequently retrieved") [at right 0]
    else [text "↻ 최근 · " "↻ Recent · " ^ at left 0; text "◇ 조회 · " "◇ Retrieved · " ^ at right 0] in
  let changes = match events state keeper_name |> List.take 2 with
    | [] -> if Option.is_some (Fetched.value (activity_view state keeper_name))
        then [quiet (text "확인된 변경 없음" "no observed changes")] else []
    | first :: rest ->
      quiet (Table.header_row (event_cells ~ko ~now ~cols:width first))
      :: List.map (fun event -> Table.row (event_cells ~ko ~now ~cols:width event)) (first :: rest) in
  let usage = match Fetched.value (facts_view state keeper_name) with
    | Some ({mfs_ordinary = Facts.Memory_store_present _ | Facts.Memory_store_absent; _}, _) ->
      let total = List.length (facts state keeper_name) in
      [quiet (text (Printf.sprintf "현재 기억 %d · 조회 기록 %d / %d" total (List.length (frequent state keeper_name)) total)
        (Printf.sprintf "%d current memories · %d / %d with recorded retrievals" total (List.length (frequent state keeper_name)) total))]
    | Some ({mfs_ordinary = Facts.Memory_store_read_error _; _}, _) | None -> [] in
  List.take max_lines (List.map (fun line -> "  " ^ line)
    (notes @ List.take budget (usage @ claims @ changes) @ [nav]))

let changes_page_size (state : Masc_tui_types.state) ~max_lines ~keeper_name =
  let notes = activity_notes ~ko:(state.ui_language = Masc_tui_types.Lang_ko) state keeper_name in
  let scope_rows = if Option.is_some (Fetched.value (activity_view state keeper_name)) then 1 else 0 in
  max 0 (max_lines - 1 - List.length notes - scope_rows - 4)

let changes_lines (state : Masc_tui_types.state) ~cols ~max_lines ~now ~keeper_name =
  let ko = state.ui_language = Masc_tui_types.Lang_ko in
  let text ko_text en = if ko then ko_text else en in
  let notes = activity_notes ~ko state keeper_name in
  let rows = events state keeper_name in
  let total = List.length rows in
  let offset = max 0 (min (max 0 (total - 1)) state.memory_changes_cursor) in
  let header = quiet (text "1 최근  2 조회  3 변화  4 저장" "1 recent  2 retrievals  3 changes  4 storage") in
  let scope = match Fetched.value (activity_view state keeper_name) with
    | None -> []
    | Some activity -> [quiet (text
        (Printf.sprintf "최근 처리 기록 %d / 최대 %d회" activity.journal_lines activity.limit)
        (Printf.sprintf "latest %d / up to %d journal entries" activity.journal_lines activity.limit))] in
  let budget = changes_page_size state ~max_lines ~keeper_name in
  let body ~cells = match rows with
    | [] -> if Option.is_some (Fetched.value (activity_view state keeper_name))
        then [quiet (text "확인된 변경 없음" "no observed changes")] else []
    | first :: _ ->
      let shown = List.drop offset rows |> List.take budget in
      quiet (Table.header_row (event_cells ~ko ~now ~cols:cells first))
      :: List.mapi (fun i event ->
          let row = Table.row ~close:(if i = 0 then Ansi.reset ^ Theme.selection else Ansi.reset)
            (event_cells ~selected:(i = 0) ~ko ~now ~cols:cells event) in
          if i = 0 then Theme.selection ^ row ^ Ansi.reset else row) shown
      @ [quiet (Printf.sprintf "%d–%d / %d · Enter %s" (offset + 1) (offset + List.length shown) total
          (text "전문  ·  … [.] 형성 트리" "full reading  ·  … [.] formation tree"))] in
  let height = max 0 (min (total + 4) (max_lines - 1 - List.length notes - List.length scope)) in
  let style : Card.style = {edge=Theme.recede ();title_style=Theme.info ();reset=Ansi.reset} in
  let body = Card.render ~rounded:true ~style ~width:(max 1 (cols - 4)) ~height
    {title=text "◇ 기억의 흐름" "◇ Memory flow";body} in
  List.take max_lines (List.map (fun line -> "  " ^ line) ([header] @ notes @ scope @ body))

let change_reading (state : Masc_tui_types.state) ~keeper_name =
  let ko = state.ui_language = Masc_tui_types.Lang_ko in
  let text ko_text en = if ko then ko_text else en in
  match selected_event state keeper_name with
  | None -> None
  | Some event ->
    let body facts = match facts with
      | [] -> "—"
      | facts -> String.concat "\n\n" (List.map (fun (fact : Activity.fact) ->
          match fact.claim with Some claim -> claim
          | None -> text "본문 미확인 · " "claim not observed · " ^ fact.memory_id) facts) in
    let notes = match activity_view state keeper_name with
      | Fetched.Ready activity -> activity.notes
      | Fetched.Stale (activity, reason) ->
          (text "이전 관측 · " "last observation · " ^ reason) :: activity.notes
      | Fetched.Failed reason -> [reason]
      | Fetched.Absent | Fetched.Loading -> [] in
    let section heading body : Masc_tui_detail_reading.section = {heading; body} in
    let sections =
      [section keeper_name (String.concat "\n" notes);
       section (text "이전" "Before") (body event.before);
       section (text "이후" "After") (body event.after)]
      @ (match event.reason with None -> [] | Some reason ->
          [section (text "사유" "Reason") reason]) in
    Some (Masc_tui_detail_reading.create ~ko
      ~title:(text "기억 변화 · " "Memory change · " ^ kind_word ~ko event.kind) sections)

let change_diagram (state : Masc_tui_types.state) ~keeper_name =
  match selected_event state keeper_name, activity_view state keeper_name with
  | Some event, (Fetched.Ready activity | Fetched.Stale (activity, _)) ->
      let notes = match activity_view state keeper_name with
        | Fetched.Stale (_, reason) -> ("Last observation: " ^ reason) :: activity.notes
        | Fetched.Ready _ | Fetched.Absent | Fetched.Loading | Fetched.Failed _ -> activity.notes in
      Masc_tui_memory_lineage.select ~event_id:event.identity {activity with notes}
      |> Option.map (fun chart -> Masc_tui_image_preview.mermaid
          ~name:((if state.ui_language = Masc_tui_types.Lang_ko then "기억 형성 · " else "Memory formation · ") ^ keeper_name)
          (Masc_tui_memory_lineage.mermaid ~ko:(state.ui_language = Masc_tui_types.Lang_ko) chart))
  | (Some _ | None), (Fetched.Absent | Fetched.Loading | Fetched.Failed _)
  | None, (Fetched.Ready _ | Fetched.Stale _) -> None
