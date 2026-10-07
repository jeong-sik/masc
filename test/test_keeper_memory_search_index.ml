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

(* A workspace-sized batch: enough rows and queries that building and
   querying the table takes a measurable time. *)
let workspace_batch () =
  let texts =
    List.init 4000 (fun i ->
      Printf.sprintf "keeper-%d" (i mod 25),
      Printf.sprintf "fact %d about the report pipeline, release %d and the board" i (i mod 97))
  in
  let queries =
    List.init 25 (fun i -> Printf.sprintf "keeper-%d" i, "report pipeline release board")
  in
  texts, queries

let rank_batch (texts, queries) =
  match Index.rank_many_excluding_owners ~queries ~texts ~max_results:8 with
  | Ok (ranked, _) -> List.map (List.map fst) ranked
  | Error error -> Alcotest.fail (Index.error_to_string error)

let with_pool env f =
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests f

(* How many times another fiber on the caller's domain ran while one batch
   was being ranked. *)
let ticks_during_rank batch =
  let ticks = ref 0 and stop = ref false in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    while not !stop do
      incr ticks;
      Eio.Fiber.yield ()
    done);
  Eio.Fiber.yield ();
  let before = !ticks in
  let ranked = rank_batch batch in
  let during = !ticks - before in
  stop := true;
  ranked, during

let test_pool_and_inline_rank_the_same () =
  Eio_main.run @@ fun env ->
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  let batch = workspace_batch () in
  let inline = rank_batch batch in
  let pooled = with_pool env (fun () -> rank_batch batch) in
  Alcotest.(check (list (list int))) "pooled ranking equals inline ranking" inline pooled

let test_the_calling_domain_keeps_running () =
  Eio_main.run @@ fun env ->
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  let batch = workspace_batch () in
  let _, inline_ticks = ticks_during_rank batch in
  Alcotest.(check int) "inline, the caller's domain runs nothing else" 0 inline_ticks;
  let _, pooled_ticks = with_pool env (fun () -> ticks_during_rank batch) in
  Alcotest.(check bool) "with a pool, other fibers run while the batch is ranked" true
    (pooled_ticks > 0)

let () =
  Alcotest.run "Keeper memory search index"
    ["multi-query", [Alcotest.test_case "one transient index answers each query" `Quick
      test_many_queries_share_one_snapshot;
      Alcotest.test_case "owner filter precedes limit and reports build cost" `Quick
      test_owner_filter_and_index_cost];
     "domain pool", [Alcotest.test_case "pooled and inline rankings agree" `Quick
      test_pool_and_inline_rank_the_same;
      Alcotest.test_case "the calling domain keeps running" `Quick
      test_the_calling_domain_keeps_running]]
