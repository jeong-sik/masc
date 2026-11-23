module Grapheme = Masc_tui_term.Grapheme
module Palette = Masc_tui_term.Palette
module Ids = Set.Make (String)
module Observed = Map.Make (String)

type fact = {
  memory_id : string;
  claim : string option;
}

type event_kind =
  | Created
  | Reobserved
  | Revised
  | Absorbed
  | Retracted
  | Removed
  | Invalidated
  | Relation_unavailable

type event = {
  identity : string;
  recorded_at : float;
  revision : int;
  kind : event_kind;
  before : fact list;
  after : fact list;
  reason : string option;
}

type activity = {
  events : event list;
  limit : int;
  journal_lines : int;
  notes : string list;
}

type chart = {
  selected : event;
  events : event list;
  facts : fact list;
  journal_lines : int;
  limit : int;
  notes : string list;
}

type t = chart

let equal_event_kind a b =
  match a, b with
  | Created, Created
  | Reobserved, Reobserved
  | Revised, Revised
  | Absorbed, Absorbed
  | Retracted, Retracted
  | Removed, Removed
  | Invalidated, Invalidated
  | Relation_unavailable, Relation_unavailable ->
      true
  | ( Created,
      ( Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated
      | Relation_unavailable ) )
  | ( Reobserved,
      ( Created | Revised | Absorbed | Retracted | Removed | Invalidated
      | Relation_unavailable ) )
  | ( Revised,
      ( Created | Reobserved | Absorbed | Retracted | Removed | Invalidated
      | Relation_unavailable ) )
  | ( Absorbed,
      ( Created | Reobserved | Revised | Retracted | Removed | Invalidated
      | Relation_unavailable ) )
  | ( Retracted,
      ( Created | Reobserved | Revised | Absorbed | Removed | Invalidated
      | Relation_unavailable ) )
  | ( Removed,
      ( Created | Reobserved | Revised | Absorbed | Retracted | Invalidated
      | Relation_unavailable ) )
  | ( Invalidated,
      ( Created | Reobserved | Revised | Absorbed | Retracted | Removed
      | Relation_unavailable ) )
  | ( Relation_unavailable,
      ( Created | Reobserved | Revised | Absorbed | Retracted | Removed
      | Invalidated ) ) ->
      false

let identities (ev : event) =
  List.fold_left
    (fun ids (f : fact) -> Ids.add f.memory_id ids)
    Ids.empty (ev.before @ ev.after)

let observed_facts events =
  List.concat_map (fun (ev : event) -> ev.before @ ev.after) events
  |> List.fold_left
       (fun observed (f : fact) ->
         match Observed.find_opt f.memory_id observed with
         | Some { claim = Some _; _ } -> observed
         | None | Some { claim = None; _ } -> Observed.add f.memory_id f observed)
       Observed.empty
  |> Observed.bindings
  |> List.map snd

let select ~event_id (act : activity) =
  match
    List.find_opt (fun (ev : event) -> String.equal ev.identity event_id) act.events
  with
  | None -> None
  | Some selected ->
      let rec expand ids =
        let next =
          List.fold_left
            (fun ids ev ->
              let endpoints = identities ev in
              if Ids.disjoint ids endpoints then ids else Ids.union ids endpoints)
            ids act.events
        in
        if Ids.equal ids next then ids else expand next
      in
      let ids = expand (identities selected) in
      let events =
        List.filter
          (fun (ev : event) ->
            String.equal ev.identity event_id
            || not (Ids.disjoint ids (identities ev)))
          act.events
      in
      Some
        {
          selected;
          events;
          facts = observed_facts events;
          journal_lines = act.journal_lines;
          limit = act.limit;
          notes = act.notes;
        }

let sanitize_single_line text =
  let len = String.length text in
  let buf = Buffer.create len in
  for i = 0 to len - 1 do
    match text.[i] with
    | '\n' | '\r' | '\t' -> Buffer.add_char buf ' '
    | ch -> Buffer.add_char buf ch
  done;
  Grapheme.sanitize_controls (Buffer.contents buf)

let sanitize_multiline text =
  String.split_on_char '\n' text
  |> List.map (fun line ->
         let len = String.length line in
         let buf = Buffer.create len in
         for i = 0 to len - 1 do
           match line.[i] with
           | '\r' -> ()
           | '\t' -> Buffer.add_char buf ' '
           | ch -> Buffer.add_char buf ch
         done;
         Grapheme.sanitize_controls (Buffer.contents buf))
  |> String.concat "\n"

let dedup_notes items =
  let seen = Hashtbl.create (List.length items) in
  List.filter_map
    (fun item ->
      let clean = String.trim (sanitize_single_line item) in
      if String.equal clean "" || Hashtbl.mem seen clean then None
      else begin
        Hashtbl.add seen clean ();
        Some clean
      end)
    items

let wrap_single_line ~max_cells line =
  let limit = Int.max 1 max_cells in
  let words = String.split_on_char ' ' line in
  let rows = ref [] in
  let cur = Buffer.create (min 128 (String.length line)) in
  let cur_w = ref 0 in
  let flush () =
    if Buffer.length cur > 0 then begin
      rows := Buffer.contents cur :: !rows;
      Buffer.clear cur;
      cur_w := 0
    end
  in
  let append_long_word w =
    let clusters = Grapheme.split_clusters w in
    List.iter
      (fun (seg, seg_w) ->
        if !cur_w > 0 && !cur_w + seg_w > limit then flush ();
        Buffer.add_string cur seg;
        cur_w := !cur_w + seg_w;
        if !cur_w >= limit then flush ())
      clusters
  in
  List.iter
    (fun word ->
      if String.equal word "" then ()
      else
        let w_width = Grapheme.display_width word in
        if !cur_w = 0 then begin
          if w_width <= limit then begin
            Buffer.add_string cur word;
            cur_w := w_width
          end
          else append_long_word word
        end
        else if !cur_w + 1 + w_width <= limit then begin
          Buffer.add_char cur ' ';
          Buffer.add_string cur word;
          cur_w := !cur_w + 1 + w_width
        end
        else begin
          flush ();
          if w_width <= limit then begin
            Buffer.add_string cur word;
            cur_w := w_width
          end
          else append_long_word word
        end)
    words;
  flush ();
  match List.rev !rows with
  | [] -> [ "" ]
  | wrapped -> wrapped

let wrap_full_lines ~max_cells value =
  let sanitized = sanitize_multiline value in
  String.split_on_char '\n' sanitized
  |> List.concat_map (fun line ->
         let trimmed = String.trim line in
         if String.equal trimmed "" then [ "" ]
         else wrap_single_line ~max_cells trimmed)

(* Pure Howard Hinnant civil-from-days calendar decomposition. *)
let civil_of_unix ~tz_offset_sec ts =
  let shifted =
    Int64.add (Int64.of_float (Float.floor ts)) (Int64.of_int tz_offset_sec)
  in
  let secs_per_day = 86_400L in
  let rem = Int64.rem shifted secs_per_day in
  let day_s =
    if Int64.compare rem 0L < 0 then Int64.add rem secs_per_day else rem
  in
  let days = Int64.div (Int64.sub shifted day_s) secs_per_day in
  let z = Int64.add days 719_468L in
  let era =
    Int64.div
      (if Int64.compare z 0L >= 0 then z else Int64.sub z 146_096L)
      146_097L
  in
  let doe = Int64.to_int (Int64.sub z (Int64.mul era 146_097L)) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y_base = yoe + (Int64.to_int era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let day = doy - (((153 * mp) + 2) / 5) + 1 in
  let month = if mp < 10 then mp + 3 else mp - 9 in
  let year = if month <= 2 then y_base + 1 else y_base in
  let ds = Int64.to_int day_s in
  let hour = ds / 3600 in
  let minute = (ds mod 3600) / 60 in
  (year, month, day, hour, minute)

let format_instant ?(tz_offset_sec = 0) ~now at =
  if (not (Float.is_finite at)) || at <= 0.0 then "?"
  else
    let y, m, d, hh, mm = civil_of_unix ~tz_offset_sec at in
    if (not (Float.is_finite now)) || now <= 0.0 then
      Printf.sprintf "%04d-%02d-%02d %02d:%02d" y m d hh mm
    else
      let ny, nm, nd, _, _ = civil_of_unix ~tz_offset_sec now in
      if y = ny && m = nm && d = nd then Printf.sprintf "%02d:%02d" hh mm
      else if y = ny then Printf.sprintf "%02d-%02d %02d:%02d" m d hh mm
      else Printf.sprintf "%04d-%02d-%02d %02d:%02d" y m d hh mm

let escape_mermaid value =
  let clean = sanitize_single_line value in
  let buffer = Buffer.create (String.length clean) in
  String.iter
    (function
      | '#' -> Buffer.add_string buffer "#35;"
      | '&' -> Buffer.add_string buffer "#38;"
      | '"' -> Buffer.add_string buffer "#quot;"
      | '`' -> Buffer.add_string buffer "#96;"
      | '<' -> Buffer.add_string buffer "#60;"
      | '>' -> Buffer.add_string buffer "#62;"
      | c -> Buffer.add_char buffer c)
    clean;
  Buffer.contents buffer

let mermaid_label ~max_cells text =
  wrap_full_lines ~max_cells text
  |> List.map escape_mermaid
  |> String.concat "<br/>"

let kind_label ~ko = function
  | Created -> if ko then "＋ 생성" else "+ Created"
  | Reobserved -> if ko then "↻ 재관측" else "Reobserved"
  | Revised -> if ko then "↗ 수정" else "Revised"
  | Absorbed -> if ko then "◇ 흡수" else "Absorbed"
  | Retracted -> if ko then "× 삭제" else "Retracted"
  | Removed -> if ko then "− 제외" else "Removed"
  | Invalidated -> if ko then "! 무효화" else "Invalidated"
  | Relation_unavailable ->
      if ko then "? 관계 보고 안 됨" else "? Relation not reported"

let hex_of_rgb rgb =
  Printf.sprintf "#%02x%02x%02x" (Palette.red rgb) (Palette.green rgb)
    (Palette.blue rgb)

let fact_claim_text ~ko (chart : chart) (f : fact) =
  let observed =
    List.find_opt
      (fun (known : fact) -> String.equal known.memory_id f.memory_id)
      chart.facts
  in
  let claim_opt =
    match Option.bind observed (fun known -> known.claim) with
    | Some _ as c -> c
    | None -> f.claim
  in
  match claim_opt with
  | Some claim when not (String.equal (String.trim claim) "") -> claim
  | Some _ | None ->
      if ko then "? 본문 보고 안 됨" else "? Claim not reported"

let fact_status ~ko (chart : chart) (f : fact) =
  let touches =
    List.filter_map
      (fun (ev : event) ->
        let in_after =
          List.exists
            (fun (x : fact) -> String.equal x.memory_id f.memory_id)
            ev.after
        in
        let in_before =
          List.exists
            (fun (x : fact) -> String.equal x.memory_id f.memory_id)
            ev.before
        in
        if in_after then Some (`After ev)
        else if in_before then Some (`Before ev)
        else None)
      chart.events
  in
  let last_touch = List.fold_left (fun _ x -> Some x) None touches in
  match f.claim, last_touch with
  | None, _ ->
      ("unconfirmed", if ko then "본문 보고 안 됨" else "Claim not reported")
  | Some _, Some (`After ev | `Before ev)
    when equal_event_kind ev.kind Relation_unavailable ->
      ("unconfirmed", if ko then "관계 보고 안 됨" else "Relation not reported")
  | Some _, Some (`After _) ->
      ("retained", if ko then "유지됨" else "Retained")
  | Some _, Some (`Before ev) ->
      let badge =
        match ev.kind with
        | Retracted -> if ko then "삭제됨" else "Retracted"
        | Removed -> if ko then "제외됨" else "Removed"
        | Invalidated -> if ko then "무효화" else "Invalidated"
        | Created | Reobserved | Revised | Absorbed | Relation_unavailable ->
            if ko then "이전 기억" else "Prior"
      in
      ("consumed", badge)
  | Some _, None ->
      ("unconfirmed", if ko then "변화 보고 안 됨" else "Change not reported")

let event_tone_name = function
  | Created -> "ok"
  | Relation_unavailable -> "warn"
  | Retracted | Removed | Invalidated -> "bad"
  | Reobserved | Revised | Absorbed -> "info"

let successor_count_text (ev : event) =
  match ev.kind with
  | Relation_unavailable -> "?"
  | Created | Reobserved | Revised | Absorbed | Retracted | Removed
  | Invalidated ->
      string_of_int (List.length ev.after)

let transition_svg ?(tz_offset_sec = 0) ~ko ~now ~palette (chart : chart) =
  let text korean english = if ko then korean else english in
  let xml value =
    let clean = sanitize_single_line value in
    let buffer = Buffer.create (String.length clean) in
    String.iter
      (function
        | '&' -> Buffer.add_string buffer "&amp;"
        | '<' -> Buffer.add_string buffer "&lt;"
        | '>' -> Buffer.add_string buffer "&gt;"
        | '"' -> Buffer.add_string buffer "&quot;"
        | '\'' -> Buffer.add_string buffer "&apos;"
        | c -> Buffer.add_char buffer c)
      clean;
    Buffer.contents buffer
  in
  let foreground = Palette.foreground palette in
  let background = Palette.background palette in
  let ink = hex_of_rgb foreground in
  let page = hex_of_rgb background in
  let accent slot fallback =
    match Palette.ansi palette slot with
    | Some rgb -> hex_of_rgb rgb
    | None -> hex_of_rgb fallback
  in
  let before_accent =
    accent 14 (Palette.make_rgb ~red:96 ~green:182 ~blue:212)
  in
  let after_accent =
    accent 10 (Palette.make_rgb ~red:124 ~green:190 ~blue:160)
  in
  let warn_accent =
    accent 11 (Palette.make_rgb ~red:234 ~green:179 ~blue:8)
  in
  let panel = page in
  let ev = chart.selected in
  let successor_count = successor_count_text ev in
  let card_line_height = 22 in
  let card_gap = 18 in
  let prepare_cards facts =
    List.mapi
      (fun i (f : fact) ->
        let lines = wrap_full_lines ~max_cells:36 (fact_claim_text ~ko chart f) in
        let height = max 108 (56 + (List.length lines * card_line_height) + 16) in
        (i, f, lines, height))
      facts
  in
  let before_cards = prepare_cards ev.before in
  let after_cards = prepare_cards ev.after in
  let empty_height = 148 in
  let col_height cards =
    match cards with
    | [] -> empty_height
    | _ :: _ ->
        let sum = List.fold_left (fun acc (_, _, _, h) -> acc + h) 0 cards in
        sum + (card_gap * (List.length cards - 1))
  in
  let reason_lines =
    match ev.reason with
    | Some r when not (String.equal (String.trim r) "") ->
        wrap_full_lines ~max_cells:24 (String.trim r)
    | Some _ | None -> []
  in
  let center_main_height = 148 in
  let reason_box_height =
    if reason_lines = [] then 0 else 22 + (List.length reason_lines * 20)
  in
  let center_col_height =
    if reason_lines = [] then center_main_height
    else center_main_height + 14 + reason_box_height
  in
  let before_col_h = col_height before_cards in
  let after_col_h = col_height after_cards in
  let body_height =
    max 220 (max center_col_height (max before_col_h after_col_h))
  in
  let body_top = 140 in
  let center_top = body_top + ((body_height - center_col_height) / 2) in
  let center_mid_y = center_top + (center_main_height / 2) in
  let notes_wrapped =
    dedup_notes chart.notes
    |> List.concat_map (fun note -> wrap_full_lines ~max_cells:106 ("! " ^ note))
  in
  let notes_height =
    if notes_wrapped = [] then 0
    else 24 + (List.length notes_wrapped * 20) + 18
  in
  let footer_block_height = 86 in
  let height =
    body_top + body_height + 24 + notes_height + footer_block_height
  in
  let buffer = Buffer.create 4096 in
  let add fmt = Printf.bprintf buffer fmt in
  add
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1240\" height=\"%d\" viewBox=\"0 0 1240 %d\">\n"
    height height;
  add "<title>%s</title>\n"
    (xml (text "선택한 기억의 변화" "Selected memory change"));
  add "<rect width=\"1240\" height=\"%d\" rx=\"20\" fill=\"%s\"/>\n" height page;
  add
    "<defs><marker id=\"arrow\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"4\" orient=\"auto\"><path d=\"M0 1 L7 4 L0 7\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"/></marker></defs>\n"
    ink;
  add "<g font-family=\"Menlo,monospace\" fill=\"%s\">\n" ink;
  let line ~x ~y ~size ?(weight = "400") ?color value =
    let fill_attr =
      match color with
      | Some c -> Printf.sprintf " fill=\"%s\"" c
      | None -> ""
    in
    add "<text x=\"%d\" y=\"%d\" font-size=\"%d\" font-weight=\"%s\"%s>%s</text>\n"
      x y size weight fill_attr (xml value)
  in
  line ~x:32 ~y:43 ~size:26 ~weight:"700" (text "기억의 변화" "Memory change");
  line ~x:32 ~y:73 ~size:14
    (Printf.sprintf "r%d  ·  %s" ev.revision
       (format_instant ~tz_offset_sec ~now ev.recorded_at));
  line ~x:32 ~y:118 ~size:16 ~weight:"700"
    (Printf.sprintf "%s  %02d" (text "이전 기억" "Before") (List.length ev.before));
  line ~x:504 ~y:118 ~size:16 ~weight:"700" (text "선택한 변화" "Selected change");
  line ~x:824 ~y:118 ~size:16 ~weight:"700"
    (Printf.sprintf "%s  %s" (text "이후 기억" "After") successor_count);
  let dash =
    match ev.kind with
    | Relation_unavailable -> " stroke-dasharray=\"6 5\""
    | Created | Reobserved | Revised | Absorbed | Retracted | Removed
    | Invalidated ->
        ""
  in
  let curve ~x1 ~y1 ~x2 ~y2 =
    let middle = (x1 + x2) / 2 in
    add
      "<path d=\"M%d %d C%d %d %d %d %d %d\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"%s marker-end=\"url(#arrow)\"/>\n"
      x1 y1 middle y1 middle y2 x2 y2 ink dash
  in
  let layout_cards total_h cards =
    let start_y = body_top + ((body_height - total_h) / 2) in
    let rec loop y = function
      | [] -> []
      | (i, f, lines, h) :: rest -> (i, f, lines, y, h) :: loop (y + h + card_gap) rest
    in
    loop start_y cards
  in
  let before_placed = layout_cards before_col_h before_cards in
  let after_placed = layout_cards after_col_h after_cards in
  List.iter
    (fun (_, _, _, y, h) ->
      curve ~x1:416 ~y1:(y + (h / 2)) ~x2:500 ~y2:center_mid_y)
    before_placed;
  List.iter
    (fun (_, _, _, y, h) ->
      curve ~x1:740 ~y1:center_mid_y ~x2:824 ~y2:(y + (h / 2)))
    after_placed;
  let draw_cards ~x ~accent placed =
    List.iter
      (fun (i, (f : fact), lines, y, card_h) ->
        add
          "<rect x=\"%d\" y=\"%d\" width=\"384\" height=\"%d\" rx=\"14\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\"/>\n"
          x y card_h panel accent;
        add "<rect x=\"%d\" y=\"%d\" width=\"3\" height=\"%d\" rx=\"1.5\" fill=\"%s\"/>\n"
          (x + 1) (y + 14) (card_h - 28) accent;
        line ~x:(x + 16) ~y:(y + 26) ~size:12 ~weight:"700"
          (Printf.sprintf "#%02d · %s" (i + 1)
             (Grapheme.truncate_to_width ~max_width:42 f.memory_id));
        add
          "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"%s\" stroke-opacity=\"0.25\"/>\n"
          (x + 14) (y + 36) (x + 370) (y + 36) ink;
        List.iteri
          (fun row value ->
            line ~x:(x + 16) ~y:(y + 58 + (row * card_line_height)) ~size:15 value)
          lines)
      placed
  in
  draw_cards ~x:32 ~accent:before_accent before_placed;
  draw_cards ~x:824 ~accent:after_accent after_placed;
  let empty ~x value =
    let ey = body_top + ((body_height - empty_height) / 2) in
    add
      "<rect x=\"%d\" y=\"%d\" width=\"384\" height=\"%d\" rx=\"14\" fill=\"none\" stroke=\"%s\" stroke-dasharray=\"4 5\"/>\n"
      x ey empty_height ink;
    let lines = wrap_full_lines ~max_cells:34 value in
    let top_pad = max 34 (((empty_height - (List.length lines * 22)) / 2) + 14) in
    List.iteri
      (fun row line_text ->
        line ~x:(x + 18) ~y:(ey + top_pad + (row * 22)) ~size:15 line_text)
      lines
  in
  (match before_placed with
   | [] ->
       empty ~x:32
         (text "이전 본문이 기록되지 않았습니다" "No prior claim in this record")
   | _ :: _ -> ());
  (match after_placed, ev.kind with
   | [], Relation_unavailable ->
       empty ~x:824
         (text "? 후속 관계 보고 안 됨" "? Successor relation not reported")
   | ( [],
       ( Created | Reobserved | Revised | Absorbed | Retracted | Removed
       | Invalidated ) ) ->
       empty ~x:824 (text "후속 기억이 없는 변화입니다" "No successor in this change")
   | _ :: _, _ -> ());
  add
    "<rect x=\"500\" y=\"%d\" width=\"240\" height=\"%d\" rx=\"24\" fill=\"%s\" stroke=\"%s\" stroke-width=\"2\"/>\n"
    center_top center_main_height panel ink;
  List.iteri
    (fun row value ->
      line ~x:522 ~y:(center_top + 42 + (row * 23)) ~size:18 ~weight:"700" value)
    (wrap_full_lines ~max_cells:18 (kind_label ~ko ev.kind));
  line ~x:522 ~y:(center_top + 100) ~size:26 ~weight:"700"
    (Printf.sprintf "%d → %s" (List.length ev.before) successor_count);
  line ~x:522 ~y:(center_top + 126) ~size:13 (Printf.sprintf "r%d" ev.revision);
  if reason_lines <> [] then begin
    let ry = center_top + center_main_height + 14 in
    add
      "<rect x=\"500\" y=\"%d\" width=\"240\" height=\"%d\" rx=\"12\" fill=\"%s\" stroke=\"%s\" stroke-opacity=\"0.45\" stroke-width=\"1.2\"/>\n"
      ry reason_box_height panel ink;
    List.iteri
      (fun row rline ->
        line ~x:514 ~y:(ry + 22 + (row * 20)) ~size:13 rline)
      reason_lines
  end;
  if notes_wrapped <> [] then begin
    let ny = body_top + body_height + 20 in
    let nh = notes_height - 14 in
    add
      "<rect x=\"32\" y=\"%d\" width=\"1176\" height=\"%d\" rx=\"10\" fill=\"none\" stroke=\"%s\" stroke-dasharray=\"5 3\" stroke-width=\"1.2\"/>\n"
      ny nh warn_accent;
    List.iteri
      (fun idx note_line ->
        line ~x:48 ~y:(ny + 24 + (idx * 20)) ~size:13 ~color:warn_accent note_line)
      notes_wrapped
  end;
  let footer = height - 62 in
  add "<path d=\"M32 %d H1208\" stroke=\"%s\" stroke-opacity=\"0.35\"/>\n"
    (footer - 20) ink;
  line ~x:32 ~y:footer ~size:13
    (Printf.sprintf
       (if ko then "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건"
        else "Observed window: latest %d / up to %d entries · %d connected changes")
       chart.journal_lines chart.limit (List.length chart.events));
  line ~x:32 ~y:(footer + 25) ~size:13
    (text "원문 전체 · Esc 목록으로 · 목록에서 Enter 원문 / Ctrl-O 연결 트리"
       "Full claims · Esc back · From the list: Enter full text / Ctrl-O connected tree");
  add "</g></svg>\n";
  Buffer.contents buffer

let palette_json = function
  | None -> `Null
  | Some palette ->
      let slot_hex n fallback =
        match Palette.ansi palette n with
        | Some rgb -> hex_of_rgb rgb
        | None -> fallback
      in
      `Assoc
        [
          ("ok", `String (slot_hex 10 "#4ade80"));
          ("info", `String (slot_hex 12 "#60a5fa"));
          ("warn", `String (slot_hex 11 "#fbbf24"));
          ("bad", `String (slot_hex 9 "#f87171"));
          ("cyan", `String (slot_hex 14 "#22d3ee"));
        ]

let formation_graph_json ?(tz_offset_sec = 0) ~ko ?now ?palette
    ?(keeper_name = "") (chart : chart) =
  let now =
    match now with
    | Some ts -> ts
    | None -> chart.selected.recorded_at
  in
  let text korean english = if ko then korean else english in
  let facts = chart.facts in
  let index = Hashtbl.create (List.length facts) in
  let fact_nodes =
    List.mapi
      (fun i (f : fact) ->
        Hashtbl.replace index f.memory_id i;
        let status, badge = fact_status ~ko chart f in
        let lines = wrap_full_lines ~max_cells:46 (fact_claim_text ~ko chart f) in
        `Assoc
          [
            ("id", `String (Printf.sprintf "F%d" i));
            ("kind", `String "fact");
            ("tag", `String (Printf.sprintf "F%d" (i + 1)));
            ("memoryId", `String f.memory_id);
            ("status", `String status);
            ("badge", `String badge);
            ("lines", `List (List.map (fun l -> `String l) lines));
          ])
      facts
  in
  let event_nodes_and_edges =
    List.mapi
      (fun i (ev : event) ->
        let eid = Printf.sprintf "E%d" i in
        let is_selected = String.equal ev.identity chart.selected.identity in
        let timestamp = format_instant ~tz_offset_sec ~now ev.recorded_at in
        let reason_lines =
          match ev.reason with
          | Some r when not (String.equal (String.trim r) "") ->
              wrap_full_lines ~max_cells:42 (String.trim r)
          | Some _ | None -> []
        in
        let counts =
          Printf.sprintf "%d → %s" (List.length ev.before)
            (successor_count_text ev)
        in
        let node =
          `Assoc
            [
              ("id", `String eid);
              ("kind", `String "event");
              ("tag", `String (kind_label ~ko ev.kind));
              ("tone", `String (event_tone_name ev.kind));
              ("selected", `Bool is_selected);
              ("selectedLabel", `String (text "★ 선택됨" "★ Selected"));
              ("counts", `String counts);
              ("revision", `String (Printf.sprintf "r%d" ev.revision));
              ("timestamp", `String timestamp);
              ("reasonLines", `List (List.map (fun l -> `String l) reason_lines));
            ]
        in
        let is_unconfirmed = equal_event_kind ev.kind Relation_unavailable in
        let before_edges =
          List.filter_map
            (fun (f : fact) ->
              Hashtbl.find_opt index f.memory_id
              |> Option.map (fun fi ->
                     `Assoc
                       [
                         ("from", `String (Printf.sprintf "F%d" fi));
                         ("to", `String eid);
                         ( "role",
                           `String
                             (if is_unconfirmed then "unconfirmed" else "input") );
                         ("dashed", `Bool is_unconfirmed);
                       ]))
            ev.before
        in
        let after_edges =
          List.filter_map
            (fun (f : fact) ->
              Hashtbl.find_opt index f.memory_id
              |> Option.map (fun fi ->
                     `Assoc
                       [
                         ("from", `String eid);
                         ("to", `String (Printf.sprintf "F%d" fi));
                         ( "role",
                           `String
                             (if is_unconfirmed then "unconfirmed" else "output") );
                         ("dashed", `Bool is_unconfirmed);
                       ]))
            ev.after
        in
        (node, before_edges @ after_edges))
      chart.events
  in
  let event_nodes = List.map fst event_nodes_and_edges in
  let edges = List.concat_map snd event_nodes_and_edges in
  let wrapped_notes =
    dedup_notes chart.notes
    |> List.concat_map (fun note -> wrap_full_lines ~max_cells:84 note)
  in
  let subtitle =
    Printf.sprintf
      (if ko then "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건 · 사실 %d건"
       else "Observed window: latest %d / up to %d entries · %d events · %d facts")
      chart.journal_lines chart.limit (List.length chart.events)
      (List.length chart.facts)
  in
  let clean_keeper = String.trim (sanitize_single_line keeper_name) in
  let title =
    if String.equal clean_keeper "" then text "기억 형성" "Memory formation"
    else text "기억 형성 · " "Memory formation · " ^ clean_keeper
  in
  let payload =
    `Assoc
      [
        ("title", `String title);
        ("subtitle", `String subtitle);
        ("palette", palette_json palette);
        ( "legend",
          `Assoc
            [
              ("retained", `String (text "유지됨" "Retained"));
              ("consumed", `String (text "이전 기억" "Prior"));
              ("unconfirmed", `String (text "보고 안 됨" "Not reported"));
              ("solid", `String (text "확인된 전이" "Confirmed transition"));
              ("dashed", `String (text "관계 보고 안 됨" "Relation not reported"));
              ( "footer",
                `String
                  (text
                     "+/- 확대·축소 · 방향키/hjkl 이동 · 0 맞춤 · Esc 목록으로"
                     "+/- zoom · arrows/hjkl pan · 0 fit · Esc back") );
            ] );
        ("notes", `List (List.map (fun n -> `String n) wrapped_notes));
        ("nodes", `List (fact_nodes @ event_nodes));
        ("edges", `List edges);
      ]
  in
  Yojson.Safe.to_string payload

let mermaid ?(tz_offset_sec = 0) ~ko ?now (chart : chart) =
  let now =
    match now with
    | Some ts -> ts
    | None -> chart.selected.recorded_at
  in
  let buffer = Buffer.create 2048 in
  let add fmt = Printf.bprintf buffer fmt in
  add "flowchart TD\n";
  add "classDef scope fill:#1e293b,stroke:#475569,color:#cbd5e1\n";
  add "classDef note fill:#422006,stroke:#f59e0b,color:#fef3c7\n";
  add "classDef retained fill:#052e16,stroke:#22c55e,color:#dcfce7\n";
  add "classDef prior fill:#082f49,stroke:#38bdf8,color:#e0f2fe\n";
  add
    "classDef unconfirmed fill:#451a03,stroke:#f59e0b,color:#fef3c7,stroke-dasharray: 5 4\n";
  add "classDef evt fill:#1e1b4b,stroke:#818cf8,color:#e0e7ff\n";
  add
    "classDef selected fill:#172554,stroke:#22d3ee,color:#ecfeff,stroke-width:2.5px\n";
  let scope =
    Printf.sprintf
      (if ko then "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건"
       else "Observed window: latest %d / up to %d entries · %d events")
      chart.journal_lines chart.limit (List.length chart.events)
  in
  add "Scope[\"%s\"]:::scope\n" (escape_mermaid scope);
  dedup_notes chart.notes
  |> List.iteri (fun i note ->
         add "Note%d[\"! %s\"]:::note\n" i (mermaid_label ~max_cells:60 note));
  let facts = chart.facts in
  let index = Hashtbl.create (List.length facts) in
  List.iteri
    (fun i (f : fact) ->
      Hashtbl.replace index f.memory_id i;
      let status, badge = fact_status ~ko chart f in
      let cls =
        match status with
        | "retained" -> "retained"
        | "consumed" -> "prior"
        | _ -> "unconfirmed"
      in
      let header = Printf.sprintf "[F%d · %s · %s]" (i + 1) badge f.memory_id in
      let body = fact_claim_text ~ko chart f in
      add "F%d(\"%s<br/>%s\"):::%s\n" i (escape_mermaid header)
        (mermaid_label ~max_cells:46 body)
        cls)
    facts;
  let edge_idx = ref 0 in
  let dotted_edges = ref [] in
  List.iteri
    (fun i (ev : event) ->
      let is_selected = String.equal ev.identity chart.selected.identity in
      let selected = if is_selected then "★ " else "" in
      let header =
        Printf.sprintf "%s%s · r%d · %s" selected (kind_label ~ko ev.kind)
          ev.revision (format_instant ~tz_offset_sec ~now ev.recorded_at)
      in
      let reason_part =
        match ev.reason with
        | Some r when not (String.equal (String.trim r) "") ->
            "<br/>" ^ mermaid_label ~max_cells:42 (String.trim r)
        | Some _ | None -> ""
      in
      let cls = if is_selected then "selected" else "evt" in
      add "E%d[\"%s%s\"]:::%s\n" i (escape_mermaid header) reason_part cls;
      let is_unconfirmed = equal_event_kind ev.kind Relation_unavailable in
      let arrow = if is_unconfirmed then "-.->" else "-->" in
      let emit_edge src dst =
        add "%s %s %s\n" src arrow dst;
        if is_unconfirmed then dotted_edges := !edge_idx :: !dotted_edges;
        incr edge_idx
      in
      List.iter
        (fun (f : fact) ->
          Option.iter
            (fun fi -> emit_edge (Printf.sprintf "F%d" fi) (Printf.sprintf "E%d" i))
            (Hashtbl.find_opt index f.memory_id))
        ev.before;
      List.iter
        (fun (f : fact) ->
          Option.iter
            (fun fi -> emit_edge (Printf.sprintf "E%d" i) (Printf.sprintf "F%d" fi))
            (Hashtbl.find_opt index f.memory_id))
        ev.after)
    chart.events;
  List.iter
    (fun idx ->
      add "linkStyle %d stroke:#f59e0b,stroke-dasharray: 5 4\n" idx)
    (List.rev !dotted_edges);
  Buffer.contents buffer

let transition_mermaid ?(tz_offset_sec = 0) ~ko ?now (chart : chart) =
  let ids = identities chart.selected in
  mermaid ~tz_offset_sec ~ko ?now
    {
      chart with
      events = [ chart.selected ];
      facts =
        List.filter (fun (f : fact) -> Ids.mem f.memory_id ids) chart.facts;
    }
