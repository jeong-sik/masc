(** Tests for context.ml — cross-turn shared state *)

open Alcotest
open Agent_sdk

let check_backend label expected ctx =
  check bool label true (Context.concurrency_backend ctx = expected)
;;

let test_create_empty () =
  let ctx = Context.create_sync () in
  check (list string) "empty context has no keys" [] (Context.keys ctx)
;;

let test_set_get () =
  let ctx = Context.create_sync () in
  Context.set ctx "name" (`String "alice");
  let result = Context.get ctx "name" in
  check bool "key exists" true (result = Some (`String "alice"))
;;

let test_get_missing () =
  let ctx = Context.create_sync () in
  let result = Context.get ctx "missing" in
  check bool "missing key returns None" true (result = None)
;;

let test_set_overwrite () =
  let ctx = Context.create_sync () in
  Context.set ctx "count" (`Int 1);
  Context.set ctx "count" (`Int 2);
  let result = Context.get ctx "count" in
  check bool "overwrite works" true (result = Some (`Int 2))
;;

let test_delete () =
  let ctx = Context.create_sync () in
  Context.set ctx "count" (`Int 2);
  Context.delete ctx "count";
  check bool "delete removes key" true (Context.get ctx "count" = None)
;;

let test_keys () =
  let ctx = Context.create_sync () in
  Context.set ctx "a" (`String "1");
  Context.set ctx "b" (`String "2");
  let keys = List.sort String.compare (Context.keys ctx) in
  check (list string) "keys" [ "a"; "b" ] keys
;;

let test_merge () =
  let ctx = Context.create_sync () in
  Context.set ctx "existing" (`String "old");
  Context.merge ctx [ "existing", `String "new"; "added", `Int 42 ];
  check bool "merge overwrites" true (Context.get ctx "existing" = Some (`String "new"));
  check bool "merge adds" true (Context.get ctx "added" = Some (`Int 42))
;;

let test_scoped_helpers () =
  let ctx = Context.create_sync () in
  Context.set_scoped ctx Context.Session "trace_id" (`String "abc");
  Context.set_scoped ctx Context.User "theme" (`String "dark");
  check
    bool
    "scoped session get"
    true
    (Context.get_scoped ctx Context.Session "trace_id" = Some (`String "abc"));
  check
    bool
    "scoped user get"
    true
    (Context.get_scoped ctx Context.User "theme" = Some (`String "dark"));
  check
    (list string)
    "keys in session scope"
    [ "trace_id" ]
    (Context.keys_in_scope ctx Context.Session)
;;

let test_snapshot_sorted () =
  let ctx = Context.create_sync () in
  Context.set ctx "b" (`Int 2);
  Context.set ctx "a" (`Int 1);
  let snapshot = Context.snapshot ctx in
  check (list string) "snapshot sorted" [ "a"; "b" ] (List.map fst snapshot)
;;

let test_diff () =
  let before = Context.create_sync () in
  Context.set before "stable" (`String "x");
  Context.set before "removed" (`Int 1);
  Context.set before "changed" (`Int 1);
  let after = Context.copy before in
  Context.delete after "removed";
  Context.set after "changed" (`Int 2);
  Context.set after "added" (`Bool true);
  let diff = Context.diff before after in
  check (list string) "removed" [ "removed" ] diff.removed;
  check (list string) "added keys" [ "added" ] (List.map fst diff.added);
  check (list string) "changed keys" [ "changed" ] (List.map fst diff.changed)
;;

let test_diff_interleaved_order () =
  let before = Context.create_sync () in
  List.iter
    (fun (key, value) -> Context.set before key value)
    [ "a", `Int 1; "c", `Int 1; "e", `Int 1; "g", `Int 1 ];
  let after = Context.create_sync () in
  List.iter
    (fun (key, value) -> Context.set after key value)
    [ "b", `Int 2; "c", `Int 3; "d", `Int 4; "g", `Int 1 ];
  let diff = Context.diff before after in
  check (list string) "added keys" [ "b"; "d" ] (List.map fst diff.added);
  check (list string) "removed keys" [ "a"; "e" ] diff.removed;
  check (list string) "changed keys" [ "c" ] (List.map fst diff.changed);
  check
    (list (pair string int))
    "changed values"
    [ "c", 3 ]
    (List.map
       (fun (key, value) ->
          match value with
          | `Int n -> key, n
          | _ -> fail "expected int diff value")
       diff.changed)
;;

let test_diff_sorted () =
  let before = Context.create_sync () in
  List.iter
    (fun key -> Context.set before key (`String ("before-" ^ key)))
    [ "removed-b"; "stable"; "changed-b"; "removed-a"; "changed-a" ];
  let after = Context.copy before in
  Context.delete after "removed-b";
  Context.delete after "removed-a";
  Context.set after "changed-b" (`String "after-b");
  Context.set after "changed-a" (`String "after-a");
  Context.set after "added-b" (`String "b");
  Context.set after "added-a" (`String "a");
  let diff = Context.diff before after in
  check (list string) "removed sorted" [ "removed-a"; "removed-b" ] diff.removed;
  check (list string) "added sorted" [ "added-a"; "added-b" ] (List.map fst diff.added);
  check
    (list string)
    "changed sorted"
    [ "changed-a"; "changed-b" ]
    (List.map fst diff.changed)
;;

let test_to_json () =
  let ctx = Context.create_sync () in
  Context.set ctx "key" (`String "value");
  let json = Context.to_json ctx in
  match json with
  | `Assoc pairs ->
    check bool "has key" true (List.assoc_opt "key" pairs = Some (`String "value"))
  | _ -> fail "to_json should return Assoc"
;;

let test_of_json_roundtrip () =
  let json = `Assoc [ "x", `Int 10; "y", `String "hello" ] in
  let ctx = Context.of_json json in
  check bool "x restored" true (Context.get ctx "x" = Some (`Int 10));
  check bool "y restored" true (Context.get ctx "y" = Some (`String "hello"))
;;

let test_of_json_non_assoc () =
  check_raises
    "non-Assoc rejected"
    (Invalid_argument "Context.of_json: expected JSON object")
    (fun () -> ignore (Context.of_json (`String "invalid") : Context.t))
;;

let test_of_json_eio_backend () =
  Eio_main.run
  @@ fun _env ->
  let ctx = Context.of_json ~eio:true (`Assoc [ "x", `Int 1 ]) in
  check_backend "eio backend" Context.Eio_mutex ctx;
  check bool "value restored" true (Context.get ctx "x" = Some (`Int 1))
;;

let test_copy_empty () =
  let ctx = Context.create_sync () in
  let copy = Context.copy ctx in
  check (list string) "copy of empty is empty" [] (Context.keys copy)
;;

let test_copy_values () =
  let ctx = Context.create_sync () in
  Context.set ctx "a" (`String "hello");
  Context.set ctx "b" (`Int 99);
  let copy = Context.copy ctx in
  check bool "a copied" true (Context.get copy "a" = Some (`String "hello"));
  check bool "b copied" true (Context.get copy "b" = Some (`Int 99))
;;

let test_copy_independence () =
  let ctx = Context.create_sync () in
  Context.set ctx "x" (`String "original");
  let copy = Context.copy ctx in
  Context.set copy "x" (`String "modified");
  check bool "original unchanged" true (Context.get ctx "x" = Some (`String "original"))
;;

let test_copy_backend_override () =
  Eio_main.run
  @@ fun _env ->
  let ctx = Context.create_sync () in
  Context.set ctx "x" (`String "value");
  let eio_copy = Context.copy ~eio:true ctx in
  check_backend "copy override to eio" Context.Eio_mutex eio_copy;
  check bool "value copied" true (Context.get eio_copy "x" = Some (`String "value"));
  let stdlib_copy = Context.copy ~eio:false eio_copy in
  check_backend "copy override to stdlib" Context.Stdlib_mutex stdlib_copy
;;

let test_scope_inherits_parent_backend () =
  Eio_main.run
  @@ fun _env ->
  let parent = Context.create () in
  Context.set parent "k" (`String "v");
  let scope =
    Context.create_scope ~parent ~propagate_down:[ "k" ] ~propagate_up:[ "result" ]
  in
  check_backend "scope local inherits eio" Context.Eio_mutex scope.local;
  check
    bool
    "propagate_down copied"
    true
    (Context.get scope.local "k" = Some (`String "v"))
;;

let () =
  run
    "Context"
    [ "create", [ test_case "empty" `Quick test_create_empty ]
    ; ( "get_set"
      , [ test_case "set and get" `Quick test_set_get
        ; test_case "get missing" `Quick test_get_missing
        ; test_case "overwrite" `Quick test_set_overwrite
        ; test_case "delete" `Quick test_delete
        ] )
    ; ( "keys"
      , [ test_case "keys" `Quick test_keys
        ; test_case "snapshot sorted" `Quick test_snapshot_sorted
        ] )
    ; "merge", [ test_case "merge" `Quick test_merge ]
    ; ( "scope"
      , [ test_case "scoped helpers" `Quick test_scoped_helpers
        ; test_case "diff" `Quick test_diff
        ; test_case "diff interleaved order" `Quick test_diff_interleaved_order
        ; test_case "diff sorted" `Quick test_diff_sorted
        ] )
    ; ( "json"
      , [ test_case "to_json" `Quick test_to_json
        ; test_case "of_json roundtrip" `Quick test_of_json_roundtrip
        ; test_case "of_json non-Assoc" `Quick test_of_json_non_assoc
        ; test_case "of_json eio backend" `Quick test_of_json_eio_backend
        ] )
    ; ( "copy"
      , [ test_case "copy empty" `Quick test_copy_empty
        ; test_case "copy values" `Quick test_copy_values
        ; test_case "copy independence" `Quick test_copy_independence
        ; test_case "copy backend override" `Quick test_copy_backend_override
        ; test_case
            "scope inherits parent backend"
            `Quick
            test_scope_inherits_parent_backend
        ] )
    ; ( "user_data"
      , [ test_case "set and get" `Quick (fun () ->
            let ctx = Context.create_sync () in
            Context.set_user_data ctx "name" (`String "alice");
            let actual = Context.get_user_data ctx "name" in
            check bool "get returns value" true (actual = Some (`String "alice")))
        ; test_case "stored with user: prefix" `Quick (fun () ->
            let ctx = Context.create_sync () in
            Context.set_user_data ctx "role" (`String "admin");
            let raw = Context.get ctx "user:role" in
            check bool "raw key has prefix" true (raw = Some (`String "admin")))
        ; test_case "all_user_data" `Quick (fun () ->
            let ctx = Context.create_sync () in
            Context.set_user_data ctx "a" (`Int 1);
            Context.set_user_data ctx "b" (`Int 2);
            Context.set_scoped ctx Context.Session "c" (`Int 3);
            let ud = Context.all_user_data ctx in
            check int "only user keys" 2 (List.length ud);
            check bool "has a" true (List.assoc_opt "a" ud = Some (`Int 1));
            check bool "has b" true (List.assoc_opt "b" ud = Some (`Int 2)))
        ; test_case "delete_user_data" `Quick (fun () ->
            let ctx = Context.create_sync () in
            Context.set_user_data ctx "x" (`Bool true);
            Context.delete_user_data ctx "x";
            check bool "deleted" true (Context.get_user_data ctx "x" = None))
        ] )
    ]
;;
