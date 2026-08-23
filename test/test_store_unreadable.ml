(** task-478: typed observation of currently-unreadable keeper stores.

    [Store_unreadable] is the server-side closed-variant registry that the
    dashboard "주의 필요" card projects.  This pins its contract: register
    dedups on identical (site, path, detail), updates on changed detail,
    clear removes, and the snapshot / yojson projection is stable. *)

open Alcotest
open Masc

let test_register_adds_entry () =
  Store_unreadable.reset ();
  let added = Store_unreadable.register ~site:"meta_read" ~path:"/a/b.json" ~detail:"boom" in
  check bool "first register reports new" true added;
  let snap = Store_unreadable.snapshot () in
  check int "one entry" 1 (List.length snap);
  let e = List.hd snap in
  check string "site" "meta_read" e.Store_unreadable.site;
  check string "path" "/a/b.json" e.Store_unreadable.path;
  check string "detail" "boom" e.Store_unreadable.detail;
  check bool "first_observed set" (e.Store_unreadable.first_observed > 0.) true
;;

let test_register_dedups_identical () =
  Store_unreadable.reset ();
  ignore (Store_unreadable.register ~site:"meta_read" ~path:"/a/b.json" ~detail:"boom");
  let again = Store_unreadable.register ~site:"meta_read" ~path:"/a/b.json" ~detail:"boom" in
  check bool "identical detail is not a new report" false again;
  check int "still one entry" 1 (List.length (Store_unreadable.snapshot ()))
;;

let test_register_updates_changed_detail () =
  Store_unreadable.reset ();
  ignore (Store_unreadable.register ~site:"meta_read" ~path:"/a/b.json" ~detail:"boom");
  let changed = Store_unreadable.register ~site:"meta_read" ~path:"/a/b.json" ~detail:"worse" in
  check bool "changed detail is a new report" true changed;
  let snap = Store_unreadable.snapshot () in
  check int "still one entry" 1 (List.length snap);
  check string "detail updated" "worse" (List.hd snap).Store_unreadable.detail
;;

let test_clear_removes () =
  Store_unreadable.reset ();
  ignore (Store_unreadable.register ~site:"meta_read" ~path:"/a/b.json" ~detail:"boom");
  Store_unreadable.clear ~site:"meta_read" ~path:"/a/b.json";
  check int "cleared" 0 (List.length (Store_unreadable.snapshot ()))
;;

let test_snapshot_to_yojson_shape () =
  Store_unreadable.reset ();
  ignore (Store_unreadable.register ~site:"keepalive_scan" ~path:"/k.json" ~detail:"corrupt");
  let json = Store_unreadable.snapshot_to_yojson () in
  match json with
  | `List [ `Assoc fields ] ->
    let get k = List.assoc_opt k fields in
    let str k =
      match get k with Some (`String s) -> Some s | _ -> None
    in
    check (option string) "site field" (Some "keepalive_scan") (str "site");
    check (option string) "path field" (Some "/k.json") (str "path");
    check (option string) "detail field" (Some "corrupt") (str "detail");
    check bool "first_observed present" (Option.is_some (get "first_observed")) true
  | _ -> fail "expected a list with one assoc object"
;;

let () =
  run "store_unreadable"
    [ ( "registry"
      , [ test_case "register adds entry" `Quick test_register_adds_entry
        ; test_case "register dedups identical" `Quick test_register_dedups_identical
        ; test_case "register updates changed detail" `Quick test_register_updates_changed_detail
        ; test_case "clear removes" `Quick test_clear_removes
        ; test_case "snapshot_to_yojson shape" `Quick test_snapshot_to_yojson_shape
        ] )
    ]
;;
