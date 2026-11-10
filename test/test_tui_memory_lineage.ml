module Activity = Masc.Keeper_memory_activity
module Lineage = Masc_tui_memory_lineage

let fact memory_id : Activity.fact = {memory_id; claim=Some memory_id}
let event identity before after : Activity.event =
  {identity; recorded_at=1.; revision=1; kind=Activity.Absorbed;
   before=List.map fact before; after=List.map fact after; reason=None}
let activity events : Activity.t = {events; limit=50; journal_lines=50; notes=["partial history"]}
let ids chart = List.map (fun (event : Activity.event) -> event.identity) chart.Lineage.events

let connected () =
  let source = activity [event "a" [] ["A"]; event "other" [] ["unrelated"];
    event "merge" ["A";"B"] ["C"]; event "revise" ["C"] ["D"]] in
  let chart = Option.get (Lineage.select ~event_id:"merge" source) in
  Alcotest.(check (list string)) "persisted component in original order" ["a";"merge";"revise"] (ids chart);
  Alcotest.(check (list string)) "partial observation retained" source.notes chart.notes;
  Alcotest.(check int) "window retained" 50 chart.journal_lines

let cycle () =
  let chart = Lineage.select ~event_id:"b" (activity [event "a" ["A"] ["B"];event "b" ["B"] ["A"]]) |> Option.get in
  Alcotest.(check (list string)) "finite identity closure" ["a";"b"] (ids chart)

let missing () =
  Alcotest.(check bool) "absent selection has no chart" true
    (Option.is_none (Lineage.select ~event_id:"missing" (activity [event "a" [] ["A"]])))

let observed_body () =
  let unknown : Activity.event = { (event "unknown" ["A"] []) with
    kind=Activity.Relation_unavailable; after=[{memory_id="C";claim=None}]} in
  let chart = Lineage.select ~event_id:"unknown"
    (activity [unknown;event "known" ["C"] ["D"]]) |> Option.get in
  let resolved = List.find (fun (fact : Activity.fact) -> fact.memory_id="C") chart.facts in
  Alcotest.(check (option string)) "retain observed body for the same identity" (Some "C") resolved.claim;
  Alcotest.(check bool) "unknown relation is not upgraded" true
    (chart.selected.kind=Activity.Relation_unavailable)

let () = Alcotest.run "Memory lineage selection" ["observed identities",[
  Alcotest.test_case "connected component" `Quick connected;
  Alcotest.test_case "cycle" `Quick cycle;
  Alcotest.test_case "observed body with unknown relation" `Quick observed_body;
  Alcotest.test_case "missing selected event" `Quick missing]]
