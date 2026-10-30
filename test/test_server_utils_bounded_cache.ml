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

let () =
  run "server_utils_bounded_cache"
    [ ( "evict_oldest_if_full"
      , [ test_case "no-op below cap" `Quick test_noop_below_cap
        ; test_case "evicts oldest at cap" `Quick test_evicts_oldest_at_cap
        ; test_case "stays bounded under churn" `Quick
            test_stays_bounded_under_churn
        ; test_case "empty cache no-op" `Quick test_empty_cache
        ] )
    ]
