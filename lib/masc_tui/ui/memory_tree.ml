module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid
module Grapheme = Masc_tui_term.Grapheme

type edge_style =
  | Confirmed
  | Unconfirmed

type line_kind =
  | Header
  | Scope
  | Note
  | Event_selected
  | Event_other
  | Edge of edge_style
  | Fact_before
  | Fact_after
  | Reason
  | Separator

type line = {
  kind : line_kind;
  text : string;
}

let sanitize_single_line = Memory_lineage.sanitize_single_line

let fit ~max_width text =
  let clean = sanitize_single_line text in
  if Grapheme.display_width clean <= max_width then clean
  else Grapheme.truncate_to_width ~max_width clean

let wrap_with_prefix ~max_width ~first_prefix ~cont_prefix text =
  let prefix_w =
    Int.max
      (Grapheme.display_width first_prefix)
      (Grapheme.display_width cont_prefix)
  in
  let body_w = Int.max 1 (max_width - prefix_w) in
  let wrapped = Memory_lineage.wrap_full_lines ~max_cells:body_w text in
  List.mapi
    (fun idx row ->
      let p = if idx = 0 then first_prefix else cont_prefix in
      fit ~max_width (p ^ row))
    wrapped

let successor_count_text (ev : Memory_lineage.event) =
  match ev.kind with
  | Memory_lineage.Relation_unavailable -> "?"
  | Created | Reobserved | Revised | Absorbed | Retracted | Removed
  | Invalidated ->
      string_of_int (List.length ev.after)

let render_lines ?(tz_offset_sec = 0) ~ko ?now ?(keeper_name = "") ~max_width
    (chart : Memory_lineage.chart) =
  let max_width = Int.max 1 max_width in
  let now =
    match now with
    | Some ts -> ts
    | None -> chart.selected.recorded_at
  in
  let text korean english = if ko then korean else english in
  let fact_index = Hashtbl.create (List.length chart.facts) in
  List.iteri
    (fun i (f : Memory_lineage.fact) ->
      Hashtbl.replace fact_index f.memory_id (i + 1))
    chart.facts;
  let fact_tag (f : Memory_lineage.fact) =
    match Hashtbl.find_opt fact_index f.memory_id with
    | Some idx -> Printf.sprintf "F%d" idx
    | None -> "F?"
  in
  let acc = ref [] in
  let push kind s = acc := { kind; text = fit ~max_width s } :: !acc in
  let clean_keeper = String.trim (sanitize_single_line keeper_name) in
  let header_text =
    if String.equal clean_keeper "" then
      text "기억 형성 트리" "Memory formation tree"
    else
      text "기억 형성 트리 · " "Memory formation tree · " ^ clean_keeper
  in
  push Header header_text;
  let scope_text =
    Printf.sprintf
      (if ko then "관측 범위: 최근 %d / 최대 %d회 · 연결된 변화 %d건 · 사실 %d건"
       else "Observed window: latest %d / up to %d entries · %d events · %d facts")
      chart.journal_lines chart.limit (List.length chart.events)
      (List.length chart.facts)
  in
  List.iter (push Scope)
    (wrap_with_prefix ~max_width ~first_prefix:"" ~cont_prefix:"  " scope_text);
  let notes = Memory_lineage.dedup_notes chart.notes in
  List.iter
    (fun note ->
      List.iter (push Note)
        (wrap_with_prefix ~max_width ~first_prefix:"! " ~cont_prefix:"  " note))
    notes;
  let event_count = List.length chart.events in
  List.iteri
    (fun ev_idx (ev : Memory_lineage.event) ->
      let is_selected =
        String.equal ev.identity chart.selected.identity
      in
      let unconfirmed =
        Memory_lineage.equal_event_kind ev.kind
          Memory_lineage.Relation_unavailable
      in
      let edge_style = if unconfirmed then Unconfirmed else Confirmed in
      let rail = if unconfirmed then "┆" else "│" in
      let hbar = if unconfirmed then "┄" else "─" in
      let branch_mid = if unconfirmed then "├┄ " else "├─ " in
      let branch_last = if unconfirmed then "└┄ " else "└─ " in
      let arrow_mid = if unconfirmed then "├┄▶ " else "├─▶ " in
      let arrow_last = if unconfirmed then "└┄▶ " else "└─▶ " in
      let star = if is_selected then "★ " else "" in
      let ts = Memory_lineage.format_instant ~tz_offset_sec ~now ev.recorded_at in
      let header =
        Printf.sprintf "╭%s %s%s · r%d · %s (%d → %s)" hbar star
          (Memory_lineage.kind_label ~ko ev.kind)
          ev.revision ts (List.length ev.before) (successor_count_text ev)
      in
      let ev_kind = if is_selected then Event_selected else Event_other in
      push ev_kind header;
      (* Prior facts *)
      (match ev.before with
       | [] ->
           push Fact_before
             (Printf.sprintf "%s %s (%s)" rail
                (text "이전" "Before")
                (text "이전 본문 없음" "no prior claim"))
       | before_facts ->
           let total = List.length before_facts in
           List.iteri
             (fun i (f : Memory_lineage.fact) ->
               let is_last = i = total - 1 in
               let prefix =
                 rail ^ " " ^ (if is_last then branch_last else branch_mid)
               in
               let cont =
                 rail ^ " " ^ (if is_last then "   " else rail ^ "  ")
               in
               let _, badge = Memory_lineage.fact_status ~ko chart f in
               let claim = Memory_lineage.fact_claim_text ~ko chart f in
               let heading =
                 Printf.sprintf "[%s · %s · %s]" (fact_tag f) badge
                   (sanitize_single_line f.memory_id)
               in
               push Fact_before (prefix ^ heading);
               List.iter (push Fact_before)
                 (wrap_with_prefix ~max_width ~first_prefix:(cont ^ "  ")
                    ~cont_prefix:(cont ^ "  ") claim))
             before_facts);
      (* Optional transition reason *)
      (match ev.reason with
       | Some r when not (String.equal (String.trim r) "") ->
           let label = text "사유: " "Reason: " in
           List.iter (push Reason)
             (wrap_with_prefix ~max_width
                ~first_prefix:(rail ^ " " ^ label)
                ~cont_prefix:(rail ^ "   ") (String.trim r))
       | Some _ | None -> ());
      (* Successor facts *)
      (match ev.after with
       | [] ->
           let empty_msg =
             if unconfirmed then
               text "? 후속 관계 보고 안 됨" "? Successor relation not reported"
             else text "후속 기억 없음" "no successor"
           in
           push (Edge edge_style) (arrow_last ^ empty_msg)
       | after_facts ->
           let total = List.length after_facts in
           List.iteri
             (fun i (f : Memory_lineage.fact) ->
               let is_last = i = total - 1 in
               let prefix = if is_last then arrow_last else arrow_mid in
               let cont = if is_last then "    " else rail ^ "   " in
               let _, badge = Memory_lineage.fact_status ~ko chart f in
               let claim = Memory_lineage.fact_claim_text ~ko chart f in
               let heading =
                 Printf.sprintf "[%s · %s · %s]" (fact_tag f) badge
                   (sanitize_single_line f.memory_id)
               in
               push (Edge edge_style) (prefix ^ heading);
               List.iter (push Fact_after)
                 (wrap_with_prefix ~max_width ~first_prefix:(cont ^ "  ")
                    ~cont_prefix:(cont ^ "  ") claim))
             after_facts);
      if ev_idx < event_count - 1 then begin
        let connector = if unconfirmed then "┆" else "│" in
        push (Edge edge_style) connector
      end)
    chart.events;
  List.rev !acc

let render ?tz_offset_sec ~ko ?now ?keeper_name ~max_width chart =
  render_lines ?tz_offset_sec ~ko ?now ?keeper_name ~max_width chart
  |> List.map (fun l -> l.text)

let style_of_line ~(theme : Theme.t) = function
  | Header -> Typography.anchor theme
  | Scope | Separator -> Typography.whisper theme
  | Note -> Typography.status theme Theme.Status_attention
  | Event_selected -> Typography.accent ~bold:true theme
  | Event_other -> Typography.structure ~bold:true theme
  | Edge Confirmed -> Typography.structure theme
  | Edge Unconfirmed -> Typography.status theme Theme.Status_attention
  | Fact_before -> Typography.primary theme
  | Fact_after -> Typography.status theme Theme.Status_ok
  | Reason -> Typography.whisper theme

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ?tz_offset_sec ~ko ?now
    ?keeper_name ?(scroll = 0) chart =
  if rect.w <= 0 || rect.h <= 0 then 0
  else
    let lines =
      render_lines ?tz_offset_sec ~ko ?now ?keeper_name ~max_width:rect.w chart
    in
    let total = List.length lines in
    let start = Int.max 0 scroll in
    let visible =
      lines
      |> List.filteri (fun idx _ -> idx >= start && idx < start + rect.h)
    in
    List.iteri
      (fun row (item : line) ->
        let style = style_of_line ~theme item.kind in
        ignore
          (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:(rect.y + row)
             ~style item.text
            : int))
      visible;
    total
