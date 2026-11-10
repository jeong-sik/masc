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

(* Labels are data in quoted Mermaid nodes. Entity escaping prevents a claim
   containing quote/bracket/markup syntax from declaring nodes or edges. *)
let label text =
  let text = Masc_tui_message_layout.truncate_middle 48 (Masc.Tui_terminal_text.sanitize_terminal_text text) in
  let buffer = Buffer.create (String.length text) in
  String.iter (function
    | '#' -> Buffer.add_string buffer "#35;"
    | '&' -> Buffer.add_string buffer "#38;"
    | '"' -> Buffer.add_string buffer "#quot;"
    | '`' -> Buffer.add_string buffer "#96;"
    | '<' -> Buffer.add_string buffer "#60;"
    | '>' -> Buffer.add_string buffer "#62;"
    | c -> Buffer.add_char buffer c) text;
  Buffer.contents buffer

let kind_label ~ko = function
  | Activity.Created -> if ko then "＋ 생성" else "+ Created"
  | Activity.Reobserved -> if ko then "↻ 재관측" else "Reobserved"
  | Activity.Revised -> if ko then "↗ 수정" else "Revised"
  | Activity.Absorbed -> if ko then "◇ 흡수" else "Absorbed"
  | Activity.Retracted -> if ko then "× 삭제" else "Retracted"
  | Activity.Removed -> if ko then "− 제외" else "Removed"
  | Activity.Invalidated -> if ko then "! 무효화" else "Invalidated"
  | Activity.Relation_unavailable -> if ko then "? 관계 미확인" else "? Unresolved relation"

let transition_svg ~ko ~palette (chart : t) =
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
  let hex rgb = Printf.sprintf "#%02x%02x%02x"
      (Palette.red rgb) (Palette.green rgb) (Palette.blue rgb) in
  let foreground = Palette.foreground palette and background = Palette.background palette in
  let ink = hex foreground and page = hex background in
  (* Role accents are decorative; labels keep the observed foreground. *)
  let accent slot fallback = hex (Option.value (Palette.ansi palette slot) ~default:fallback) in
  let before_accent = accent 14 (Palette.make_rgb ~red:96 ~green:182 ~blue:212)
  and after_accent = accent 10 (Palette.make_rgb ~red:124 ~green:190 ~blue:160) in
  let panel = page in
  let event = chart.selected in
  let successor_count = match event.kind with
    | Activity.Relation_unavailable -> "?"
    | Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated ->
        string_of_int (List.length event.after) in
  let rows = max 2 (max (List.length event.before) (List.length event.after)) in
  let row_height = 184 in
  let body_height = rows * row_height in
  let height = 140 + body_height + 112 in
  let center_y = 140 + (body_height - 20) / 2 in
  let buffer = Buffer.create 4096 in
  let add format = Printf.bprintf buffer format in
  add "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1240\" height=\"%d\" viewBox=\"0 0 1240 %d\">\n" height height;
  add "<title>%s</title>\n" (xml (text "선택한 기억의 변화" "Selected memory change"));
  add "<rect width=\"1240\" height=\"%d\" rx=\"20\" fill=\"%s\"/>\n" height page;
  add "<defs><marker id=\"arrow\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"4\" orient=\"auto\"><path d=\"M0 1 L7 4 L0 7\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"/></marker></defs>\n" ink;
  add "<g font-family=\"Menlo,monospace\" fill=\"%s\">\n" ink;
  let line ~x ~y ~size ?(weight="400") value =
    add "<text x=\"%d\" y=\"%d\" font-size=\"%d\" font-weight=\"%s\">%s</text>\n"
      x y size weight (xml value) in
  line ~x:32 ~y:43 ~size:26 ~weight:"700" (text "기억의 변화" "Memory change");
  let clock = Unix.gmtime event.recorded_at in
  line ~x:32 ~y:73 ~size:14
    (Printf.sprintf "r%d  ·  %04d-%02d-%02d %02d:%02d UTC"
      event.revision (clock.tm_year + 1900) (clock.tm_mon + 1) clock.tm_mday clock.tm_hour clock.tm_min);
  line ~x:32 ~y:118 ~size:16 ~weight:"700"
    (Printf.sprintf "%s  %02d" (text "이전 기억" "Before") (List.length event.before));
  line ~x:518 ~y:118 ~size:16 ~weight:"700" (text "선택한 변화" "Selected change");
  line ~x:824 ~y:118 ~size:16 ~weight:"700"
    (Printf.sprintf "%s  %s" (text "이후 기억" "After") successor_count);
  let dash = match event.kind with
    | Activity.Relation_unavailable -> " stroke-dasharray=\"6 5\""
    | Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated -> "" in
  let curve ~x1 ~y1 ~x2 ~y2 =
    let middle = (x1 + x2) / 2 in
    add "<path d=\"M%d %d C%d %d %d %d %d %d\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"%s marker-end=\"url(#arrow)\"/>\n"
      x1 y1 middle y1 middle y2 x2 y2 ink dash in
  let card_height count = body_height / count - 20 in
  let card_y count i = 140 + i * body_height / count in
  let card_center count i = card_y count i + card_height count / 2 in
  List.iteri (fun i _ -> curve ~x1:416 ~y1:(card_center (List.length event.before) i)
    ~x2:510 ~y2:center_y) event.before;
  List.iteri (fun i _ -> curve ~x1:730 ~y1:center_y
    ~x2:824 ~y2:(card_center (List.length event.after) i)) event.after;
  let excerpt ~max_lines value =
    let lines = Layout.wrap_words ~max_cells:36
        (Masc.Tui_terminal_text.sanitize_terminal_text value) in
    let visible = List.take max_lines lines in
    if List.length lines <= max_lines then visible else
      List.mapi (fun i value -> if i = max_lines - 1 then Layout.fit_width value 34 ^ " …" else value) visible in
  let body (fact : Activity.fact) =
    let observed = List.find_opt (fun (known : Activity.fact) -> known.memory_id = fact.memory_id) chart.facts in
    match Option.bind observed (fun (known : Activity.fact) -> known.claim) with
    | Some claim -> claim
    | None -> text "? 본문 미확인" "? Claim not observed" in
  let cards ~x ~accent facts =
    List.iteri (fun i (fact : Activity.fact) ->
      let y = card_y (List.length facts) i in
      let height = card_height (List.length facts) in
      add "<rect x=\"%d\" y=\"%d\" width=\"384\" height=\"%d\" rx=\"14\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\"/>\n" x y height panel accent;
      add "<rect x=\"%d\" y=\"%d\" width=\"3\" height=\"26\" rx=\"1.5\" fill=\"%s\"/>\n" (x + 1) (y + 20) accent;
      line ~x:(x + 18) ~y:(y + 26) ~size:12 (Printf.sprintf "%02d" (i + 1));
      List.iteri (fun row value -> line ~x:(x + 18) ~y:(y + 57 + row * 24) ~size:16 value)
        (excerpt ~max_lines:((height - 68) / 24) (body fact))) facts in
  cards ~x:32 ~accent:before_accent event.before;
  cards ~x:824 ~accent:after_accent event.after;
  let empty ~x value =
    add "<rect x=\"%d\" y=\"%d\" width=\"384\" height=\"164\" rx=\"14\" fill=\"none\" stroke=\"%s\" stroke-dasharray=\"4 5\"/>\n" x (center_y - 82) ink;
    List.iteri (fun row value -> line ~x:(x + 18) ~y:(center_y - 10 + row * 24) ~size:16 value)
      (excerpt ~max_lines:4 value) in
  (match event.before with [] -> empty ~x:32 (text "이전 본문이 기록되지 않았습니다" "No prior claim in this record") | _ :: _ -> ());
  (match event.after, event.kind with
   | [], Activity.Relation_unavailable -> empty ~x:824 (text "? 후속 관계 미확인" "? Successor relation unconfirmed")
   | [], (Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated) ->
       empty ~x:824 (Option.value event.reason ~default:(text "후속 기억이 없는 변화입니다" "No successor in this change"))
   | _ :: _, (Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated | Relation_unavailable) -> ());
  add "<rect x=\"510\" y=\"%d\" width=\"220\" height=\"136\" rx=\"24\" fill=\"%s\" stroke=\"%s\" stroke-width=\"2\"/>\n" (center_y - 68) panel ink;
  List.iteri (fun row value -> line ~x:534 ~y:(center_y - 30 + row * 23) ~size:18 ~weight:"700" value)
    (Layout.wrap_words ~max_cells:18 (kind_label ~ko event.kind));
  line ~x:534 ~y:(center_y + 28) ~size:26 ~weight:"700"
    (Printf.sprintf "%d → %s" (List.length event.before) successor_count);
  line ~x:534 ~y:(center_y + 53) ~size:13 (Printf.sprintf "r%d" event.revision);
  let footer = height - 72 in
  add "<path d=\"M32 %d H1208\" stroke=\"%s\" stroke-opacity=\"0.35\"/>\n" (footer - 20) ink;
  line ~x:32 ~y:footer ~size:13
    (Printf.sprintf (text "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건" "Observed window: latest %d / up to %d entries · %d connected changes")
      chart.journal_lines chart.limit (List.length chart.events));
  line ~x:32 ~y:(footer + 25) ~size:13
    (if chart.notes = [] then text "원문 일부 · Esc 목록으로 · 목록에서 Enter 원문 / Ctrl-O 연결 트리"
        "Claim excerpts · Esc back · From the list: Enter full text / Ctrl-O connected tree"
     else Printf.sprintf (text "! 부분 이력 %d건 · Esc 목록으로 · 목록에서 Enter 원문과 관측 안내" "! %d history notes · Esc back · From the list: Enter full text and observation notes") (List.length chart.notes));
  add "</g></svg>\n";
  Buffer.contents buffer

let mermaid ~ko (chart : t) =
  let buffer = Buffer.create 1024 in
  let add format = Printf.bprintf buffer format in
  add "flowchart TD\n";
  let scope = Printf.sprintf
    (if ko then "관측 범위: 최근 %d / 최대 %d회" else "Observed window: latest %d / up to %d entries")
    chart.journal_lines chart.limit in
  add "Scope[\"%s\"]\n" scope;
  List.iteri (fun i note -> add "Note%d[\"! %s\"]\n" i (label note)) chart.notes;
  let facts = chart.facts in
  let index = Hashtbl.create (List.length facts) in
  List.iteri (fun i (fact : Activity.fact) ->
    Hashtbl.add index fact.memory_id i;
    let claim = match fact.claim with Some claim -> claim
      | None -> (if ko then "? 본문 미확인 · " else "? Claim unavailable · ") ^ fact.memory_id in
    add "F%d(\"%s\")\n" i (label claim)) facts;
  List.iteri (fun i (event : Activity.event) ->
    let selected = if event.identity = chart.selected.identity then "★ " else "" in
    let clock = Unix.gmtime event.recorded_at in
    add "E%d[\"%s%s · r%d · %02d-%02d %02d:%02d UTC\"]\n" i selected
      (kind_label ~ko event.kind) event.revision (clock.tm_mon + 1) clock.tm_mday clock.tm_hour clock.tm_min;
    let arrow = match event.kind with Activity.Relation_unavailable -> "-.->"
      | Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated -> "-->" in
    List.iter (fun (fact : Activity.fact) -> add "F%d %s E%d\n" (Hashtbl.find index fact.memory_id) arrow i) event.before;
    List.iter (fun (fact : Activity.fact) -> add "E%d %s F%d\n" i arrow (Hashtbl.find index fact.memory_id)) event.after) chart.events;
  Buffer.contents buffer

let transition_mermaid ~ko (chart : t) =
  let ids = identities chart.selected in
  mermaid ~ko {chart with events=[chart.selected];
    facts=List.filter (fun (fact : Activity.fact) -> Ids.mem fact.memory_id ids) chart.facts}
