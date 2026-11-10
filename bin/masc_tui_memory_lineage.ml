module Activity = Masc.Keeper_memory_activity
module Ids = Set.Make (String)

type t = {
  selected : Activity.event;
  events : Activity.event list;
  journal_lines : int;
  limit : int;
  notes : string list;
}

let identities (event : Activity.event) =
  List.fold_left (fun ids (fact : Activity.fact) -> Ids.add fact.memory_id ids)
    Ids.empty (event.before @ event.after)

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
    Some {selected; events; journal_lines=activity.journal_lines; limit=activity.limit; notes=activity.notes}

(* Labels are data in quoted Mermaid nodes. Entity escaping prevents a claim
   containing quote/bracket/markup syntax from declaring nodes or edges. *)
let label text =
  let text = Masc_tui_message_layout.truncate_middle 48 (Terminal_text.single_line text) in
  let buffer = Buffer.create (String.length text) in
  String.iter (function
    | '#' -> Buffer.add_string buffer "#35;"
    | '&' -> Buffer.add_string buffer "#38;"
    | '"' -> Buffer.add_string buffer "#quot;"
    | '<' -> Buffer.add_string buffer "#60;"
    | '>' -> Buffer.add_string buffer "#62;"
    | c -> Buffer.add_char buffer c) text;
  Buffer.contents buffer

let kind_word ~ko = function
  | Activity.Created -> if ko then "＋ 생성" else "+ Created"
  | Activity.Reobserved -> if ko then "↻ 재관측" else "Reobserved"
  | Activity.Revised -> if ko then "↗ 수정" else "Revised"
  | Activity.Absorbed -> if ko then "◇ 흡수" else "Absorbed"
  | Activity.Retracted -> if ko then "× 삭제" else "Retracted"
  | Activity.Removed -> if ko then "− 제외" else "Removed"
  | Activity.Invalidated -> if ko then "! 무효화" else "Invalidated"
  | Activity.Relation_unavailable -> if ko then "? 관계 미확인" else "? Unresolved relation"

let mermaid ~ko (chart : t) =
  let buffer = Buffer.create 1024 in
  let add = Printf.bprintf buffer in
  add "flowchart TD\n";
  let scope = Printf.sprintf
    (if ko then "관측 범위: 최근 %d / 최대 %d회" else "Observed window: latest %d / up to %d entries")
    chart.journal_lines chart.limit in
  add "Scope[\"%s\"]\n" scope;
  List.iteri (fun i note -> add "Note%d[\"! %s\"]\n" i (label note)) chart.notes;
  let facts = List.concat_map (fun (event : Activity.event) -> event.before @ event.after) chart.events
    |> List.sort_uniq (fun (a : Activity.fact) b -> String.compare a.memory_id b.memory_id) in
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
      (kind_word ~ko event.kind) event.revision (clock.tm_mon + 1) clock.tm_mday clock.tm_hour clock.tm_min;
    let arrow = match event.kind with Activity.Relation_unavailable -> "-.->"
      | Activity.Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated -> "-->" in
    List.iter (fun (fact : Activity.fact) -> add "F%d %s E%d\n" (Hashtbl.find index fact.memory_id) arrow i) event.before;
    List.iter (fun (fact : Activity.fact) -> add "E%d %s F%d\n" i arrow (Hashtbl.find index fact.memory_id)) event.after) chart.events;
  Buffer.contents buffer
