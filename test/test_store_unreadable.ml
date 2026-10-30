(** task-478: typed observation of currently-unreadable keeper stores.

    [Keeper_meta_store.Problem_report_state] is the one registry: the write
    side gates log noise (dedup on identical (site, path, detail), update on
    changed detail) and the read side projects the same rows for the
    dashboard. This pins the whole contract — one table, typed sites, no
    second registry to keep in step. *)

open Alcotest
open Masc

module Problem = Keeper_meta_store.Problem_report_state

let entry_of_site ~path =
  List.find_opt
    (fun (e : Problem.entry) -> String.equal e.path path)
    (Problem.snapshot ())

let test_register_adds_entry () =
  Problem.reset ();
  let added =
    Problem.should_report ~site:Problem.Meta_read ~path:"/a/b.json"
      ~detail:"boom"
  in
  check bool "first report is new" true added;
  check bool "the row is there" true (entry_of_site ~path:"/a/b.json" |> Option.is_some);
  (match entry_of_site ~path:"/a/b.json" with
   | None -> fail "snapshot lost the row"
   | Some e ->
     check string "site serialises" "meta_read" (Problem.site_to_string e.site);
     check string "path" "/a/b.json" e.path;
     check string "detail" "boom" e.detail;
     check bool "first_observed set" (e.first_observed > 0.) true)
;;

let test_register_dedups_identical () =
  Problem.reset ();
  let first =
    Problem.should_report ~site:Problem.Persistent_scan ~path:"/c.json"
      ~detail:"corrupt"
  in
  let again =
    Problem.should_report ~site:Problem.Persistent_scan ~path:"/c.json"
      ~detail:"corrupt"
  in
  check bool "first is new" true first;
  check bool "repeat is quiet" false again;
  check int "one row, not two" 1 (List.length (Problem.snapshot ()))
;;

let test_changed_detail_reports_and_keeps_first_observed () =
  Problem.reset ();
  ignore
    (Problem.should_report ~site:Problem.Keepalive_scan ~path:"/d.json"
       ~detail:"first failure");
  let first_observed =
    (match entry_of_site ~path:"/d.json" with
     | Some e -> e.first_observed
     | None -> fail "row missing")
  in
  let changed =
    Problem.should_report ~site:Problem.Keepalive_scan ~path:"/d.json"
      ~detail:"a different failure"
  in
  check bool "changed detail reports again" true changed;
  (match entry_of_site ~path:"/d.json" with
   | Some e ->
     check string "detail follows the change" "a different failure" e.detail;
     check bool "first_observed survives the change"
       (Float.equal first_observed e.first_observed) true
   | None -> fail "row missing after change")
;;

let test_clear_removes_the_row () =
  Problem.reset ();
  ignore
    (Problem.should_report ~site:Problem.Meta_read ~path:"/e.json"
       ~detail:"boom");
  Problem.clear ~site:Problem.Meta_read ~path:"/e.json";
  check bool "cleared row is gone"
    false (entry_of_site ~path:"/e.json" |> Option.is_some)
;;

let test_snapshot_projection_is_the_same_table () =
  Problem.reset ();
  ignore
    (Problem.should_report ~site:Problem.Persistent_scan ~path:"/f.json"
       ~detail:"corrupt");
  let json = Problem.snapshot_to_yojson () in
  let open Yojson.Safe.Util in
  let rows = json |> to_list in
  check int "one projected row" 1 (List.length rows);
  (match rows with
   | [ row ] ->
     check string "site field" "persistent_scan" (row |> member "site" |> to_string);
     check string "path field" "/f.json" (row |> member "path" |> to_string);
     check bool "first_observed field" (row |> member "first_observed" |> to_float > 0.) true
   | _ -> fail "expected exactly one row")
;;

let () =
  run
    "store_unreadable"
    [ ( "registry"
      , [ test_case "report adds one typed row" `Quick test_register_adds_entry
        ; test_case "identical repeats stay quiet" `Quick
            test_register_dedups_identical
        ; test_case "changed detail reports and keeps first_observed" `Quick
            test_changed_detail_reports_and_keeps_first_observed
        ; test_case "clear removes the row" `Quick test_clear_removes_the_row
        ; test_case "the projection reads the same table" `Quick
            test_snapshot_projection_is_the_same_table
        ] )
    ]
;;
