module Activity = Masc.Keeper_memory_activity
module Ids = Set.Make (String)
module Observed = Map.Make (String)

type t = {
  selected : Activity.event;
  events : Activity.event list;
  facts : Activity.fact list;
  journal_lines : int;
  limit : int;
  notes : string list;
}

let identities (event : Activity.event) =
  List.fold_left (fun ids (fact : Activity.fact) -> Ids.add fact.memory_id ids)
    Ids.empty (event.before @ event.after)

let observed_facts events =
  List.concat_map (fun (event : Activity.event) -> event.before @ event.after) events
  |> List.fold_left (fun observed (fact : Activity.fact) ->
      match Observed.find_opt fact.memory_id observed with
      | Some {Activity.claim=Some _; _} -> observed
      | None | Some {Activity.claim=None; _} -> Observed.add fact.memory_id fact observed) Observed.empty
  |> Observed.bindings |> List.map snd

let select ~event_id (activity : Activity.t) =
  match List.find_opt (fun (event : Activity.event) -> event.identity = event_id) activity.events with
  | None -> None
  | Some selected ->
    let rec expand ids =
      let next = List.fold_left (fun ids event ->
        let endpoints = identities event in
        if Ids.disjoint ids endpoints then ids else Ids.union ids endpoints)
        ids activity.events in
      if Ids.equal ids next then ids else expand next in
    let ids = expand (identities selected) in
    let events = List.filter (fun (event : Activity.event) ->
      event.identity = event_id || not (Ids.disjoint ids (identities event))) activity.events in
    Some {selected; events; facts=observed_facts events;
      journal_lines=activity.journal_lines; limit=activity.limit; notes=activity.notes}

let dedup_strings items =
  let seen = Hashtbl.create (List.length items) in
  List.filter (fun item ->
    let key = String.trim (Masc.Tui_terminal_text.sanitize_terminal_text item) in
    if key = "" || Hashtbl.mem seen key then false
    else (Hashtbl.add seen key (); true)) items

let wrap_full_lines ~max_cells value =
  let sanitized = Masc.Tui_terminal_text.sanitize_terminal_lines value in
  let lines = String.split_on_char '\n' sanitized in
  List.concat_map (fun line ->
    let trimmed = String.trim line in
    if trimmed = "" then [ "" ]
    else
      match Masc_tui_message_layout.wrap_words ~max_cells trimmed with
      | [] -> [ "" ]
      | wrapped -> wrapped) lines

let escape_mermaid value =
  let buffer = Buffer.create (String.length value) in
  String.iter (function
    | '#' -> Buffer.add_string buffer "#35;"
    | '&' -> Buffer.add_string buffer "#38;"
    | '"' -> Buffer.add_string buffer "#quot;"
    | '`' -> Buffer.add_string buffer "#96;"
    | '<' -> Buffer.add_string buffer "#60;"
    | '>' -> Buffer.add_string buffer "#62;"
    | c -> Buffer.add_char buffer c)
    (Masc.Tui_terminal_text.sanitize_terminal_text value);
  Buffer.contents buffer

(* Full wrapped lines joined with Mermaid <br/> after per-line entity escaping. *)
let mermaid_label ~max_cells text =
  wrap_full_lines ~max_cells text
  |> List.map escape_mermaid
  |> String.concat "<br/>"

let kind_label ~ko = function
  | Activity.Created -> if ko then "＋ 생성" else "+ Created"
  | Activity.Reobserved -> if ko then "↻ 재관측" else "Reobserved"
  | Activity.Revised -> if ko then "↗ 수정" else "Revised"
  | Activity.Absorbed -> if ko then "◇ 흡수" else "Absorbed"
  | Activity.Retracted -> if ko then "× 삭제" else "Retracted"
  | Activity.Removed -> if ko then "− 제외" else "Removed"
  | Activity.Invalidated -> if ko then "! 무효화" else "Invalidated"
  | Activity.Relation_unavailable -> if ko then "? 관계 보고 안 됨" else "? Relation not reported"

let hex_of_rgb rgb =
  let module Palette = Masc_tui_terminal_palette in
  Printf.sprintf "#%02x%02x%02x"
    (Palette.red rgb) (Palette.green rgb) (Palette.blue rgb)

let fact_claim_text ~ko (chart : t) (fact : Activity.fact) =
  let observed = List.find_opt (fun (known : Activity.fact) -> known.memory_id = fact.memory_id) chart.facts in
  match Option.bind observed (fun (known : Activity.fact) -> known.claim) with
  | Some claim when String.trim claim <> "" -> claim
  | Some _ | None ->
      if ko then "? 본문 보고 안 됨" else "? Claim not reported"

let fact_status ~ko (chart : t) (fact : Activity.fact) =
  let touches =
    List.filter_map (fun (event : Activity.event) ->
      let in_after = List.exists (fun (f : Activity.fact) -> f.memory_id = fact.memory_id) event.after in
      let in_before = List.exists (fun (f : Activity.fact) -> f.memory_id = fact.memory_id) event.before in
      if in_after then Some (`After event)
      else if in_before then Some (`Before event)
      else None)
      chart.events in
  let last_touch = List.fold_left (fun _ x -> Some x) None touches in
  match fact.claim, last_touch with
  | None, _ -> ("unconfirmed", if ko then "본문 보고 안 됨" else "Claim not reported")
  | Some _, (Some (`After event | `Before event)) when event.kind = Activity.Relation_unavailable ->
      ("unconfirmed", if ko then "관계 보고 안 됨" else "Relation not reported")
  | Some _, Some (`After _) ->
      ("retained", if ko then "유지됨" else "Retained")
  | Some _, Some (`Before event) ->
      let badge = match event.kind with
        | Activity.Retracted -> if ko then "삭제됨" else "Retracted"
        | Activity.Removed -> if ko then "제외됨" else "Removed"
        | Activity.Invalidated -> if ko then "무효화" else "Invalidated"
        | Activity.Created | Reobserved | Revised | Absorbed | Relation_unavailable ->
            if ko then "이전 기억" else "Prior" in
      ("consumed", badge)
  | Some _, None ->
      ("unconfirmed", if ko then "변화 보고 안 됨" else "Change not reported")

let event_tone_name = function
  | Activity.Created -> "ok"
  | Activity.Relation_unavailable -> "warn"
  | Activity.Retracted | Activity.Removed | Activity.Invalidated -> "bad"
  | Activity.Reobserved | Activity.Revised | Activity.Absorbed -> "info"

let successor_count_text (event : Activity.event) =
  match event.kind with
  | Activity.Relation_unavailable -> "?"
  | Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated ->
      string_of_int (List.length event.after)

let transition_svg ~ko ~now ~palette (chart : t) =
  let module Palette = Masc_tui_terminal_palette in
  let module Layout = Masc_tui_message_layout in
  let text korean english = if ko then korean else english in
  let xml value =
    let buffer = Buffer.create (String.length value) in
    String.iter (function
      | '&' -> Buffer.add_string buffer "&amp;"
      | '<' -> Buffer.add_string buffer "&lt;"
      | '>' -> Buffer.add_string buffer "&gt;"
      | '"' -> Buffer.add_string buffer "&quot;"
      | '\'' -> Buffer.add_string buffer "&apos;"
      | c -> Buffer.add_char buffer c)
      (Masc.Tui_terminal_text.sanitize_terminal_text value);
    Buffer.contents buffer in
  let foreground = Palette.foreground palette and background = Palette.background palette in
  let ink = hex_of_rgb foreground and page = hex_of_rgb background in
  let accent slot fallback = hex_of_rgb (Option.value (Palette.ansi palette slot) ~default:fallback) in
  let before_accent = accent 14 (Palette.make_rgb ~red:96 ~green:182 ~blue:212)
  and after_accent = accent 10 (Palette.make_rgb ~red:124 ~green:190 ~blue:160)
  and warn_accent = accent 11 (Palette.make_rgb ~red:234 ~green:179 ~blue:8) in
  let panel = page in
  let event = chart.selected in
  let successor_count = successor_count_text event in
  let card_line_height = 22 in
  let card_gap = 18 in
  let prepare_cards facts =
    List.mapi (fun i (fact : Activity.fact) ->
      let lines = wrap_full_lines ~max_cells:36 (fact_claim_text ~ko chart fact) in
      let height = max 108 (56 + List.length lines * card_line_height + 16) in
      (i, fact, lines, height)) facts in
  let before_cards = prepare_cards event.before in
  let after_cards = prepare_cards event.after in
  let empty_height = 148 in
  let col_height cards =
    match cards with
    | [] -> empty_height
    | _ :: _ ->
        let sum = List.fold_left (fun acc (_, _, _, h) -> acc + h) 0 cards in
        sum + card_gap * (List.length cards - 1) in
  let reason_lines = match event.reason with
    | Some r when String.trim r <> "" -> wrap_full_lines ~max_cells:24 (String.trim r)
    | Some _ | None -> [] in
  let center_main_height = 148 in
  let reason_box_height =
    if reason_lines = [] then 0 else 22 + List.length reason_lines * 20 in
  let center_col_height =
    if reason_lines = [] then center_main_height
    else center_main_height + 14 + reason_box_height in
  let before_col_h = col_height before_cards in
  let after_col_h = col_height after_cards in
  let body_height = max 220 (max center_col_height (max before_col_h after_col_h)) in
  let body_top = 140 in
  let center_top = body_top + (body_height - center_col_height) / 2 in
  let center_mid_y = center_top + center_main_height / 2 in
  let notes_wrapped =
    dedup_strings chart.notes
    |> List.concat_map (fun note -> wrap_full_lines ~max_cells:106 ("! " ^ note)) in
  let notes_height =
    if notes_wrapped = [] then 0 else 24 + List.length notes_wrapped * 20 + 18 in
  let footer_block_height = 86 in
  let height = body_top + body_height + 24 + notes_height + footer_block_height in
  let buffer = Buffer.create 4096 in
  let add format = Printf.bprintf buffer format in
  add "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1240\" height=\"%d\" viewBox=\"0 0 1240 %d\">\n" height height;
  add "<title>%s</title>\n" (xml (text "선택한 기억의 변화" "Selected memory change"));
  add "<rect width=\"1240\" height=\"%d\" rx=\"20\" fill=\"%s\"/>\n" height page;
  add "<defs><marker id=\"arrow\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"4\" orient=\"auto\"><path d=\"M0 1 L7 4 L0 7\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"/></marker></defs>\n" ink;
  add "<g font-family=\"Menlo,monospace\" fill=\"%s\">\n" ink;
  let line ~x ~y ~size ?(weight="400") ?color value =
    let fill_attr = match color with
      | Some c -> Printf.sprintf " fill=\"%s\"" c
      | None -> "" in
    add "<text x=\"%d\" y=\"%d\" font-size=\"%d\" font-weight=\"%s\"%s>%s</text>\n"
      x y size weight fill_attr (xml value) in
  line ~x:32 ~y:43 ~size:26 ~weight:"700" (text "기억의 변화" "Memory change");
  line ~x:32 ~y:73 ~size:14
    (Printf.sprintf "r%d  ·  %s" event.revision
      (Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now event.recorded_at));
  line ~x:32 ~y:118 ~size:16 ~weight:"700"
    (Printf.sprintf "%s  %02d" (text "이전 기억" "Before") (List.length event.before));
  line ~x:504 ~y:118 ~size:16 ~weight:"700" (text "선택한 변화" "Selected change");
  line ~x:824 ~y:118 ~size:16 ~weight:"700"
    (Printf.sprintf "%s  %s" (text "이후 기억" "After") successor_count);
  let dash = match event.kind with
    | Activity.Relation_unavailable -> " stroke-dasharray=\"6 5\""
    | Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated -> "" in
  let curve ~x1 ~y1 ~x2 ~y2 =
    let middle = (x1 + x2) / 2 in
    add "<path d=\"M%d %d C%d %d %d %d %d %d\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"%s marker-end=\"url(#arrow)\"/>\n"
      x1 y1 middle y1 middle y2 x2 y2 ink dash in
  let layout_cards total_h cards =
    let start_y = body_top + (body_height - total_h) / 2 in
    let rec loop y = function
      | [] -> []
      | (i, fact, lines, h) :: rest -> (i, fact, lines, y, h) :: loop (y + h + card_gap) rest in
    loop start_y cards in
  let before_placed = layout_cards before_col_h before_cards in
  let after_placed = layout_cards after_col_h after_cards in
  List.iter (fun (_, _, _, y, h) ->
    curve ~x1:416 ~y1:(y + h / 2) ~x2:500 ~y2:center_mid_y) before_placed;
  List.iter (fun (_, _, _, y, h) ->
    curve ~x1:740 ~y1:center_mid_y ~x2:824 ~y2:(y + h / 2)) after_placed;
  let draw_cards ~x ~accent placed =
    List.iter (fun (i, (fact : Activity.fact), lines, y, height) ->
      add "<rect x=\"%d\" y=\"%d\" width=\"384\" height=\"%d\" rx=\"14\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\"/>\n"
        x y height panel accent;
      add "<rect x=\"%d\" y=\"%d\" width=\"3\" height=\"%d\" rx=\"1.5\" fill=\"%s\"/>\n"
        (x + 1) (y + 14) (height - 28) accent;
      line ~x:(x + 16) ~y:(y + 26) ~size:12 ~weight:"700"
        (Printf.sprintf "#%02d · %s" (i + 1) (Layout.fit_width fact.memory_id 42));
      add "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"%s\" stroke-opacity=\"0.25\"/>\n"
        (x + 14) (y + 36) (x + 370) (y + 36) ink;
      List.iteri (fun row value ->
        line ~x:(x + 16) ~y:(y + 58 + row * card_line_height) ~size:15 value) lines)
      placed in
  draw_cards ~x:32 ~accent:before_accent before_placed;
  draw_cards ~x:824 ~accent:after_accent after_placed;
  let empty ~x value =
    let ey = body_top + (body_height - empty_height) / 2 in
    add "<rect x=\"%d\" y=\"%d\" width=\"384\" height=\"%d\" rx=\"14\" fill=\"none\" stroke=\"%s\" stroke-dasharray=\"4 5\"/>\n"
      x ey empty_height ink;
    let lines = wrap_full_lines ~max_cells:34 value in
    let top_pad = max 34 ((empty_height - List.length lines * 22) / 2 + 14) in
    List.iteri (fun row line_text ->
      line ~x:(x + 18) ~y:(ey + top_pad + row * 22) ~size:15 line_text) lines in
  (match before_placed with
   | [] -> empty ~x:32 (text "이전 본문이 기록되지 않았습니다" "No prior claim in this record")
   | _ :: _ -> ());
  (match after_placed, event.kind with
   | [], Activity.Relation_unavailable -> empty ~x:824 (text "? 후속 관계 보고 안 됨" "? Successor relation not reported")
   | [], (Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated) ->
       empty ~x:824 (text "후속 기억이 없는 변화입니다" "No successor in this change")
   | _ :: _, _ -> ());
  add "<rect x=\"500\" y=\"%d\" width=\"240\" height=\"%d\" rx=\"24\" fill=\"%s\" stroke=\"%s\" stroke-width=\"2\"/>\n"
    center_top center_main_height panel ink;
  List.iteri (fun row value ->
    line ~x:522 ~y:(center_top + 42 + row * 23) ~size:18 ~weight:"700" value)
    (wrap_full_lines ~max_cells:18 (kind_label ~ko event.kind));
  line ~x:522 ~y:(center_top + 100) ~size:26 ~weight:"700"
    (Printf.sprintf "%d → %s" (List.length event.before) successor_count);
  line ~x:522 ~y:(center_top + 126) ~size:13 (Printf.sprintf "r%d" event.revision);
  if reason_lines <> [] then begin
    let ry = center_top + center_main_height + 14 in
    add "<rect x=\"500\" y=\"%d\" width=\"240\" height=\"%d\" rx=\"12\" fill=\"%s\" stroke=\"%s\" stroke-opacity=\"0.45\" stroke-width=\"1.2\"/>\n"
      ry reason_box_height panel ink;
    List.iteri (fun row rline ->
      line ~x:514 ~y:(ry + 22 + row * 20) ~size:13 rline) reason_lines
  end;
  if notes_wrapped <> [] then begin
    let ny = body_top + body_height + 20 in
    let nh = notes_height - 14 in
    add "<rect x=\"32\" y=\"%d\" width=\"1176\" height=\"%d\" rx=\"10\" fill=\"none\" stroke=\"%s\" stroke-dasharray=\"5 3\" stroke-width=\"1.2\"/>\n"
      ny nh warn_accent;
    List.iteri (fun idx note_line ->
      line ~x:48 ~y:(ny + 24 + idx * 20) ~size:13 ~color:warn_accent note_line)
      notes_wrapped
  end;
  let footer = height - 62 in
  add "<path d=\"M32 %d H1208\" stroke=\"%s\" stroke-opacity=\"0.35\"/>\n" (footer - 20) ink;
  line ~x:32 ~y:footer ~size:13
    (Printf.sprintf (if ko then "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건" else "Observed window: latest %d / up to %d entries · %d connected changes")
      chart.journal_lines chart.limit (List.length chart.events));
  line ~x:32 ~y:(footer + 25) ~size:13
    (text "원문 전체 · Esc 목록으로 · 목록에서 Enter 원문 / Ctrl-O 연결 트리"
       "Full claims · Esc back · From the list: Enter full text / Ctrl-O connected tree");
  add "</g></svg>\n";
  Buffer.contents buffer

let palette_json = function
  | None -> `Null
  | Some palette ->
      let module Palette = Masc_tui_terminal_palette in
      let slot_hex n fallback =
        match Palette.ansi palette n with
        | Some rgb -> hex_of_rgb rgb
        | None -> fallback in
      `Assoc [
        "ok", `String (slot_hex 10 "#4ade80");
        "info", `String (slot_hex 12 "#60a5fa");
        "warn", `String (slot_hex 11 "#fbbf24");
        "bad", `String (slot_hex 9 "#f87171");
        "cyan", `String (slot_hex 14 "#22d3ee");
      ]

let lineage_graph ~ko ~now ?palette ~keeper_name (chart : t) =
  let text korean english = if ko then korean else english in
  let facts = chart.facts in
  let index = Hashtbl.create (List.length facts) in
  let fact_nodes =
    List.mapi (fun i (fact : Activity.fact) ->
      Hashtbl.replace index fact.memory_id i;
      let status, badge = fact_status ~ko chart fact in
      let lines = wrap_full_lines ~max_cells:46 (fact_claim_text ~ko chart fact) in
      `Assoc [
        "id", `String (Printf.sprintf "F%d" i);
        "kind", `String "fact";
        "tag", `String (Printf.sprintf "F%d" (i + 1));
        "memoryId", `String fact.memory_id;
        "status", `String status;
        "badge", `String badge;
        "lines", `List (List.map (fun l -> `String l) lines);
      ]) facts in
  let event_nodes_and_edges =
    List.mapi (fun i (event : Activity.event) ->
      let eid = Printf.sprintf "E%d" i in
      let is_selected = String.equal event.identity chart.selected.identity in
      let timestamp = Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now event.recorded_at in
      let reason_lines = match event.reason with
        | Some r when String.trim r <> "" -> wrap_full_lines ~max_cells:42 (String.trim r)
        | Some _ | None -> [] in
      let counts = Printf.sprintf "%d → %s" (List.length event.before) (successor_count_text event) in
      let node = `Assoc [
        "id", `String eid;
        "kind", `String "event";
        "tag", `String (kind_label ~ko event.kind);
        "tone", `String (event_tone_name event.kind);
        "selected", `Bool is_selected;
        "selectedLabel", `String (text "★ 선택됨" "★ Selected");
        "counts", `String counts;
        "revision", `String (Printf.sprintf "r%d" event.revision);
        "timestamp", `String timestamp;
        "reasonLines", `List (List.map (fun l -> `String l) reason_lines);
      ] in
      let is_unconfirmed = (event.kind = Activity.Relation_unavailable) in
      let before_edges =
        List.filter_map (fun (fact : Activity.fact) ->
          Hashtbl.find_opt index fact.memory_id |> Option.map (fun fi ->
            `Assoc [
              "from", `String (Printf.sprintf "F%d" fi);
              "to", `String eid;
              "role", `String (if is_unconfirmed then "unconfirmed" else "input");
              "dashed", `Bool is_unconfirmed;
            ])) event.before in
      let after_edges =
        List.filter_map (fun (fact : Activity.fact) ->
          Hashtbl.find_opt index fact.memory_id |> Option.map (fun fi ->
            `Assoc [
              "from", `String eid;
              "to", `String (Printf.sprintf "F%d" fi);
              "role", `String (if is_unconfirmed then "unconfirmed" else "output");
              "dashed", `Bool is_unconfirmed;
            ])) event.after in
      (node, before_edges @ after_edges)) chart.events in
  let event_nodes = List.map fst event_nodes_and_edges in
  let edges = List.concat_map snd event_nodes_and_edges in
  let wrapped_notes =
    dedup_strings chart.notes
    |> List.concat_map (fun note -> wrap_full_lines ~max_cells:84 note) in
  let subtitle =
    Printf.sprintf
      (if ko then "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건 · 사실 %d건"
       else "Observed window: latest %d / up to %d entries · %d events · %d facts")
      chart.journal_lines chart.limit (List.length chart.events) (List.length chart.facts) in
  let payload = `Assoc [
    "title", `String ((text "기억 형성 · " "Memory formation · ") ^ keeper_name);
    "subtitle", `String subtitle;
    "palette", palette_json palette;
    "legend", `Assoc [
      "retained", `String (text "유지됨" "Retained");
      "consumed", `String (text "이전 기억" "Prior");
      "unconfirmed", `String (text "보고 안 됨" "Not reported");
      "solid", `String (text "확인된 전이" "Confirmed transition");
      "dashed", `String (text "관계 보고 안 됨" "Relation not reported");
      "footer", `String (text "+/- 확대·축소 · 방향키/hjkl 이동 · 0 맞춤 · Esc 목록으로"
                           "+/- zoom · arrows/hjkl pan · 0 fit · Esc back");
    ];
    "notes", `List (List.map (fun n -> `String n) wrapped_notes);
    "nodes", `List (fact_nodes @ event_nodes);
    "edges", `List edges;
  ] in
  Yojson.Safe.to_string payload

let mermaid ~ko ~now (chart : t) =
  let buffer = Buffer.create 2048 in
  let add format = Printf.bprintf buffer format in
  add "flowchart TD\n";
  add "classDef scope fill:#1e293b,stroke:#475569,color:#cbd5e1\n";
  add "classDef note fill:#422006,stroke:#f59e0b,color:#fef3c7\n";
  add "classDef retained fill:#052e16,stroke:#22c55e,color:#dcfce7\n";
  add "classDef prior fill:#082f49,stroke:#38bdf8,color:#e0f2fe\n";
  add "classDef unconfirmed fill:#451a03,stroke:#f59e0b,color:#fef3c7,stroke-dasharray: 5 4\n";
  add "classDef evt fill:#1e1b4b,stroke:#818cf8,color:#e0e7ff\n";
  add "classDef selected fill:#172554,stroke:#22d3ee,color:#ecfeff,stroke-width:2.5px\n";
  let scope = Printf.sprintf
    (if ko then "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건"
     else "Observed window: latest %d / up to %d entries · %d events")
    chart.journal_lines chart.limit (List.length chart.events) in
  add "Scope[\"%s\"]:::scope\n" (escape_mermaid scope);
  dedup_strings chart.notes
  |> List.iteri (fun i note ->
      add "Note%d[\"! %s\"]:::note\n" i (mermaid_label ~max_cells:60 note));
  let facts = chart.facts in
  let index = Hashtbl.create (List.length facts) in
  List.iteri (fun i (fact : Activity.fact) ->
    Hashtbl.replace index fact.memory_id i;
    let status, badge = fact_status ~ko chart fact in
    let cls = match status with
      | "retained" -> "retained"
      | "consumed" -> "prior"
      | _ -> "unconfirmed" in
    let header = Printf.sprintf "[F%d · %s · %s]" (i + 1) badge fact.memory_id in
    let body = fact_claim_text ~ko chart fact in
    add "F%d(\"%s<br/>%s\"):::%s\n" i (escape_mermaid header)
      (mermaid_label ~max_cells:46 body) cls) facts;
  let edge_idx = ref 0 in
  let dotted_edges = ref [] in
  List.iteri (fun i (event : Activity.event) ->
    let selected = if event.identity = chart.selected.identity then "★ " else "" in
    let header = Printf.sprintf "%s%s · r%d · %s"
        selected (kind_label ~ko event.kind) event.revision
        (Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now event.recorded_at) in
    let reason_part = match event.reason with
      | Some r when String.trim r <> "" -> "<br/>" ^ mermaid_label ~max_cells:42 (String.trim r)
      | Some _ | None -> "" in
    let cls = if event.identity = chart.selected.identity then "selected" else "evt" in
    add "E%d[\"%s%s\"]:::%s\n" i (escape_mermaid header) reason_part cls;
    let is_unconfirmed = (event.kind = Activity.Relation_unavailable) in
    let arrow = if is_unconfirmed then "-.->" else "-->" in
    let emit_edge src dst =
      add "%s %s %s\n" src arrow dst;
      if is_unconfirmed then dotted_edges := !edge_idx :: !dotted_edges;
      incr edge_idx in
    List.iter (fun (fact : Activity.fact) ->
      Option.iter (fun fi -> emit_edge (Printf.sprintf "F%d" fi) (Printf.sprintf "E%d" i))
        (Hashtbl.find_opt index fact.memory_id)) event.before;
    List.iter (fun (fact : Activity.fact) ->
      Option.iter (fun fi -> emit_edge (Printf.sprintf "E%d" i) (Printf.sprintf "F%d" fi))
        (Hashtbl.find_opt index fact.memory_id)) event.after) chart.events;
  List.iter (fun idx -> add "linkStyle %d stroke:#f59e0b,stroke-dasharray: 5 4\n" idx)
    (List.rev !dotted_edges);
  Buffer.contents buffer

let transition_mermaid ~ko ~now (chart : t) =
  let ids = identities chart.selected in
  mermaid ~ko ~now {chart with events=[chart.selected];
    facts=List.filter (fun (fact : Activity.fact) -> Ids.mem fact.memory_id ids) chart.facts}
