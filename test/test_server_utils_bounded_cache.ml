(** Tests for [Server_utils.evict_oldest_if_full] — the bound that keeps
    client-keyed dashboard caches from growing without limit. *)

open Alcotest

(* Values are their own age, so [~age_of:Fun.id] makes the smallest float the
   "oldest" entry. *)
let age_of = Fun.id

let test_noop_below_cap () =
  let cache = Hashtbl.create 8 in
  Hashtbl.replace cache "a" 1.0;
  Hashtbl.replace cache "b" 2.0;
  Masc.Server_utils.evict_oldest_if_full ~max_entries:10 ~age_of cache;
  check int "no eviction below cap" 2 (Hashtbl.length cache);
  check bool "a kept" true (Hashtbl.mem cache "a");
  check bool "b kept" true (Hashtbl.mem cache "b")

let test_evicts_oldest_at_cap () =
  let cache = Hashtbl.create 8 in
  Hashtbl.replace cache "a" 10.0;
  Hashtbl.replace cache "b" 20.0;
  Hashtbl.replace cache "c" 30.0;
  Hashtbl.replace cache "d" 40.0;
  (* length (4) >= max_entries (4): evict the smallest-age entry ("a"). *)
  Masc.Server_utils.evict_oldest_if_full ~max_entries:4 ~age_of cache;
  check int "one entry evicted at cap" 3 (Hashtbl.length cache);
  check bool "oldest (a) removed" false (Hashtbl.mem cache "a");
  check bool "newest (d) kept" true (Hashtbl.mem cache "d");
  check bool "b kept" true (Hashtbl.mem cache "b");
  check bool "c kept" true (Hashtbl.mem cache "c")

(* Insert-on-miss with eviction-before-insert keeps the table at the cap no
   matter how many distinct keys arrive — the unbounded-growth scenario. *)
let test_stays_bounded_under_churn () =
  let cache = Hashtbl.create 8 in
  let max_entries = 16 in
  for i = 1 to max_entries + 500 do
    Masc.Server_utils.evict_oldest_if_full ~max_entries ~age_of cache;
    Hashtbl.replace cache (string_of_int i) (float_of_int i)
  done;
  check bool "bounded at or below cap" true
    (Hashtbl.length cache <= max_entries);
  (* The survivors are the most-recently-inserted keys (highest ages). *)
  check bool "latest key present" true
    (Hashtbl.mem cache (string_of_int (max_entries + 500)));
  check bool "earliest key evicted" false (Hashtbl.mem cache "1")

let test_empty_cache () =
  let cache : (string, float) Hashtbl.t = Hashtbl.create 8 in
  Masc.Server_utils.evict_oldest_if_full ~max_entries:4 ~age_of cache;
  check int "empty stays empty" 0 (Hashtbl.length cache)

let make_req target =
  Httpun.Request.create `GET target

let test_query_param_target () =
  let check_opt = Alcotest.(check (option string)) in
  let req_clean = make_req "/api/v1/keepers" in
  check_opt "no query param" None (Masc.Server_utils.query_param req_clean "limit");

  let req_params = make_req "/api/v1/keepers?limit=50&offset=100&flag&empty=" in
  check_opt "limit" (Some "50") (Masc.Server_utils.query_param req_params "limit");
  check_opt "offset" (Some "100") (Masc.Server_utils.query_param req_params "offset");
  check_opt "flag bare" (Some "") (Masc.Server_utils.query_param req_params "flag");
  check_opt "empty" (Some "") (Masc.Server_utils.query_param req_params "empty");
  check_opt "missing" None (Masc.Server_utils.query_param req_params "other");

  let req_encoded = make_req "/search?q=hello%20world%21&cat=a%2Bb" in
  check_opt "encoded space and bang" (Some "hello world!") (Masc.Server_utils.query_param req_encoded "q");
  check_opt "encoded plus" (Some "a+b") (Masc.Server_utils.query_param req_encoded "cat");

  check_opt "from target direct" (Some "50") (Masc.Server_utils.query_param_from_target "/foo?limit=50" "limit")

let test_typed_query_params () =
  let req = make_req "/api?limit=50&bad_int=foo&enabled=true&disabled=0&unknown=maybe" in
  check int "int param valid" 50 (Masc.Server_utils.int_query_param req "limit" ~default:10);
  check int "int param invalid" 10 (Masc.Server_utils.int_query_param req "bad_int" ~default:10);
  check int "int param missing" 10 (Masc.Server_utils.int_query_param req "missing" ~default:10);

  check bool "bool param true" true (Masc.Server_utils.bool_query_param req "enabled" ~default:false);
  check bool "bool param false" false (Masc.Server_utils.bool_query_param req "disabled" ~default:true);
  check bool "bool param fallback" true (Masc.Server_utils.bool_query_param req "unknown" ~default:true)

let () =
  run "server_utils_bounded_cache"
    [ ( "evict_oldest_if_full"
      , [ test_case "no-op below cap" `Quick test_noop_below_cap
        ; test_case "evicts oldest at cap" `Quick test_evicts_oldest_at_cap
        ; test_case "stays bounded under churn" `Quick
            test_stays_bounded_under_churn
        ; test_case "empty cache no-op" `Quick test_empty_cache
        ] )
    ; ( "query_param"
      , [ test_case "query param target extraction" `Quick test_query_param_target
        ; test_case "typed query params" `Quick test_typed_query_params
        ] )
    ]
