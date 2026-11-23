module Lineage = Masc_tui_ui.Memory_lineage
module Tree = Masc_tui_ui.Memory_tree
module Palette = Masc_tui_term.Palette
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid
module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

let fact ?claim memory_id : Lineage.fact =
  { memory_id; claim = Some (Option.value claim ~default:memory_id) }

let event ?(kind = Lineage.Absorbed) ?reason identity before after : Lineage.event =
  {
    identity;
    recorded_at = 1_794_700_000.;
    revision = 3698;
    kind;
    before;
    after;
    reason;
  }

let activity ?(notes = [ "partial history" ]) events : Lineage.activity =
  { events; limit = 50; journal_lines = 50; notes }

let ids (chart : Lineage.chart) =
  List.map (fun (ev : Lineage.event) -> ev.identity) chart.events

let test_connected_cycle_and_missing () =
  let source =
    activity
      [
        event "a" [] [ fact "A" ];
        event "other" [] [ fact "unrelated" ];
        event "merge" [ fact "A"; fact "B" ] [ fact "C" ];
        event "revise" [ fact "C" ] [ fact "D" ];
      ]
  in
  let chart = Option.get (Lineage.select ~event_id:"merge" source) in
  Alcotest.(check (list string)) "connected component in persisted order"
    [ "a"; "merge"; "revise" ] (ids chart);
  Alcotest.(check (list string)) "notes retained" source.notes chart.notes;
  Alcotest.(check int) "journal_lines retained" 50 chart.journal_lines;

  let cyc =
    Lineage.select ~event_id:"b"
      (activity
         [
           event "a" [ fact "A" ] [ fact "B" ];
           event "b" [ fact "B" ] [ fact "A" ];
         ])
    |> Option.get
  in
  Alcotest.(check (list string)) "finite closure on cycle" [ "a"; "b" ] (ids cyc);

  Alcotest.(check bool) "missing event returns None" true
    (Option.is_none
       (Lineage.select ~event_id:"missing" (activity [ event "a" [] [ fact "A" ] ])))

let test_observed_body_does_not_upgrade_relation_unavailable () =
  let unknown : Lineage.event =
    {
      (event ~kind:Lineage.Relation_unavailable "unknown" [ fact "A" ] []) with
      after = [ { memory_id = "C"; claim = None } ];
    }
  in
  let chart =
    Lineage.select ~event_id:"unknown"
      (activity [ unknown; event "known" [ fact "C" ] [ fact "D" ] ])
    |> Option.get
  in
  let resolved =
    List.find (fun (f : Lineage.fact) -> String.equal f.memory_id "C") chart.facts
  in
  Alcotest.(check (option string)) "retains observed claim body" (Some "C")
    resolved.claim;
  Alcotest.(check bool) "Relation_unavailable stays unconfirmed" true
    (Lineage.equal_event_kind chart.selected.kind Lineage.Relation_unavailable)

let test_transition_svg_and_mermaid_fallback () =
  let palette =
    Palette.of_responses
      ~foreground:(Some (Palette.make_rgb ~red:226 ~green:232 ~blue:240))
      ~background:(Some (Palette.make_rgb ~red:15 ~green:23 ~blue:42))
      ~ansi:(Array.make Palette.ansi_slot_count None)
    |> Option.get
  in
  let long_claim =
    "첫 번째 매우 긴 한국어 메모리 주장 텍스트로서 동적 카드 높이 계산으로 끝문장까지 완전히 표시되어야 하며 \
     누락되는 단어가 없어야 합니다. 마지막 꼬리 문구 TAIL_VERIFICATION_TOKEN 까지 출력합니다."
  in
  let e_prior = event ~kind:Lineage.Created "e0" [] [ fact ~claim:long_claim "mem-long-001" ] in
  let e_sel =
    event ~kind:Lineage.Revised ~reason:"상세 근거 역시 누락 없이 표시" "e1"
      [ fact ~claim:long_claim "mem-long-001" ]
      [ fact ~claim:"갱신된 최종 결론 텍스트 END_TOKEN" "mem-long-002" ]
  in
  let chart =
    Lineage.select ~event_id:"e1"
      (activity ~notes:[ "note-a"; "note-a" ] [ e_prior; e_sel ])
    |> Option.get
  in
  let svg = Lineage.transition_svg ~ko:true ~now:1_794_700_000. ~palette chart in
  Alcotest.(check bool) "SVG root element" true (contains ~needle:"<svg " svg);
  Alcotest.(check bool) "uses observed background hex" true
    (contains ~needle:"#0f172a" svg);
  Alcotest.(check bool) "uses observed foreground hex" true
    (contains ~needle:"#e2e8f0" svg);
  Alcotest.(check bool) "full claim tail preserved" true
    (contains ~needle:"TAIL_VERIFICATION_TOKEN" svg);
  Alcotest.(check bool) "after claim preserved" true
    (contains ~needle:"END_TOKEN" svg);
  Alcotest.(check bool) "memory id preserved" true
    (contains ~needle:"mem-long-001" svg);
  Alcotest.(check bool) "reason callout preserved" true
    (contains ~needle:"상세 근거" svg);
  Alcotest.(check bool) "no truncation ellipsis injected" false
    (contains ~needle:" …</text>" svg);

  (* transition_mermaid covers ONLY the selected event, never expands to e0 *)
  let tm = Lineage.transition_mermaid ~ko:true chart in
  Alcotest.(check bool) "transition_mermaid starts with flowchart TD" true
    (String.starts_with ~prefix:"flowchart TD" tm);
  Alcotest.(check bool) "transition_mermaid keeps selected event E0" true
    (contains ~needle:"E0[" tm);
  Alcotest.(check bool) "transition_mermaid does not expand to second event E1" false
    (contains ~needle:"E1[" tm);
  Alcotest.(check bool) "transition_mermaid preserves full tail token" true
    (contains ~needle:"TAIL_VERIFICATION_TOKEN" tm)

let test_formation_graph_json_and_memory_tree () =
  let long_before =
    "MASC 저장소 Git 이력과 PR 리뷰만으로는 외부 운영자의 실제 배포 의도를 단정할 수 없으며, \
     명시적 감사 로그가 함께 확인되어야 한다."
  in
  let long_after =
    "계정 공유 여부는 감사 로그와 Keeper 핸드오프 영수증이 교차 검증된 뒤에만 확정한다."
  in
  let dup_note = "retained successors are missing beyond this historical transition" in
  let e1 =
    event ~kind:Lineage.Absorbed ~reason:"중복 운영 규칙을 단일 정책으로 통합 흡수함" "e1"
      [ fact ~claim:long_before "mem-prior-001" ]
      [ fact ~claim:long_after "mem-final-002" ]
  in
  let e2 =
    event ~kind:Lineage.Relation_unavailable "e2"
      [ fact ~claim:long_after "mem-final-002" ]
      []
  in
  let chart =
    Lineage.select ~event_id:"e1"
      (activity ~notes:[ dup_note; dup_note ] [ e1; e2 ])
    |> Option.get
  in
  let json_str =
    Lineage.formation_graph_json ~ko:true ~keeper_name:"e-masc-the-leader" chart
  in
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string json_str in
  let notes = json |> member "notes" |> to_list |> List.map to_string in
  Alcotest.(check int) "duplicate observation note collapsed" 1 (List.length notes);
  let nodes = json |> member "nodes" |> to_list in
  let event_nodes =
    List.filter (fun n -> n |> member "kind" |> to_string = "event") nodes
  in
  Alcotest.(check int) "two connected events in graph" 2 (List.length event_nodes);
  let selected_events =
    List.filter (fun n -> n |> member "selected" |> to_bool) event_nodes
  in
  Alcotest.(check int) "exactly one selected event" 1 (List.length selected_events);
  Alcotest.(check bool) "selected label carries star" true
    (contains ~needle:"★"
       (List.hd selected_events |> member "selectedLabel" |> to_string));
  let edges = json |> member "edges" |> to_list in
  Alcotest.(check bool) "confirmed solid edge present" true
    (List.exists (fun e -> not (e |> member "dashed" |> to_bool)) edges);
  Alcotest.(check bool) "Relation_unavailable dashed edge present" true
    (List.exists (fun e -> e |> member "dashed" |> to_bool) edges);

  (* Full Mermaid includes both events, star, and dotted -.-> edge *)
  let full_mm = Lineage.mermaid ~ko:true chart in
  Alcotest.(check bool) "mermaid marks selected with ★" true
    (contains ~needle:"★ " full_mm);
  Alcotest.(check bool) "mermaid uses solid --> for confirmed" true
    (contains ~needle:"-->" full_mm);
  Alcotest.(check bool) "mermaid uses dotted -.-> for Relation_unavailable" true
    (contains ~needle:"-.->" full_mm);

  (* Memory_tree.render terminal box/tree view *)
  let max_width = 64 in
  let tree_lines =
    Tree.render ~ko:true ~keeper_name:"e-masc-the-leader" ~max_width chart
  in
  let joined = String.concat "\n" tree_lines in
  Alcotest.(check bool) "tree marks selected change with ★" true
    (contains ~needle:"★" joined);
  Alcotest.(check bool) "tree renders solid edge for confirmed transition" true
    (contains ~needle:"└─▶" joined || contains ~needle:"├─▶" joined);
  Alcotest.(check bool) "tree renders dotted edge for Relation_unavailable" true
    (contains ~needle:"└┄▶" joined || contains ~needle:"┆" joined);
  Alcotest.(check bool) "tree includes scope window" true
    (contains ~needle:"50" joined);
  Alcotest.(check bool) "tree includes deduplicated note" true
    (contains ~needle:"retained successors" joined);
  List.iter
    (fun line ->
      let w = Grapheme.display_width line in
      if w > max_width then
        Alcotest.failf "tree line exceeded max_width %d (got %d): %S" max_width w line)
    tree_lines;

  (* Memory_tree.draw paints cleanly onto Cell_grid without raising *)
  let grid = Cell_grid.create ~cols:64 ~rows:20 in
  let total =
    Tree.draw grid
      ~rect:(Rect.make ~x:0 ~y:0 ~w:64 ~h:20)
      ~theme:Theme.default ~ko:true ~keeper_name:"e-masc-the-leader" chart
  in
  Alcotest.(check int) "draw returns rendered line count"
    (List.length tree_lines) total

let () =
  Alcotest.run "masc_tui_v2_memory_lineage"
    [
      ( "lineage_and_tree",
        [
          Alcotest.test_case "connected component, cycle, and absent selection"
            `Quick test_connected_cycle_and_missing;
          Alcotest.test_case "observed body does not upgrade Relation_unavailable"
            `Quick test_observed_body_does_not_upgrade_relation_unavailable;
          Alcotest.test_case "3-stage transition SVG & Mermaid fallback" `Quick
            test_transition_svg_and_mermaid_fallback;
          Alcotest.test_case "formation_graph_json & Memory_tree.render/draw"
            `Quick test_formation_graph_json_and_memory_tree;
        ] );
    ]
