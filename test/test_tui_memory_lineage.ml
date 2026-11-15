module Activity = Masc.Keeper_memory_activity
module Lineage = Masc_tui_memory_lineage
module Palette = Masc_tui_terminal_palette

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

let fact ?claim memory_id : Activity.fact =
  { memory_id; claim = Some (Option.value claim ~default:memory_id) }

let event ?(kind = Activity.Absorbed) ?reason identity before after : Activity.event =
  { identity; recorded_at = 1_794_700_000.; revision = 3698; kind;
    before; after; reason }

let activity ?(notes = ["partial history"]) events : Activity.t =
  { events; limit = 50; journal_lines = 50; notes }

let ids chart = List.map (fun (event : Activity.event) -> event.identity) chart.Lineage.events

let connected () =
  let source = activity [
    event "a" [] [fact "A"];
    event "other" [] [fact "unrelated"];
    event "merge" [fact "A"; fact "B"] [fact "C"];
    event "revise" [fact "C"] [fact "D"]
  ] in
  let chart = Option.get (Lineage.select ~event_id:"merge" source) in
  Alcotest.(check (list string)) "persisted component in original order" ["a";"merge";"revise"] (ids chart);
  Alcotest.(check (list string)) "partial observation retained" source.notes chart.notes;
  Alcotest.(check int) "window retained" 50 chart.journal_lines

let cycle () =
  let chart = Lineage.select ~event_id:"b"
      (activity [event "a" [fact "A"] [fact "B"]; event "b" [fact "B"] [fact "A"]])
    |> Option.get in
  Alcotest.(check (list string)) "finite identity closure" ["a";"b"] (ids chart)

let missing () =
  Alcotest.(check bool) "absent selection has no chart" true
    (Option.is_none (Lineage.select ~event_id:"missing" (activity [event "a" [] [fact "A"]])))

let observed_body () =
  let unknown : Activity.event = {
    (event ~kind:Activity.Relation_unavailable "unknown" [fact "A"] []) with
    after = [{ memory_id = "C"; claim = None }]
  } in
  let chart = Lineage.select ~event_id:"unknown"
      (activity [unknown; event "known" [fact "C"] [fact "D"]]) |> Option.get in
  let resolved = List.find (fun (fact : Activity.fact) -> fact.memory_id = "C") chart.facts in
  Alcotest.(check (option string)) "retain observed body for the same identity" (Some "C") resolved.claim;
  Alcotest.(check bool) "unknown relation is not upgraded" true
    (chart.selected.kind = Activity.Relation_unavailable)

let rich_graph_preserves_full_text () =
  let long_before =
    "MASC 저장소 Git 이력과 PR 리뷰만으로는 외부 운영자의 실제 배포 의도나 계정 소유권을 단정할 수 없으며, \
anyang-keepers 또는 리더 레인의 명시적 감사 로그가 함께 확인되어야 한다." in
  let long_after =
    "계정 공유 여부는 2026-11-10 이후 감사 로그와 Keeper 핸드오프 영수증이 교차 검증된 뒤에만 확정하며, \
추측 기반 운영자 행동 판정은 금지된다." in
  let reason_text = "중복 운영 규칙을 단일 검증 정책으로 통합 흡수함" in
  let duplicated_note = "retained successors are missing beyond this historical transition" in
  let e1 = event ~kind:Activity.Absorbed ~reason:reason_text "e1"
      [fact ~claim:long_before "mem-prior-001"]
      [fact ~claim:long_after "mem-final-002"] in
  let e2 = event ~kind:Activity.Relation_unavailable "e2"
      [fact ~claim:"외부 워커 상태 미확인 주장" "mem-unconfirmed-003"] [] in
  let chart = Lineage.select ~event_id:"e1"
      (activity ~notes:[duplicated_note; duplicated_note] [e1; e2]) |> Option.get in
  let e2_chart = Lineage.select ~event_id:"e2"
      (activity ~notes:[duplicated_note; duplicated_note] [e1; e2]) |> Option.get in
  let json_str = Lineage.lineage_graph ~ko:true ~keeper_name:"e-masc-the-leader" chart in
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string json_str in
  let notes = json |> member "notes" |> to_list |> List.map to_string in
  Alcotest.(check int) "duplicate observation note collapsed" 1 (List.length notes);
  let nodes = json |> member "nodes" |> to_list in
  let fact_nodes = List.filter (fun n -> n |> member "kind" |> to_string = "fact") nodes in
  let join_lines n = n |> member "lines" |> to_list |> List.map to_string |> String.concat " " in
  let find_fact mid = List.find (fun n -> n |> member "memoryId" |> to_string = mid) fact_nodes in
  let prior_node = find_fact "mem-prior-001" in
  let final_node = find_fact "mem-final-002" in
  Alcotest.(check string) "consumed prior status" "consumed" (prior_node |> member "status" |> to_string);
  Alcotest.(check string) "retained successor status" "retained" (final_node |> member "status" |> to_string);
  Alcotest.(check bool) "full prior claim preserved without ellipsis" true
    (contains ~needle:"명시적 감사 로그가 함께 확인되어야 한다." (join_lines prior_node));
  Alcotest.(check bool) "full successor claim preserved without ellipsis" true
    (contains ~needle:"추측 기반 운영자 행동 판정은 금지된다." (join_lines final_node));
  Alcotest.(check bool) "no truncation ellipsis injected" false
    (contains ~needle:"..." (join_lines prior_node));
  let evt_node = List.find (fun n -> n |> member "kind" |> to_string = "event") nodes in
  Alcotest.(check bool) "selected flag preserved" true (evt_node |> member "selected" |> to_bool);
  let reason_lines = evt_node |> member "reasonLines" |> to_list |> List.map to_string |> String.concat " " in
  Alcotest.(check bool) "event reason preserved" true (contains ~needle:"통합 흡수함" reason_lines);
  let json_u = Yojson.Safe.from_string (Lineage.lineage_graph ~ko:true ~keeper_name:"k" e2_chart) in
  let edges_u = json_u |> member "edges" |> to_list in
  Alcotest.(check bool) "unresolved edge keeps dashed flag" true
    (List.exists (fun e -> e |> member "dashed" |> to_bool) edges_u)

let transition_svg_full_claims () =
  let palette = Palette.of_responses
      ~foreground:(Some (Palette.make_rgb ~red:226 ~green:232 ~blue:240))
      ~background:(Some (Palette.make_rgb ~red:15 ~green:23 ~blue:42))
      ~ansi:(Array.make Palette.ansi_slot_count None)
    |> Option.get in
  let long_claim =
    "첫 번째 매우 긴 한국어 메모리 주장 텍스트로서 이전에 여섯 줄을 초과하면 말줄임표로 잘렸지만 \
이제는 동적 카드 높이 계산으로 끝문장까지 완전히 표시되어야 하며 누락되는 단어가 없어야 합니다. \
여기에 추가 세부 설명과 식별 검증 조건까지 전부 포함해서 마지막 꼬리 문구 TAIL_VERIFICATION_TOKEN 까지 출력합니다." in
  let e1 = event ~kind:Activity.Revised ~reason:"상세 근거 역시 누락 없이 표시" "e1"
      [fact ~claim:long_claim "mem-long-001"]
      [fact ~claim:"갱신된 최종 결론 텍스트 END_TOKEN" "mem-long-002"] in
  let chart = Lineage.select ~event_id:"e1" (activity ~notes:["note-a"; "note-a"] [e1]) |> Option.get in
  let svg = Lineage.transition_svg ~ko:true ~palette chart in
  Alcotest.(check bool) "long claim tail token preserved in SVG" true
    (contains ~needle:"TAIL_VERIFICATION_TOKEN" svg);
  Alcotest.(check bool) "after token preserved in SVG" true
    (contains ~needle:"END_TOKEN" svg);
  Alcotest.(check bool) "memory id shown in SVG" true
    (contains ~needle:"mem-long-001" svg);
  Alcotest.(check bool) "reason callout first wrapped part shown in SVG" true
    (contains ~needle:"상세 근거 역시 누락 없이" svg);
  Alcotest.(check bool) "reason callout tail word shown in SVG" true
    (contains ~needle:"표시" svg);
  Alcotest.(check bool) "no truncation ellipsis in transition SVG" false
    (contains ~needle:" …</text>" svg);
  let mm = Lineage.mermaid ~ko:true chart in
  Alcotest.(check bool) "mermaid retains full tail token without 48-char cut" true
    (contains ~needle:"TAIL_VERIFICATION_TOKEN" mm);
  Alcotest.(check bool) "mermaid uses classDef styling" true
    (contains ~needle:"classDef retained" mm)

let () = Alcotest.run "Memory lineage selection" [
  "observed identities", [
    Alcotest.test_case "connected component" `Quick connected;
    Alcotest.test_case "cycle" `Quick cycle;
    Alcotest.test_case "observed body with unknown relation" `Quick observed_body;
    Alcotest.test_case "missing selected event" `Quick missing;
  ];
  "rich rendering", [
    Alcotest.test_case "rich graph preserves full claims and notes" `Quick rich_graph_preserves_full_text;
    Alcotest.test_case "transition SVG and mermaid preserve full claims" `Quick transition_svg_full_claims;
  ];
]
