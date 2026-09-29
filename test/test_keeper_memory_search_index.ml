module Index = Masc.Keeper_memory_search_index

let ranks ~queries texts =
  match Index.rank_many ~queries texts with
  | Ok rows -> rows
  | Error error -> Alcotest.fail (Index.error_to_string error)

let test_many_queries_share_one_snapshot () =
  let texts =
    [ "The report has twelve pages"
    ; "배포는 금요일에 끝났습니다"
    ; "The report has ten pages" ]
  in
  let queries = ["report pages"; "금요일"; ""; "nonsense-nomatch"] in
  let rows = ranks ~queries texts in
  Alcotest.(check int) "one result per query" (List.length queries) (List.length rows);
  List.iter2
    (fun query many ->
       match Index.rank ~query texts with
       | Ok one -> Alcotest.(check (list int)) ("same ranking: " ^ query)
                     (List.map fst one) (List.map fst many)
       | Error error -> Alcotest.fail (Index.error_to_string error))
    queries rows;
  Alcotest.(check (list int)) "Korean trigram query finds its source"
    [1] (List.map fst (List.nth rows 1));
  Alcotest.(check (list int)) "blank query does not select neighbors"
    [] (List.map fst (List.nth rows 2))

let test_owner_filter_and_index_cost () =
  let texts = ["writer", "The report has twelve pages";
               "writer", "The report has eleven pages";
               "reviewer", "The report has ten pages"] in
  let query = ["writer", "report pages"] in
  match Index.rank_many_excluding_owners ~queries:query ~texts ~max_results:1 with
  | Error error -> Alcotest.fail (Index.error_to_string error)
  | Ok (ranked, stats) ->
    Alcotest.(check (list int)) "SQL excludes the query's Keeper before limiting"
      [2] (List.map fst (List.hd ranked));
    Alcotest.(check int) "one table for the batch" 1 stats.index_builds;
    Alcotest.(check int) "each source inserted once" 3 stats.indexed_rows;
    Alcotest.(check int) "one nonblank query" 1 stats.queries_executed;
    (match Index.rank_many_excluding_owners ~queries:query ~texts ~max_results:0 with
     | Ok (_, empty_stats) ->
       Alcotest.(check int) "zero neighbors build no table" 0 empty_stats.index_builds
     | Error error -> Alcotest.fail (Index.error_to_string error))

let () =
  Alcotest.run "Keeper memory search index"
    ["multi-query", [Alcotest.test_case "one transient index answers each query" `Quick
      test_many_queries_share_one_snapshot;
      Alcotest.test_case "owner filter precedes limit and reports build cost" `Quick
      test_owner_filter_and_index_cost]]
